import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../data/server_installer.dart';
import '../data/dropbox_authorization.dart';
import '../data/sync.dart';
import '../domain/models.dart';
import 'providers.dart';
import 'local_backups.dart';
import 'encryption_settings.dart';
import '../domain/server_metrics.dart';
import 'settings.dart';
import 'theme.dart';

class SettingsDetail extends StatelessWidget {
  const SettingsDetail({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: ListView(padding: const EdgeInsets.all(24), children: children),
      ),
    ),
  );
}

Widget settingsCard(String title, List<Widget> children) => Padding(
  padding: const EdgeInsets.only(bottom: 20),
  child: Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  ),
);

Future<bool> confirmServerAction(
  BuildContext context,
  String title,
  String message, {
  String action = 'Продолжить',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class SynchronizationPage extends ConsumerStatefulWidget {
  const SynchronizationPage({super.key, this.invitation});
  final String? invitation;
  @override
  ConsumerState<SynchronizationPage> createState() =>
      _SynchronizationPageState();
}

class _SynchronizationPageState extends ConsumerState<SynchronizationPage> {
  final link = TextEditingController();
  late final TextEditingController name;
  bool busy = false;
  List<Map<String, dynamic>> devices = [];
  String? error;
  ServerMetrics? metrics;
  String? metricsError;
  bool refreshing = false;
  bool? reachable;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: ref.read(appProvider).deviceName);
    link.text = widget.invitation ?? '';
    unawaited(refresh());
  }

  @override
  void dispose() {
    for (final c in [link, name]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> refresh() async {
    final sync = ref.read(syncProvider);
    if (refreshing || !sync.connected) return;
    setState(() => refreshing = true);
    await Future.wait([
      () async {
        try {
          final result = await sync.devices();
          if (mounted) {
            setState(() {
              devices = result;
              error = null;
              reachable = true;
            });
          }
        } catch (_) {
          if (mounted) {
            setState(() {
              reachable = false;
              error = 'Нет ответа от сервера. Локальные данные доступны.';
            });
          }
        }
      }(),
      () async {
        try {
          final result = await sync.metrics();
          if (mounted) {
            setState(() {
              metrics = result;
              metricsError = null;
            });
          }
        } catch (_) {
          if (mounted) {
            setState(
              () => metricsError =
                  'Метрики недоступны. Проверьте связь и обновите сервер.',
            );
          }
        }
      }(),
    ]);
    if (mounted) setState(() => refreshing = false);
  }

  Future<void> forget() async {
    if (!await confirmServerAction(
          context,
          'Забыть сервер?',
          'Устройство перейдёт в локальный режим. Заметки, задачи и файлы останутся здесь. На сервере ничего не удалится, остальные устройства продолжат синхронизацию.',
          action: 'Забыть сервер',
        ) ||
        !mounted) {
      return;
    }
    await action(() async {
      await ref.read(syncProvider).disconnect();
      if (mounted) {
        setState(() {
          devices = [];
          metrics = null;
          reachable = null;
          error = null;
          metricsError = null;
        });
      }
    });
  }

  void manage(ServerOperation operation) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => InstallServerPage(operation: operation),
      ),
    ).then((_) {
      if (mounted) {
        setState(() {});
        refresh();
      }
    });
  }

  Widget metricsCard() {
    String bytes(int n) => n >= 1073741824
        ? '${(n / 1073741824).toStringAsFixed(1)} ГБ'
        : '${(n / 1048576).toStringAsFixed(0)} МБ';
    final m = metrics;
    return settingsCard('Состояние VPS', [
      Row(
        children: [
          Icon(
            reachable == true
                ? Icons.check_circle_outline_rounded
                : Icons.cloud_off_rounded,
            color: reachable == true
                ? context.accentColor
                : context.palette.muted,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              reachable == true
                  ? 'Сервер доступен'
                  : reachable == false
                  ? 'Нет подключения'
                  : 'Проверяем подключение…',
            ),
          ),
          IconButton(
            tooltip: 'Обновить метрики',
            onPressed: refreshing ? null : refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      if (refreshing) const LinearProgressIndicator(),
      if (m != null) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.speed_rounded),
          title: const Text('CPU'),
          trailing: Text(
            m.cpuPercent == null ? '—' : '${m.cpuPercent!.toStringAsFixed(1)}%',
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.memory_rounded),
          title: const Text('Память VPS'),
          subtitle: Text('Yggvion: ${bytes(m.processMemory)}'),
          trailing: Text('${bytes(m.memoryUsed)} / ${bytes(m.memoryTotal)}'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.storage_rounded),
          title: const Text('Диск VPS'),
          subtitle: Text('Свободно ${bytes(m.diskAvailable)}'),
          trailing: Text(
            '${bytes(m.diskTotal - m.diskAvailable)} / ${bytes(m.diskTotal)}',
          ),
        ),
        Text(
          'Снимок ${DateFormat('HH:mm:ss').format(m.sampledAt.toLocal())} · обновление при открытии экрана',
          style: TextStyle(fontSize: 12, color: context.palette.muted),
        ),
      ],
      if (metricsError != null)
        Text(metricsError!, style: TextStyle(color: context.palette.muted)),
    ]);
  }

  Future<void> action(Future<void> Function() fn) async {
    setState(() => busy = true);
    await guard(context, () async {
      await fn();
      final sync = ref.read(syncProvider);
      if (mounted &&
          sync.connected &&
          (sync.needsEncryptionKey || !sync.passwordConfigured)) {
        await ensureEncryptionPassword(context, ref);
      }
    });
    if (mounted) {
      setState(() => busy = false);
      await refresh();
    }
  }

  Future<void> invite() async {
    final invitation = await ref.read(syncProvider).createInvitation();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Подключить устройство'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: invitation, size: 270),
              ),
              const SizedBox(height: 16),
              const Text(
                'Откройте «Синхронизация» на другом устройстве и отсканируйте код. Одно подключение · 10 минут.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: invitation)),
            child: const Text('Скопировать ссылку'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }

  Future<void> scan() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const InvitationScanner()),
    );
    if (result != null && mounted) setState(() => link.text = result);
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider), sync = ref.read(syncProvider);
    return SettingsDetail(
      title: 'Синхронизация',
      children: [
        settingsCard(
          sync.connected
              ? 'Ваш сервер'
              : 'Ваше пространство на всех устройствах',
          [
            Text(
              sync.connected
                  ? sync.url!
                  : 'Изменения сохраняются на устройстве сразу. VPS объединяет их, когда появляется интернет.',
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
            if (sync.connected) ...[
              const SizedBox(height: 12),
              Text(
                repo.syncStatus,
                style: TextStyle(color: context.accentColor),
              ),
              if (repo.syncError != null) Text(repo.syncError!),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : () => action(invite),
                    icon: const Icon(Icons.qr_code_rounded),
                    label: const Text('Подключить устройство'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => action(sync.sync),
                    child: const Text('Синхронизировать'),
                  ),
                ],
              ),
            ],
          ],
        ),
        if (sync.connected && widget.invitation != null)
          settingsCard('Сервер уже подключён', [
            const Text(
              'Чтобы использовать приглашение другого сервера, сначала нажмите «Забыть сервер». Локальные данные сохранятся.',
            ),
          ]),
        if (sync.connected) metricsCard(),
        if (sync.connected)
          settingsCard('Устройства', [
            if (error != null) Text(error!),
            for (final device in devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices_rounded),
                title: Text(device['name'] as String),
                subtitle: device['id'] == repo.deviceId
                    ? const Text('Это устройство')
                    : null,
                trailing: device['id'] == repo.deviceId
                    ? null
                    : IconButton(
                        tooltip: 'Отозвать доступ',
                        icon: const Icon(Icons.link_off_rounded),
                        onPressed: busy
                            ? null
                            : () => action(() async {
                                if (await confirmServerAction(
                                  context,
                                  'Отозвать доступ?',
                                  '${device['name']} больше не сможет синхронизироваться.',
                                  action: 'Отозвать',
                                )) {
                                  await sync.revoke(device['id'] as String);
                                }
                              }),
                      ),
              ),
          ]),
        if (sync.connected)
          settingsCard('Управление сервером', [
            Text(
              'Обновление сохраняет данные. Очистка полностью удаляет Yggvion с VPS. «Забыть» отключает только это устройство.',
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => manage(ServerOperation.update),
                  icon: const Icon(Icons.system_update_alt_rounded),
                  label: const Text('Обновить серверную часть'),
                ),
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => manage(ServerOperation.uninstall),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Очистить сервер'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : forget,
                  icon: const Icon(Icons.link_off_rounded),
                  label: const Text('Забыть сервер'),
                ),
              ],
            ),
          ]),
        if (!sync.connected)
          settingsCard('Установить на VPS', [
            Text(
              'Ubuntu / Debian · x86_64 или ARM64\nSSH нужен только для установки и обновления. Домен не требуется.',
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const InstallServerPage(),
                        ),
                      ).then((_) => refresh()),
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Настроить VPS'),
              ),
            ),
          ]),
        if (!sync.connected)
          settingsCard('Подключиться по приглашению', [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Это устройство'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: link,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Ссылка приглашения',
                hintText: 'yggvion://connect…',
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => action(() async {
                          await sync.pairInvitation(link.text, name.text);
                          link.clear();
                        }),
                  child: const Text('Подключиться'),
                ),
                if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS)
                  TextButton.icon(
                    onPressed: busy ? null : scan,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Сканировать QR'),
                  ),
              ],
            ),
          ]),
        if (repo.conflictCount > 0 ||
            sessionConflicts(repo.snapshot.sessions, repo.now()).isNotEmpty)
          settingsCard('Конфликты', [const ConflictsPanel()]),
      ],
    );
  }
}

