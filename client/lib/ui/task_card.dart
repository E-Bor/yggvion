import '../l10n/strings.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import 'providers.dart';
import 'task_editor.dart';
import 'theme.dart';

class BoardTask extends StatelessWidget {
  const BoardTask({super.key, required this.task});
  final Task task;
  @override
  Widget build(BuildContext context) {
    final card = TaskCard(
      key: ValueKey('board-task-${task.id}'),
      task: task,
      enableLongPress: false,
    );
    final feedback = Material(
      color: Colors.transparent,
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 260,
        child: IgnorePointer(
          child: TaskCard(task: task, enableLongPress: false),
        ),
      ),
    );
    final ghost = Opacity(opacity: .25, child: card);
    final mobile =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    if (mobile) {
      return LongPressDraggable<Task>(
        data: task,
        feedback: feedback,
        childWhenDragging: ghost,
        hapticFeedbackOnStart: true,
        child: card,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<Task>(
        data: task,
        feedback: feedback,
        childWhenDragging: ghost,
        child: card,
      ),
    );
  }
}

class TaskCard extends ConsumerWidget {
  const TaskCard({
    super.key,
    required this.task,
    this.selected = false,
    this.onSelect,
    this.compact = false,
    this.showDescription = false,
    this.enableLongPress = true,
  });
  final Task task;
  final bool selected, compact, enableLongPress, showDescription;
  final VoidCallback? onSelect;
  void action(BuildContext context, WidgetRef ref, String value) {
    final repo = ref.read(appProvider);
    guard(context, () async {
      switch (value) {
        case 'edit':
          await openTask(context, task: task);
        case 'review':
          await repo.completeForReview(task);
        case 'time':
          await editSession(context, task);
        case 'delete':
          await deleteTask(context, ref, task);
        default:
          if (value.startsWith('status:')) {
            await repo.status(task, TaskStatus.parse(value.substring(7)));
          }
      }
    });
  }

  List<PopupMenuEntry<String>> menu() => [
    PopupMenuItem(value: 'edit', child: Text(tr("Редактировать"))),
    const PopupMenuDivider(),
    if (!task.done)
      PopupMenuItem(
        value: 'review',
        child: Text(tr("Готово → создать проверку")),
      ),
    PopupMenuItem(value: 'time', child: Text(tr("Добавить потраченное время"))),
    const PopupMenuDivider(),
    for (final s in TaskStatus.values)
      PopupMenuItem(value: 'status:${s.wire}', child: Text(s.label)),
    const PopupMenuDivider(),
    PopupMenuItem(value: 'delete', child: Text(tr("Удалить"))),
  ];
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(appProvider),
        project = repo.snapshot.project(task.projectId),
        running = repo.snapshot.sessions.any(
          (s) => s.taskId == task.id && s.running,
        );
    final accent = context.palette.accent(Color(repo.snapshot.taskColor(task)));
    return GestureDetector(
      onSecondaryTapDown: (details) async {
        final value = await showMenu<String>(
          context: context,
          position: menuPosition(context, details.globalPosition),
          items: menu(),
        );
        if (value != null && context.mounted) action(context, ref, value);
      },
      onLongPress: !enableLongPress
          ? null
          : () async {
              final box = context.findRenderObject() as RenderBox;
              final point = box.localToGlobal(Offset.zero);
              final value = await showMenu<String>(
                context: context,
                position: menuPosition(context, point),
                items: menu(),
              );
              if (value != null && context.mounted) action(context, ref, value);
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: context.palette.taskSurface(
            accent,
            subdued: task.done,
            selected: selected,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? accent
                : running
                ? context.palette.pink.withValues(alpha: .5)
                : accent.withValues(alpha: .3),
            width: .7,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onSelect ?? () => openTask(context, task: task),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 6 : 10,
              vertical: compact ? 6 : 10,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: Checkbox(
                    value: task.done,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    onChanged: (v) => guard(
                      context,
                      () => repo.status(
                        task,
                        v == true ? TaskStatus.done : TaskStatus.todo,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(
                        task.title,
                        maxLines: compact ? 2 : 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          decoration: task.done
                              ? TextDecoration.lineThrough
                              : null,
                          color: task.done
                              ? context.palette.muted
                              : context.palette.text,
                        ),
                      ),
                      if (showDescription)
                        TaskDescriptionPreview(description: task.description),
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (project != null)
                            Text(
                              '● ${project.title}',
                              style: TextStyle(
                                fontSize: 10,
                                color: context.palette.accent(
                                  Color(project.color),
                                ),
                              ),
                            ),
                          if (repo.snapshot.estimate(task.id) > Duration.zero)
                            Text(
                              formatDuration(repo.snapshot.estimate(task.id)),
                              style: TextStyle(
                                fontSize: 10,
                                color: context.palette.muted,
                              ),
                            ),
                          if (running ||
                              repo.snapshot.spent(task.id, repo.now()) >
                                  Duration.zero)
                            Text(
                              formatDuration(
                                repo.snapshot.spent(task.id, repo.now()),
                              ),
                              style: TextStyle(
                                fontSize: 10,
                                color: context.palette.pink,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: running
                        ? tr("Остановить таймер")
                        : tr("Начать работу"),
                    onPressed: task.done
                        ? null
                        : () => guard(context, () => repo.toggleTimer(task)),
                    icon: Icon(
                      running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 22,
                      color: running
                          ? context.palette.pink
                          : context.palette.muted,
                    ),
                  ),
                ),
                if (!compact)
                  SizedBox(
                    width: 25,
                    height: 32,
                    child: PopupMenuButton<String>(
                      key: ValueKey('task-menu-${task.id}'),
                      tooltip: tr("Действия с задачей"),
                      padding: EdgeInsets.zero,
                      iconSize: 17,
                      onSelected: (v) => action(context, ref, v),
                      itemBuilder: (_) => menu(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TaskDescriptionPreview extends StatelessWidget {
  const TaskDescriptionPreview({super.key, required this.description});

  final String description;

  @override
  Widget build(BuildContext context) {
    final firstLine = LineSplitter.split(
      description,
    ).map((line) => line.trim()).where((line) => line.isNotEmpty).firstOrNull;
    if (firstLine == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        firstLine,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: context.palette.muted),
      ),
    );
  }
}
