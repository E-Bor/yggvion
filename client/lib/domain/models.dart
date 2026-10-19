import 'dart:convert';
import 'package:timezone/timezone.dart' as tz;

enum TaskStatus {
  todo('To Do'),
  inProgress('In Progress'),
  waiting('Waiting'),
  done('Done');

  const TaskStatus(this.label);
  final String label;
  String get wire => this == inProgress ? 'in_progress' : name;
  static TaskStatus parse(String value) =>
      values.firstWhere((s) => s.wire == value);
}

enum CalendarView { day, threeDays, week, month }

extension CalendarViewLabel on CalendarView {
  String get label => switch (this) {
    CalendarView.day => 'День',
    CalendarView.threeDays => '3 дня',
    CalendarView.week => 'Неделя',
    CalendarView.month => 'Месяц',
  };
  int get days => switch (this) {
    CalendarView.day => 1,
    CalendarView.threeDays => 3,
    CalendarView.week => 7,
    CalendarView.month => 42,
  };
}

DateTime parseTime(Object? value) => DateTime.parse(value! as String).toUtc();
String wireTime(DateTime value) => value.toUtc().toIso8601String();
// RFC 5545 identifies occurrences to the second, even when a timer-created
// source block contains subsecond precision.
String occurrenceKey(DateTime value) {
  final utc = value.toUtc();
  return wireTime(
    DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
    ),
  );
}

DateTime dayOf(DateTime value) => DateTime(value.year, value.month, value.day);
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 60) return '$minutes мин';
  return '${minutes ~/ 60} ч${minutes % 60 == 0 ? '' : ' ${minutes % 60} мин'}';
}

class Entity {
  const Entity({
    required this.id,
    required this.kind,
    required this.data,
    this.version = 0,
    this.deleted = false,
    this.seq = 0,
  });
  final String id, kind;
  final Map<String, dynamic> data;
  final int version, seq;
  final bool deleted;
  factory Entity.fromJson(Map<String, dynamic> json) => Entity(
    id: json['id'] as String,
    kind: json['kind'] as String,
    data: Map<String, dynamic>.from(json['data'] as Map),
    version: json['version'] as int? ?? 0,
    deleted: json['deleted'] as bool? ?? false,
    seq: json['seq'] as int? ?? 0,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'data': data,
    'version': version,
    'deleted': deleted,
    'seq': seq,
  };
  Entity change(Map<String, dynamic> values) => Entity(
    id: id,
    kind: kind,
    data: {...data, ...values},
    version: version,
    deleted: deleted,
    seq: seq,
  );
  Entity withVersion(int value) => Entity(
    id: id,
    kind: kind,
    data: data,
    version: value,
    deleted: deleted,
    seq: seq,
  );
  Entity tombstone() => Entity(
    id: id,
    kind: kind,
    data: data,
    version: version,
    deleted: true,
    seq: seq,
  );
  String get encoded => jsonEncode(toJson());
  String get searchable => [
    data['title'],
    data['description'],
    data['content'],
  ].whereType<String>().join('\n');
}

class Task {
  const Task(this.entity);
  final Entity entity;
  String get id => entity.id;
  String get title => entity.data['title'] as String;
  String get description => entity.data['description'] as String? ?? '';
  String get projectId => entity.data['project_id'] as String? ?? '';
  String get seriesId => entity.data['series_id'] as String? ?? '';
  String get occurrence {
    final value = entity.data['occurrence'] as String? ?? '';
    return value.isEmpty ? '' : occurrenceKey(parseTime(value));
  }

  String get parentId => entity.data['parent_id'] as String? ?? '';
  TaskStatus get status => TaskStatus.parse(entity.data['status'] as String);
  bool get done => status == TaskStatus.done;
  static Entity create(
    String id,
    String title, {
    String description = '',
    String projectId = '',
    String parentId = '',
    String seriesId = '',
    String occurrence = '',
  }) => Entity(
    id: id,
    kind: 'task',
    data: {
      'title': title.trim(),
      'description': description,
      'project_id': projectId,
      'status': 'todo',
      'parent_id': parentId,
      'series_id': seriesId,
      'occurrence': occurrence,
    },
  );
}

class TimeBlock {
  const TimeBlock(this.entity);
  final Entity entity;
  String get id => entity.id;
  String get taskId => entity.data['task_id'] as String;
  DateTime get start => parseTime(entity.data['start']);
  DateTime get end => parseTime(entity.data['end']);
  String get timezone => entity.data['timezone'] as String;
  bool get allDay => entity.data['all_day'] as bool? ?? false;
  bool get historical => entity.data['historical'] as bool? ?? false;
  List<int> get reminders =>
      (entity.data['reminders'] as List? ?? []).cast<int>();
  Duration get duration => end.difference(start);
  static Entity create(
    String id,
    String taskId,
    DateTime start,
    DateTime end, {
    required String timezone,
    bool allDay = false,
    List<int> reminders = const [0],
  }) => Entity(
    id: id,
    kind: 'block',
    data: {
      'task_id': taskId,
      'start': wireTime(start),
      'end': wireTime(end),
      'timezone': timezone,
      'all_day': allDay,
      'historical': false,
      'reminders': reminders,
    },
  );
}

class WorkSession {
  const WorkSession(this.entity);
  final Entity entity;
  String get id => entity.id;
  String get taskId => entity.data['task_id'] as String;
  String get deviceId => entity.data['device_id'] as String;
  DateTime get start => parseTime(entity.data['start']);
  DateTime? get end =>
      entity.data['end'] == null ? null : parseTime(entity.data['end']);
  bool get discarded => entity.data['discarded'] as bool? ?? false;
  bool get running => end == null && !discarded;
  static Entity create(
    String id,
    String taskId,
    String deviceId,
    DateTime start,
    DateTime? end,
  ) => Entity(
    id: id,
    kind: 'session',
    data: {
      'task_id': taskId,
      'device_id': deviceId,
      'start': wireTime(start),
      'end': end == null ? null : wireTime(end),
      'discarded': false,
    },
  );
}

