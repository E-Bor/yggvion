part of 'sync.dart';

extension EncryptedSync on SyncService {
  bool get encrypted => _cipher != null;
  String? get encryptionKeyId => _requiredKeyId ?? _cipher?.id;
  bool get needsEncryptionKey =>
      _requiredKeyId != null && _cipher?.id != _requiredKeyId;

  Future<WorkspaceKey> prepareWorkspaceKey() async {
    final id = await repo.db.meta('workspace_key_id');
    if (id == null) throw const PasswordRequired();
    _password = PasswordConfig.fromEncoded(
      await repo.db.meta(PasswordConfig.storageKey(id)),
    );
    if (_password == null) {
      throw StateError('Прежний формат шифрования не поддерживается');
    }
    if (_cipher?.id == id) {
      _password!.verify(_cipher!);
      return _cipher!;
    }
    _requiredKeyId = id;
    final password = await credentials.read(key: 'password_$id');
    if (password == null) throw const PasswordRequired();
    _cipher = await _password!.unlock(password);
    return _cipher!;
  }

  bool get passwordConfigured => _password != null;

  Future<void> unlockWithPassword(String password) async {
    if (_busy || _pairing) {
      throw StateError('Дождитесь завершения синхронизации');
    }
    _busy = true;
    try {
      if (connected) {
        final state = await request('GET', '/api/v1/state');
        if (state['protocol'] != 6) {
          throw StateError('Нужна новая версия сервера');
        }
        final raw = state['password_config'];
        if (raw is! Map<String, dynamic>) {
          throw StateError('На сервере ещё не настроен пароль шифрования');
        }
        _password = PasswordConfig.fromJson(raw);
        if (_password!.keyId != state['encryption_key_id']) {
          throw const FormatException('Некорректные параметры шифрования');
        }
      } else {
        final id = await repo.db.meta('workspace_key_id');
        _password = id == null
            ? null
            : PasswordConfig.fromEncoded(
                await repo.db.meta(PasswordConfig.storageKey(id)),
              );
      }
      if (_password == null) {
        throw StateError('Сначала подключитесь к серверу или выберите копию');
      }
      final key = await _password!.unlock(password);
      await _rememberPassword(_password!, password, key);
      repo.syncError = null;
    } finally {
      _busy = false;
      repo.publish();
    }
    if (connected) await sync();
  }

  Future<void> setEncryptionPassword(
    String password, {
    String? currentPassword,
  }) async {
    if (_busy || _pairing) {
      throw StateError('Дождитесь завершения синхронизации');
    }
    PasswordConfig.validatePassword(password, creating: true);
    _busy = true;
    try {
      final stored = await repo.db.meta('workspace_key_id');
      final current = stored == null
          ? null
          : PasswordConfig.fromEncoded(
              await repo.db.meta(PasswordConfig.storageKey(stored)),
            );
      if (stored != null && current == null) {
        throw StateError('Прежний формат шифрования не поддерживается');
      }
      if (current != null) {
        if (currentPassword == null) {
          throw const FormatException('Введите текущий пароль');
        }
        _cipher = await current.unlock(currentPassword);
        _password = current;
      }
      if (connected && current != null) {
        _busy = false;
        await sync();
        _busy = true;
        if (repo.syncError != null) throw StateError(repo.syncError!);
      }
      Map<String, dynamic>? state;
      if (connected) {
        state = await request('GET', '/api/v1/state');
        if (state['protocol'] != 6) {
          throw StateError('Нужна новая версия сервера');
        }
        if ((state['encryption_key_id'] as String).isNotEmpty) {
          if (current == null || state['encryption_key_id'] != current.keyId) {
            throw StateError(
              'Сначала введите пароль существующего пространства',
            );
          }
        }
      }
      final config = await PasswordConfig.create(password);
      final key = await config.unlock(password);
      if (state != null && (state['encryption_key_id'] as String).isNotEmpty) {
        // Persist the user's new password before committing remotely. A lost reply
        // is recovered from /state using this local value after an app restart.
        await credentials.write(key: 'password_${key.id}', value: password);
        await repo.db.setMeta(
          PasswordConfig.storageKey(key.id),
          config.encoded,
        );
        await _rotatePassword(config, key);
      }
      await _rememberPassword(config, password, key);
    } finally {
      _busy = false;
      repo.publish();
    }
    if (connected) await sync();
  }

