part of 'sync.dart';

extension EncryptedSync on SyncService {
  bool get encrypted => _cipher != null;
  String? get encryptionKeyId => _requiredKeyId ?? _cipher?.id;
  bool get needsEncryptionKey =>
      _requiredKeyId != null && _cipher?.id != _requiredKeyId;

  Future<WorkspaceKey> prepareWorkspaceKey() => repo.serial(() async {
    final stored = await repo.db.meta('workspace_key_id');
    final key = stored == null
        ? WorkspaceKey.generate()
        : (_cipher?.id == stored
              ? _cipher
              : await WorkspaceKey.load(stored, secure));
    if (key == null) {
      _requiredKeyId = stored;
      _cipher = null;
      _password = PasswordEnvelope.fromEncoded(
        await repo.db.meta(PasswordEnvelope.storageKey(stored!)),
      );
      throw StateError('Введите пароль шифрования для восстановления доступа');
    }
    if (stored == null) {
      await key.save(secure);
      await repo.db.setMeta('workspace_key_id', key.id);
    }
    _cipher = key;
    _password = PasswordEnvelope.fromEncoded(
      await repo.db.meta(PasswordEnvelope.storageKey(key.id)),
    );
    _password?.verify(key);
    if (_password == null) {
      final cached = await repo.db
          .customSelect(
            'SELECT (SELECT count(*) FROM encrypted_outbox) + (SELECT count(*) FROM encrypted_files) AS count',
          )
          .getSingle();
      if (cached.read<int>('count') > 0 ||
          await repo.db.meta('encrypted_server_key_id') != null) {
        throw StateError(
          'Данные прежнего формата E2EE не поддерживаются. Перенос не предусмотрен.',
        );
      }
    }
    return key;
  });

  bool get passwordConfigured => _password != null;

