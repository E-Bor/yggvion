import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import '../domain/statistics.dart';
import 'providers.dart';
import 'theme.dart';

typedef _ReportInput = ({
  Snapshot snapshot,
  List<TimeRange> activity,
  DateTime start,
  DateTime end,
  DateTime now,
  tz.Location location,
});

StatisticsReport _calculate(_ReportInput input) => StatisticsReport.calculate(
  input.snapshot,
  input.activity,
  input.start,
  input.end,
  input.now,
  location: input.location,
);

class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});
  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends ConsumerState<StatisticsPage> {
  int days = 7, offset = 0, generation = 0;
  StatisticsReport? report;
  DateTime? firstActivity;
  String? error;
  bool busy = false;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!busy) load();
    });
  }

  Future<void> load({bool reset = false}) async {
    if (!mounted) return;
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      if (reset) report = null;
    });
    try {
      final repo = ref.read(appProvider);
      final snapshot = repo.snapshot;
      final now = repo.now();
      final local = tz.TZDateTime.from(
        now,
        tz.getLocation(snapshot.settings.timezone),
      );
      final end = tz.TZDateTime(
        local.location,
        local.year,
        local.month,
        local.day + 1 - offset * days,
      );
      final start = tz.TZDateTime(
        local.location,
        end.year,
        end.month,
        end.day - days,
      );
      await ref.read(activityProvider)?.flush();
      final activity = await repo.db.activity(start, end);
      final first = await repo.db.activityStarted;
      final next = await compute(_calculate, (
        snapshot: snapshot,
        activity: activity,
        start: start,
        end: end,
        now: now,
        location: local.location,
      ));
      if (!mounted || request != generation) return;
      setState(() {
        report = next;
        firstActivity = first;
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() => error = 'Не удалось рассчитать статистику: $e');
      }
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appProvider.select((repo) => repo.snapshot), (_, _) => load());
    final data = report;
    final usageError = ref.watch(activityProvider)?.error;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Статистика'),
        actions: [
          IconButton(
            tooltip: 'Обновить статистику',
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 2,
            child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('statistics-scroll'),
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 16 : 28,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Время в деталях',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Как соотносятся планы и учтённое время',
                        style: TextStyle(color: context.palette.muted),
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 20,
                        runSpacing: 12,
                        children: [
                          SegmentedButton<int>(
                            key: const ValueKey('statistics-period'),
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 7, label: Text('7 дней')),
                              ButtonSegment(value: 30, label: Text('30 дней')),
                              ButtonSegment(value: 90, label: Text('90 дней')),
                            ],
                            selected: {days},
                            onSelectionChanged: (value) {
                              days = value.single;
                              offset = 0;
                              load(reset: true);
                            },
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Предыдущий период',
                                onPressed: () {
                                  offset++;
                                  load(reset: true);
                                },
                                icon: const Icon(Icons.chevron_left_rounded),
                              ),
                              Text(
                                data == null
                                    ? 'Загрузка…'
                                    : '${DateFormat('d MMM', 'ru').format(data.days.first.date)} — ${DateFormat('d MMM y', 'ru').format(data.days.last.date)}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Следующий период',
                                onPressed: offset == 0
                                    ? null
                                    : () {
                                        offset--;
                                        load(reset: true);
                                      },
                                icon: const Icon(Icons.chevron_right_rounded),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      if (error != null)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              children: [
                                Text(
                                  error!,
                                  style: TextStyle(color: context.palette.pink),
                                ),
                                TextButton(
                                  onPressed: load,
                                  child: const Text('Повторить'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (data != null) ...[
                        _Totals(data: data),
                        const SizedBox(height: 18),
                        _StatCard(
                          title: 'План и факт',
                          subtitle: days == 90
                              ? 'По неделям · нажмите на столбец для деталей'
                              : 'По дням · нажмите на столбец для деталей',
                          child: _TimeChart(
                            key: ValueKey('work-$days-$offset'),
                            days: data.days,
                          ),
                        ),
                        if (data.overlap > Duration.zero)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                            child: Text(
                              '${formatDuration(data.overlap)} записаны одновременно в разных задачах. В общем факте пересечения считаются один раз; в проектах и задачах показан их собственный учёт.',
                              style: TextStyle(
                                color: context.palette.pink,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                        const SizedBox(height: 18),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final projects = _ProjectCard(
                              projects: data.projects,
                            );
                            final estimates = _EstimateCard(
                              estimates: data.estimates,
                            );
                            if (constraints.maxWidth < 850) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  projects,
                                  const SizedBox(height: 18),
                                  estimates,
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: projects),
                                const SizedBox(width: 18),
                                Expanded(child: estimates),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 18),
                        _StatCard(
                          title: 'Использование приложения',
                          subtitle:
                              'Только это устройство${firstActivity == null ? '' : ' · с ${DateFormat('d MMM y', 'ru').format(tz.TZDateTime.from(firstActivity!, tz.getLocation(ref.read(appProvider).snapshot.settings.timezone)))}'}',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                spacing: 32,
                                runSpacing: 16,
                                children: [
                                  _SmallTotal(
                                    label: 'Активное время',
                                    value: formatDuration(data.application),
                                  ),
                                  _SmallTotal(
                                    label: 'Сеансов использования',
                                    value: '${data.applicationSessions}',
                                  ),
                                ],
                              ),
                              if (usageError != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(
                                    usageError,
                                    style: TextStyle(
                                      color: context.palette.pink,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 20),
                              _TimeChart(
                                key: ValueKey('usage-$days-$offset'),
                                days: data.days,
                                application: true,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Время в активном окне. После 2 минут без действий учёт приостанавливается. Рабочий таймер считается отдельно.',
                                style: TextStyle(
                                  color: context.palette.muted,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Сейчас в пространстве: ${data.tasks} задач · ${data.notes} заметок',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.palette.muted,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const _StatisticsExplanation(),
                      ] else if (busy)
                        const SizedBox(
                          height: 260,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.data});
  final StatisticsReport data;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 800 ? 4 : 2;
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      final completion = data.plannedTasks == 0
          ? null
          : (100 * data.completedTasks / data.plannedTasks).round();
      final values = [
        (
          label: 'Фактическое время',
          value: formatDuration(data.actual),
          detail: 'Без двойного учёта',
          icon: Icons.timelapse_rounded,
        ),
        (
          label: 'Запланировано',
          value: formatDuration(data.planned),
          detail: 'В выбранном периоде',
          icon: Icons.calendar_today_outlined,
        ),
        (
          label: 'Закрыто из плана',
          value: completion == null ? '—' : '$completion%',
          detail: '${data.completedTasks} из ${data.plannedTasks} задач',
          icon: Icons.task_alt_rounded,
        ),
        (
          label: 'Дней с учётом',
          value: '${data.activeDays}',
          detail: 'Из ${data.days.length} дней',
          icon: Icons.bar_chart_rounded,
        ),
      ];
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final item in values)
            SizedBox(
              width: width,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(item.icon, color: context.accentColor, size: 20),
                      const SizedBox(height: 16),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          item.value,
                          style: const TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.detail,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title, subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: context.palette.muted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 22),
          child,
        ],
      ),
    ),
  );
}

class _SmallTotal extends StatelessWidget {
  const _SmallTotal({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(fontSize: 12, color: context.palette.muted)),
    ],
  );
}

class _TimeChart extends StatefulWidget {
  const _TimeChart({super.key, required this.days, this.application = false});
  final List<DailyStatistics> days;
  final bool application;
  @override
  State<_TimeChart> createState() => _TimeChartState();
}

class _TimeChartState extends State<_TimeChart> {
  int? selected;
  @override
  Widget build(BuildContext context) {
    final groups =
        <({DateTime start, DateTime end, Duration plan, Duration fact})>[];
    final step = widget.days.length > 31 ? 7 : 1;
    for (var i = 0; i < widget.days.length; i += step) {
      final slice = widget.days.skip(i).take(step).toList();
      groups.add((
        start: slice.first.date,
        end: slice.last.date,
        plan: widget.application
            ? Duration.zero
            : sumDurations(slice.map((d) => d.planned)),
        fact: sumDurations(
          slice.map((d) => widget.application ? d.application : d.actual),
        ),
      ));
    }
    final maximum = groups.fold(
      0.0,
      (value, day) => math.max(
        value,
        math.max(day.plan.inSeconds / 3600, day.fact.inSeconds / 3600),
      ),
    );
    final ceiling = math.max(1.0, maximum.ceilToDouble());
    final accent = widget.application
        ? context.palette.green
        : context.accentColor;
    final picked =
        groups[(selected ?? groups.length - 1).clamp(0, groups.length - 1)];
    String label(DateTime start, DateTime end) => start == end
        ? DateFormat('d MMM', 'ru').format(start)
        : '${DateFormat('d MMM', 'ru').format(start)} — ${DateFormat('d MMM', 'ru').format(end)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.application) ...[
          Row(
            children: [
              _Legend(color: context.palette.muted, text: 'План'),
              const SizedBox(width: 20),
              _Legend(color: accent, text: 'Факт'),
            ],
          ),
          const SizedBox(height: 18),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              height: 180,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${ceiling.toInt()} ч',
                    style: TextStyle(
                      fontSize: 10,
                      color: context.palette.muted,
                    ),
                  ),
                  Text(
                    '${ceiling / 2 == (ceiling / 2).round() ? (ceiling / 2).toInt() : (ceiling / 2).toStringAsFixed(1)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: context.palette.muted,
                    ),
                  ),
                  Text(
                    '0',
                    style: TextStyle(
                      fontSize: 10,
                      color: context.palette.muted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  SizedBox(
                    height: 180,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _GridPainter(context.palette.border),
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (var i = 0; i < groups.length; i++)
                              Expanded(
                                child: Tooltip(
                                  message:
                                      '${label(groups[i].start, groups[i].end)}\n${widget.application ? 'Активность' : 'Факт'}: ${formatDuration(groups[i].fact)}${widget.application ? '' : '\nПлан: ${formatDuration(groups[i].plan)}'}',
                                  child: Semantics(
                                    label:
                                        '${label(groups[i].start, groups[i].end)}, ${widget.application ? 'активность' : 'факт'} ${formatDuration(groups[i].fact)}, план ${formatDuration(groups[i].plan)}',
                                    button: true,
                                    selected: selected == i,
                                    child: InkWell(
                                      key: ValueKey(
                                        '${widget.application ? 'usage' : 'work'}-bar-$i',
                                      ),
                                      onTap: () => setState(() => selected = i),
                                      borderRadius: BorderRadius.circular(5),
                                      child: Container(
                                        height: 180,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 1,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: selected == i
                                              ? accent.withValues(alpha: .08)
                                              : null,
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            if (!widget.application) ...[
                                              Expanded(
                                                child: _Bar(
                                                  duration: groups[i].plan,
                                                  maximum: ceiling,
                                                  color: context.palette.muted
                                                      .withValues(alpha: .45),
                                                ),
                                              ),
                                              const SizedBox(width: 2),
                                            ],
                                            Expanded(
                                              child: _Bar(
                                                duration: groups[i].fact,
                                                maximum: ceiling,
                                                color: accent,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (var i = 0; i < groups.length; i++)
                        Expanded(
                          child: Text(
                            groups.length <= 7 ||
                                    i % (groups.length > 15 ? 5 : 3) == 0
                                ? '${groups[i].start.day}'
                                : '',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            Text(
              label(picked.start, picked.end),
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
            if (!widget.application)
              Text(
                'План ${formatDuration(picked.plan)}',
                style: TextStyle(fontSize: 12, color: context.palette.muted),
              ),
            Text(
              '${widget.application ? 'Активно' : 'Факт'} ${formatDuration(picked.fact)}',
              style: TextStyle(fontSize: 12, color: accent),
            ),
          ],
        ),
        if (maximum == 0)
          Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'За этот период пока нет данных.',
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
          ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.duration,
    required this.maximum,
    required this.color,
  });
  final Duration duration;
  final double maximum;
  final Color color;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
    height: duration == Duration.zero
        ? 0
        : math.max(2, duration.inSeconds / 3600 / maximum * 176),
    decoration: BoxDecoration(
      color: color,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
    ),
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.border);
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = border.withValues(alpha: .6)
      ..strokeWidth = .5;
    for (final fraction in [0.0, .5, 1.0]) {
      final y = fraction * (size.height - 1);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => oldDelegate.border != border;
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 7),
      Text(text, style: TextStyle(fontSize: 12, color: context.palette.muted)),
    ],
  );
}

class _ProjectCard extends StatefulWidget {
  const _ProjectCard({required this.projects});
  final List<ProjectStatistics> projects;
  @override
  State<_ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<_ProjectCard> {
  bool all = false;
  @override
  Widget build(BuildContext context) {
    final maximum = widget.projects.fold(
      1,
      (n, p) => math.max(n, p.actual.inSeconds),
    );
    return _StatCard(
      title: 'Куда уходит время',
      subtitle: 'Фактическое время по проектам за период',
      child: widget.projects.isEmpty
          ? Text(
              'Проекты появятся вместе с планом или учётом времени.',
              style: TextStyle(color: context.palette.muted, height: 1.5),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final project in widget.projects.take(
                  all ? widget.projects.length : 6,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: context.palette.accent(
                                  Color(project.color),
                                ),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                project.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              formatDuration(project.actual),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: project.actual.inSeconds / maximum,
                            minHeight: 5,
                            backgroundColor: context.palette.raised,
                            color: context.palette.accent(Color(project.color)),
                            semanticsLabel:
                                '${project.title}: ${formatDuration(project.actual)}, план ${formatDuration(project.planned)}',
                          ),
                        ),
                        const SizedBox(height: 5),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            'План ${formatDuration(project.planned)}',
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (widget.projects.length > 6)
                  TextButton(
                    onPressed: () => setState(() => all = !all),
                    child: Text(
                      all
                          ? 'Свернуть'
                          : 'Все проекты (${widget.projects.length})',
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EstimateCard extends StatelessWidget {
  const _EstimateCard({required this.estimates});
  final List<EstimateComparison> estimates;
  @override
  Widget build(BuildContext context) {
    final measured = estimates.where((e) => e.actual > Duration.zero).toList();
    final delta = sumDurations(measured.map((e) => e.difference));
    return _StatCard(
      title: 'Точность эстимейта',
      subtitle: 'Завершённые задачи с планом в периоде · задача целиком',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (measured.isNotEmpty) ...[
            _SmallTotal(
              label: delta == Duration.zero
                  ? 'План совпал с фактом · ${measured.length} задач'
                  : '${delta.isNegative ? 'Меньше' : 'Больше'} плана · ${measured.length} задач с учётом',
              value:
                  '${delta.isNegative
                      ? '−'
                      : delta == Duration.zero
                      ? ''
                      : '+'}${formatDuration(delta.abs())}',
            ),
            const SizedBox(height: 20),
          ],
          if (estimates.isEmpty)
            Text(
              'Завершите запланированную задачу и запишите потраченное время, чтобы сравнить оценку с фактом.',
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
          for (final item in estimates.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    item.task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      Text(
                        'План ${formatDuration(item.planned)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.palette.muted,
                        ),
                      ),
                      Text(
                        item.actual == Duration.zero
                            ? 'Нет учёта времени'
                            : 'Факт ${formatDuration(item.actual)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: item.actual == Duration.zero
                              ? context.palette.muted
                              : context.accentColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (estimates.length > 8)
            Text(
              'Показаны 8 задач с наибольшим отклонением.',
              style: TextStyle(fontSize: 11, color: context.palette.muted),
            ),
        ],
      ),
    );
  }
}

class _StatisticsExplanation extends StatelessWidget {
  const _StatisticsExplanation();
  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      title: const Text(
        'Как считаются показатели',
        style: TextStyle(fontSize: 13),
      ),
      leading: Icon(
        Icons.info_outline_rounded,
        size: 19,
        color: context.palette.muted,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Text(
          'План — длительности блоков, попавшие в выбранный период, включая сохранённый невыполненный план прошлых дней. Событие на весь день учитывается целиком; дни рождения исключены.\n\n'
          'Факт — таймер и ручной учёт до текущего момента. Отменённые записи исключены, пересечения в общей сумме считаются один раз. Границы дней соответствуют часовому поясу приложения.\n\n'
          'Закрыто из плана — текущий статус задач, у которых есть блок в периоде. Это не история дат завершения. Удалённые задачи не учитываются.\n\n'
          'Точность эстимейта сравнивает текущий полный план завершённой задачи со всем её учтённым временем. Задачи без учёта не принимаются за нулевую фактическую длительность.\n\n'
          'Использование приложения сохраняется только на этом устройстве с момента обновления. Новый сеанс начинается при возвращении в приложение или после паузы без действий. Фоновое время не учитывается.',
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.6,
          ),
        ),
      ],
    ),
  );
}
