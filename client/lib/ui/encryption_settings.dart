import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/sync.dart';
import '../data/encryption.dart';
import 'providers.dart';
import 'server_settings.dart';
import 'theme.dart';

class EncryptionPage extends ConsumerWidget {
  const EncryptionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsDetail(
    title: 'Шифрование',
    children: [
      const EncryptionSettings(),
      settingsCard('Очистить хранилище', [
        const Text(
          'Удалить все данные Yggvion с этого устройства и начать заново. '
          'Подходит, если на устройстве остался прежний формат шифрования.',
          style: TextStyle(height: 1.5),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('clear-storage'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Очистить хранилище'),
            onPressed: () => showStorageResetDialog(
              context,
              reset: ref.read(resetStorageProvider),
            ),
          ),
        ),
      ]),
    ],
  );
}

Future<bool> showStorageResetDialog(
  BuildContext context, {
  required Future<void> Function() reset,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StorageResetDialog(reset: reset),
    ) ??
    false;

class _StorageResetDialog extends StatefulWidget {
  const _StorageResetDialog({required this.reset});
  final Future<void> Function() reset;

  @override
  State<_StorageResetDialog> createState() => _StorageResetDialogState();
}

class _StorageResetDialogState extends State<_StorageResetDialog> {
  static const phrase = 'Удалить хранилище';
  final controller = TextEditingController();
  bool busy = false;
  String? error;

  Future<void> submit() async {
    if (busy || controller.text != phrase) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.reset();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Удалить хранилище?'),
      icon: Icon(
        Icons.delete_forever_outlined,
        color: Theme.of(context).colorScheme.error,
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'С этого устройства будут удалены задачи, заметки, проекты, '
                'учёт времени, вложения, локальные резервные копии, пароль и настройки. '
                'Подключение к серверу будет сброшено.\n\n'
                'Данные на VPS и копии, сохранённые вне приложения, останутся. '
                'Это действие нельзя отменить.',
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 20),
              const Text('Для подтверждения введите «Удалить хранилище»:'),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('storage-reset-confirmation'),
                controller: controller,
                autofocus: true,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Фраза подтверждения',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => submit(),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const ValueKey('confirm-storage-reset'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: busy || controller.text != phrase ? null : submit,
          child: const Text('Удалить хранилище'),
        ),
      ],
    ),
  );
}

class EncryptionSettings extends ConsumerStatefulWidget {
  const EncryptionSettings({super.key});
  @override
  ConsumerState<EncryptionSettings> createState() => _EncryptionSettingsState();
}

class _EncryptionSettingsState extends ConsumerState<EncryptionSettings> {
  @override
  Widget build(BuildContext context) {
    ref.watch(appProvider);
    final sync = ref.read(syncProvider);
    final locked = sync.needsEncryptionKey;
    final configured = sync.passwordConfigured;
    return settingsCard('Сквозное шифрование', [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            locked ? Icons.lock_outline_rounded : Icons.password_rounded,
            color: context.accentColor,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              locked
                  ? 'Введите пароль, чтобы открыть личные данные на этом устройстве.'
                  : configured
                  ? 'Пароль шифрования настроен. Пароль сохранён локально и используется автоматически при запуске.'
                  : 'Создайте пароль для синхронизации и резервных копий. Сохранять длинный ключ вручную больше не нужно.',
              style: const TextStyle(height: 1.5),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        'Пароль не отправляется на сервер. Для восстановления на новом устройстве потребуется ваш пароль и доступ к серверу или файлу копии.',
        style: TextStyle(color: context.palette.muted, height: 1.4),
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: const ValueKey('encryption-password'),
          icon: Icon(locked ? Icons.lock_open_rounded : Icons.password_rounded),
          label: Text(
            locked
                ? 'Ввести пароль'
                : configured
                ? 'Сменить пароль'
                : 'Создать пароль',
          ),
          onPressed: () => showEncryptionPasswordDialog(
            context,
            creating: !locked,
            changing: !locked && configured,
            submit: (password, current) async {
              if (locked) {
                await sync.unlockWithPassword(password);
              } else {
                await sync.setEncryptionPassword(
                  password,
                  currentPassword: current,
                );
              }
            },
          ),
        ),
      ),
    ]);
  }
}

Future<bool> ensureEncryptionPassword(
  BuildContext context,
  WidgetRef ref,
) async {
  final sync = ref.read(syncProvider);
  if (!sync.needsEncryptionKey) {
    try {
      await sync.prepareWorkspaceKey();
    } on PasswordRequired {
      // Ask once on a new device or after a password change.
    } on StateError {
      if (!sync.needsEncryptionKey) rethrow;
    }
  }
  if (!context.mounted) return false;
  if (!sync.needsEncryptionKey && sync.passwordConfigured) return true;
  final locked = sync.needsEncryptionKey;
  return showEncryptionPasswordDialog(
    context,
    creating: !locked,
    submit: (password, _) async {
      if (locked) {
        await sync.unlockWithPassword(password);
      } else {
        await sync.setEncryptionPassword(password);
      }
    },
  );
}

Future<bool> showEncryptionPasswordDialog(
  BuildContext context, {
  bool creating = false,
  bool changing = false,
  required Future<void> Function(String password, String? current) submit,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PasswordDialog(
        creating: creating,
        changing: changing,
        submit: submit,
      ),
    ) ??
    false;

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.creating,
    required this.changing,
    required this.submit,
  });
  final bool creating, changing;
  final Future<void> Function(String password, String? current) submit;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final password = TextEditingController(),
      confirm = TextEditingController(),
      current = TextEditingController();
  bool busy = false, visible = false;
  String? error;
  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    current.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      PasswordConfig.validatePassword(password.text, creating: widget.creating);
      if (widget.creating && password.text != confirm.text) {
        throw const FormatException('Пароли не совпадают');
      }
      await widget.submit(password.text, widget.changing ? current.text : null);
      if (mounted) {
        setState(() => busy = false);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is FormatException ? e.message : '$e';
        });
      }
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool autofocus = false,
    bool last = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: !busy,
      obscureText: !visible,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 256,
      autofillHints: [
        widget.creating && controller != current
            ? AutofillHints.newPassword
            : AutofillHints.password,
      ],
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onSubmitted: last ? (_) => save() : null,
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        suffixIcon: controller == password
            ? IconButton(
                tooltip: visible ? 'Скрыть пароль' : 'Показать пароль',
                onPressed: () => setState(() => visible = !visible),
                icon: Icon(
                  visible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      icon: Icon(Icons.lock_outline_rounded, color: context.accentColor),
      title: Text(
        widget.changing
            ? 'Сменить пароль шифрования'
            : widget.creating
            ? 'Создайте пароль шифрования'
            : 'Введите пароль шифрования',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.creating
                      ? 'Используйте фразу от 12 символов. Сохраните её в менеджере паролей: сервер не сможет восстановить пароль.'
                      : 'Введите пароль пространства или пароль, действовавший при создании резервной копии.',
                  style: const TextStyle(height: 1.4),
                ),
                if (widget.changing)
                  field(current, 'Текущий пароль', autofocus: true),
                field(
                  password,
                  widget.creating ? 'Новый пароль' : 'Пароль',
                  autofocus: !widget.changing,
                  last: !widget.creating,
                ),
                if (widget.creating)
                  field(confirm, 'Повторите пароль', last: true),
                if (widget.changing)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Данные на сервере будут перешифрованы. На других устройствах потребуется новый пароль. Старые копии сохраняют прежний пароль.',
                      style: TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(widget.creating ? 'Сохранить пароль' : 'Продолжить'),
        ),
      ],
    ),
  );
}