  Future<void> unlockWithPassword(String password) async {
    if (_busy || _pairing) {
      throw StateError('Дождитесь завершения синхронизации');
    }
    _busy = true;
    try {
      if (connected) {
        final state = await request('GET', '/api/v1/state');
        final raw = state['password_envelope'];
        if (raw is! Map<String, dynamic>) {
          throw StateError('На сервере ещё не настроен пароль шифрования');
        }
        _password = PasswordEnvelope.fromJson(raw);
        if (_password!.keyId != state['encryption_key_id']) {
          throw const FormatException('Неверная защита паролем');
        }
      }
      if (_password == null) {
        throw StateError(
          'Сначала подключитесь к серверу или выберите резервную копию',
        );
      }
      final pinned = await repo.db.meta('encrypted_server_key_id');
      if (connected && pinned != null && pinned != _password!.keyId) {
        throw StateError(
          'Изменился ключ сервера. Переподключитесь с доверенного устройства',
        );
      }
      final key = await _password!.unlock(password);
      final cached = PasswordEnvelope.fromEncoded(
        await repo.db.meta(PasswordEnvelope.storageKey(key.id)),
      );
      if (cached != null && cached.revision > _password!.revision) {
        throw StateError('Сервер вернул устаревшую защиту паролем');
      }
      await key.save(secure);
      await repo.db.setMeta('workspace_key_id', key.id);
      await repo.db.setMeta(
        PasswordEnvelope.storageKey(key.id),
        _password!.encoded,
      );
      _cipher = key;
      _requiredKeyId = key.id;
      if (!connected) {
        repo.syncError = null;
        repo.syncStatus = 'Локально';
      }
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
    PasswordEnvelope.validatePassword(password, creating: true);
    _busy = true;
    try {
      final key = await prepareWorkspaceKey();
      Map<String, dynamic>? state;
      var current = _password;
      if (connected) {
        state = await request('GET', '/api/v1/state');
        if (state['protocol'] != 5) {
          throw StateError('Обновите сервер для защиты паролем');
        }
        final serverKey = state['encryption_key_id'] as String? ?? '';
        if (serverKey.isNotEmpty && serverKey != key.id) {
          throw StateError('Сначала введите пароль существующего пространства');
        }
        if (serverKey.isNotEmpty &&
            state['password_envelope'] is! Map<String, dynamic>) {
          throw StateError(
            'Пространство без парольного E2EE не поддерживается. Создайте новое.',
          );
        }
        if (state['password_envelope'] case final Map<String, dynamic> raw) {
          current = PasswordEnvelope.fromJson(raw);
          current.verify(key);
        }
      }
      if (current != null) {
        if (currentPassword == null) {
          throw const FormatException('Введите текущий пароль');
        }
        final unlocked = await current.unlock(currentPassword);
        if (unlocked.id != key.id) {
          throw const FormatException('Неверный текущий пароль');
        }
      }
      final next = await PasswordEnvelope.create(
        key,
        password,
        revision: (current?.revision ?? 0) + 1,
      );
      if (state != null &&
          (state['encryption_key_id'] as String? ?? '').isNotEmpty) {
        // Durable retry: losing a successful HTTP response cannot lose the new password wrapping.
        await repo.db.setMeta('pending_password_${key.id}', next.encoded);
        await _flushPassword(state, key);
      } else {
        await repo.db.setMeta(
          PasswordEnvelope.storageKey(key.id),
          next.encoded,
        );
        _password = next;
      }
    } finally {
      _busy = false;
      repo.publish();
    }
    if (connected) await sync();
  }

  Future<Map<String, dynamic>> _flushPassword(
    Map<String, dynamic> state,
    WorkspaceKey key,
  ) async {
    final pending = PasswordEnvelope.fromEncoded(
      await repo.db.meta('pending_password_${key.id}'),
    );
    if (pending == null) return state;
    pending.verify(key);
    final remote = state['password_envelope'] is Map<String, dynamic>
        ? PasswordEnvelope.fromJson(
            state['password_envelope'] as Map<String, dynamic>,
          )
        : null;
    if (remote == null) {
      throw StateError(
        "Сервер не поддерживает парольное шифрование. Нужна чистая установка.",
      );
    }
    remote.verify(key);
    if (!const DeepCollectionEquality().equals(remote.value, pending.value)) {
      if (remote.revision != pending.revision - 1) {
        await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
          'pending_password_${key.id}',
        ]);
        throw StateError(
          'Пароль изменён на другом устройстве. Обновите синхронизацию и повторите смену.',
        );
      }
      await client.put<Object?>(
        '$_url/api/v1/encryption/password',
        options: Options(
          headers: {
            ...authHeaders,
            'X-Yggvion-Generation': state['generation'],
          },
        ),
        data: {
          'key_id': key.id,
          'expected_revision': pending.revision - 1,
          'password_envelope': pending.value,
        },
      );
      state = {...state, 'password_envelope': pending.value};
    }
    await repo.db.transaction(() async {
      await repo.db.setMeta(
        PasswordEnvelope.storageKey(key.id),
        pending.encoded,
      );
      await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
        'pending_password_${key.id}',
      ]);
    });
    _password = pending;
    return state;
  }

  Future<Map<String, dynamic>> _checkEncryption(
    Map<String, dynamic> state,
  ) async {
    if (state['e2ee'] != true || state['protocol'] != 5) {
      throw StateError('Обновите сервер: необходима поддержка E2EE');
    }
    var keyId = state['encryption_key_id'] as String? ?? '';
    if (keyId.isEmpty) {
      // A fresh VPS is initialized before any local records or files leave the
      // device. Existing plaintext servers are not silently adopted.
      final pinned = await repo.db.meta('encrypted_server_key_id');
      if (pinned != null) {
        throw StateError(
          'Сервер потерял состояние E2EE. Синхронизация остановлена',
        );
      }
      final page = await client.get<Map<String, dynamic>>(
        '$_url/api/v1/changes',
        queryParameters: {'after': 0},
        options: Options(
          headers: {
            ...authHeaders,
            'X-Yggvion-Generation': state['generation'],
          },
        ),
      );
      if ((page.data!['records'] as List).isNotEmpty) {
        throw StateError(
          'Этот сервер содержит открытые данные. Для нового E2EE-пространства нужен пустой сервер',
        );
      }
      final key = await prepareWorkspaceKey();
      if (_password == null) {
        throw StateError(
          'Создайте пароль шифрования в настройках синхронизации',
        );
      }
      await client.post<Object?>(
        '$_url/api/v1/encryption',
        options: Options(
          headers: {
            ...authHeaders,
            'X-Yggvion-Generation': state['generation'],
          },
        ),
        data: {'key_id': key.id, 'password_envelope': _password!.value},
      );
      state = await request('GET', '/api/v1/state');
      keyId = state['encryption_key_id'] as String;
      // The initial empty generation must not replace the first device's data.
      _generation = state['generation'] as String;
      await repo.db.setMeta('server_generation', _generation!);
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(keyId)) {
      throw const FormatException('Неверный идентификатор ключа сервера');
    }
    _requiredKeyId = keyId;
    if (_cipher?.id != keyId) _cipher = await WorkspaceKey.load(keyId, secure);
    if (_cipher != null) state = await _flushPassword(state, _cipher!);
    final rawPassword = state['password_envelope'];
    _password = rawPassword is Map<String, dynamic>
        ? PasswordEnvelope.fromJson(rawPassword)
        : null;
    if (_password != null && _password!.keyId != keyId) {
      throw const FormatException('Неверная защита паролем сервера');
    }
    if (_cipher == null) {
      throw StateError('Введите пароль шифрования в настройках синхронизации');
    }
    if (_password == null) {
      throw StateError(
        'Пространство без парольного E2EE не поддерживается. Создайте новое.',
      );
    }
    _password!.verify(_cipher!);
    final cached = PasswordEnvelope.fromEncoded(
      await repo.db.meta(PasswordEnvelope.storageKey(keyId)),
    );
    if (cached != null && cached.revision > _password!.revision) {
      throw StateError(
        'Сервер вернул устаревшую защиту паролем. Синхронизация остановлена.',
      );
    }
    await repo.db.setMeta(
      PasswordEnvelope.storageKey(keyId),
      _password!.encoded,
    );
    final pinned = await repo.db.meta('encrypted_server_key_id');
    if (pinned != null && pinned != keyId) {
      throw StateError(
        'Изменился ключ сервера. Переподключитесь с доверенного устройства',
      );
    }
    if (_generation == null && pinned == null) {
      _generation = state['generation'] as String;
      await repo.db.setMeta('server_generation', _generation!);
    }
    await repo.db.setMeta('workspace_key_id', keyId);
    await repo.db.setMeta('encrypted_server_key_id', keyId);
    return state;
  }

  Future<Map<String, String>> _attachmentMap(Entity entity) async {
    final result = <String, String>{};
    for (final match in RegExp(
      r'attachment:([a-f0-9]{64})',
    ).allMatches(jsonEncode(entity.data))) {
      final id = match[1]!;
      final row = await repo.db
          .customSelect(
            'SELECT cipher_id FROM encrypted_files WHERE key_id=? AND id=?',
            variables: [Variable(_cipher!.id), Variable(id)],
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

  Future<void> _uploadEncryptedFiles() async {
    final rows = await repo.db
        .customSelect(
          'SELECT f.*,e.cipher_id FROM files f LEFT JOIN encrypted_files e ON e.id=f.id AND e.key_id=?',
          variables: [Variable(_cipher!.id)],
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
        await _cipher!.encryptFile(source, file, 'attachment:$id');
        final cipherId = (await sha256.bind(file.openRead()).first).toString();
        await client.put<Object?>(
          '$_url/api/v1/attachments/$cipherId',
          data: file.openRead(),
          options: Options(
            sendTimeout: const Duration(minutes: 15),
            headers: {
              ...authHeaders,
              'Content-Type': 'application/octet-stream',
              'Content-Length': await file.length(),
              'X-Yggvion-Encryption': _cipher!.id,
            },
          ),
        );
        await repo.db.transaction(() async {
          await repo.db.customStatement(
            'INSERT OR REPLACE INTO encrypted_files VALUES(?,?,?)',
            [_cipher!.id, id, cipherId],
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

  Future<void> _downloadEncryptedFiles() async {
    final entities = await repo.db.entities();
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
        await client.download(
          '$_url/api/v1/attachments/$cipherId',
          encrypted.path,
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
            title.trim(),
            description: description,
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
