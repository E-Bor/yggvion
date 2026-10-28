import '../l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:url_launcher/url_launcher.dart';
import 'sync.dart';

/// Short-lived PKCE transaction. The browser returns only a one-use code;
/// access/refresh tokens are obtained and stored by the user's VPS.
class DropboxAuthorization {
  DropboxAuthorization({
    // Public OAuth client identifier shared by all Yggvion builds.
    this.appKey = const String.fromEnvironment(
      'DROPBOX_APP_KEY',
      defaultValue: 'c2jw7clbuepnqq7',
    ),
    Stream<Uri>? links,
    Future<bool> Function(Uri)? openBrowser,
    this.timeout = const Duration(minutes: 5),
    this.loopback,
  }) : _links = links,
       _openBrowser =
           openBrowser ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  static const redirect = 'yggvion://oauth/dropbox';
  static const desktopRedirect = 'http://127.0.0.1:43827/dropbox';
  final String appKey;
  final Stream<Uri>? _links;
  final Future<bool> Function(Uri) _openBrowser;
  final Duration timeout;
  final bool? loopback;
  Completer<String?>? _pending;
  bool get configured => RegExp(r'^[a-zA-Z0-9_-]{5,128}$').hasMatch(appKey);

  String _random() {
    final random = Random.secure();
    return base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  void cancel() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }

  Future<bool> connect(SyncService sync) async {
    if (!configured) {
      throw StateError(tr("Dropbox не настроен в этой сборке приложения."));
    }
    if (!sync.connected) throw StateError(tr("Сначала подключите сервер."));
    if (_pending != null) {
      throw StateError(tr("Вход в Dropbox уже выполняется."));
    }
    final server = sync.url;
    final state = _random(), verifier = _random();
    final pending = Completer<String?>();
    _pending = pending;
    final useLoopback =
        loopback ??
        (_links == null && (Platform.isWindows || Platform.isLinux));
    final redirectUri = Uri.parse(useLoopback ? desktopRedirect : redirect);
    final callback = pending.future.then<Object?>(
      (value) => value,
      onError: (Object error) => error,
    );
    bool receive(Uri uri) {
      if (pending.isCompleted ||
          uri.scheme != redirectUri.scheme ||
          uri.host != redirectUri.host ||
          uri.path != redirectUri.path ||
          uri.port != redirectUri.port ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.queryParametersAll['state']?.length != 1 ||
          uri.queryParameters['state'] != state) {
        return false;
      }
      if (uri.queryParameters.containsKey('error')) {
        pending.completeError(
          StateError(tr("Доступ к Dropbox не предоставлен.")),
        );
      } else {
        final codes = uri.queryParametersAll['code'];
        if (codes == null ||
            codes.length != 1 ||
            codes.single.isEmpty ||
            codes.single.length > 4096) {
          pending.completeError(
            StateError(
              tr("Dropbox вернул некорректный ответ. Попробуйте ещё раз."),
            ),
          );
        } else {
          pending.complete(codes.single);
        }
      }
      return true;
    }

    StreamSubscription<Uri>? subscription;
    HttpServer? callbackServer;
    final timer = Timer(timeout, () {
      if (!pending.isCompleted) {
        pending.completeError(
          StateError(tr("Время входа в Dropbox истекло. Попробуйте ещё раз.")),
        );
      }
    });
    try {
      if (useLoopback) {
        try {
          callbackServer = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            redirectUri.port,
            shared: false,
          );
        } on SocketException {
          throw StateError(
            tr(
              "Локальный порт входа Dropbox (43827) занят. Закройте другое окно входа и повторите попытку.",
            ),
          );
        }
        callbackServer.listen((request) async {
          final accepted =
              request.method == 'GET' &&
              request.uri.path == redirectUri.path &&
              receive(redirectUri.replace(query: request.uri.query));
          request.response.statusCode = accepted ? 200 : 400;
          request.response.headers
            ..contentType = ContentType.text
            ..set('Cache-Control', 'no-store')
            ..set(
              'Content-Security-Policy',
              "default-src 'none'; frame-ancestors 'none'",
            );
          request.response.write(
            accepted
                ? tr(
                    "Ответ Dropbox получен. Вернитесь в Yggvion для завершения подключения.",
                  )
                : tr("Неизвестный запрос. Начните подключение в Yggvion."),
          );
          await request.response.close();
        });
      } else {
        subscription = (_links ?? AppLinks().uriLinkStream).listen(
          receive,
          onError: (Object _) {
            if (!pending.isCompleted) {
              pending.completeError(
                StateError(tr("Не удалось получить ответ Dropbox.")),
              );
            }
          },
        );
      }
      final authorization = Uri.https('www.dropbox.com', '/oauth2/authorize', {
        'client_id': appKey,
        'redirect_uri': redirectUri.toString(),
        'response_type': 'code',
        'token_access_type': 'offline',
        'scope': 'files.metadata.read files.content.read files.content.write',
        'state': state,
        'code_challenge_method': 'S256',
        'code_challenge': base64Url
            .encode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', ''),
      });
      if (!await _openBrowser(authorization)) {
        throw StateError(tr("Не удалось открыть Dropbox в браузере."));
      }
      final result = await callback;
      if (result == null) return false;
      if (result is! String) throw result;
      if (!sync.connected || sync.url != server) {
        throw StateError(
          tr("Подключение к серверу изменилось. Повторите вход в Dropbox."),
        );
      }
      await sync.request(
        'POST',
        '/api/v1/backups/dropbox/connect',
        data: {
          'app_key': appKey,
          'code': result,
          'code_verifier': verifier,
          'redirect_uri': redirectUri.toString(),
        },
      );
      return true;
    } finally {
      timer.cancel();
      await subscription?.cancel();
      await callbackServer?.close(force: true);
      _pending = null;
    }
  }
}
