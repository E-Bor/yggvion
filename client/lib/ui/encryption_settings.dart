import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/sync.dart';
import '../data/encryption.dart';
import 'providers.dart';
import 'server_settings.dart';
import 'theme.dart';

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
                  ? 'Пароль шифрования настроен. Это устройство запоминает доступ в защищённом хранилище.'
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
      PasswordEnvelope.validatePassword(
        password.text,
        creating: widget.creating,
      );
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
                      'Старые файлы копий сохраняют прежний пароль. Подключённые устройства продолжат работать.',
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