class Note {
  const Note(this.entity);
  final Entity entity;
  String get id => entity.id;
  String get title => entity.data['title'] as String;
  String get content => entity.data['content'] as String? ?? '';
  String get pinned => entity.data['pinned'] as String? ?? '';
  static Entity create(
    String id,
    String title, {
    String pinned = '',
    String content = '',
  }) => Entity(
    id: id,
    kind: 'note',
    data: {'title': title, 'content': content, 'pinned': pinned},
  );
}

class Project {
  const Project(this.entity);
  final Entity entity;
  String get id => entity.id;
  String get title => entity.data['title'] as String;
  int get color => entity.data['color'] as int;
}

class AppSettings {
  const AppSettings(this.entity);
  final Entity entity;
  int get defaultMinutes => entity.data['default_minutes'] as int;
  List<int> get reminders => (entity.data['reminders'] as List).cast<int>();
  String get timezone => entity.data['timezone'] as String;
  int get taskColor => entity.data['task_color'] as int? ?? 0xff9cb9ff;
}

class TimeRange {
  const TimeRange(this.start, this.end);
  final DateTime start, end;
  Duration get duration => end.difference(start);
}

/// Union preserves gaps and counts overlap only once; adjacent intervals coalesce.
List<TimeRange> unionRanges(Iterable<TimeRange> source) {
  final sorted = source.where((v) => v.end.isAfter(v.start)).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final result = <TimeRange>[];
  for (final next in sorted) {
    if (result.isEmpty || next.start.isAfter(result.last.end)) {
      result.add(next);
    } else {
      final previous = result.removeLast();
      result.add(
        TimeRange(
          previous.start,
          next.end.isAfter(previous.end) ? next.end : previous.end,
        ),
      );
    }
  }
  return result;
}

class SessionConflict {
  const SessionConflict(this.sessions);
  final List<WorkSession> sessions;
  Set<String> get devices => sessions.map((s) => s.deviceId).toSet();
}

List<SessionConflict> sessionConflicts(
  Iterable<WorkSession> sessions,
  DateTime now,
) {
  final sorted = sessions.where((s) => !s.discarded).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final groups = <List<WorkSession>>[];
  DateTime? until;
  for (final s in sorted) {
    final end = s.end ?? now;
    if (until == null || !s.start.isBefore(until)) {
      groups.add([s]);
      until = end;
    } else {
      groups.last.add(s);
      if (end.isAfter(until)) until = end;
    }
  }
  return groups
      .where((g) => g.map((s) => s.deviceId).toSet().length > 1)
      .map(SessionConflict.new)
      .toList();
}

class Snapshot {
  Snapshot(this.entities);
  final List<Entity> entities;
  late final tasks = entities
      .where((e) => e.kind == 'task')
      .map(Task.new)
      .toList();
  late final blocks = entities
      .where((e) => e.kind == 'block')
      .map(TimeBlock.new)
      .toList();
  late final sessions = entities
      .where((e) => e.kind == 'session')
      .map(WorkSession.new)
      .toList();
  late final notes = entities
      .where((e) => e.kind == 'note')
      .map(Note.new)
      .toList();
  late final projects = entities
      .where((e) => e.kind == 'project')
      .map(Project.new)
      .toList();
  late final settings = AppSettings(
    entities.firstWhere((e) => e.kind == 'settings'),
  );
  late final _tasksById = {for (final t in tasks) t.id: t};
  late final _projectsById = {for (final p in projects) p.id: p};
  late final _blocksByTask = _indexBlocks();
  late final _sessionsByTask = _indexSessions();
  Map<String, List<TimeBlock>> _indexBlocks() {
    final result = <String, List<TimeBlock>>{};
    for (final b in blocks) {
      (result[b.taskId] ??= []).add(b);
    }
    for (final list in result.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    return result;
  }

  Map<String, List<WorkSession>> _indexSessions() {
    final result = <String, List<WorkSession>>{};
    for (final s in sessions) {
      (result[s.taskId] ??= []).add(s);
    }
    return result;
  }

  Task? task(String id) => _tasksById[id];
  Project? project(String id) => _projectsById[id];
  int taskColor(Task task) =>
      project(task.projectId)?.color ?? settings.taskColor;
  List<TimeBlock> taskBlocks(String id) => [...?_blocksByTask[id]];
  DateTime dayBoundary(DateTime now) {
    final local = tz.TZDateTime.from(now, tz.getLocation(settings.timezone));
    return tz.TZDateTime(local.location, local.year, local.month, local.day);
  }

  bool unscheduled(Task t, DateTime now) =>
      !t.done &&
      !(_blocksByTask[t.id] ?? const <TimeBlock>[]).any(
        (b) => !b.historical && b.end.isAfter(dayBoundary(now)),
      );
  Duration estimate(String taskId) =>
      (_blocksByTask[taskId] ?? const <TimeBlock>[])
          .where((b) => !b.historical)
          .fold(Duration.zero, (s, b) => s + b.duration);
  Duration spent(String taskId, DateTime now) => unionRanges(
    (_sessionsByTask[taskId] ?? const <WorkSession>[])
        .where((s) => !s.discarded)
        .map((s) => TimeRange(s.start, s.end ?? now)),
  ).fold(Duration.zero, (d, r) => d + r.duration);
}