class InvitationScanner extends StatefulWidget {
  const InvitationScanner({super.key});
  @override
  State<InvitationScanner> createState() => _InvitationScannerState();
}

class _InvitationScannerState extends State<InvitationScanner> {
  bool done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Код подключения')),
    body: MobileScanner(
      onDetect: (capture) {
        if (done) return;
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (value != null && value.startsWith('yggvion://connect')) {
            done = true;
            Navigator.pop(context, value);
            break;
          }
        }
      },
    ),
  );
}

class InstallServerPage extends ConsumerStatefulWidget {
  const InstallServerPage({
    super.key,
    this.operation = ServerOperation.install,
  });
  final ServerOperation operation;
  @override
  ConsumerState<InstallServerPage> createState() => _InstallServerPageState();
}

class _InstallServerPageState extends ConsumerState<InstallServerPage> {
  final host = TextEditingController(),
      user = TextEditingController(text: 'root'),
      password = TextEditingController(),
      sshPort = TextEditingController(text: '22'),
      httpsPort = TextEditingController(text: '443'),
      passphrase = TextEditingController();
  late final ServerInstaller installer;
  String? privateKey, keyName;
  String status = '';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    final address = ref.read(syncProvider).url;
    if (address != null) {
      final uri = Uri.parse(address);
      host.text = uri.host;
      httpsPort.text = '${uri.port}';
    }
    installer = ServerInstaller(ref.read(syncProvider));
  }

  @override
  void dispose() {
    installer.cancel();
    for (final c in [host, user, password, sshPort, httpsPort, passphrase]) {
      c.dispose();
    }
    privateKey = null;
    super.dispose();
  }

  Future<void> install() async {
    if (widget.operation == ServerOperation.install) {
      var ready = false;
      await guard(context, () async {
        ready = await ensureEncryptionPassword(context, ref);
      });
      if (!ready || !mounted) return;
    }
    if (widget.operation == ServerOperation.uninstall) {
      final confirm = TextEditingController();
      final yes = await showDialog<bool>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, set) => AlertDialog(
            title: const Text('Очистить сервер?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Yggvion, его база, вложения, сертификаты, настройки и резервные копии на VPS будут удалены. Данные на устройствах и внешние копии останутся. Введите IP сервера для подтверждения.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: confirm,
                  onChanged: (_) => set(() {}),
                  decoration: InputDecoration(hintText: host.text),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed:
                    confirm.text.trim() == host.text.trim() &&
                        host.text.trim().isNotEmpty
                    ? () => Navigator.pop(dialog, true)
                    : null,
                child: const Text('Очистить сервер'),
              ),
            ],
          ),
        ),
      );
      Future<void>.delayed(const Duration(milliseconds: 300), confirm.dispose);
      if (yes != true || !mounted) return;
    }
    setState(() => busy = true);
    await guard(context, () async {
      await installer.install(
        operation: widget.operation,
        deleteData: widget.operation == ServerOperation.uninstall,
        host: host.text.trim(),
        sshPort: int.tryParse(sshPort.text) ?? 0,
        httpsPort: int.tryParse(httpsPort.text) ?? 0,
        user: user.text.trim(),
        password: password.text,
        deviceName: ref.read(appProvider).deviceName,
        privateKey: privateKey,
        keyPassphrase: passphrase.text.isEmpty ? null : passphrase.text,
        verifyHost: (fingerprint, changed) async =>
            mounted &&
            await confirmServerAction(
              context,
              changed ? 'SSH-ключ сервера изменился' : 'Проверьте сервер',
              '${host.text}\n\n$fingerprint\n\nСверьте отпечаток с панелью VPS. ${changed ? 'При неожиданной смене ключа отмените подключение.' : 'После подтверждения ключ будет сохранён на этом устройстве.'}',
              action: 'Доверять этому ключу',
            ),
        onStatus: (value) {
          if (mounted) setState(() => status = value);
        },
      );
      password.clear();
      passphrase.clear();
      privateKey = null;
      final sync = ref.read(syncProvider);
      if (mounted &&
          sync.connected &&
          (sync.needsEncryptionKey || !sync.passwordConfigured)) {
        await ensureEncryptionPassword(context, ref);
      }
      if (mounted) {
        Navigator.pop(context);
      }
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => SettingsDetail(
    title: switch (widget.operation) {
      ServerOperation.install => 'Настроить VPS',
      ServerOperation.update => 'Обновить сервер',
      ServerOperation.uninstall => 'Очистить сервер',
    },
    children: [
      settingsCard('Подключение по SSH', [
        Text(
          widget.operation == ServerOperation.install
              ? 'Приложение установит отдельный сервис Yggvion, настроит HTTPS и резервные копии. Данные SSH не сохраняются.'
              : 'Операция выполняется через SSH. Пароль и ключ не сохраняются.',
          style: TextStyle(color: context.palette.muted, height: 1.5),
        ),
        const SizedBox(height: 20),
        for (final item in [
          (host, 'IP-адрес VPS'),
          (sshPort, 'SSH-порт'),
          (user, 'Пользователь'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: item.$1,
              enabled: !busy,
              readOnly:
                  item.$1 == host &&
                  widget.operation != ServerOperation.install,
              decoration: InputDecoration(labelText: item.$2),
            ),
          ),
        TextField(
          controller: password,
          enabled: !busy,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Пароль SSH / sudo'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => guard(context, () async {
                  final result = await FilePicker.platform.pickFiles(
                    withData: true,
                  );
                  if (result == null) return;
                  final file = result.files.single;
                  if (file.size > 128 * 1024) {
                    throw StateError('Это не файл SSH-ключа');
                  }
                  final bytes =
                      file.bytes ?? await File(file.path!).readAsBytes();
                  if (mounted) {
                    setState(() {
                      privateKey = utf8.decode(bytes);
                      keyName = file.name;
                    });
                  }
                }),
          icon: const Icon(Icons.key_rounded),
          label: Text(keyName ?? 'Использовать SSH-ключ'),
        ),
        if (privateKey != null)
          TextField(
            controller: passphrase,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Пароль ключа, если задан',
            ),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: httpsPort,
          enabled: !busy,
          readOnly: widget.operation != ServerOperation.install,
          decoration: const InputDecoration(labelText: 'HTTPS-порт'),
        ),
        const SizedBox(height: 20),
        if (busy) const LinearProgressIndicator(),
        if (status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(status),
          ),
        FilledButton(
          onPressed: busy ? null : install,
          child: Text(switch (widget.operation) {
            ServerOperation.install => 'Установить и подключить',
            ServerOperation.update => 'Обновить сервер',
            ServerOperation.uninstall => 'Очистить сервер',
          }),
        ),
        if (busy)
          TextButton(
            onPressed: installer.cancel,
            child: const Text('Отменить подключение'),
          ),
      ]),
    ],
  );
}

