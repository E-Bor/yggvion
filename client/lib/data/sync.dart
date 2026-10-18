import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import 'repository.dart';

class SyncService {
  SyncService(this.repo, {Dio? client, FlutterSecureStorage? secureStorage})
    : client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 60),
            ),
          ),
      secure =
          secureStorage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(useDataProtectionKeyChain: false),
          );
  final Repository repo;
  final Dio client;
  final FlutterSecureStorage secure;
  Timer? _timer;
  Timer? _eventRetry;
  StreamSubscription<List<int>>? _events;
  CancelToken? _eventCancel;
  bool _listening = false;
  bool _busy = false, _disposed = false;
  String? _url, _token;
  String? get url => _url;
  bool get connected => _url != null && _token != null;
  Future<void> initialize() async {
    _url = await repo.db.meta('server_url');
    _token = _url == null ? null : await secure.read(key: 'server_token');
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
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
      throw ArgumentError(
        'Укажите HTTPS-адрес сервера. HTTP разрешён только для localhost.',
      );
    }
    return uri;
  }

  Future<void> pair(String url, String key, String name) async {
    final uri = validateURL(url);
    final base = uri.toString().replaceAll(RegExp(r'/+$'), '');
    final response = await client.post<Map<String, dynamic>>(
      '$base/api/v1/pair',
      data: {'name': name, 'key': key},
    );
    final data = response.data!;
    final oldId = repo.deviceId;
    final newId = data['device_id'] as String;
    await secure.write(key: 'server_token', value: data['token'] as String);
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
    await sync();
    unawaited(_listen());
  }

  Future<void> _listen() async {
    if (!connected || _disposed || _listening) return;
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

  Options get _auth => Options(headers: {'Authorization': 'Bearer $_token'});
  Future<void> sync() async {
    if (!connected || _busy || _disposed) return;
    _busy = true;
    repo.syncStatus = 'Синхронизация';
    repo.syncError = null;
    repo.publish();
    try {
      // Drain in dependency order; do not hold the local write queue over HTTP.
      while (!_disposed) {
        final pending = await repo.serial(
          () => repo.db
              .customSelect(
                "SELECT * FROM outbox ORDER BY CASE json_extract(payload,'\$.kind') WHEN 'project' THEN 0 WHEN 'series' THEN 1 WHEN 'task' THEN 2 ELSE 3 END, ordinal LIMIT 100",
              )
              .get(),
        );
        if (pending.isEmpty) break;
        final response = await client.post<Map<String, dynamic>>(
          '$_url/api/v1/sync',
          options: _auth,
          data: {
            'mutations': pending
                .map(
                  (r) => {
                    'operation_id': r.read<String>('operation_id'),
                    'record': jsonDecode(r.read<String>('payload')),
                  },
                )
                .toList(),
          },
        );
        await repo.serial(() async {
          await repo.db.transaction(() async {
            for (final raw in response.data!['results'] as List) {
              final result = raw as Map<String, dynamic>;
              final remote = Entity.fromJson(
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
              if (result['status'] == 'conflict') {
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
              final remote = Entity.fromJson(raw as Map<String, dynamic>);
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
      await _files();
      repo.syncStatus = 'Синхронизировано';
      await repo.reload();
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

  Future<void> _files() async {
    final files = await repo.db
        .customSelect('SELECT * FROM files WHERE uploaded=0')
        .get();
    for (final row in files) {
      final file = File(row.read<String>('path'));
      await client.put<Object?>(
        '$_url/api/v1/attachments/${row.read<String>('id')}',
        data: file.openRead(),
        options: Options(
          headers: {
            'Authorization': 'Bearer $_token',
            'Content-Type': 'application/octet-stream',
            'Content-Length': await file.length(),
            'X-File-Name': Uri.encodeComponent(row.read<String>('name')),
          },
        ),
      );
      await repo.db.customStatement('UPDATE files SET uploaded=1 WHERE id=?', [
        row.read<String>('id'),
      ]);
    }
    final entities = await repo.db.entities();
    final attachmentNames = <String, String>{};
    for (final entity in entities) {
      for (final match in RegExp(
        r'\[([^\]]*)\]\(attachment:([a-f0-9]{64})\)',
      ).allMatches(entity.searchable)) {
        attachmentNames[match[2]!] = match[1]!;
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
      try {
        final dir = Directory(
          p.join((await getApplicationSupportDirectory()).path, 'attachments'),
        );
        await dir.create(recursive: true);
        final name = attachmentNames[id] ?? id;
        final extension = p.extension(name).toLowerCase();
        final target = p.join(
          dir.path,
          '$id${RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(extension) ? extension : ''}',
        );
        await client.download(
          '$_url/api/v1/attachments/$id',
          '$target.part',
          options: _auth,
        );
        final digest = await sha256.bind(File('$target.part').openRead()).first;
        if (digest.toString() != id) {
          await File('$target.part').delete();
          throw StateError('Контрольная сумма вложения не совпадает');
        }
        await File('$target.part').rename(target);
        await repo.db.customStatement(
          'INSERT INTO files(id,name,path,uploaded) VALUES (?,?,?,1) ON CONFLICT(id) DO NOTHING',
          [id, name, target],
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }
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

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _eventRetry?.cancel();
    _eventCancel?.cancel();
    _events?.cancel();
    client.close();
  }
}
