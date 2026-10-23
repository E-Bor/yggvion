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
  List<TimeRange> historyActivity,
  DateTime start,
  DateTime end,
  DateTime now,
  tz.Location location,
});

({StatisticsReport period, ActivityHistory history}) _calculate(
  _ReportInput input,
) => (
  period: StatisticsReport.calculate(
    input.snapshot,
    input.activity,
    input.start,
    input.end,
    input.now,
    location: input.location,
  ),
  history: ActivityHistory.calculate(
    input.historyActivity,
    input.now,
    location: input.location,
  ),
);

class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});
  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends ConsumerState<StatisticsPage> {
  int days = 7, offset = 0, generation = 0;
  StatisticsReport? report;
  ActivityHistory? history;
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
      final historyStart = ActivityHistory.startFor(now, local.location);
      final historyEnd = tz.TZDateTime(
        local.location,
        local.year,
        local.month,
        local.day + 1,
      );
      final historyActivity = await repo.db.activity(historyStart, historyEnd);
      final activity = start.isBefore(historyStart)
          ? await repo.db.activity(start, end)
          : historyActivity;
      final first = await repo.db.activityStarted;
      final next = await compute(_calculate, (
        snapshot: snapshot,
        activity: activity,
        historyActivity: historyActivity,
        start: start,
        end: end,
        now: now,
        location: local.location,
      ));
      if (!mounted || request != generation) return;
      setState(() {
        report = next.period;
        history = next.history;
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
                              ? 'По неделям · выберите точку для деталей'
                              : 'По дням · выберите точку для деталей',
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
                        if (history != null) ...[
                          const SizedBox(height: 18),
                          RepaintBoundary(
                            key: const ValueKey('activity-calendar'),
                            child: _StatCard(
                              title: 'Календарь активности',
                              subtitle:
                                  'Последние 365 дней · только это устройство',
                              child: _ActivityCalendar(
                                history: history!,
                                firstActivity: firstActivity,
                              ),
                            ),
                          ),
                        ],
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
    final minutes = maximum < 1;
    final ceiling = minutes
        ? [5, 15, 30, 60].firstWhere((m) => m >= maximum * 60) / 60
        : maximum.ceilToDouble();
    final accent = context.accentColor;
    final selectedIndex = (selected ?? groups.length - 1).clamp(
      0,
      groups.length - 1,
    );
    final picked = groups[selectedIndex];
    String label(DateTime start, DateTime end) => start == end
        ? DateFormat('d MMM', 'ru').format(start)
        : '${DateFormat('d MMM', 'ru').format(start)} — ${DateFormat('d MMM', 'ru').format(end)}';
    String axis(double hours) =>
        NumberFormat('0.#', 'ru').format(minutes ? hours * 60 : hours);
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
              width: 42,
              height: 180,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final text in [
                    '${axis(ceiling)} ${minutes ? 'мин' : 'ч'}',
                    axis(ceiling / 2),
                    '0',
                  ])
                    Text(
                      text,
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
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        void pick(double x) => setState(
                          () => selected =
                              (x / constraints.maxWidth * groups.length)
                                  .floor()
                                  .clamp(0, groups.length - 1),
                        );
                        return GestureDetector(
                          onHorizontalDragStart: (details) =>
                              pick(details.localPosition.dx),
                          onHorizontalDragUpdate: (details) =>
                              pick(details.localPosition.dx),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: CustomPaint(
                                  key: ValueKey(
                                    '${widget.application ? 'usage' : 'work'}-line-chart',
                                  ),
                                  painter: _LineChartPainter(
                                    plan: widget.application
                                        ? const []
                                        : [
                                            for (final group in groups)
                                              group.plan.inSeconds / 3600,
                                          ],
                                    fact: [
                                      for (final group in groups)
                                        group.fact.inSeconds / 3600,
                                    ],
                                    maximum: ceiling,
                                    selected: selectedIndex,
                                    accent: accent,
                                    muted: context.palette.muted,
                                    border: context.palette.border,
                                    surface: context.palette.surface,
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  for (var i = 0; i < groups.length; i++)
                                    Expanded(
                                      child: Tooltip(
                                        message:
                                            '${label(groups[i].start, groups[i].end)}\n${widget.application ? 'Активно' : 'Факт'}: ${formatDuration(groups[i].fact)}${widget.application ? '' : '\nПлан: ${formatDuration(groups[i].plan)}'}',
                                        child: Semantics(
                                          label:
                                              '${label(groups[i].start, groups[i].end)}, ${widget.application ? 'активность' : 'факт'} ${formatDuration(groups[i].fact)}${widget.application ? '' : ', план ${formatDuration(groups[i].plan)}'}',
                                          button: true,
                                          selected: selectedIndex == i,
                                          child: InkWell(
                                            key: ValueKey(
                                              '${widget.application ? 'usage' : 'work'}-point-$i',
                                            ),
                                            onTap: () =>
                                                setState(() => selected = i),
                                            onHover: (hover) {
                                              if (hover) {
                                                setState(() => selected = i);
                                              }
                                            },
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                            child: const SizedBox(height: 180),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
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
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'За этот период пока нет данных.',
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
          ),
      ],
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.plan,
    required this.fact,
    required this.maximum,
    required this.selected,
    required this.accent,
    required this.muted,
    required this.border,
    required this.surface,
  });
  final List<double> plan, fact;
  final double maximum;
  final int selected;
  final Color accent, muted, border, surface;

  @override
  void paint(Canvas canvas, Size size) {
    if (fact.isEmpty || size.isEmpty) return;
    final grid = Paint()
      ..color = border.withValues(alpha: .6)
      ..strokeWidth = .7;
    for (final fraction in [0.0, .5, 1.0]) {
      final y = 4 + fraction * (size.height - 8);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    Offset point(int index, double value) => Offset(
      (index + .5) * size.width / fact.length,
      4 + (size.height - 8) * (1 - (value / maximum).clamp(0, 1)),
    );
    Path line(List<double> values) {
      final path = Path();
      for (var i = 0; i < values.length; i++) {
        final p = point(i, values[i]);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path;
    }

    final actual = line(fact);
    final fill = Path.from(actual)
      ..lineTo(point(fact.length - 1, 0).dx, size.height - 4)
      ..lineTo(point(0, 0).dx, size.height - 4)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: .18),
            accent.withValues(alpha: .015),
          ],
        ).createShader(Offset.zero & size),
    );
    if (plan.isNotEmpty) {
      final plannedPaint = Paint()
        ..color = muted
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (final metric in line(plan).computeMetrics()) {
        for (var offset = 0.0; offset < metric.length; offset += 9) {
          canvas.drawPath(
            metric.extractPath(offset, math.min(offset + 4.5, metric.length)),
            plannedPaint,
          );
        }
      }
    }
    final guide = point(selected, fact[selected]);
    canvas.drawLine(
      Offset(guide.dx, 4),
      Offset(guide.dx, size.height - 4),
      Paint()
        ..color = accent.withValues(alpha: .2)
        ..strokeWidth = 1,
    );
    canvas.drawPath(
      actual,
      Paint()
        ..color = accent
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
    if (fact.length <= 7) {
      for (var i = 0; i < fact.length; i++) {
        canvas.drawCircle(point(i, fact[i]), 2.5, Paint()..color = accent);
      }
    }
    if (plan.isNotEmpty) {
      final p = point(selected, plan[selected]);
      canvas.drawCircle(p, 4, Paint()..color = surface);
      canvas.drawCircle(
        p,
        3,
        Paint()
          ..color = muted
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    canvas.drawCircle(guide, 6, Paint()..color = surface);
    canvas.drawCircle(guide, 4, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      !listEquals(old.plan, plan) ||
      !listEquals(old.fact, fact) ||
      old.maximum != maximum ||
      old.selected != selected ||
      old.accent != accent ||
      old.muted != muted ||
      old.border != border ||
      old.surface != surface;
}

class _ActivityCalendar extends StatefulWidget {
  const _ActivityCalendar({required this.history, required this.firstActivity});
  final ActivityHistory history;
  final DateTime? firstActivity;
  @override
  State<_ActivityCalendar> createState() => _ActivityCalendarState();
}

class _ActivityCalendarState extends State<_ActivityCalendar> {
  final scroll = ScrollController();
  String? selectedDay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Color color(BuildContext context, int level) => Color.alphaBlend(
    context.accentColor.withValues(alpha: [0.0, .2, .4, .68, 1.0][level]),
    context.palette.raised,
  );

  String duration(DailyActivity day) {
    if (day.duration == Duration.zero) {
      final first = widget.firstActivity;
      if (first == null) return 'Пока нет данных';
      final date = day.date as tz.TZDateTime;
      final next = tz.TZDateTime(
        date.location,
        date.year,
        date.month,
        date.day + 1,
      );
      return first.isBefore(next) ? 'Нет активности' : 'Учёт ещё не велся';
    }
    return day.duration < const Duration(minutes: 1)
        ? 'Меньше минуты'
        : formatDuration(day.duration);
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.history;
    final days = history.days;
    final selectedIndex = days.indexWhere(
      (day) => dayKey(day.date) == selectedDay,
    );
    final picked = days[selectedIndex < 0 ? days.length - 1 : selectedIndex];
    final offset = days.first.date.weekday - 1;
    final weeks = (offset + days.length + 6) ~/ 7;
    final months = <({int week, String label})>[
      for (var i = 0; i < days.length; i++)
        if (i == 0 || days[i].date.day == 1)
          (
            week: (offset + i) ~/ 7,
            label: DateFormat('LLL', 'ru').format(days[i].date),
          ),
    ];
    const levels = [
      'Нет активности',
      'До 5 минут',
      'От 5 до 20 минут',
      'От 20 до 60 минут',
      'От часа',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 16,
          children: [
            _SmallTotal(
              label: 'Дней с активностью',
              value: '${history.activeDays}',
            ),
            _SmallTotal(
              label: 'Текущая серия, дней',
              value: '${history.currentStreak}',
            ),
            _SmallTotal(
              label: 'Лучшая серия, дней',
              value: '${history.longestStreak}',
            ),
          ],
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final cell = ((constraints.maxWidth - 28) / weeks - 4).clamp(
              12.0,
              16.0,
            );
            final step = cell + 4;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Column(
                    children: [
                      const SizedBox(height: 22),
                      for (var row = 0; row < 7; row++)
                        SizedBox(
                          height: step,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              {0: 'Пн', 2: 'Ср', 4: 'Пт'}[row] ?? '',
                              style: TextStyle(
                                fontSize: 10,
                                color: context.palette.muted,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      key: const ValueKey('activity-calendar-scroll'),
                      controller: scroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SizedBox(
                        width: weeks * step,
                        child: Column(
                          children: [
                            SizedBox(
                              height: 22,
                              child: Stack(
                                children: [
                                  for (var i = 0; i < months.length; i++)
                                    if (i == months.length - 1 ||
                                        months[i + 1].week - months[i].week >=
                                            3)
                                      Positioned(
                                        left: math.min(
                                          months[i].week * step + 2,
                                          weeks * step - 32,
                                        ),
                                        child: Text(
                                          months[i].label,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: context.palette.muted,
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var week = 0; week < weeks; week++)
                                  Column(
                                    children: [
                                      for (var row = 0; row < 7; row++)
                                        if (week * 7 + row - offset < 0 ||
                                            week * 7 + row - offset >=
                                                days.length)
                                          SizedBox(width: step, height: step)
                                        else
                                          dayCell(
                                            context,
                                            days[week * 7 + row - offset],
                                            picked,
                                            step,
                                          ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            Text(
              'Нажмите на день',
              style: TextStyle(fontSize: 11, color: context.palette.muted),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Меньше',
                  style: TextStyle(fontSize: 10, color: context.palette.muted),
                ),
                const SizedBox(width: 6),
                for (var level = 0; level < levels.length; level++)
                  Tooltip(
                    message: levels[level],
                    child: Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: color(context, level),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                Text(
                  'Больше',
                  style: TextStyle(fontSize: 10, color: context.palette.muted),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),
        Container(
          key: const ValueKey('activity-day-details'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: context.palette.raised,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Icons.calendar_today_outlined,
                size: 18,
                color: context.accentColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        DateFormat('EEE, d MMMM y', 'ru').format(picked.date),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        duration(picked),
                        style: TextStyle(
                          color: context.accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Яркость: до 5 · 5–20 · 20–60 · от 60 минут в день. Учитывается активное время на этом устройстве.',
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: context.palette.muted,
          ),
        ),
      ],
    );
  }

  Widget dayCell(
    BuildContext context,
    DailyActivity day,
    DailyActivity picked,
    double step,
  ) {
    final label =
        '${DateFormat('EEEE, d MMMM y', 'ru').format(day.date)} · ${duration(day)}';
    final selected = day.date == picked.date;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey('activity-day-${dayKey(day.date)}'),
          onTap: () => setState(() => selectedDay = dayKey(day.date)),
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            width: step,
            height: step,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color(context, day.level),
                  borderRadius: BorderRadius.circular(3),
                  border: selected
                      ? Border.all(color: context.palette.text, width: 1.5)
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
          'Использование приложения сохраняется только на этом устройстве с момента обновления. Новый сеанс начинается при возвращении в приложение или после паузы без действий. Фоновое время не учитывается. Календарь активности показывает последние 365 дней независимо от периода графиков. Яркость растёт на отметках 5, 20 и 60 минут. Любое сохранённое активное время засчитывает день; текущая серия сохраняется до конца сегодняшнего дня, если он пока пуст.',
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
