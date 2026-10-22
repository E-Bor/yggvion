import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import 'theme.dart';

void toggleLastCalendarTimer(BuildContext context, WidgetRef ref) {
  final repo = ref.read(appProvider),
      task = ref.read(appProvider).globalTimerTask;
  if (task == null || task.done) return;
  guard(context, () => repo.toggleCalendarTimer(task));
}

class TimerControl extends ConsumerStatefulWidget {
  const TimerControl({super.key, this.compact = false});
  final bool compact;
  @override
  ConsumerState<TimerControl> createState() => _TimerControlState();
}

class _TimerControlState extends ConsumerState<TimerControl> {
  Timer? ticker;
  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (ref.read(appProvider).snapshot.sessions.any((s) => s.running) &&
          mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider), task = repo.globalTimerTask;
    final running =
        task != null &&
        repo.snapshot.sessions.any((s) => s.taskId == task.id && s.running);
    final duration = task == null
        ? Duration.zero
        : repo.snapshot.spent(task.id, repo.now());
    String part(int n) => n.toString().padLeft(2, '0');
    final time =
        '${part(duration.inHours)}:${part(duration.inMinutes % 60)}:${part(duration.inSeconds % 60)}';
    final tooltip = task == null
        ? 'Включите таймер задачи в календаре'
        : '${running ? 'Остановить' : 'Продолжить'}: ${task.title} · ⌘⇧Space / Ctrl+Shift+Space';
    final enabled = task != null && !task.done;
    return Tooltip(
      message: tooltip,
      child: widget.compact
          ? IconButton(
              key: const ValueKey('global-timer'),
              onPressed: enabled
                  ? () => toggleLastCalendarTimer(context, ref)
                  : null,
              icon: Icon(
                running
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                color: running ? context.palette.pink : null,
              ),
            )
          : Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: running
                    ? context.palette.pink.withValues(alpha: .08)
                    : context.palette.raised.withValues(alpha: .5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: running
                      ? context.palette.pink.withValues(alpha: .3)
                      : context.palette.border,
                  width: .6,
                ),
              ),
              child: TextButton.icon(
                key: const ValueKey('global-timer'),
                onPressed: enabled
                    ? () => toggleLastCalendarTimer(context, ref)
                    : null,
                icon: Icon(
                  running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 18,
                  color: running ? context.palette.pink : null,
                ),
                label: Text(
                  time,
                  style: TextStyle(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontSize: 12,
                    color: running
                        ? context.palette.pink
                        : context.palette.muted,
                  ),
                ),
              ),
            ),
    );
  }
}
