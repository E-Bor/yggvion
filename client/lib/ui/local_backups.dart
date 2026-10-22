import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/local_backup.dart';
import 'providers.dart';
import 'theme.dart';

class LocalBackupsPanel extends ConsumerStatefulWidget {
  const LocalBackupsPanel({super.key});
  @override
  ConsumerState<LocalBackupsPanel> createState() => _LocalBackupsPanelState();
}

class _LocalBackupsPanelState extends ConsumerState<LocalBackupsPanel> {
  late final LocalBackupService service;
  List<LocalBackupEntry> entries = [];
  bool busy = false;
  String? error;
  String? status;
  @override
  void initState() {
    super.initState();
    final sync = ref.read(syncProvider);
    service = LocalBackupService(
      ref.read(appProvider),
      beforeRestore: sync.disconnect,
    );
    refresh();
  }

  Future<void> refresh() async {
    try {
      final next = await service.list();
      if (mounted) {
        setState(() {
          entries = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = 'Не удалось открыть локальные копии: $e');
      }
    }
  }

  Future<void> action(String message, Future<void> Function() work) async {
    setState(() {
      busy = true;
      status = message;
      error = null;
    });
    try {
      await work();
      await refresh();
      if (mounted) setState(() => status = 'Готово');
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          status = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export(LocalBackupEntry entry) async {
    if (Platform.isIOS || Platform.isAndroid) {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(entry.path)],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else {
      final destination = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить локальную копию',
        fileName: p.basename(entry.path),
      );
      if (destination != null &&
          p.normalize(destination) != p.normalize(entry.path)) {
        await File(entry.path).copy(destination);
      }
    }
  }

  Future<void> restore(String path) async {
    final connected = ref.read(syncProvider).connected;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Восстановить локальную копию?'),
        content: Text(
          'Заметки, события и настройки на этом устройстве будут заменены. Сначала сохраним текущие данные в отдельную копию.${connected ? '\n\nСинхронизация с VPS отключится. Сервер и остальные устройства останутся без изменений.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await action(
        'Проверяем архив и восстанавливаем данные…',
        () => service.restore(path),
      );
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Работает без VPS и интернета. В копию входят заметки, папки, события, настройки и вложения на этом устройстве.',
          style: TextStyle(color: context.palette.muted, height: 1.5),
        ),
        const SizedBox(height: 8),
        Text(
          'Локальный архив не зашифрован. Сохраняйте его в доверенном месте.',
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => action('Создаём локальную копию…', () async {
                      await service.create();
                    }),
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('Создать на устройстве'),
            ),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => guard(context, () async {
                      final file = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['ygglocal'],
                      );
                      if (file == null || !mounted) return;
                      final path = file.files.single.path;
                      if (path == null) {
                        throw StateError('Не удалось прочитать архив');
                      }
                      await restore(path);
                    }),
              icon: const Icon(Icons.restore_rounded),
              label: const Text('Восстановить из файла'),
            ),
            if (!Platform.isIOS && !Platform.isAndroid)
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => guard(context, () async {
                        final folder = await service.folder();
                        if (!await launchUrl(
                          Uri.directory(folder.path),
                          mode: LaunchMode.externalApplication,
                        )) {
                          throw StateError(
                            'Не удалось открыть папку ${folder.path}',
                          );
                        }
                      }),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Открыть папку с копиями'),
              ),
          ],
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(status!, style: const TextStyle(fontSize: 12)),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (entries.isNotEmpty) const Divider(height: 28),
        for (final entry in entries.take(30))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(
              DateFormat(
                'd MMMM yyyy · HH:mm',
                'ru',
              ).format(entry.created.toLocal()),
            ),
            subtitle: Text(
              '${(entry.bytes / 1048576).toStringAsFixed(1)} МБ · на этом устройстве',
            ),
            trailing: PopupMenuButton<String>(
              enabled: !busy,
              tooltip: 'Действия с копией',
              onSelected: (value) async {
                if (value == 'restore') {
                  await restore(entry.path);
                  return;
                }
                if (value == 'export') {
                  await action('Сохраняем копию…', () => export(entry));
                  return;
                }
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('Удалить эту локальную копию?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialog, false),
                        child: const Text('Отмена'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: const Text('Удалить'),
                      ),
                    ],
                  ),
                );
                if (yes == true && mounted) {
                  await action('Удаляем копию…', () async {
                    await File(entry.path).delete();
                  });
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'export',
                  child: Text('Сохранить / поделиться'),
                ),
                PopupMenuItem(value: 'restore', child: Text('Восстановить')),
                PopupMenuItem(value: 'delete', child: Text('Удалить копию')),
              ],
            ),
          ),
      ],
    ),
  );
}
