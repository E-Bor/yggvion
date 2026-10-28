import '../l10n/strings.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/models.dart';
import 'providers.dart';
import 'task_card.dart';
import 'task_editor.dart';
import 'theme.dart';

Future<void> shareCalendar(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const CalendarShareDialog(),
);

class CalendarShareDialog extends ConsumerStatefulWidget {
  const CalendarShareDialog({super.key});
  @override
  ConsumerState<CalendarShareDialog> createState() =>
      _CalendarShareDialogState();
}

class _CalendarShareDialogState extends ConsumerState<CalendarShareDialog> {
  int days = 14;
  bool busy = false;
  bool copied = false;
  Map<String, dynamic>? link;
  String? error;
  Timer? ticker;

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> create() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await ref.read(syncProvider).createCalendarShare(days);
      if (!mounted) return;
      setState(() {
        link = result;
        copied = false;
      });
      ticker?.cancel();
      ticker = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
      try {
        await Clipboard.setData(ClipboardData(text: result['url'] as String));
        if (mounted) setState(() => copied = true);
      } on Object {
        if (mounted) {
          setState(
            () => error = tr(
              "Ссылка создана, но не удалось скопировать её. Выделите ссылку и скопируйте вручную.",
            ),
          );
        }
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(
          () => error = e.response?.statusCode == 404
              ? tr("Обновите сервер, чтобы делиться календарём.")
              : e.response?.statusCode == 503
              ? tr(
                  "Не удалось подготовить публичный HTTPS. Проверьте доступность портов публичной страницы на VPS и повторите попытку.",
                )
              : tr(
                  "Не удалось создать ссылку. Проверьте соединение и повторите попытку.",
                ),
        );
      }
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final expires = link == null
        ? null
        : DateTime.parse(link!['expires'] as String);
    final remaining = expires?.difference(DateTime.now());
    final expired = remaining != null && remaining <= Duration.zero;
    return AlertDialog(
      title: Text(tr("Поделиться календарём")),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.accentColor.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.visibility_outlined,
                      color: context.accentColor,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tr(
                          "Гость увидит только занятые интервалы. Названия, описания и проекты скрыты. Предложения попадут в ваш планировщик.",
                        ),
                        style: TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (link == null) ...[
                Text(tr("Показать занятость на ближайшие")),
                const SizedBox(height: 12),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  segments: [
                    ButtonSegment(value: 7, label: Text(tr("7 дней"))),
                    ButtonSegment(value: 14, label: Text(tr("14 дней"))),
                    ButtonSegment(value: 30, label: Text(tr("30 дней"))),
                  ],
                  selected: {days},
                  onSelectionChanged: busy
                      ? null
                      : (v) => setState(() => days = v.first),
                ),
                const SizedBox(height: 14),
                Text(
                  tr(
                    "Ссылка действует 1 час. Любой получивший её сможет предложить встречу. Доступ можно отозвать раньше.",
                  ),
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    Icon(
                      expired ? Icons.timer_off_outlined : Icons.timer_outlined,
                      size: 18,
                      color: context.accentColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        expired
                            ? tr("Срок ссылки закончился")
                            : tr("Доступ ещё {0} мин.", [
                                remaining!.inMinutes + 1,
                              ]),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: context.palette.raised,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    link!['url'] as String,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
                if (copied && !expired)
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: context.accentColor,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            tr("Ссылка скопирована"),
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                TextButton(
                  onPressed: busy || expired
                      ? null
                      : () => guard(context, () async {
                          setState(() => busy = true);
                          try {
                            await ref
                                .read(syncProvider)
                                .request(
                                  'DELETE',
                                  '/api/v1/calendar-shares/${link!['id']}',
                                );
                            if (mounted) {
                              ticker?.cancel();
                              setState(() {
                                link = null;
                                copied = false;
                                error = null;
                              });
                            }
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        }),
                  child: Text(tr("Отозвать доступ")),
                ),
              ],
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (busy && link == null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    tr(
                      "При первом запуске подготовка защищённой страницы может занять пару минут.",
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.muted,
                    ),
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr("Закрыть")),
        ),
        if (link == null || expired)
          FilledButton(
            onPressed: busy ? null : create,
            child: Text(tr("Создать ссылку")),
          ),
      ],
    );
  }
}

class ProposedTaskCard extends ConsumerWidget {
  const ProposedTaskCard({
    super.key,
    required this.task,
    required this.onSelect,
    this.onResolved,
    this.selected = false,
  });
  final Task task;
  final VoidCallback onSelect;
  final VoidCallback? onResolved;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(appProvider);
    final zone = tz.getLocation(repo.snapshot.settings.timezone);
    final start = tz.TZDateTime.from(task.proposedStart!, zone);
    final end = tz.TZDateTime.from(task.proposedEnd!, zone);
    final label =
        '${DateFormat('d MMM · HH:mm', AppLocale.language).format(start)} — ${DateFormat(dayKey(start) == dayKey(end) ? 'HH:mm' : 'd MMM · HH:mm', AppLocale.language).format(end)}';
    return AnimatedContainer(
      key: ValueKey('proposal-${task.id}'),
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          context.accentColor.withValues(alpha: .06),
          context.palette.surface,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: context.accentColor.withValues(alpha: selected ? .8 : .25),
        ),
      ),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.mark_email_unread_outlined,
                    size: 15,
                    color: context.accentColor,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    tr("ПРЕДЛОЖЕНО"),
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                      color: context.accentColor,
                    ),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    tooltip: tr("Действия с предложением"),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 180),
                    icon: const Icon(Icons.more_horiz_rounded, size: 18),
                    onSelected: (value) {
                      if (value == 'edit') openTask(context, task: task);
                      if (value == 'decline') {
                        guard(context, () async {
                          await repo.deleteEntity(task.entity);
                          if (context.mounted) onResolved?.call();
                        });
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(tr("Открыть предложение")),
                      ),
                      PopupMenuItem(
                        value: 'decline',
                        child: Text(tr("Отклонить")),
                      ),
                    ],
                  ),
                ],
              ),
              Text(
                task.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TaskDescriptionPreview(description: task.description),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: context.accentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: ValueKey('accept-proposal-${task.id}'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => guard(context, () async {
                      await repo.acceptProposal(task);
                      if (context.mounted) onResolved?.call();
                    }),
                    child: Text(tr("Принять")),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
