import 'package:timezone/timezone.dart' as tz;
import 'models.dart';

class DailyStatistics {
  const DailyStatistics({
    required this.date,
    required this.planned,
    required this.actual,
    required this.application,
  });
  final DateTime date;
  final Duration planned, actual, application;
}

class ProjectStatistics {
  const ProjectStatistics(this.title, this.color, this.planned, this.actual);
  final String title;
  final int color;
  final Duration planned, actual;
}

class EstimateComparison {
  const EstimateComparison(this.task, this.planned, this.actual);
  final Task task;
  final Duration planned, actual;
  Duration get difference => actual - planned;
}

class StatisticsReport {
  const StatisticsReport({
    required this.days,
    required this.projects,
    required this.estimates,
    required this.plannedTasks,
    required this.completedTasks,
    required this.overlap,
    required this.applicationSessions,
    required this.notes,
    required this.tasks,
  });
  final List<DailyStatistics> days;
  final List<ProjectStatistics> projects;
  final List<EstimateComparison> estimates;
  final int plannedTasks, completedTasks, applicationSessions, notes, tasks;
  final Duration overlap;
  Duration get planned => sumDurations(days.map((d) => d.planned));
  Duration get actual => sumDurations(days.map((d) => d.actual));
  Duration get application => sumDurations(days.map((d) => d.application));
  int get activeDays => days.where((d) => d.actual > Duration.zero).length;

  /// Period is [start, end), in the workspace timezone. Plan includes retained
  /// historical blocks; actual time ends at now and merges overlapping sessions.
  static StatisticsReport calculate(
    Snapshot snapshot,
    List<TimeRange> usage,
    DateTime start,
    DateTime end,
    DateTime now, {
    tz.Location? location,
  }) {
    final zone = location ?? tz.getLocation(snapshot.settings.timezone);
    final tasks = {
      for (final task in snapshot.tasks)
        if (!task.isBirthday && !task.entity.deleted) task.id: task,
    };
    final plans = <String, List<TimeRange>>{};
    for (final block in snapshot.blocks) {
      if (!tasks.containsKey(block.taskId) || block.entity.deleted) continue;
      final clipped = clipRange(TimeRange(block.start, block.end), start, end);
      if (clipped != null) (plans[block.taskId] ??= []).add(clipped);
    }
    final sessions = <String, List<TimeRange>>{};
    final allSessions = <String, List<TimeRange>>{};
    for (final session in snapshot.sessions) {
      if (!tasks.containsKey(session.taskId) ||
          session.entity.deleted ||
          session.discarded) {
        continue;
      }
      final finish = session.end == null || session.end!.isAfter(now)
          ? now
          : session.end!;
      if (!finish.isAfter(session.start)) continue;
      final range = TimeRange(session.start, finish);
      (allSessions[session.taskId] ??= []).add(range);
      final clipped = clipRange(range, start, end);
      if (clipped != null) (sessions[session.taskId] ??= []).add(clipped);
    }
    final taskActual = {
      for (final entry in sessions.entries) entry.key: unionRanges(entry.value),
    };
    final actual = unionRanges(taskActual.values.expand((v) => v));
    final planned = plans.values.expand((v) => v).toList();
    final application = unionRanges(
      usage
          .map((v) => clipRange(v, start, end.isAfter(now) ? now : end))
          .nonNulls,
    );
    final days = <DailyStatistics>[];
    var day = tz.TZDateTime.from(start, zone);
    while (day.isBefore(end)) {
      final next = tz.TZDateTime(zone, day.year, day.month, day.day + 1);
      days.add(
        DailyStatistics(
          date: day,
          planned: durationIn(planned, day, next),
          actual: durationIn(actual, day, next),
          application: durationIn(application, day, next),
        ),
      );
      day = next;
    }
    final projectPlans = <String, List<TimeRange>>{};
    final projectActual = <String, List<TimeRange>>{};
    for (final task in tasks.values) {
      (projectPlans[task.projectId] ??= []).addAll(plans[task.id] ?? []);
      (projectActual[task.projectId] ??= []).addAll(taskActual[task.id] ?? []);
    }
    final projects = <ProjectStatistics>[
      for (final id in {...projectPlans.keys, ...projectActual.keys})
        if ((projectPlans[id]?.isNotEmpty ?? false) ||
            (projectActual[id]?.isNotEmpty ?? false))
          ProjectStatistics(
            id.isEmpty
                ? 'Без проекта'
                : snapshot.project(id)?.title ?? 'Удалённый проект',
            snapshot.project(id)?.color ?? snapshot.settings.accentColor,
            sumRanges(projectPlans[id] ?? []),
            sumRanges(unionRanges(projectActual[id] ?? [])),
          ),
    ]..sort((a, b) => b.actual.compareTo(a.actual));
    final comparisons = <EstimateComparison>[];
    for (final id in plans.keys) {
      final task = tasks[id]!;
      if (!task.done) continue;
      final estimate = snapshot.estimate(id);
      if (estimate == Duration.zero) continue;
      comparisons.add(
        EstimateComparison(
          task,
          estimate,
          sumRanges(unionRanges(allSessions[id] ?? [])),
        ),
      );
    }
    comparisons.sort((a, b) {
      if (a.actual == Duration.zero && b.actual != Duration.zero) return 1;
      if (b.actual == Duration.zero && a.actual != Duration.zero) return -1;
      return b.difference.inMicroseconds.abs().compareTo(
        a.difference.inMicroseconds.abs(),
      );
    });
    return StatisticsReport(
      days: days,
      projects: projects,
      estimates: comparisons,
      plannedTasks: plans.length,
      completedTasks: plans.keys.where((id) => tasks[id]!.done).length,
      overlap:
          sumRanges(taskActual.values.expand((v) => v)) - sumRanges(actual),
      applicationSessions: usage
          .where(
            (u) =>
                !u.start.isBefore(start) &&
                u.start.isBefore(end) &&
                !u.start.isAfter(now),
          )
          .length,
      notes: snapshot.notes
          .where((n) => n.pinned.isEmpty && n.content.trim().isNotEmpty)
          .length,
      tasks: tasks.length,
    );
  }
}

TimeRange? clipRange(TimeRange range, DateTime start, DateTime end) {
  final from = range.start.isAfter(start) ? range.start : start;
  final to = range.end.isBefore(end) ? range.end : end;
  return to.isAfter(from) ? TimeRange(from, to) : null;
}

Duration sumDurations(Iterable<Duration> durations) =>
    durations.fold(Duration.zero, (sum, d) => sum + d);
Duration sumRanges(Iterable<TimeRange> ranges) =>
    sumDurations(ranges.map((r) => r.duration));
Duration durationIn(Iterable<TimeRange> ranges, DateTime start, DateTime end) =>
    sumRanges(ranges.map((r) => clipRange(r, start, end)).nonNulls);