  Future<void> _rotatePassword(PasswordConfig config, WorkspaceKey key) async {
    final snapshot = await request('GET', '/api/v1/snapshot');
    final records = <Entity>[];
    for (final raw in snapshot['records'] as List) {
      records.add(await _decodeRecord(raw as Map<String, dynamic>));
    }
    await _downloadEncryptedFiles(records: records);
    await _uploadEncryptedFiles(key: key, rekeyFrom: _cipher!.id);
    final encrypted = <Map<String, dynamic>>[];
    for (final record in records) {
      encrypted.add(
        (await key.encrypt(
          record,
          await _attachmentMap(record, key: key),
        )).toJson(),
      );
    }
    await client.put<Object?>(
      '$_url/api/v1/encryption/password',
      options: Options(
        headers: authHeaders,
        sendTimeout: const Duration(minutes: 15),
        receiveTimeout: const Duration(minutes: 15),
      ),
      data: {
        'key_id': _cipher!.id,
        'cursor': snapshot['cursor'],
        'password_config': config.value,
        'records': encrypted,
      },
    );
  }

  Future<void> _rememberPassword(
    PasswordConfig config,
    String password,
    WorkspaceKey key,
  ) async {
    config.verify(key);
    await repo.db.transaction(() async {
      final old = await repo.db.meta('workspace_key_id');
      await credentials.write(key: 'password_${key.id}', value: password);
      await repo.db.setMeta(PasswordConfig.storageKey(key.id), config.encoded);
      await repo.db.setMeta('workspace_key_id', key.id);
      if (old != key.id) {
        await repo.db.customStatement('DELETE FROM encrypted_outbox');
        if (old != null) await credentials.delete(key: 'password_$old');
      }
    });
    _cipher = key;
    _password = config;
    _requiredKeyId = key.id;
  }

  Future<Map<String, dynamic>> _checkEncryption(
    Map<String, dynamic> state,
  ) async {
    if (state['e2ee'] != true || state['protocol'] != 6) {
      throw StateError('Нужна новая версия сервера с парольным шифрованием');
    }
    var keyId = state['encryption_key_id'] as String;
    if (keyId.isEmpty) {
      if (await repo.db.meta('encrypted_server_key_id') != null) {
        throw StateError('Сервер потерял настройки шифрования');
      }
      final key = await prepareWorkspaceKey();
      await client.post<Object?>(
        '$_url/api/v1/encryption',
        options: Options(
          headers: {
            ...authHeaders,
            'X-Yggvion-Generation': state['generation'],
          },
        ),
        data: {'key_id': key.id, 'password_config': _password!.value},
      );
      state = await request('GET', '/api/v1/state');
      keyId = state['encryption_key_id'] as String;
      _generation = state['generation'] as String;
      await repo.db.setMeta('server_generation', _generation!);
    }
    final config = PasswordConfig.fromJson(
      state['password_config'] as Map<String, dynamic>,
    );
    if (config.keyId != keyId) {
      throw const FormatException('Повреждены параметры шифрования');
    }
    _password = config;
    _requiredKeyId = keyId;
    final password = await credentials.read(key: 'password_$keyId');
    if (password == null) {
      _cipher = null;
      throw StateError('Введите пароль в разделе «Шифрование» в настройках');
    }
    final key = _cipher?.id == keyId ? _cipher! : await config.unlock(password);
    config.verify(key);
    await _rememberPassword(config, password, key);
    final pinned = await repo.db.meta('encrypted_server_key_id');
    if (_generation == null && pinned == null) {
      _generation = state['generation'] as String;
      await repo.db.setMeta('server_generation', _generation!);
    }
    await repo.db.setMeta('encrypted_server_key_id', keyId);
    return state;
  }

  Future<Map<String, String>> _attachmentMap(
    Entity entity, {
    WorkspaceKey? key,
  }) async {
    key ??= _cipher!;
    final result = <String, String>{};
    for (final match in RegExp(
      r'attachment:([a-f0-9]{64})',
    ).allMatches(jsonEncode(entity.data))) {
      final id = match[1]!;
      final row = await repo.db
          .customSelect(
            'SELECT cipher_id FROM encrypted_files WHERE key_id=? AND id=?',
            variables: [Variable(key.id), Variable(id)],
          )
          .getSingleOrNull();
      if (row == null) {
        throw StateError('Вложение ещё не подготовлено для E2EE');
      }
      result[id] = row.read<String>('cipher_id');
    }
    return result;
  }

