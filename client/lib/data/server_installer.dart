import '../l10n/strings.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'server_script.dart';
import 'sync.dart';

enum ServerOperation { install, update, uninstall }

class ServerInstaller {
  ServerInstaller(this.sync);
  final SyncService sync;
  SSHClient? _ssh;
  bool _cancelled = false;

  static String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  void cancel() {
    _cancelled = true;
    _ssh?.close();
  }

  Future<void> install({
    ServerOperation operation = ServerOperation.install,
    bool deleteData = false,
    required String host,
    required int sshPort,
    required int httpsPort,
    required String user,
    required String password,
    required String deviceName,
    String? privateKey,
    String? keyPassphrase,
    required Future<bool> Function(String fingerprint, bool changed) verifyHost,
    required void Function(String status) onStatus,
  }) async {
    if (operation == ServerOperation.install) {
      sync.requireDisconnected();
    } else {
      final current = Uri.tryParse(sync.url ?? '');
      if (!sync.connected ||
          current?.host != host ||
          current?.port != httpsPort) {
        throw StateError(
          tr("Обновлять и очищать можно только подключённый сервер."),
        );
      }
    }
    if (InternetAddress.tryParse(host) == null ||
        sshPort < 1 ||
        sshPort > 65535 ||
        httpsPort < 1 ||
        httpsPort > 65535) {
      throw ArgumentError(tr("Укажите IP-адрес и корректные порты"));
    }
    if (user.trim().isEmpty) {
      throw ArgumentError(tr("Укажите SSH-пользователя"));
    }
    _cancelled = false;
    final hostKey = 'ssh_host_${host}_$sshPort';
    final known = await sync.credentials.read(key: hostKey);
    String? accepted;
    onStatus(tr("Проверяем подлинность сервера"));
    final socket = await SSHSocket.connect(
      host,
      sshPort,
      timeout: const Duration(seconds: 15),
    );
    if (_cancelled) {
      socket.close();
      throw StateError(tr("Установка отменена"));
    }
    final ssh = SSHClient(
      socket,
      username: user.trim(),
      identities: privateKey == null
          ? null
          : SSHKeyPair.fromPem(privateKey, keyPassphrase),
      onPasswordRequest: () => password,
      onVerifyHostKey: (type, fingerprint) async {
        final value = utf8.decode(fingerprint);
        if (known == value) return true;
        // A changed key is never silently trusted, including reinstallations.
        final allow = await verifyHost(value, known != null);
        if (allow) accepted = value;
        return allow;
      },
    );
    _ssh = ssh;
    String? temporary;
    try {
      await ssh.authenticated.timeout(const Duration(seconds: 60));
      if (accepted != null) {
        await sync.credentials.write(key: hostKey, value: accepted!);
      }
      Future<String> run(String command) async {
        final result = await ssh
            .runWithResult(command)
            .timeout(const Duration(minutes: 15));
        if (result.exitCode != 0) {
          throw StateError(
            tr("Установка остановлена: {0}", [
              utf8.decode(result.stderr, allowMalformed: true).trim(),
            ]),
          );
        }
        return utf8.decode(result.stdout).trim();
      }

      Map<String, dynamic>? artifact;
      Uint8List? bytes;
      if (operation != ServerOperation.uninstall) {
        onStatus(tr("Определяем архитектуру VPS"));
        final arch = switch (await run('uname -m')) {
          'x86_64' => 'amd64',
          'aarch64' => 'arm64',
          _ => throw StateError(tr("Поддерживаются VPS x86_64 и ARM64")),
        };
        final manifest =
            jsonDecode(
                  await rootBundle.loadString('assets/server/manifest.json'),
                )
                as Map<String, dynamic>;
        artifact = manifest[arch] as Map<String, dynamic>;
        bytes = (await rootBundle.load(
          'assets/server/${artifact['file']}',
        )).buffer.asUint8List();
        if (sha256.convert(bytes).toString() != artifact['sha256']) {
          throw StateError(tr("Установочный файл повреждён"));
        }
      }
      temporary = await run('mktemp -d /tmp/yggvion-install.XXXXXXXX');
      if (!RegExp(
        r'^/tmp/yggvion-install\.[A-Za-z0-9]+$',
      ).hasMatch(temporary)) {
        throw StateError(tr("Некорректный временный каталог"));
      }
      final sftp = await ssh.sftp();
      Future<void> upload(String name, Uint8List data) async {
        final file = await sftp.open(
          '$temporary/$name',
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate,
        );
        try {
          await file.write(Stream.value(data));
        } finally {
          await file.close();
        }
      }

      onStatus(tr("Передаём сервер по защищённому соединению"));
      if (bytes != null) await upload('yggvion', bytes);
      await upload(
        'install.sh',
        await loadServerScript(
          uninstall: operation == ServerOperation.uninstall,
        ),
      );
      onStatus(switch (operation) {
        ServerOperation.install => tr("Устанавливаем сервис и сертификат"),
        ServerOperation.update => tr("Обновляем сервер и применяем миграции"),
        ServerOperation.uninstall => tr("Удаляем сервер"),
      });
      final command = operation == ServerOperation.uninstall
          ? 'sh ${quote('$temporary/install.sh')} ${deleteData ? 'purge DELETE-YGGVION' : 'keep-data'}'
          : 'sh ${quote('$temporary/install.sh')} ${quote(host)} $httpsPort ${quote('$temporary/yggvion')} ${quote(artifact!['sha256'] as String)} ${operation.name}';
      String output;
      if (user == 'root') {
        output = await run(command);
      } else {
        // Password goes to stdin, never command arguments, environment or logs.
        final session = await ssh.execute('sudo -S -p "" -- $command');
        session.stdin.add(utf8.encode('$password\n'));
        await session.stdin.close();
        final outputs = await Future.wait([
          utf8.decoder.bind(session.stdout).join(),
          utf8.decoder.bind(session.stderr).join(),
        ]).timeout(const Duration(minutes: 15));
        await session.done;
        if (session.exitCode != 0) {
          throw StateError(
            tr("Операция через sudo остановлена: {0}", [outputs[1].trim()]),
          );
        }
        output = outputs.first;
      }
      if (operation == ServerOperation.uninstall) {
        await sync.disconnect();
        onStatus(
          deleteData
              ? tr("Сервер и его данные удалены. Локальные данные сохранены.")
              : tr("Сервер удалён. База и файлы сохранены на VPS."),
        );
        return;
      }
      if (operation == ServerOperation.update) {
        onStatus(tr("Сервер обновлён. Данные и подключения сохранены."));
        await sync.sync();
        return;
      }
      final payload = output
          .split('\n')
          .where((line) => line.startsWith('{'))
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .last;
      onStatus(tr("Подключаем это устройство"));
      final url = Uri(scheme: 'https', host: host, port: httpsPort).toString();
      await sync.pair(
        url,
        payload['code'] as String,
        deviceName,
        privateCA: payload['private_ca'] as String,
      );
      onStatus(tr("Сервер готов. Сертификат продлевается автоматически."));
    } finally {
      if (temporary != null && !_cancelled) {
        try {
          await ssh
              .runWithResult('rm -rf -- ${quote(temporary)}')
              .timeout(const Duration(seconds: 5));
        } on Object {
          /* The server's private /tmp install directory is harmless if disconnected. */
        }
      }
      ssh.close();
      _ssh = null;
    }
  }
}
