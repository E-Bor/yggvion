import '../l10n/strings.dart';
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
  String language,
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
) {
  AppLocale.use(input.language);
  return (
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
}

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
      final first = await repo.db.activityStarted;
      final end = tz.TZDateTime(
        local.location,
        local.year,
        local.month,
        local.day + 1 - offset * days,
      );
      final start = days == 0
          ? StatisticsReport.historyStart(snapshot, now, first)
          : tz.TZDateTime(local.location, end.year, end.month, end.day - days);
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
      final next = await compute(_calculate, (
        language: repo.language,
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
        setState(
          () => error = tr("Не удалось рассчитать статистику: {0}", [e]),
        );
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
        title: Text(tr("Статистика")),
        actions: [
          IconButton(
            tooltip: tr("Обновить статистику"),
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
                      Text(
                        tr("Время в деталях"),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tr("Как соотносятся планы и учтённое время"),
                        style: TextStyle(color: context.palette.muted),
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 20,
                        runSpacing: 12,
                        children: [
                          Wrap(
                            key: const ValueKey('statistics-period'),
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final period in [7, 30, 90, 0])
                                ChoiceChip(
                                  showCheckmark: false,
                                  label: Text(
                                    period == 0
                                        ? tr("За всё время")
                                        : tr("{0} дней", [period]),
                                  ),
                                  selected: days == period,
                                  onSelected: (_) {
                                    days = period;
                                    offset = 0;
                                    load(reset: true);
                                  },
                                ),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: tr("Предыдущий период"),
                                onPressed: days == 0
                                    ? null
                                    : () {
                                        offset++;
                                        load(reset: true);
                                      },
                                icon: const Icon(Icons.chevron_left_rounded),
                              ),
                              Flexible(
                                child: Text(
                                  data == null
                                      ? tr("Загрузка…")
                                      : '${DateFormat('d MMM', AppLocale.language).format(data.days.first.date)} — ${DateFormat('d MMM y', AppLocale.language).format(data.days.last.date)}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: tr("Следующий период"),
                                onPressed: offset == 0 || days == 0
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
                                  child: Text(tr("Повторить")),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (data != null) ...[
                        _Totals(data: data),
                        const SizedBox(height: 18),
                        _StatCard(
                          title: tr("План и факт"),
                          infoId: 'plan-fact',
                          info: tr(
                            "План — сумма длительностей календарных блоков в выбранном периоде, включая невыполненный план. Факт — таймер и ручной учёт до текущего момента; пересечения считаются один раз. Пунктир показывает план, акцентная линия — факт. Здесь интервалы делятся по календарным датам в часовом поясе приложения. Дни рождения и удалённые задачи исключены. На длинных периодах точка объединяет несколько дней.",
                          ),
                          subtitle: tr("{0} · выберите точку для деталей", [
                            _chartStep(data.days.length) == 1
                                ? tr("По дням")
                                : tr("По {0} дней", [
                                    _chartStep(data.days.length),
                                  ]),
                          ]),
                          child: _TimeChart(
                            key: ValueKey('work-$days-$offset'),
                            days: data.days,
                          ),
                        ),
                        if (data.overlap > Duration.zero)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                            child: Text(
                              tr(
                                "{0} записаны одновременно в разных задачах. В общем факте пересечения считаются один раз; в проектах и задачах показан их собственный учёт.",
                                [formatDuration(data.overlap)],
                              ),
                              style: TextStyle(
                                color: context.palette.pink,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                        const SizedBox(height: 18),
                        _EstimateCard(
                          estimates: data.estimates,
                          statistics: data.estimateStatistics,
                        ),
                        const SizedBox(height: 18),
                        _ProjectCard(projects: data.projects),
                        const SizedBox(height: 18),
                        _StatCard(
                          title: tr("Работа в течение дня"),
                          infoId: 'workday',
                          info: tr(
                            "Часы — объединённое время таймера и ручного учёта внутри границ рабочего дня. Доля = эти часы / длительность рабочего дня × 100%; за период делятся суммы. Ночь после полуночи относится к дате начала рабочего дня, даже на границе выбранного периода. Будущее время не учитывается. Границы берутся из режима, действующего на дату рабочего дня; перемещение метки в календаре корректирует выбранный день. При пересечении соседних рабочих дней общий интервал относится к более раннему дню. Вне рабочего дня — учёт за календарные даты периода, не попавший ни в один рабочий интервал. Поэтому итог может отличаться от календарного графика плана и факта.",
                          ),
                          subtitle: tr(
                            "Таймтрек внутри рабочего дня · часы и доля времени",
                          ),
                          child: _WorkdayChart(
                            key: ValueKey('workday-utilization-$days-$offset'),
                            data: data,
                          ),
                        ),
                        const SizedBox(height: 18),
                        _StatCard(
                          title: tr("Начало и конец дня"),
                          infoId: 'boundaries',
                          info: tr(
                            "Точки показывают начало и конец каждого рабочего дня по режиму на его дату или ручным корректировкам в календаре. Подтверждение не требуется. Средние считаются отдельно по каждой границе, когда её время наступило. Будущие моменты и нерабочие дни без заданных границ исключены. Ночная граница относится к дате начала рабочего дня: +1 означает следующие сутки. Для среднего 01:00 +1 учитывается как 25:00, поэтому среднее между 23:00 и 01:00 +1 — 00:00 +1. На длинных периодах точки показывают среднее по рабочим дням группы. Пропуски не заменяются нулями.",
                          ),
                          subtitle: tr(
                            "Все рабочие дни · среднее за выбранный период",
                          ),
                          child: _WorkdayChart(
                            key: ValueKey('workday-boundaries-$days-$offset'),
                            data: data,
                            boundaries: true,
                          ),
                        ),
                        const SizedBox(height: 18),
                        _StatCard(
                          title: tr("Использование приложения"),
                          infoId: 'usage',
                          info: tr(
                            "Активное время считается только в открытом активном окне на этом устройстве. После двух минут без действий учёт приостанавливается. Фоновый таймер задач в эту метрику не входит. Линия показывает активное время по календарным датам; на длинных периодах дни объединяются. Сеансы — интервалы активности, начавшиеся в выбранном периоде. Эти данные хранятся локально и не суммируются между устройствами.",
                          ),
                          subtitle: tr("Только это устройство{0}", [
                            firstActivity == null
                                ? ''
                                : tr(" · с {0}", [
                                    DateFormat(
                                      'd MMM y',
                                      AppLocale.language,
                                    ).format(
                                      tz.TZDateTime.from(
                                        firstActivity!,
                                        tz.getLocation(
                                          ref
                                              .read(appProvider)
                                              .snapshot
                                              .settings
                                              .timezone,
                                        ),
                                      ),
                                    ),
                                  ]),
                          ]),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                spacing: 32,
                                runSpacing: 16,
                                children: [
                                  _SmallTotal(
                                    label: tr("Активное время"),
                                    value: formatDuration(data.application),
                                  ),
                                  _SmallTotal(
                                    label: tr("Сеансов использования"),
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
                                tr(
                                  "Время в активном окне. После 2 минут без действий учёт приостанавливается. Рабочий таймер считается отдельно.",
                                ),
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
                              title: tr("Календарь активности"),
                              infoId: 'activity',
                              info: tr(
                                "Показаны последние 365 дней независимо от периода остальных графиков. Яркость акцента отражает активное использование приложения на этом устройстве: нет активности; меньше 5 минут; от 5 до 20; от 20 до 60; от часа. Дни до начала учёта не считаются пропусками. Серия — последовательные дни с активностью; сегодняшняя серия сохраняется от вчерашнего дня до конца сегодня. Фоновый таймер задач не влияет на яркость.",
                              ),
                              subtitle: tr(
                                "Последние 365 дней · только это устройство",
                              ),
                              child: _ActivityCalendar(
                                history: history!,
                                firstActivity: firstActivity,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          tr("Сейчас в пространстве: {0} задач · {1} заметок", [
                            data.tasks,
                            data.notes,
                          ]),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.palette.muted,
                            fontSize: 12,
                          ),
                        ),
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
          label: tr("Фактическое время"),
          value: formatDuration(data.actual),
          detail: tr("Без двойного учёта"),
          icon: Icons.timelapse_rounded,
        ),
        (
          label: tr("Запланировано"),
          value: formatDuration(data.planned),
          detail: tr("В выбранном периоде"),
          icon: Icons.calendar_today_outlined,
        ),
        (
          label: tr("Закрыто из плана"),
          value: completion == null ? '—' : '$completion%',
          detail: tr("{0} из {1} задач", [
            data.completedTasks,
            data.plannedTasks,
          ]),
          icon: Icons.task_alt_rounded,
        ),
        (
          label: tr("Дней с учётом"),
          value: '${data.activeDays}',
          detail: tr("Из {0} дней", [data.days.length]),
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
    required this.infoId,
    required this.info,
    required this.child,
  });
  final String title, subtitle, infoId, info;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StatisticsExplanation(
                id: infoId,
                title: title,
                description: info,
              ),
            ],
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

int _chartStep(int days) => days <= 31
    ? 1
    : days <= 365
    ? 7
    : (days / 52).ceil();

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
    final step = _chartStep(widget.days.length);
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
        ? DateFormat('d MMM', AppLocale.language).format(start)
        : '${DateFormat('d MMM', AppLocale.language).format(start)} — ${DateFormat('d MMM', AppLocale.language).format(end)}';
    String axis(double hours) => NumberFormat(
      '0.#',
      AppLocale.language,
    ).format(minutes ? hours * 60 : hours);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.application) ...[
          Row(
            children: [
              _Legend(color: context.palette.muted, text: tr("План")),
              const SizedBox(width: 20),
              _Legend(color: accent, text: tr("Факт")),
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
                    '${axis(ceiling)} ${minutes ? tr("мин") : tr("ч")}',
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
                                            '${label(groups[i].start, groups[i].end)}\n${widget.application ? tr("Активно") : tr("Факт")}: ${formatDuration(groups[i].fact)}${widget.application ? '' : tr("\nПлан: {0}", [formatDuration(groups[i].plan)])}',
                                        child: Semantics(
                                          label:
                                              '${label(groups[i].start, groups[i].end)}, ${widget.application ? tr("активность") : tr("факт")} ${formatDuration(groups[i].fact)}${widget.application ? '' : tr(", план {0}", [formatDuration(groups[i].plan)])}',
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
                tr("План {0}", [formatDuration(picked.plan)]),
                style: TextStyle(fontSize: 12, color: context.palette.muted),
              ),
            Text(
              '${widget.application ? tr("Активно") : tr("Факт")} ${formatDuration(picked.fact)}',
              style: TextStyle(fontSize: 12, color: accent),
            ),
          ],
        ),
        if (maximum == 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              tr("За этот период пока нет данных."),
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
    this.minimum = 0,
    this.fill = true,
    this.dashPlan = true,
  });
  final List<double?> plan, fact;
  final double maximum, minimum;
  final int selected;
  final Color accent, muted, border, surface;
  final bool fill, dashPlan;

  @override
  void paint(Canvas canvas, Size size) {
    if (fact.isEmpty || size.isEmpty || maximum <= minimum) return;
    final grid = Paint()
      ..color = border.withValues(alpha: .6)
      ..strokeWidth = .7;
    for (final fraction in [0.0, .5, 1.0]) {
      final y = 4 + fraction * (size.height - 8);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    Offset point(int index, double value) => Offset(
      (index + .5) * size.width / fact.length,
      4 +
          (size.height - 8) *
              (1 - ((value - minimum) / (maximum - minimum)).clamp(0, 1)),
    );
    Path line(List<double?> values) {
      final path = Path();
      Offset? previous;
      for (var i = 0; i < values.length; i++) {
        final value = values[i];
        if (value == null) {
          previous = null;
          continue;
        }
        final p = point(i, value);
        if (previous == null) {
          path.moveTo(p.dx, p.dy);
        } else {
          // Horizontal tangents round the corners without inventing peaks or
          // negative time between samples. Missing days remain gaps.
          final middle = (previous.dx + p.dx) / 2;
          path.cubicTo(middle, previous.dy, middle, p.dy, p.dx, p.dy);
        }
        previous = p;
      }
      return path;
    }

    final actual = line(fact);
    if (fill && fact.every((v) => v != null)) {
      final area = Path.from(actual)
        ..lineTo(point(fact.length - 1, minimum).dx, size.height - 4)
        ..lineTo(point(0, minimum).dx, size.height - 4)
        ..close();
      canvas.drawPath(
        area,
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
    }
    if (plan.isNotEmpty) {
      final paint = Paint()
        ..color = muted
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      if (dashPlan) {
        for (final metric in line(plan).computeMetrics()) {
          for (var offset = 0.0; offset < metric.length; offset += 9) {
            canvas.drawPath(
              metric.extractPath(offset, math.min(offset + 4.5, metric.length)),
              paint,
            );
          }
        }
      } else {
        canvas.drawPath(line(plan), paint);
      }
    }
    final guideX = point(selected, minimum).dx;
    canvas.drawLine(
      Offset(guideX, 4),
      Offset(guideX, size.height - 4),
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
    for (final series in [(fact, accent), (plan, muted)]) {
      if (series.$1.isEmpty) continue;
      for (var i = 0; i < series.$1.length; i++) {
        final value = series.$1[i];
        if (value == null) continue;
        if (i == selected) {
          final p = point(i, value);
          canvas.drawCircle(p, 6, Paint()..color = surface);
          canvas.drawCircle(p, 4, Paint()..color = series.$2);
        } else if (fact.length <= 7 || !fill) {
          canvas.drawCircle(point(i, value), 2.5, Paint()..color = series.$2);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      !listEquals(old.plan, plan) ||
      !listEquals(old.fact, fact) ||
      old.maximum != maximum ||
      old.minimum != minimum ||
      old.fill != fill ||
      old.dashPlan != dashPlan ||
      old.selected != selected ||
      old.accent != accent ||
      old.muted != muted ||
      old.border != border ||
      old.surface != surface;
}

class _WorkdayChart extends StatefulWidget {
  const _WorkdayChart({super.key, required this.data, this.boundaries = false});
  final StatisticsReport data;
  final bool boundaries;
  @override
  State<_WorkdayChart> createState() => _WorkdayChartState();
}

class _WorkdayChartState extends State<_WorkdayChart> {
  int? selected;
  bool percentages = true;

  String time(double? minutes) {
    if (minutes == null) return '—';
    final value = minutes.round();
    final clock = value % 1440;
    final days = value ~/ 1440;
    return '${(clock ~/ 60).toString().padLeft(2, '0')}:${(clock % 60).toString().padLeft(2, '0')}${days > 0 ? ' +$days' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final groups =
        <
          ({
            DateTime start,
            DateTime end,
            Duration worked,
            Duration available,
            Duration outside,
            double? begin,
            double? finish,
          })
        >[];
    final step = _chartStep(data.workdays.length);
    double? mean(Iterable<double> values) {
      final list = values.toList();
      return list.isEmpty ? null : list.reduce((a, b) => a + b) / list.length;
    }

    for (var i = 0; i < data.workdays.length; i += step) {
      final slice = data.workdays.skip(i).take(step).toList();
      groups.add((
        start: slice.first.date,
        end: slice.last.date,
        worked: sumDurations(slice.map((d) => d.worked)),
        available: sumDurations(slice.map((d) => d.available)),
        outside: sumDurations(slice.map((d) => d.outside)),
        begin: mean(slice.map((d) => d.startMinutes).nonNulls),
        finish: mean(slice.map((d) => d.endMinutes).nonNulls),
      ));
    }
    if (groups.isEmpty) return Text(tr("Пока нет данных."));
    final plan = widget.boundaries
        ? [for (final g in groups) g.begin == null ? null : g.begin! / 60]
        : <double?>[];
    final fact = [
      for (final g in groups)
        widget.boundaries
            ? (g.finish == null ? null : g.finish! / 60)
            : g.available == Duration.zero
            ? null
            : percentages
            ? g.worked.inMicroseconds / g.available.inMicroseconds * 100
            : g.worked.inSeconds / 3600,
    ];
    final measured = [...plan, ...fact].nonNulls.toList();
    final minimum = widget.boundaries && measured.isNotEmpty
        ? math.max(0.0, measured.reduce(math.min).floorToDouble() - 1)
        : 0.0;
    final maximum = widget.boundaries
        ? (measured.isEmpty
              ? 24.0
              : math.max(
                  minimum + 1,
                  measured.reduce(math.max).ceilToDouble() + 1,
                ))
        : percentages
        ? 100.0
        : math.max(
            1.0,
            measured.isEmpty ? 1.0 : measured.reduce(math.max).ceilToDouble(),
          );
    final index = (selected ?? groups.length - 1).clamp(0, groups.length - 1);
    final picked = groups[index];
    final number = NumberFormat('0.#', AppLocale.language);
    String percent(double? value) =>
        value == null ? '—' : '${number.format(value)}%';
    String label(DateTime start, DateTime end) => start == end
        ? DateFormat('d MMM', AppLocale.language).format(start)
        : '${DateFormat('d MMM', AppLocale.language).format(start)} — ${DateFormat('d MMM', AppLocale.language).format(end)}';
    String detail(int i) {
      final g = groups[i];
      if (widget.boundaries) {
        return tr("Начало {0} · конец {1}", [time(g.begin), time(g.finish)]);
      }
      final ratio = g.available == Duration.zero
          ? null
          : g.worked.inMicroseconds / g.available.inMicroseconds * 100;
      return tr("{0} · {1} рабочего дня{2}", [
        formatDuration(g.worked),
        percent(ratio),
        g.outside > Duration.zero
            ? tr(" · вне границ {0}", [formatDuration(g.outside)])
            : '',
      ]);
    }

    String axis(double v) => widget.boundaries
        ? time(v * 60)
        : '${number.format(v)}${percentages ? '%' : tr(" ч")}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 32,
          runSpacing: 16,
          children: [
            if (widget.boundaries) ...[
              _SmallTotal(
                label: tr("Среднее начало"),
                value: time(data.meanWorkdayStart),
              ),
              _SmallTotal(
                label: tr("Среднее завершение"),
                value: time(data.meanWorkdayEnd),
              ),
            ] else ...[
              _SmallTotal(
                label: tr("Работа в границах дня"),
                value: formatDuration(data.workdayActual),
              ),
              _SmallTotal(
                label: tr("Доля рабочего времени"),
                value: percent(data.workdayPercent),
              ),
              if (data.outsideWorkday > Duration.zero)
                _SmallTotal(
                  label: tr("Вне рабочего дня"),
                  value: formatDuration(data.outsideWorkday),
                ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        if (widget.boundaries)
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _Legend(color: context.palette.muted, text: tr("Начало")),
              _Legend(color: context.accentColor, text: tr("Конец")),
            ],
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              key: const ValueKey('workday-chart-unit'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(tr("Доля дня"))),
                ButtonSegment(value: false, label: Text(tr("Часы"))),
              ],
              selected: {percentages},
              onSelectionChanged: (v) => setState(() => percentages = v.single),
            ),
          ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 46,
              height: 180,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final value in [
                    maximum,
                    (minimum + maximum) / 2,
                    minimum,
                  ])
                    Text(
                      axis(value),
                      style: TextStyle(
                        fontSize: 10,
                        color: context.palette.muted,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SizedBox(
                height: 180,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    void pick(double x) => setState(
                      () =>
                          selected = (x / constraints.maxWidth * groups.length)
                              .floor()
                              .clamp(0, groups.length - 1),
                    );
                    return GestureDetector(
                      onHorizontalDragStart: (d) => pick(d.localPosition.dx),
                      onHorizontalDragUpdate: (d) => pick(d.localPosition.dx),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              key: ValueKey(
                                widget.boundaries
                                    ? 'workday-boundary-chart'
                                    : 'workday-productivity-chart',
                              ),
                              painter: _LineChartPainter(
                                plan: plan,
                                fact: fact,
                                minimum: minimum,
                                maximum: maximum,
                                selected: index,
                                accent: context.accentColor,
                                muted: context.palette.muted,
                                border: context.palette.border,
                                surface: context.palette.surface,
                                fill: false,
                                dashPlan: false,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              for (var i = 0; i < groups.length; i++)
                                Expanded(
                                  child: Tooltip(
                                    message:
                                        '${label(groups[i].start, groups[i].end)}\n${detail(i)}',
                                    child: Semantics(
                                      label:
                                          '${label(groups[i].start, groups[i].end)}, ${detail(i)}',
                                      selected: index == i,
                                      button: true,
                                      child: InkWell(
                                        key: ValueKey(
                                          'workday-${widget.boundaries ? 'boundary' : 'productivity'}-point-$i',
                                        ),
                                        onTap: () =>
                                            setState(() => selected = i),
                                        onHover: (hover) {
                                          if (hover) {
                                            setState(() => selected = i);
                                          }
                                        },
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
            ),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 46),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final i in {0, groups.length ~/ 2, groups.length - 1})
                Text(
                  DateFormat(
                    'd MMM',
                    AppLocale.language,
                  ).format(groups[i].start),
                  style: TextStyle(fontSize: 10, color: context.palette.muted),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            Text(
              label(picked.start, picked.end),
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
            Text(
              detail(index),
              style: TextStyle(fontSize: 12, color: context.accentColor),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          widget.boundaries
              ? tr(
                  "Границы учитываются автоматически, когда наступает их время. {0}",
                  [
                    step == 1
                        ? tr("Точки показывают каждый рабочий день.")
                        : tr("Точки — среднее за {0} дней.", [step]),
                  ],
                )
              : tr(
                  "Пересечения таймеров считаются один раз. Сегодня учитывается только прошедшая часть дня. Учитываются история режима и ручные изменения в календаре.",
                ),
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: context.palette.muted,
          ),
        ),
      ],
    );
  }
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
      if (first == null) return tr("Пока нет данных");
      final date = day.date as tz.TZDateTime;
      final next = tz.TZDateTime(
        date.location,
        date.year,
        date.month,
        date.day + 1,
      );
      return first.isBefore(next)
          ? tr("Нет активности")
          : tr("Учёт ещё не велся");
    }
    return day.duration < const Duration(minutes: 1)
        ? tr("Меньше минуты")
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
            label: DateFormat('LLL', AppLocale.language).format(days[i].date),
          ),
    ];
    final levels = [
      tr("Нет активности"),
      tr("До 5 минут"),
      tr("От 5 до 20 минут"),
      tr("От 20 до 60 минут"),
      tr("От часа"),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 16,
          children: [
            _SmallTotal(
              label: tr("Дней с активностью"),
              value: '${history.activeDays}',
            ),
            _SmallTotal(
              label: tr("Текущая серия, дней"),
              value: '${history.currentStreak}',
            ),
            _SmallTotal(
              label: tr("Лучшая серия, дней"),
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
                              {0: tr("Пн"), 2: tr("Ср"), 4: tr("Пт")}[row] ??
                                  '',
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
              tr("Нажмите на день"),
              style: TextStyle(fontSize: 11, color: context.palette.muted),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr("Меньше"),
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
                  tr("Больше"),
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
                        DateFormat(
                          'EEE, d MMMM y',
                          AppLocale.language,
                        ).format(picked.date),
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
          tr(
            "Яркость: до 5 · 5–20 · 20–60 · от 60 минут в день. Учитывается активное время на этом устройстве.",
          ),
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
        '${DateFormat('EEEE, d MMMM y', AppLocale.language).format(day.date)} · ${duration(day)}';
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
      title: tr("Куда уходит время"),
      infoId: 'projects',
      info: tr(
        "Фактическое время объединяется отдельно внутри каждого проекта за выбранный период. Полная полоска соответствует проекту с наибольшим фактом; остальные показаны относительно него. Под полоской — сумма запланированных блоков проекта. Без проекта — задачи без выбранного проекта. Пересекающиеся интервалы разных проектов входят в каждый из них, поэтому сумма проектов может превышать общий факт.",
      ),
      subtitle: tr("Фактическое время по проектам за период"),
      child: widget.projects.isEmpty
          ? Text(
              tr("Проекты появятся вместе с планом или учётом времени."),
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
                            semanticsLabel: tr("{0}: {1}, план {2}", [
                              project.title,
                              formatDuration(project.actual),
                              formatDuration(project.planned),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            tr("План {0}", [formatDuration(project.planned)]),
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
                          ? tr("Свернуть")
                          : tr("Все проекты ({0})", [widget.projects.length]),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EstimateCard extends StatelessWidget {
  const _EstimateCard({required this.estimates, required this.statistics});
  final List<EstimateComparison> estimates;
  final EstimateStatistics statistics;

  @override
  Widget build(BuildContext context) {
    final number = NumberFormat('0.#', AppLocale.language);
    String percent(double? value) =>
        value == null ? '—' : '${number.format(value)}%';
    final metrics = [
      (
        key: 'estimate-mean-error',
        label: tr("Средняя ошибка"),
        value: percent(statistics.meanErrorPercent),
        detail: tr("Задач в расчёте: {0}", [statistics.measuredTasks]),
      ),
      (
        key: 'estimate-outside-tolerance',
        label: tr("Ошибка больше 10%"),
        value: tr("{0} из {1}", [
          statistics.outsideToleranceTasks,
          statistics.measuredTasks,
        ]),
        detail: tr("Недооценка и переоценка"),
      ),
      (
        key: 'estimate-underestimated',
        label: tr("Средняя недооценка"),
        value: percent(statistics.meanUnderestimatePercent),
        detail: tr("Факт дольше плана · задач: {0}", [
          statistics.underestimatedTasks,
        ]),
      ),
      (
        key: 'estimate-overestimated',
        label: tr("Средняя переоценка"),
        value: percent(statistics.meanOverestimatePercent),
        detail: tr("Факт короче плана · задач: {0}", [
          statistics.overestimatedTasks,
        ]),
      ),
    ];
    return _StatCard(
      title: tr("Ошибка эстимейта"),
      infoId: 'estimate',
      info: tr(
        "Для завершённых задач с планом в периоде сравниваются полный план задачи и всё её учтённое время. Ошибка = |факт − план| / план × 100%. Средняя ошибка даёт каждой задаче одинаковый вес. Счётчик учитывает ошибку строго больше 10% до округления. Средняя недооценка считается только там, где факт больше плана; переоценка — где он меньше. Эти ошибки не компенсируют друг друга. Задачи без учёта времени или положительного плана исключены; прочерк означает отсутствие данных.",
      ),
      subtitle: tr("Завершённые задачи с планом в периоде · задача целиком"),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (statistics.measuredTasks > 0) ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context);
                final availableWidth = constraints.maxWidth / scale.scale(1);
                final columns = availableWidth >= 800
                    ? 4
                    : availableWidth >= 300
                    ? 2
                    : 1;
                final width =
                    (constraints.maxWidth - (columns - 1) * 12) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final metric in metrics)
                      Container(
                        key: ValueKey(metric.key),
                        width: width,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: context.palette.raised,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: scale.scale(12) * 2.8,
                              ),
                              child: Text(
                                metric.label,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                metric.value,
                                style: TextStyle(
                                  fontSize: 25,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -.5,
                                  color: context.accentColor,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: scale.scale(11) * 2.8,
                              ),
                              child: Text(
                                metric.detail,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.4,
                                  color: context.palette.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            Text(
              tr(
                "Проценты от плана каждой задачи. Недооценка и переоценка не компенсируют друг друга.",
              ),
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: context.palette.muted,
              ),
            ),
          ] else
            Text(
              tr(
                "Завершите запланированную задачу и запишите потраченное время, чтобы сравнить оценку с фактом.",
              ),
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
          if (statistics.missingTimeTasks > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                tr(
                  "Без учёта времени: {0}. Эти задачи не включены в проценты.",
                  [statistics.missingTimeTasks],
                ),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: context.palette.muted,
                ),
              ),
            ),
          if (estimates.isNotEmpty) ...[
            const SizedBox(height: 8),
            ExpansionTile(
              key: const ValueKey('estimate-task-details'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 8),
              title: Text(tr("По задачам"), style: TextStyle(fontSize: 13)),
              subtitle: Text(
                estimates.length > 8
                    ? tr("8 задач с наибольшей ошибкой")
                    : tr("План, факт и отклонение"),
                style: TextStyle(fontSize: 11, color: context.palette.muted),
              ),
              children: [
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
                          spacing: 10,
                          runSpacing: 4,
                          children: [
                            Text(
                              tr("План {0}", [formatDuration(item.planned)]),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.palette.muted,
                              ),
                            ),
                            Text(
                              item.errorPercent == null
                                  ? tr("Нет учёта времени")
                                  : tr("Факт {0}", [
                                      formatDuration(item.actual),
                                    ]),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.palette.muted,
                              ),
                            ),
                            if (item.errorPercent case final error?)
                              Text(
                                error == 0
                                    ? tr("Точно по плану")
                                    : '${error > 0 ? tr("Недооценка") : tr("Переоценка")} ${percent(error.abs())}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.accentColor,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatisticsExplanation extends StatelessWidget {
  const _StatisticsExplanation({
    required this.id,
    required this.title,
    required this.description,
  });
  final String id, title, description;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: description,
    constraints: const BoxConstraints(maxWidth: 360),
    padding: const EdgeInsets.all(14),
    waitDuration: const Duration(milliseconds: 350),
    triggerMode: TooltipTriggerMode.manual,
    child: SizedBox(
      key: ValueKey('statistics-info-$id'),
      width: 32,
      height: 32,
      child: Icon(
        Icons.info_outline_rounded,
        size: 18,
        color: context.palette.muted,
        semanticLabel: tr("О расчёте: {0}", [title]),
      ),
    ),
  );
}