  Future<Map<String, dynamic>> _encodeMutation(QueryRow row) async {
    final operation = row.read<String>('operation_id');
    final source = row.read<String>('payload');
    final fingerprint = sha256
        .convert(utf8.encode('${_cipher!.id}:$source'))
        .toString();
    final cached = await repo.db
        .customSelect(
          'SELECT source,payload FROM encrypted_outbox WHERE operation_id=?',
          variables: [Variable(operation)],
        )
        .getSingleOrNull();
    String encoded;
    if (cached != null && cached.read<String>('source') == fingerprint) {
      encoded = cached.read<String>('payload');
    } else {
      final local = Entity.fromJson(jsonDecode(source) as Map<String, dynamic>);
      final wire = await _cipher!.encrypt(local, await _attachmentMap(local));
      encoded = wire.encoded;
      await repo.db.customStatement(
        'INSERT OR REPLACE INTO encrypted_outbox VALUES(?,?,?)',
        [operation, fingerprint, encoded],
      );
    }
    return {'operation_id': operation, 'record': jsonDecode(encoded)};
  }

  Future<Entity> _decodeRecord(Map<String, dynamic> raw) async {
    final result = await _cipher!.decrypt(Entity.fromJson(raw));
    for (final entry in result.attachments.entries) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value)) {
        throw const FormatException('Неверный идентификатор вложения');
      }
      await repo.db.customStatement(
        'INSERT OR REPLACE INTO encrypted_files VALUES(?,?,?)',
        [_cipher!.id, entry.key, entry.value],
      );
    }
    return result.record;
  }

  Future<void> _uploadEncryptedFiles({
    WorkspaceKey? key,
    String? rekeyFrom,
  }) async {
    final cipher = key ?? _cipher!;
    final rows = await repo.db
        .customSelect(
          'SELECT f.*,e.cipher_id FROM files f LEFT JOIN encrypted_files e ON e.id=f.id AND e.key_id=?',
          variables: [Variable(cipher.id)],
        )
        .get();
    for (final row in rows) {
      if (row.readNullable<String>('cipher_id') != null &&
          row.read<int>('uploaded') == 1) {
        continue;
      }
      final id = row.read<String>('id');
      final source = File(row.read<String>('path'));
      if (!await source.exists()) {
        throw StateError('Недоступно вложение для шифрования');
      }
      if ((await sha256.bind(source.openRead()).first).toString() != id) {
        throw StateError('Вложение повреждено');
      }
      final temp = await Directory.systemTemp.createTemp('yggvion-encrypted-');
      try {
        final file = File(p.join(temp.path, 'blob'));
        await cipher.encryptFile(source, file, 'attachment:$id');
        final cipherId = (await sha256.bind(file.openRead()).first).toString();
        await client.put<Object?>(
          '$_url/api/v1/attachments/$cipherId',
          data: file.openRead(),
          options: Options(
            sendTimeout: const Duration(minutes: 15),
            headers: {
              ...authHeaders,
              "X-Yggvion-Rekey-From": ?rekeyFrom,
              'Content-Type': 'application/octet-stream',
              'Content-Length': await file.length(),
              'X-Yggvion-Encryption': cipher.id,
            },
          ),
        );
        await repo.db.transaction(() async {
          await repo.db.customStatement(
            'INSERT OR REPLACE INTO encrypted_files VALUES(?,?,?)',
            [cipher.id, id, cipherId],
          );
          await repo.db.customStatement(
            'UPDATE files SET uploaded=1 WHERE id=?',
            [id],
          );
        });
      } finally {
        await temp.delete(recursive: true);
      }
    }
  }

  Future<void> _downloadEncryptedFiles({List<Entity>? records}) async {
    final entities = records ?? await repo.db.entities();
    final names = <String, String>{};
    for (final entity in entities) {
      for (final match in RegExp(
        r'\[([^\]]*)\]\(attachment:([a-f0-9]{64})\)',
      ).allMatches(entity.searchable)) {
        names[match[2]!] = match[1]!;
      }
    }
    final ids = entities
        .expand(
          (e) => RegExp(
            r'attachment:([a-f0-9]{64})',
          ).allMatches(e.searchable).map((m) => m[1]!),
        )
        .toSet();
    for (final id in ids) {
      if (await repo.attachmentPath(id) != null) continue;
      final row = await repo.db
          .customSelect(
            'SELECT cipher_id FROM encrypted_files WHERE key_id=? AND id=?',
            variables: [Variable(_cipher!.id), Variable(id)],
          )
          .getSingleOrNull();
      if (row == null) throw StateError('Нет шифрованного вложения в записи');
      final cipherId = row.read<String>('cipher_id');
      final dir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'attachments'),
      );
      await dir.create(recursive: true);
      final name = names[id] ?? id;
      final extension = p.extension(name).toLowerCase();
      final target = File(
        p.join(
          dir.path,
          '$id${RegExp(r"^\.[a-z0-9]{1,12}$").hasMatch(extension) ? extension : ""}',
        ),
      );
      final encrypted = File('${target.path}.cipher.part');
      final plain = File('${target.path}.part');
      try {
        await downloadLimitedFile(
          client,
          '$_url/api/v1/attachments/$cipherId',
          encrypted,
          maximumBytes: maxEncryptedAttachmentBytes,
          options: _auth,
        );
        if ((await sha256.bind(encrypted.openRead()).first).toString() !=
            cipherId) {
          throw StateError('Повреждено шифрованное вложение');
        }
        await _cipher!.decryptFile(encrypted, plain, 'attachment:$id');
        if ((await sha256.bind(plain.openRead()).first).toString() != id) {
          throw StateError('Контрольная сумма вложения не совпадает');
        }
        await plain.rename(target.path);
        await repo.db.customStatement(
          'INSERT INTO files(id,name,path,uploaded) VALUES(?,?,?,1) ON CONFLICT(id) DO NOTHING',
          [id, name, target.path],
        );
      } finally {
        if (await encrypted.exists()) await encrypted.delete();
        if (await plain.exists()) await plain.delete();
      }
    }
  }

  Map<String, dynamic> _availability(
    DateTime start,
    DateTime end,
    String zone,
  ) {
    final ranges = <TimeRange>[];
    for (final b in repo.snapshot.blocks) {
      final task = repo.snapshot.task(b.taskId);
      if (task == null ||
          task.isBirthday ||
          b.historical ||
          !b.end.isAfter(start) ||
          !b.start.isBefore(end)) {
        continue;
      }
      ranges.add(
        TimeRange(
          b.start.isBefore(start) ? start : b.start,
          b.end.isAfter(end) ? end : b.end,
        ),
      );
    }
    return {
      'timezone': zone,
      'busy': unionRanges(ranges)
          .map((r) => {'start': wireTime(r.start), 'end': wireTime(r.end)})
          .toList(),
    };
  }

  Future<void> _refreshAvailability() async {
    final result = await request('GET', '/api/v1/calendar-shares');
    for (final raw in result['shares'] as List) {
      final share = raw as Map<String, dynamic>;
      final snapshot = _availability(
        DateTime.parse(share['start'] as String),
        DateTime.parse(share['end'] as String),
        share['timezone'] as String,
      );
      await request(
        'PUT',
        '/api/v1/calendar-shares/${share['id']}/availability',
        data: snapshot,
      );
    }
  }

  Future<bool> _receiveGuestProposals() async {
    final result = await request('GET', '/api/v1/guest-proposals');
    final proposals = <Entity>[];
    for (final raw in result['records'] as List) {
      final candidate = Entity.fromJson(raw as Map<String, dynamic>);
      final data = candidate.data, proposal = data['proposal'];
      final title = data['title'], description = data['description'] ?? '';
      if (candidate.kind != 'task' ||
          !RegExp(r'^guest_[a-f0-9]{64}$').hasMatch(candidate.id) ||
          candidate.deleted ||
          candidate.version != 0 ||
          proposal is! Map ||
          title is! String ||
          description is! String ||
          title.trim().isEmpty ||
          title.runes.length > 200 ||
          title.contains(RegExp(r'[\r\n]')) ||
          utf8.encode(description).length > 8000) {
        throw const FormatException('Неверное предложение события');
      }
      final start = DateTime.tryParse(proposal['start'] as String? ?? '');
      final end = DateTime.tryParse(proposal['end'] as String? ?? '');
      final zone = proposal['timezone'] as String? ?? '';
      if (start == null ||
          end == null ||
          !end.isAfter(start) ||
          end.difference(start) > const Duration(days: 1)) {
        throw const FormatException('Неверное время предложения');
      }
      tz.getLocation(zone);
      if (await repo.db.entity(candidate.id) == null) {
        proposals.add(
          Task.create(
            candidate.id,
            title.trim().replaceAll(
              RegExp('attachment:', caseSensitive: false),
              'attachment∶',
            ),
            // Older servers may still return guest-supplied internal URLs.
            // Keep the text readable, but never import guest file references.
            description: description.replaceAll(
              RegExp('attachment:', caseSensitive: false),
              'attachment∶',
            ),
          ).change({
            'proposal': {
              'pending': true,
              'start': wireTime(start),
              'end': wireTime(end),
              'timezone': zone,
            },
          }),
        );
      }
    }
    if (proposals.isNotEmpty) {
      await repo.commitComputed(
        () async => [
          for (final candidate in proposals)
            if (await repo.db.entity(candidate.id) == null) candidate,
        ],
      );
    }
    return proposals.isNotEmpty;
  }
}
