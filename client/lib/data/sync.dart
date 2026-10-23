import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:drift/drift.dart';
import 'local_credentials.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import '../domain/server_metrics.dart';
import '../domain/sync_rules.dart';
import 'repository.dart';
import 'encryption.dart';
import 'package:collection/collection.dart';
import 'package:timezone/timezone.dart' as tz;

part 'sync_encryption.dart';

class SyncService {
  SyncService(
    this.repo, {
    Dio? client,
    LocalCredentials? credentials,
    this.realtime = true,
  }) : client =
           client ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 30),
               sendTimeout: const Duration(seconds: 60),
               followRedirects: false,
             ),
           ),
       credentials = credentials ?? LocalCredentials(repo.db);
  final Repository repo;
  final Dio client;
  final LocalCredentials credentials;
  final bool realtime;
  Timer? _timer;
  Timer? _eventRetry;
  StreamSubscription<List<int>>? _events;
  CancelToken? _eventCancel;
  bool _listening = false;
  bool _busy = false, _disposed = false;
  bool _pairing = false;
  String? _url, _token;
  String? _generation, _privateCA;
  WorkspaceKey? _cipher;
  PasswordConfig? _password;
  String? _requiredKeyId;
  int _restoredThrough = 0;
  DateTime? _snapshotCreated;
  ServerMetrics? _metrics;
  DateTime? _metricsFetched;
  Future<ServerMetrics> metrics() async {
    if (_metrics != null &&
        _metricsFetched != null &&
        DateTime.now().difference(_metricsFetched!) <
            const Duration(seconds: 30)) {
      return _metrics!;
    }
    final value = ServerMetrics.fromJson(
      await request('GET', '/api/v1/metrics'),
    );
    _metrics = value;
    _metricsFetched = DateTime.now();
    return value;
  }

  String? get privateCA => _privateCA;
  String? get url => _url;
  bool get connected => _url != null && _token != null;
  Future<void> disconnect() async {
    if (_pairing) throw StateError('Дождитесь завершения подключения');
    _pairing = true;
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (_busy) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Синхронизация ещё выполняется');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      _url = null;
      _token = null;
      _generation = null;
      _requiredKeyId = null;
      if (_privateCA != null) {
        client.httpClientAdapter.close(force: true);
        client.httpClientAdapter = IOHttpClientAdapter();
      }
      _privateCA = null;
      _metrics = null;
      _metricsFetched = null;
      _eventRetry?.cancel();
      _eventCancel?.cancel();
      await _events?.cancel();
      _listening = false;
      await credentials.delete(key: 'server_token');
      await credentials.delete(key: 'server_ca');
      await repo.serial(() async {
        await repo.db.transaction(() async {
          await repo.db.customStatement(
            "DELETE FROM metadata WHERE key IN ('server_url','server_generation','sync_cursor','encrypted_server_key_id')",
          );
          // A future connection may target a fresh server. Re-send local records
          // and files; the server resolves equal IDs without losing edits.
          final records = await repo.db.entities(includeDeleted: true);
          await repo.db.customStatement('DELETE FROM outbox');
          var ordinal = 0;
          for (final old in records) {
            final record = old.withVersion(0);
            await repo.db.put(record);
            await repo.db.customStatement(
              'INSERT INTO outbox VALUES(?,?,?,?)',
              [record.id, repo.newId(), record.encoded, ++ordinal],
            );
          }
          await repo.db.customStatement('UPDATE files SET uploaded=0');
          await repo.db.setMeta('ordinal', '$ordinal');
        });
        await repo.reload();
      });
      repo.syncStatus = 'Локально';
      repo.syncError = null;
      repo.publish();
    } finally {
      _pairing = false;
    }
  }

  Future<void> initialize() async {
    try {
      if (await repo.db.meta('workspace_key_id') != null) {
        await prepareWorkspaceKey();
      }
    } on PasswordRequired catch (e) {
      repo.syncError = '$e';
    } on FormatException catch (e) {
      repo.syncError = e.message;
    } on StateError catch (e) {
      repo.syncError = e.message;
    }
    _url = await repo.db.meta('server_url');
    _token = _url == null ? null : await credentials.read(key: 'server_token');
    _privateCA = await credentials.read(key: 'server_ca');
    _generation = await repo.db.meta('server_generation');
    if (_privateCA != null) _configureTrust(client, _privateCA!);
    repo.onChange = sync;
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(sync()),
    );
    if (connected) {
      unawaited(sync());
      unawaited(_listen());
    }
  }

  static Uri validateURL(String value) {
    final uri = Uri.parse(value.trim());
    if (!uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
      throw ArgumentError(
        'Укажите HTTPS-адрес сервера. HTTP разрешён только для localhost.',
      );
    }
    return uri;
  }

  static void _configureTrust(Dio dio, String ca) {
    final context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificatesBytes(utf8.encode(ca));
    dio.httpClientAdapter.close(force: true);
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient(context: context),
    );
    dio.options.followRedirects = false;
  }

  void requireDisconnected() {
    if (connected) {
      throw StateError(
        'Сначала забудьте текущий сервер в разделе «Синхронизация».',
      );
    }
  }

  Future<void> pair(
    String url,
    String key,
    String name, {
    String? privateCA,
  }) async {
    requireDisconnected();
    if (_pairing) throw StateError('Подключение уже выполняется');
    _pairing = true;
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (_busy) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Дождитесь завершения текущей синхронизации');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await _pairNow(url, key, name, privateCA: privateCA);
    } finally {
      _pairing = false;
      unawaited(_listen());
    }
    await sync();
  }

  Future<void> _pairNow(
    String url,
    String key,
    String name, {
    String? privateCA,
  }) async {
    final uri = validateURL(url);
    final base = uri.toString().replaceAll(RegExp(r'/+$'), '');
    final candidate = privateCA == null && _privateCA == null
        ? client
        : Dio(client.options.copyWith());
    if (privateCA != null) _configureTrust(candidate, privateCA);
    late Response<Map<String, dynamic>> response;
    try {
      response = await candidate.post<Map<String, dynamic>>(
        '$base/api/v1/pair',
        data: {'name': name, 'key': key},
      );
    } finally {
      if (candidate != client) candidate.close(force: true);
    }
    final data = response.data!;
    if (data['protocol'] != 6) {
      throw StateError(
        'Несовместимая версия сервера. Нужна новая установка с парольным E2EE.',
      );
    }
    _requiredKeyId = null;
    await repo.db.customStatement(
      "DELETE FROM metadata WHERE key IN ('encrypted_server_key_id','server_generation','sync_cursor')",
    );
    _generation = null;
    final oldId = repo.deviceId;
    final newId = data['device_id'] as String;
    await credentials.write(
      key: 'server_token',
      value: data['token'] as String,
    );
    if (privateCA != null) {
      await credentials.write(key: 'server_ca', value: privateCA);
      _configureTrust(client, privateCA);
    } else {
      await credentials.delete(key: 'server_ca');
      if (_privateCA != null) {
        client.httpClientAdapter.close(force: true);
        client.httpClientAdapter = IOHttpClientAdapter();
      }
    }
    _privateCA = privateCA;
    _eventCancel?.cancel();
    await _events?.cancel();
    _listening = false;
    await repo.db.setMeta('server_url', base);
    await repo.db.setMeta('device_id', newId);
    repo.deviceId = newId;
    _url = base;
    _token = data['token'] as String;
    final active = repo.snapshot.sessions
        .where((s) => s.deviceId == oldId && s.running)
        .map((s) => s.entity.change({'device_id': newId}))
        .toList();
    if (active.isNotEmpty) await repo.commit(active);
  }

  Future<void> _listen() async {
    if (!realtime || !connected || _disposed || _listening || _pairing) return;
    _listening = true;
    _eventCancel = CancelToken();
    try {
      final response = await client.get<ResponseBody>(
        '$_url/api/v1/events',
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Authorization': 'Bearer $_token'},
          receiveTimeout: const Duration(seconds: 45),
        ),
        cancelToken: _eventCancel,
      );
      _events = response.data!.stream.listen(
        (chunk) {
          if (!_busy) unawaited(sync());
        },
        onError: (Object error) => _retryEvents(),
        onDone: _retryEvents,
        cancelOnError: true,
      );
    } on DioException {
      _retryEvents();
    }
  }

  void _retryEvents() {
    _listening = false;
    _eventRetry?.cancel();
    if (!_disposed) {
      _eventRetry = Timer(
        const Duration(seconds: 10),
        () => unawaited(_listen()),
      );
    }
  }

  Map<String, String> get authHeaders => {
    'Authorization': 'Bearer $_token',
    'X-Yggvion-Generation': ?_generation,
  };
  Options get _auth => Options(headers: authHeaders);

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    if (!connected || !path.startsWith('/api/v1/')) {
      throw StateError('Сначала подключите сервер');
    }
    final result = await client.request<Map<String, dynamic>>(
      '$_url$path',
      data: data,
      options: _auth.copyWith(method: method),
    );
    return result.data ?? {};
  }

  Future<Map<String, dynamic>> createCalendarShare(int days) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (_busy) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Дождитесь окончания синхронизации');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await sync();
    if (!connected || repo.syncError != null) {
      throw StateError(
        'Для создания ссылки подключитесь к серверу синхронизации',
      );
    }
    final zone = repo.snapshot.settings.timezone;
    final now = tz.TZDateTime.from(repo.now(), tz.getLocation(zone));
    final start = tz.TZDateTime(now.location, now.year, now.month, now.day);
    final end = tz.TZDateTime(
      now.location,
      now.year,
      now.month,
      now.day + days,
    );
    final response = await client.post<Map<String, dynamic>>(
      '$_url/api/v1/calendar-shares',
      data: {'days': days, 'snapshot': _availability(start, end, zone)},
      options: _auth.copyWith(receiveTimeout: const Duration(minutes: 3)),
    );
    return response.data!;
  }

  Future<String> createInvitation() async {
    await sync();
    if (repo.syncError != null) throw StateError(repo.syncError!);
    final data = await request('POST', '/api/v1/invitations', data: {});
    return Uri(
      scheme: 'yggvion',
      host: 'connect',
      fragment: base64Url.encode(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'url': _url,
            'code': data['code'],
            'ca': _privateCA,
            'expires_at': data['expires_at'],
          }),
        ),
      ),
    ).toString();
  }

  Future<void> pairInvitation(String link, String name) async {
    requireDisconnected();
    final uri = Uri.parse(link.trim());
    if (link.length > 16000 ||
        uri.scheme != 'yggvion' ||
        uri.host != 'connect' ||
        uri.fragment.isEmpty) {
      throw ArgumentError('Неверная ссылка приглашения');
    }
    final payload =
        jsonDecode(utf8.decode(base64Url.decode(uri.fragment)))
            as Map<String, dynamic>;
    if (payload['version'] != 1 ||
        payload.length != 5 ||
        !{
          'version',
          'url',
          'code',
          'ca',
          'expires_at',
        }.containsAll(payload.keys)) {
      throw const FormatException(
        'Формат приглашения не поддерживается. Создайте новое приглашение.',
      );
    }
    if (!DateTime.parse(
      payload['expires_at'] as String,
    ).isAfter(DateTime.now())) {
      throw StateError(
        'Приглашение истекло. Создайте новое на подключённом устройстве.',
      );
    }
    await pair(
      payload['url'] as String,
      payload['code'] as String,
      name,
      privateCA: payload['ca'] as String?,
    );
  }

  Future<void> _checkGeneration() async {
    final state = await _checkEncryption(await request('GET', '/api/v1/state'));
    _restoredThrough = state['snapshot_cursor'] as int? ?? 0;
    _snapshotCreated = DateTime.tryParse(
      state['snapshot_created'] as String? ?? '',
    );
    final next = state['generation'] as String;
    if (_generation != next) {
      // Stage every page before replacing anything locally. A network failure
      // keeps the old workspace usable and preserves edits made while fetching.
      final restored = <String, Entity>{};
      var cursor = 0;
      while (true) {
        final page = await client.get<Map<String, dynamic>>(
          '$_url/api/v1/changes',
          queryParameters: {'after': cursor},
          options: Options(
            headers: {
              'Authorization': 'Bearer $_token',
              'X-Yggvion-Generation': next,
            },
          ),
        );
        final body = page.data!;
        for (final raw in body['records'] as List) {
          final entity = await _decodeRecord(raw as Map<String, dynamic>);
          restored[entity.id] = entity;
        }
        cursor = body['cursor'] as int;
        if (body['has_more'] != true) break;
      }
      await repo.serial(() async {
        await repo.db.transaction(() async {
          if (state['generation_reason'] == 'password') {
            // Rekeying preserves record versions. Retain edits made offline;
            // their next upload will use the new password and wire IDs.
            for (final record in restored.values) {
              final dirty = await repo.db
                  .customSelect(
                    'SELECT id FROM outbox WHERE id=? UNION SELECT id FROM conflicts WHERE id=?',
                    variables: [Variable(record.id), Variable(record.id)],
                  )
                  .get();
              if (dirty.isEmpty) await repo.db.put(record);
            }
            await repo.db.customStatement('DELETE FROM encrypted_outbox');
            await repo.db.setMeta('sync_cursor', '$cursor');
            await repo.db.setMeta('server_generation', next);
            return;
          }
          final records = await repo.db.entities(includeDeleted: true);
          final outbox = await repo.db
              .customSelect('SELECT * FROM outbox')
              .get();
          final conflicts = await repo.db
              .customSelect('SELECT * FROM conflicts')
              .get();
          final now = DateTime.now().toUtc().toIso8601String();
          await repo.db.customStatement(
            'INSERT INTO recovery_snapshots VALUES(?,?,?)',
            [
              now,
              now,
              jsonEncode({
                'records': records.map((e) => jsonDecode(e.encoded)).toList(),
                'outbox': outbox.map((e) => e.data).toList(),
                'conflicts': conflicts.map((e) => e.data).toList(),
              }),
            ],
          );
          for (final table in ['outbox', 'records', 'conflicts']) {
            await repo.db.customStatement('DELETE FROM $table');
          }
          await repo.db.clearSearchIndex();
          for (final record in restored.values) {
            await repo.db.put(record);
          }
          // A snapshot taken before the first pairing can be completely empty.
          var ordinal = int.parse(await repo.db.meta('ordinal') ?? '0');
          await repo.db.customStatement('UPDATE files SET uploaded=0');
          for (final fallback in Repository.workspaceDefaults(
            repo.snapshot.settings.timezone,
          )) {
            final current = restored[fallback.id];
            if (current == null || current.deleted) {
              final initial = fallback.withVersion(current?.version ?? 0);
              await repo.db.put(initial);
              await repo.db.customStatement(
                'INSERT INTO outbox(id,operation_id,payload,ordinal) VALUES(?,?,?,?)',
                [initial.id, repo.newId(), initial.encoded, ++ordinal],
              );
            }
          }
          await repo.db.setMeta('ordinal', '$ordinal');
          await repo.db.setMeta('sync_cursor', '$cursor');
          await repo.db.setMeta('server_generation', next);
        });
        await repo.reload();
      });
    } else {
      await repo.db.setMeta('server_generation', next);
    }
    _generation = next;
  }

  Future<void> sync() async {
    if (!connected || _busy || _disposed || _pairing) return;
    _busy = true;
    repo.syncStatus = 'Синхронизация';
    repo.syncError = null;
    repo.publish();
    try {
      await _checkGeneration();
      await _uploadEncryptedFiles();
      // Drain in dependency order; do not hold the local write queue over HTTP.
      while (!_disposed) {
        final pending = await repo.serial(
          () => repo.db
              .customSelect(
                "SELECT * FROM outbox ORDER BY CASE json_extract(payload,'\$.kind') WHEN 'project' THEN 0 WHEN 'note_folder' THEN 0 WHEN 'series' THEN 1 WHEN 'task' THEN 2 ELSE 3 END, ordinal LIMIT 100",
              )
              .get(),
        );
        if (pending.isEmpty) break;
        final mutations = <Map<String, dynamic>>[];
        var bytes = 0;
        for (final row in pending) {
          final mutation = await _encodeMutation(row);
          final size = utf8.encode(jsonEncode(mutation)).length;
          if (mutations.isNotEmpty && bytes + size > 7 * 1024 * 1024) {
            break;
          }
          mutations.add(mutation);
          bytes += size;
        }
        final response = await client.post<Map<String, dynamic>>(
          '$_url/api/v1/sync',
          options: _auth,
          data: {'mutations': mutations},
        );
        await repo.serial(() async {
          await repo.db.transaction(() async {
            for (final raw in response.data!['results'] as List) {
              final result = raw as Map<String, dynamic>;
              final remote = await _decodeRecord(
                result['record'] as Map<String, dynamic>,
              );
              final current = await repo.db
                  .customSelect(
                    'SELECT * FROM outbox WHERE id=?',
                    variables: [Variable(remote.id)],
                  )
                  .getSingleOrNull();
              if (current == null) continue;
              final local = Entity.fromJson(
                jsonDecode(current.read<String>('payload'))
                    as Map<String, dynamic>,
              );
              if (result['status'] == 'conflict' &&
                  !concurrentTimerClosure(local, remote) &&
                  !(local.deleted == remote.deleted &&
                      const DeepCollectionEquality().equals(
                        local.data,
                        remote.data,
                      ))) {
                await repo.db.customStatement(
                  'INSERT INTO conflicts(id,local,remote) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET local=excluded.local,remote=excluded.remote',
                  [remote.id, local.encoded, remote.encoded],
                );
                await repo.db.customStatement('DELETE FROM outbox WHERE id=?', [
                  remote.id,
                ]);
              } else if (current.read<String>('operation_id') ==
                  result['operation_id']) {
                await repo.db.put(remote);
                await repo.db.customStatement('DELETE FROM outbox WHERE id=?', [
                  remote.id,
                ]);
              } else {
                // User edited this record during the HTTP request: retain the edit, rebase its next write.
                final rebased = local.withVersion(remote.version);
                await repo.db.put(rebased);
                await repo.db.customStatement(
                  'UPDATE outbox SET payload=? WHERE id=?',
                  [rebased.encoded, remote.id],
                );
              }
            }
          });
        });
      }
      var more = true;
      while (more && !_disposed) {
        final cursor = int.parse(await repo.db.meta('sync_cursor') ?? '0');
        final response = await client.get<Map<String, dynamic>>(
          '$_url/api/v1/changes',
          options: _auth,
          queryParameters: {'after': cursor},
        );
        final body = response.data!;
        await repo.serial(() async {
          await repo.db.transaction(() async {
            for (final raw in body['records'] as List) {
              final remote = await _decodeRecord(raw as Map<String, dynamic>);
              final dirty = await repo.db
                  .customSelect(
                    'SELECT id FROM outbox WHERE id=? UNION SELECT id FROM conflicts WHERE id=?',
                    variables: [Variable(remote.id), Variable(remote.id)],
                  )
                  .get();
              final local = await repo.db.entity(remote.id);
              if (dirty.isEmpty &&
                  (local == null || remote.version > local.version)) {
                await repo.db.put(remote);
              }
            }
            await repo.db.setMeta('sync_cursor', '${body['cursor']}');
          });
        });
        more = body['has_more'] == true;
      }
      await _downloadEncryptedFiles();
      await repo.db.customStatement(
        'DELETE FROM encrypted_outbox WHERE operation_id NOT IN (SELECT operation_id FROM outbox)',
      );
      repo.syncStatus = 'Синхронизировано';
      await repo.reload();
      final reconciled = await reconcileEncryptedRecords(
        repo,
        restoredThrough: _restoredThrough,
        snapshotCreated: _snapshotCreated,
      );
      final received = await _receiveGuestProposals();
      await _refreshAvailability();
      if (received || reconciled) {
        _busy = false;
        await sync();
      }
    } on DioException catch (e) {
      repo.syncStatus = 'Изменения на устройстве';
      repo.syncError = e.response?.statusCode == 401
          ? 'Доступ к серверу отозван. Подключите устройство заново.'
          : e.response != null
          ? 'Сервер отклонил синхронизацию (${e.response!.statusCode}). Данные сохранены локально.'
          : 'Сервер недоступен. Повторим подключение автоматически.';
    } on Object catch (e) {
      repo.syncStatus = 'Ошибка синхронизации';
      repo.syncError = '$e';
    } finally {
      _busy = false;
      repo.publish();
    }
  }

  Future<List<Map<String, dynamic>>> devices() async {
    if (!connected) return [];
    final result = await client.get<Map<String, dynamic>>(
      '$_url/api/v1/devices',
      options: _auth,
    );
    return (result.data!['devices'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> revoke(String id) async {
    await client.delete<Object?>('$_url/api/v1/devices/$id', options: _auth);
  }

  Future<void> shutdown() async {
    dispose();
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (_busy || _pairing) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Не удалось остановить синхронизацию. Повторите очистку.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    _cipher = null;
    _password = null;
    _requiredKeyId = null;
    _url = null;
    _token = null;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _eventRetry?.cancel();
    _eventCancel?.cancel();
    _events?.cancel();
    client.close(force: true);
  }
}
