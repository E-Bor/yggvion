import 'package:timezone/timezone.dart' as tz;
import 'models.dart';

/// A day's defaults are frozen on its first edit, so later setting changes do
/// not rewrite a recorded workday. Actual boundaries are optional until marked.
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
      throw const FormatException('Некорректная дата рабочего дня');
    }
    for (final range in [
      TimeRange(plannedStart, plannedEnd),
      TimeRange(start ?? plannedStart, end ?? plannedEnd),
    ]) {
      if (range.end.difference(range.start) < const Duration(minutes: 5) ||
          range.end.difference(range.start) > const Duration(hours: 25)) {
        throw const FormatException('Некорректные границы рабочего дня');
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
      settings = snapshot.settings,
      records = {
        for (final e in snapshot.entities)
          if (e.kind == 'workday' && !e.deleted)
            WorkdayRecord(e).day: WorkdayRecord(e),
      };
  final tz.Location zone;
  final AppSettings settings;
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
    final record = records[dayKey(day)];
    if (record == null && !settings.workdays.contains(day.weekday)) return null;
    return WorkdayWindow(
      date: day,
      plannedStart:
          record?.plannedStart ??
          tz.TZDateTime(
            zone,
            day.year,
            day.month,
            day.day,
            0,
            settings.workdayStart,
          ),
      plannedEnd:
          record?.plannedEnd ??
          tz.TZDateTime(
            zone,
            day.year,
            day.month,
            day.day,
            0,
            settings.workdayEnd,
          ),
      record: record,
    );
  }
}
