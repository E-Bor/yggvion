import '../l10n/strings.dart';
import 'package:timezone/timezone.dart' as tz;
import 'models.dart';

/// A default regime. Historical entries apply strictly before [until];
/// the current regime has no upper boundary.
class WorkdayPattern {
  const WorkdayPattern(this.start, this.end, this.days, {this.until});
  WorkdayPattern.fromSettings(AppSettings settings)
    : this(settings.workdayStart, settings.workdayEnd, settings.workdays);
  WorkdayPattern.fromJson(Map<String, dynamic> json)
    : this(
        json['start'] as int,
        json['end'] as int,
        (json['days'] as List).cast<int>(),
        until: json['until'] as String?,
      );
  final int start, end;
  final List<int> days;
  final String? until;

  void validate() {
    if (start < 0 ||
        start >= 1440 ||
        end - start < 5 ||
        end > start + 1440 ||
        days.any((day) => day < 1 || day > 7)) {
      throw FormatException(tr("Некорректный режим рабочего дня"));
    }
    if (until != null) {
      final date = DateTime.tryParse(until!);
      if (date == null || dayKey(date) != until) {
        throw FormatException(tr("Некорректная дата смены рабочего режима"));
      }
    }
  }

  bool sameAs(WorkdayPattern other) =>
      start == other.start &&
      end == other.end &&
      days.toSet().containsAll(other.days) &&
      other.days.toSet().containsAll(days);

  Map<String, dynamic> toJson({required String until}) => {
    'until': until,
    'start': start,
    'end': end,
    'days': days,
  };
}

/// Stores prior regimes, so changing defaults never reinterprets earlier days.
/// Keeping this with settings uses the existing encrypted sync/conflict flow.
class WorkdayHistory {
  WorkdayHistory(AppSettings settings)
    : current = WorkdayPattern.fromSettings(settings),
      previous = [
        for (final value
            in settings.entity.data['workday_history'] as List? ?? [])
          WorkdayPattern.fromJson((value as Map).cast<String, dynamic>()),
      ] {
    current.validate();
    String? last;
    for (final pattern in previous) {
      pattern.validate();
      final until = pattern.until;
      if (until == null || (last != null && until.compareTo(last) <= 0)) {
        throw FormatException(tr("Некорректная история рабочего режима"));
      }
      last = until;
    }
  }
  final WorkdayPattern current;
  final List<WorkdayPattern> previous;

  WorkdayPattern forDate(String day) {
    var low = 0, high = previous.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (day.compareTo(previous[middle].until!) < 0) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low < previous.length ? previous[low] : current;
  }

  Map<String, dynamic> changedFrom(String day, WorkdayPattern next) {
    next.validate();
    final retained = [
      for (final pattern in previous)
        if (pattern.until!.compareTo(day) <= 0)
          pattern.toJson(until: pattern.until!),
    ];
    // Repeated edits on the same date replace the current regime. If the
    // clock moved back, replace subsequent regimes, preserving earlier ones.
    if (retained.isEmpty || retained.last['until'] != day) {
      retained.add(forDate(day).toJson(until: day));
    }
    return {
      'workday_start': next.start,
      'workday_end': next.end,
      'workdays': next.days,
      'workday_history': retained,
    };
  }
}

/// A day's defaults are frozen on its first edit, so later setting changes do
/// not rewrite a recorded workday. Individual boundary overrides are optional.
class WorkdayRecord {
  const WorkdayRecord(this.entity);
  final Entity entity;
  String get day => entity.data['day'] as String;
  DateTime get plannedStart => parseTime(entity.data['planned_start']);
  DateTime get plannedEnd => parseTime(entity.data['planned_end']);
  DateTime? get start =>
      entity.data['start'] == null ? null : parseTime(entity.data['start']);
  DateTime? get end =>
      entity.data['end'] == null ? null : parseTime(entity.data['end']);

  void validate() {
    final date = DateTime.tryParse(day);
    if (date == null || dayKey(date) != day || entity.id != 'workday-$day') {
      throw FormatException(tr("Некорректная дата рабочего дня"));
    }
    for (final range in [
      TimeRange(plannedStart, plannedEnd),
      TimeRange(start ?? plannedStart, end ?? plannedEnd),
    ]) {
      if (range.end.difference(range.start) < const Duration(minutes: 5) ||
          range.end.difference(range.start) > const Duration(hours: 25)) {
        throw FormatException(tr("Некорректные границы рабочего дня"));
      }
    }
  }
}

class WorkdayWindow {
  const WorkdayWindow({
    required this.date,
    required this.plannedStart,
    required this.plannedEnd,
    this.record,
  });
  final DateTime date, plannedStart, plannedEnd;
  final WorkdayRecord? record;
  DateTime get start => record?.start ?? plannedStart;
  DateTime get end => record?.end ?? plannedEnd;
  Duration get duration => end.difference(start);
}

class WorkdaySchedule {
  WorkdaySchedule(Snapshot snapshot, {tz.Location? location})
    : zone = location ?? tz.getLocation(snapshot.settings.timezone),
      history = WorkdayHistory(snapshot.settings),
      records = {
        for (final e in snapshot.entities)
          if (e.kind == 'workday' && !e.deleted)
            WorkdayRecord(e).day: WorkdayRecord(e),
      };
  final tz.Location zone;
  final WorkdayHistory history;
  final Map<String, WorkdayRecord> records;

  /// Clock time of the end, represented as minutes from the starting date.
  static int endMinute(int start, int clockEnd) =>
      clockEnd <= start ? clockEnd + 1440 : clockEnd;

  /// A night belongs to its starting date. If adjacent windows overlap,
  /// the earlier workday keeps the overlap, so time is never counted twice.
  TimeRange? rangeForDate(DateTime date) {
    final window = forDate(date);
    if (window == null) return null;
    final day = window.date;
    final previous = forDate(
      tz.TZDateTime(zone, day.year, day.month, day.day - 1),
    );
    final begin = previous != null && previous.end.isAfter(window.start)
        ? previous.end
        : window.start;
    return window.end.isAfter(begin) ? TimeRange(begin, window.end) : null;
  }

  WorkdayWindow? forDate(DateTime date) {
    final local = tz.TZDateTime.from(date, zone);
    final day = tz.TZDateTime(zone, local.year, local.month, local.day);
    final key = dayKey(day);
    final record = records[key];
    final pattern = history.forDate(key);
    if (record == null && !pattern.days.contains(day.weekday)) return null;
    return WorkdayWindow(
      date: day,
      plannedStart:
          record?.plannedStart ??
          tz.TZDateTime(zone, day.year, day.month, day.day, 0, pattern.start),
      plannedEnd:
          record?.plannedEnd ??
          tz.TZDateTime(zone, day.year, day.month, day.day, 0, pattern.end),
      record: record,
    );
  }
}
