import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/dropbox_authorization.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';

class DropboxSync extends SyncService {
  DropboxSync(super.repo);
  bool linked = true;
  int exchanges = 0;
  Map<String, dynamic>? payload;
  @override
  bool get connected => linked;
  @override
  String get url => 'https://192.0.2.1';
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    expect(method, 'POST');
    expect(path, '/api/v1/backups/dropbox/connect');
    exchanges++;
    payload = Map<String, dynamic>.from(data! as Map);
    return {'status': 'configured'};
  }
}

void main() {
  late Repository repo;
  late DropboxSync sync;
  late StreamController<Uri> links;
  setUp(() {
    repo = Repository(LocalDatabase(NativeDatabase.memory()));
    sync = DropboxSync(repo);
    links = StreamController<Uri>.broadcast();
  });
  tearDown(() async {
    sync.dispose();
    await links.close();
    await repo.db.close();
  });

  test(
    'default OAuth configuration validates state and exchanges PKCE only with VPS',
    () async {
      late Uri opened;
      final flow = DropboxAuthorization(
        links: links.stream,
        openBrowser: (uri) async {
          opened = uri;
          return true;
        },
      );
      final connected = flow.connect(sync);
      await Future<void>.delayed(Duration.zero);
      expect(flow.configured, isTrue);
      expect(flow.appKey, isNotEmpty);
      expect(opened.host, 'www.dropbox.com');
      expect(opened.queryParameters['client_id'], flow.appKey);
      expect(opened.queryParameters['token_access_type'], 'offline');
      expect(opened.queryParameters['code_challenge_method'], 'S256');
      expect(opened.queryParameters['client_secret'], isNull);
      links.add(
        Uri.parse('${DropboxAuthorization.redirect}?code=wrong&state=wrong'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sync.exchanges, 0);
      final state = opened.queryParameters['state'];
      links.add(
        Uri.parse('${DropboxAuthorization.redirect}?code=one-use&state=$state'),
      );
      expect(await connected, isTrue);
      expect(sync.exchanges, 1);
      final verifier = sync.payload!['code_verifier'] as String;
      expect(
        base64Url
            .encode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', ''),
        opened.queryParameters['code_challenge'],
      );
      expect(sync.payload!['app_key'], flow.appKey);
      expect(sync.payload!['code'], 'one-use');
      expect(
        sync.payload!.keys,
        unorderedEquals(['app_key', 'code', 'code_verifier', 'redirect_uri']),
      );
      links.add(
        Uri.parse('${DropboxAuthorization.redirect}?code=replay&state=$state'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sync.exchanges, 1);
    },
  );

  test(
    'denial, cancellation and changed server never exchange credentials',
    () async {
      late Uri opened;
      final flow = DropboxAuthorization(
        appKey: 'test-app-key',
        links: links.stream,
        openBrowser: (uri) async {
          opened = uri;
          return true;
        },
      );
      var connected = flow.connect(sync);
      var failure = expectLater(connected, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      links.add(
        Uri.parse(
          '${DropboxAuthorization.redirect}?error=access_denied&state=${opened.queryParameters['state']}',
        ),
      );
      await failure;
      connected = flow.connect(sync);
      flow.cancel();
      expect(await connected, isFalse);
      connected = flow.connect(sync);
      failure = expectLater(connected, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      sync.linked = false;
      links.add(
        Uri.parse(
          '${DropboxAuthorization.redirect}?code=code&state=${opened.queryParameters['state']}',
        ),
      );
      await failure;
      expect(sync.exchanges, 0);
    },
  );

  test(
    'timeout and browser launch failure are visible and allow retry',
    () async {
      final flow = DropboxAuthorization(
        appKey: 'test-app-key',
        links: links.stream,
        timeout: const Duration(milliseconds: 5),
        openBrowser: (_) async => true,
      );
      await expectLater(flow.connect(sync), throwsStateError);
      final unavailable = DropboxAuthorization(
        appKey: 'test-app-key',
        links: links.stream,
        openBrowser: (_) async => false,
      );
      await expectLater(unavailable.connect(sync), throwsStateError);
      await expectLater(unavailable.connect(sync), throwsStateError);
      expect(sync.exchanges, 0);
    },
  );

  test(
    'desktop callback listens only on loopback, rejects foreign state, and closes',
    () async {
      final flow = DropboxAuthorization(
        appKey: 'test-app-key',
        loopback: true,
        openBrowser: (uri) async {
          final target = Uri.parse(uri.queryParameters['redirect_uri']!);
          expect(target.host, '127.0.0.1');
          final http = HttpClient();
          try {
            final bad = await (await http.getUrl(
              target.replace(
                queryParameters: {
                  'state': 'foreign',
                  'code': 'do-not-exchange',
                },
              ),
            )).close();
            expect(bad.statusCode, 400);
            await bad.drain<void>();
            final good = await (await http.getUrl(
              target.replace(
                queryParameters: {
                  'state': uri.queryParameters['state']!,
                  'code': 'desktop-code',
                },
              ),
            )).close();
            expect(good.statusCode, 200);
            await good.drain<void>();
          } finally {
            http.close(force: true);
          }
          return true;
        },
      );
      expect(await flow.connect(sync), isTrue);
      expect(
        sync.payload!['redirect_uri'],
        DropboxAuthorization.desktopRedirect,
      );
      final rebound = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        43827,
        shared: false,
      );
      await rebound.close(force: true);
    },
  );
}