class BackupsPage extends ConsumerStatefulWidget {
  const BackupsPage({super.key});
  @override
  ConsumerState<BackupsPage> createState() => _BackupsPageState();
}

class _BackupsPageState extends ConsumerState<BackupsPage> {
  Map<String, dynamic>? data;
  String? error;
  bool busy = false, loading = false;
  double? progress;
  Timer? poll;
  CancelToken? transfer;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    poll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    poll?.cancel();
    transfer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (loading || !ref.read(syncProvider).connected) return;
    loading = true;
    try {
      final result = await ref
          .read(syncProvider)
          .request('GET', '/api/v1/backups');
      if (mounted) {
        setState(() {
          data = result;
          error = null;
        });
      }
    } on Object {
      if (mounted) {
        setState(
          () => error =
              'Не удалось загрузить резервные копии. Проверьте подключение и версию сервера.',
        );
      }
    } finally {
      loading = false;
    }
  }

  Future<void> action(Future<void> Function() fn) async {
    setState(() => busy = true);
    await guard(context, fn);
    if (mounted) {
      setState(() {
        busy = false;
        progress = null;
      });
      await refresh();
    }
  }

  Future<void> saveConfig(String key, int value) async {
    final config = Map<String, dynamic>.from(data!['config'] as Map)
      ..[key] = value;
    await action(() async {
      await ref
          .read(syncProvider)
          .request('PUT', '/api/v1/backups/config', data: config);
    });
  }

  Future<void> download(String id) async {
    final sync = ref.read(syncProvider);
    final mobile = Platform.isIOS || Platform.isAndroid;
    final path = mobile
        ? '${(await getTemporaryDirectory()).path}/$id.yggbackup'
        : await FilePicker.platform.saveFile(
            dialogTitle: 'Сохранить резервную копию',
            fileName: '$id.yggbackup',
          );
    if (path == null) return;
    transfer = CancelToken();
    await sync.client.download(
      '${sync.url}/api/v1/backups/$id/download',
      path,
      options: Options(
        headers: sync.authHeaders,
        receiveTimeout: const Duration(minutes: 2),
      ),
      cancelToken: transfer,
      onReceiveProgress: (count, total) {
        if (mounted) {
          setState(() => progress = total > 0 ? count / total : null);
        }
      },
    );
    if (mobile) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          text: 'Зашифрованная резервная копия Yggvion',
        ),
      );
    }
  }

  Future<void> importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['yggbackup'],
    );
    if (picked == null || !mounted) return;
    final path = picked.files.single.path;
    if (path == null) throw StateError('Не удалось открыть выбранный файл');
    final file = File(path);
    final sync = ref.read(syncProvider);
    transfer = CancelToken();
    await sync.client.post<Object?>(
      '${sync.url}/api/v1/backups/import',
      data: file.openRead(),
      options: Options(
        headers: {
          ...sync.authHeaders,
          'Content-Type': 'application/octet-stream',
          'Content-Length': await file.length(),
        },
        sendTimeout: const Duration(hours: 2),
      ),
      cancelToken: transfer,
      onSendProgress: (count, total) {
        if (mounted) {
          setState(() => progress = total > 0 ? count / total : null);
        }
      },
    );
  }

  Future<void> localRecovery() async {
    final repo = ref.read(appProvider);
    final rows = await repo.localRecoverySnapshots();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Данные до восстановления'),
        content: SizedBox(
          width: 520,
          height: 300,
          child: ListView(
            children: [
              if (rows.isEmpty)
                const Text('Восстановлений на этом устройстве пока не было.'),
              for (final row in rows)
                ListTile(
                  title: Text(row.created),
                  trailing: TextButton(
                    onPressed: () => guard(context, () async {
                      final bytes = utf8.encode(
                        await repo.localRecoveryPayload(row.id),
                      );
                      final path = await FilePicker.platform.saveFile(
                        fileName: 'yggvion-local-recovery.json',
                        bytes: bytes,
                      );
                      if (path != null &&
                          !Platform.isIOS &&
                          !Platform.isAndroid) {
                        await File(path).writeAsBytes(bytes);
                      }
                    }),
                    child: const Text('Экспорт'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.read(syncProvider).connected;
    final config = data?['config'] as Map?;
    final status = data?['status'] as Map?;
    final running = busy || status?['running'] == true;
    final operation = switch (status?['operation']) {
      'create' || 'scheduled' => 'Создаём резервную копию…',
      'restore' => 'Восстанавливаем данные…',
      'import' => 'Проверяем импортированный архив…',
      'fetch_remote' => 'Загружаем копию из внешнего хранилища…',
      'delete' => 'Удаляем копию…',
      _ => 'Сервер обрабатывает копию…',
    };
    return SettingsDetail(
      title: 'Резервное копирование',
      children: [
        settingsCard('Копии на этом устройстве', [const LocalBackupsPanel()]),
        settingsCard('Серверные копии', [
          Text(
            'Зашифрованные копии включают задачи, заметки, проекты, учёт времени и вложения, уже дошедшие до сервера. Незагруженные изменения остаются на устройствах.',
            style: TextStyle(color: context.palette.muted, height: 1.5),
          ),
          if (!connected)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('Подключите VPS в разделе «Синхронизация».'),
            ),
          if (error != null) Text(error!),
          if (status?['error'] != null) Text(status!['error'] as String),
          if (running) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(busy ? 'Передача данных…' : operation),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: !connected || running
                    ? null
                    : () => action(importBackup),
                child: const Text('Импортировать'),
              ),
            ],
          ),
        ]),
        if (config != null)
          settingsCard('Расписание на сервере', [
            DropdownButtonFormField<int>(
              initialValue: config['every_hours'] as int,
              decoration: const InputDecoration(labelText: 'Частота'),
              items: [
                for (final entry in {
                  0: 'Выключено',
                  6: 'Каждые 6 часов',
                  12: 'Каждые 12 часов',
                  24: 'Ежедневно',
                  168: 'Еженедельно',
                }.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: running
                  ? null
                  : (v) {
                      if (v != null) unawaited(saveConfig('every_hours', v));
                    },
            ),
            const SizedBox(height: 16),
            Text(
              'Храним ${config['keep_daily']} ежедневных и ${config['keep_weekly']} еженедельных копий. Импортированные и страховочные копии сохраняются до удаления.',
            ),
            for (final entry in {
              'keep_daily': 'Ежедневных',
              'keep_weekly': 'Еженедельных',
            }.entries)
              Row(
                children: [
                  Expanded(child: Text(entry.value)),
                  IconButton(
                    onPressed:
                        running ||
                            (config[entry.key] as int) <=
                                (entry.key == 'keep_daily' ? 1 : 0)
                        ? null
                        : () => saveConfig(
                            entry.key,
                            (config[entry.key] as int) - 1,
                          ),
                    icon: const Icon(Icons.remove_rounded),
                  ),
                  Text('${config[entry.key]}'),
                  IconButton(
                    onPressed:
                        running ||
                            (config[entry.key] as int) >=
                                (entry.key == 'keep_daily' ? 90 : 52)
                        ? null
                        : () => saveConfig(
                            entry.key,
                            (config[entry.key] as int) + 1,
                          ),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
          ]),
        settingsCard('Копии на VPS', [
          if ((data?['backups'] as List? ?? []).isEmpty)
            const Text('Копии появятся здесь после первого сохранения.'),
          for (final raw in data?['backups'] as List? ?? [])
            Builder(
              builder: (context) {
                final entry = raw as Map;
                final id = entry['id'] as String;
                final reason = switch (entry['reason']) {
                  'scheduled' => 'По расписанию',
                  'before_restore' => 'Перед восстановлением',
                  'before_update' => 'Перед обновлением сервера',
                  'import' => 'Импортированная',
                  _ => 'Ручная копия',
                };
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    DateFormat('d MMM yyyy · HH:mm', 'ru').format(
                      DateTime.parse(entry['created'] as String).toLocal(),
                    ),
                  ),
                  subtitle: Text(
                    '$reason · ${entry['records']} записей · ${entry['files']} файлов · ${((entry['bytes'] as num) / 1048576).toStringAsFixed(1)} МБ',
                  ),
                  trailing: PopupMenuButton<String>(
                    enabled: !running,
                    onSelected: (value) => action(() async {
                      if (value == 'download') {
                        await download(id);
                        return;
                      }
                      if (!await confirmServerAction(
                        context,
                        value == 'restore'
                            ? 'Восстановить эту копию?'
                            : 'Удалить копию?',
                        value == 'restore'
                            ? 'Сервер сначала создаст страховочную копию. Данные календаря и заметок будут заменены. Устройства сохранят свои прежние данные для ручного экспорта и получат восстановленную версию.'
                            : 'Эта копия будет удалена с VPS.',
                        action: value == 'restore' ? 'Восстановить' : 'Удалить',
                      )) {
                        return;
                      }
                      await ref
                          .read(syncProvider)
                          .request(
                            value == 'restore' ? 'POST' : 'DELETE',
                            '/api/v1/backups/$id${value == 'restore' ? '/restore' : ''}',
                            data: value == 'restore'
                                ? {'confirm': 'restore'}
                                : null,
                          );
                    }),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'download', child: Text('Скачать')),
                      PopupMenuItem(
                        value: 'restore',
                        child: Text('Восстановить'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('Удалить')),
                    ],
                  ),
                );
              },
            ),
        ]),
        TextButton(
          onPressed: () => guard(context, localRecovery),
          child: const Text('Локальные данные до восстановления'),
        ),
        if (connected && data != null)
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Вторая копия вне VPS'),
            subtitle: Text(
              (data!['remote'] as Map?)?['kind'] == 'disabled'
                  ? 'Dropbox, S3 или SFTP · защита при потере сервера'
                  : 'Автоматическая отправка зашифрованных архивов',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => RemoteBackupsPage(
                  initial: Map<String, dynamic>.from(data!['remote'] as Map),
                ),
              ),
            ).then((_) => refresh()),
          ),
      ],
    );
  }
}

class RemoteBackupsPage extends ConsumerStatefulWidget {
  const RemoteBackupsPage({super.key, required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<RemoteBackupsPage> createState() => _RemoteBackupsPageState();
}

class _RemoteBackupsPageState extends ConsumerState<RemoteBackupsPage> {
  final dropbox = DropboxAuthorization();
  bool dropboxConnected = false;
  final fields = <String, TextEditingController>{};
  late String kind;
  bool busy = false;
  String? error;
  List<Map<String, dynamic>> copies = [];
  @override
  void initState() {
    super.initState();
    kind = widget.initial['kind'] as String? ?? 'disabled';
    dropboxConnected = kind == 'dropbox';
    for (final key in [
      'endpoint',
      'bucket',
      'region',
      'prefix',
      'username',
      'secret',
      'private_key',
      'fingerprint',
    ]) {
      fields[key] = TextEditingController(
        text: widget.initial[key] as String? ?? '',
      );
    }
  }

  @override
  void dispose() {
    dropbox.cancel();
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> action(Future<void> Function() work) async {
    setState(() => busy = true);
    try {
      await work();
      if (mounted) setState(() => error = null);
    } on Object {
      if (mounted) {
        setState(
          () => error =
              'Не удалось подключиться к хранилищу. Проверьте адрес, права и SSH-отпечаток.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> connectDropbox() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final connected = await dropbox.connect(ref.read(syncProvider));
      if (mounted && connected) {
        setState(() {
          dropboxConnected = true;
          kind = 'dropbox';
          copies = [];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Dropbox подключён. Новые серверные копии будут отправляться автоматически.',
            ),
          ),
        );
      }
    } on StateError catch (e) {
      if (mounted) setState(() => error = e.message);
    } on Object {
      if (mounted) {
        setState(
          () => error =
              'Не удалось подключить Dropbox. Проверьте связь с VPS и разрешения, затем повторите вход.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    await ref
        .read(syncProvider)
        .request(
          'PUT',
          '/api/v1/backups/remote',
          data: {
            'kind': kind,
            for (final field in fields.entries)
              field.key: field.key == 'secret'
                  ? field.value.text
                  : field.value.text.trim(),
          },
        );
    if (kind != 'dropbox') dropboxConnected = false;
    fields['secret']!.clear();
    fields['private_key']!.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Хранилище проверено. Новые копии будут отправляться автоматически.',
          ),
        ),
      );
    }
  }

  Future<void> list() async {
    final result = await ref
        .read(syncProvider)
        .request('GET', '/api/v1/backups/remote');
    if (mounted) {
      setState(
        () => copies = (result['backups'] as List).cast<Map<String, dynamic>>(),
      );
    }
  }

  Future<void> fetch(String id) async {
    await ref
        .read(syncProvider)
        .request('POST', '/api/v1/backups/remote/$id/fetch');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Загрузка начата. Результат появится в списке копий на VPS.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDetail(
    title: 'Вторая копия вне VPS',
    children: [
      settingsCard('Автоматическое хранение', [
        Text(
          'Личные данные в копиях защищены вашим паролем шифрования. Копии вне VPS сохраняются до удаления в самом хранилище.',
          style: TextStyle(color: context.palette.muted, height: 1.5),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          initialValue: kind,
          decoration: const InputDecoration(labelText: 'Хранилище'),
          items: const [
            DropdownMenuItem(value: 'disabled', child: Text('Выключено')),
            DropdownMenuItem(value: 'dropbox', child: Text('Dropbox')),
            DropdownMenuItem(value: 's3', child: Text('S3-совместимое')),
            DropdownMenuItem(value: 'sftp', child: Text('SFTP')),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value != null) setState(() => kind = value);
                },
        ),
        if (kind == 'dropbox') ...[
          const SizedBox(height: 16),
          Text(
            dropboxConnected
                ? 'Dropbox подключён. Архивы отправляются с VPS в папку приложения, даже когда Yggvion закрыт.'
                : 'Войдите в браузере и разрешите доступ к папке приложения в Dropbox. Остальные файлы останутся недоступны Yggvion.',
            style: TextStyle(color: context.palette.muted, height: 1.5),
          ),
          if (!dropbox.configured && !dropboxConnected)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Подключение Dropbox ещё не настроено в этой сборке.',
              ),
            ),
          if (busy)
            TextButton(
              onPressed: dropbox.cancel,
              child: const Text('Отменить вход'),
            ),
        ],
        if (kind == 's3' || kind == 'sftp') ...[
          for (final field in <String, String>{
            'endpoint': kind == 's3'
                ? 'HTTPS endpoint без пути'
                : 'SFTP адрес:порт',
            if (kind == 's3') 'bucket': 'Bucket',
            if (kind == 's3') 'region': 'Регион (если нужен)',
            'prefix': kind == 's3'
                ? 'Префикс, например yggvion'
                : 'Абсолютный путь на SFTP',
            'username': kind == 's3' ? 'Access key' : 'Пользователь',
            'secret': kind == 's3'
                ? 'Secret key'
                : 'Пароль (или SSH-ключ ниже)',
            if (kind == 'sftp') 'private_key': 'Приватный SSH-ключ',
            if (kind == 'sftp') 'fingerprint': 'Отпечаток сервера SHA256:…',
          }.entries)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: fields[field.key],
                enabled: !busy,
                obscureText: ['secret', 'private_key'].contains(field.key),
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(labelText: field.value),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            'Пустое поле секрета сохраняет ранее заданное значение для того же адреса и пользователя.',
            style: TextStyle(color: context.palette.muted, fontSize: 12),
          ),
        ],
        if (error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!)),
        if (busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : kind == 'dropbox'
              ? (dropbox.configured ? connectDropbox : null)
              : () => action(save),
          child: Text(
            kind == 'dropbox'
                ? (dropboxConnected
                      ? 'Сменить аккаунт Dropbox'
                      : 'Подключить Dropbox')
                : kind == 'disabled'
                ? 'Выключить внешние копии'
                : 'Проверить и подключить',
          ),
        ),
      ]),
      if (kind != 'disabled' && (kind != 'dropbox' || dropboxConnected))
        settingsCard('Копии во внешнем хранилище', [
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: busy ? null : () => action(list),
              child: const Text('Показать копии'),
            ),
          ),
          for (final copy in copies)
            ListTile(
              title: Text(
                DateFormat(
                  'd MMM yyyy · HH:mm',
                  'ru',
                ).format(DateTime.parse(copy['created'] as String).toLocal()),
              ),
              subtitle: Text(
                '${copy['records']} записей · ${copy['files']} файлов',
              ),
              trailing: IconButton(
                tooltip: 'Вернуть на VPS',
                onPressed: busy
                    ? null
                    : () => action(() => fetch(copy['id'] as String)),
                icon: const Icon(Icons.cloud_download_outlined),
              ),
            ),
        ]),
    ],
  );
}
