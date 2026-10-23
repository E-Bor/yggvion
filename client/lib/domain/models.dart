import 'dart:convert';
import 'package:timezone/timezone.dart' as tz;
import 'markdown_blocks.dart';

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

  Map<String, dynamic>? get proposal =>
      (entity.data['proposal'] as Map?)?.cast<String, dynamic>();
  bool get isProposed => proposal?['pending'] == true;
  DateTime? get proposedStart =>
      proposal == null ? null : parseTime(proposal!['start']);
  DateTime? get proposedEnd =>
      proposal == null ? null : parseTime(proposal!['end']);
  String? get proposedTimezone => proposal?['timezone'] as String?;
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
  bool get isBirthday =>
      (entity.data['birthday_date'] as String? ?? '').isNotEmpty;
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
  List<DateTime> get reminderAt =>
      (entity.data['reminder_at'] as List? ?? []).map(parseTime).toList();
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
  String get explicitTitle =>
      title == 'Новая заметка' || title == 'Без названия' ? '' : title.trim();
  String get folderId => entity.data['folder_id'] as String? ?? '';
  int get sortOrder => entity.data['sort_order'] as int? ?? 0;
  String get displayLabel {
    if (pinned.isNotEmpty) return title;
    if (explicitTitle.isNotEmpty) return explicitTitle;
    MarkdownFence? fence;
    String? previous;
    for (final line in const LineSplitter().convert(content)) {
      final text = line.trim();
      if (fence != null) {
        if (fence.closes(line)) fence = null;
        continue;
      }
      fence = MarkdownFence.open(line);
      if (fence != null) {
        previous = null;
        continue;
      }
      if (RegExp(r'^( {4}|	)').hasMatch(line)) {
        previous = null;
        continue;
      }
      final heading = RegExp(r'^#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(text);
      if (heading != null) return heading[1]!;
      if (previous != null && RegExp(r'^(=+|-+)$').hasMatch(text)) {
        return previous;
      }
      previous = text.isEmpty ? null : text;
    }
    final firstLine = const LineSplitter()
        .convert(content)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .firstOrNull;
    if (firstLine == null) {
      return 'Пустая заметка';
    }
    return firstLine.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
  }

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

class NoteFolder {
  const NoteFolder(this.entity);
  final Entity entity;
  String get id => entity.id;
  String get title => entity.data['title'] as String;
  int get sortOrder => entity.data['sort_order'] as int? ?? 0;
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
  static const defaultAccentColor = 0xff9cb9ff;
  final Entity entity;
  int get defaultMinutes => entity.data['default_minutes'] as int;
  List<int> get reminders => (entity.data['reminders'] as List).cast<int>();
  String get timezone => entity.data['timezone'] as String;
  // Keep the existing wire key so saved settings and older servers still work.
  int get accentColor =>
      entity.data['task_color'] as int? ?? defaultAccentColor;
  int get searchTypos => (entity.data['search_typos'] as int? ?? 1).clamp(0, 2);
}

class Birthday {
  const Birthday(this.entity);
  final Entity entity;
  String get id => entity.id;
  String get name => entity.data['title'] as String;
  DateTime get date => DateTime.parse(entity.data['birthday_date'] as String);
}

class TimeRange {
  const TimeRange(this.start, this.end);
  final DateTime start, end;
  Duration get duration => end.difference(start);
}

/// Only elapsed parts of the plan are available for recording actual work.
List<TimeRange> availablePlannedTime(
  Iterable<TimeBlock> blocks,
  DateTime now,
) => blocks
    .where((block) => block.start.isBefore(now))
    .map(
      (block) =>
          TimeRange(block.start, block.end.isAfter(now) ? now : block.end),
    )
    .where((range) => range.end.isAfter(range.start))
    .toList();

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
  late final noteFolders =
      entities
          .where((e) => e.kind == 'note_folder')
          .map(NoteFolder.new)
          .toList()
        ..sort(
          (a, b) => a.sortOrder != b.sortOrder
              ? a.sortOrder.compareTo(b.sortOrder)
              : a.id.compareTo(b.id),
        );
  Note? note(String id) => notes.where((n) => n.id == id).firstOrNull;
  List<Note> notesInFolder(String folderId) {
    final folders = noteFolders.map((f) => f.id).toSet();
    return notes
        .where(
          (n) =>
              n.pinned.isEmpty &&
              (folders.contains(n.folderId) ? n.folderId : '') == folderId,
        )
        .toList()
      ..sort(
        (a, b) => a.sortOrder != b.sortOrder
            ? a.sortOrder.compareTo(b.sortOrder)
            : a.id.compareTo(b.id),
      );
  }

  late final projects = entities
      .where((e) => e.kind == 'project')
      .map(Project.new)
      .toList();
  late final birthdays = entities
      .where(
        (e) =>
            e.kind == 'series' &&
            e.data['birthday_date'] is String &&
            (e.data['birthday_date'] as String).isNotEmpty,
      )
      .map(Birthday.new)
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
      project(task.projectId)?.color ?? settings.accentColor;
  List<TimeBlock> taskBlocks(String id) => [...?_blocksByTask[id]];
  DateTime dayBoundary(DateTime now) {
    final local = tz.TZDateTime.from(now, tz.getLocation(settings.timezone));
    return tz.TZDateTime(local.location, local.year, local.month, local.day);
  }

  bool unscheduled(Task t, DateTime now) =>
      !t.isBirthday &&
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
