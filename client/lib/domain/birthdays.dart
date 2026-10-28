import '../l10n/strings.dart';
import 'dart:math' as math;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../data/repository.dart';
import 'models.dart';

String ageLabel(int years, {String? language}) =>
    formatAge(years, language: language);

DateTime birthdayInYear(DateTime birth, int year, tz.Location zone) =>
    tz.TZDateTime(
      zone,
      year,
      birth.month,
      math.min(birth.day, DateTime.utc(year, birth.month + 1, 0).day),
    );

DateTime nextBirthday(Birthday birthday, DateTime now, tz.Location zone) {
  final local = tz.TZDateTime.from(now, zone);
  final today = tz.TZDateTime(zone, local.year, local.month, local.day);
  final next = birthdayInYear(birthday.date, local.year, zone);
  return next.isBefore(today)
      ? birthdayInYear(birthday.date, local.year + 1, zone)
      : next;
}

class BirthdayService {
  BirthdayService(this.repo);
  final Repository repo;
  static const namespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

  Future<void> save(String name, DateTime birth, {Birthday? birthday}) async {
    final zone = tz.getLocation(repo.snapshot.settings.timezone);
    final today = tz.TZDateTime.from(repo.now(), zone);
    if (name.trim().isEmpty || name.trim().length > 1000) {
      throw ArgumentError(tr("Введите имя"));
    }
    if (birth.year < 1800 || dayKey(birth).compareTo(dayKey(today)) > 0) {
      throw ArgumentError(tr("Проверьте дату рождения"));
    }
    await repo.commitComputed(() async {
      final records = {
        for (final e in await repo.db.entities(includeDeleted: true)) e.id: e,
      };
      final previous = birthday == null ? null : records[birthday.id];
      if (birthday != null && (previous == null || previous.deleted)) {
        throw StateError(tr("День рождения уже удалён"));
      }
      final series =
          (previous ?? Entity(id: repo.newId(), kind: 'series', data: const {}))
              .change({
                'title': name.trim(),
                'description': '',
                'project_id': '',
                'birthday_date': dayKey(birth),
                'start': wireTime(
                  tz.TZDateTime(zone, birth.year, birth.month, birth.day),
                ),
                'minutes': 1440,
                'day_span': 1,
                'timezone': zone.name,
                'rule':
                    'FREQ=YEARLY;BYMONTH=${birth.month};BYMONTHDAY=${birth.day}',
                'reminders': <int>[],
                'all_day': true,
                'exceptions': <String>[],
              });
      final years = {
        today.year,
        today.year + 1,
        today.year + 2,
        for (final e in records.values)
          if (e.kind == 'task' &&
              !e.deleted &&
              e.data['series_id'] == series.id)
            e.data['birthday_year'] as int,
      };
      return [series, ..._occurrences(series, years, records, zone)];
    });
  }

  Future<void> expand(DateTime from, DateTime to) async {
    if (repo.snapshot.birthdays.isEmpty) return;
    await repo.commitComputed(() async {
      final records = {
        for (final e in await repo.db.entities(includeDeleted: true)) e.id: e,
      };
      final snapshot = Snapshot(
        records.values.where((e) => !e.deleted).toList(),
      );
      final zone = tz.getLocation(snapshot.settings.timezone);
      final year = tz.TZDateTime.from(repo.now(), zone).year;
      final first = tz.TZDateTime.from(from, zone).year;
      final last = tz.TZDateTime.from(to, zone).year;
      final years = {
        year,
        year + 1,
        year + 2,
        for (var y = first; y <= last; y++) y,
      };
      return [
        for (final birthday in snapshot.birthdays)
          ..._occurrences(
            birthday.entity,
            {
              ...years,
              // Refresh previously materialized years too, including their
              // reminder policy and timezone, without changing completion.
              for (final task in snapshot.tasks)
                if (task.isBirthday && task.seriesId == birthday.id)
                  task.entity.data['birthday_year'] as int,
            },
            records,
            zone,
          ),
      ];
    });
  }

  List<Entity> _occurrences(
    Entity series,
    Set<int> years,
    Map<String, Entity> records,
    tz.Location zone,
  ) {
    final birthday = Birthday(series), birth = Birthday(series).date;
    final changes = <Entity>[];
    for (final year in years) {
      final id = const Uuid().v5(namespace, 'birthday:${series.id}:$year');
      final blockId = const Uuid().v5(namespace, 'block:$id');
      final current = records[id], oldBlock = records[blockId];
      if (current?.deleted == true || oldBlock?.deleted == true) continue;
      if (year < birth.year) {
        if (current != null) changes.add(current.tombstone());
        if (oldBlock != null) changes.add(oldBlock.tombstone());
        continue;
      }
      final start = birthdayInYear(birth, year, zone);
      final end = tz.TZDateTime(zone, start.year, start.month, start.day + 1);
      final at = [tz.TZDateTime(zone, start.year, start.month, start.day, 9)];
      final task = (current ?? Task.create(id, birthday.name)).change({
        // Generated records must be identical on devices with different languages.
        'title':
            '${birthday.name} — день рождения · ${ageLabel(year - birth.year, language: 'ru')}',
        'series_id': series.id,
        'occurrence': wireTime(start),
        'birthday_date': dayKey(birth),
        'birthday_year': year,
      });
      final block =
          (oldBlock ??
                  TimeBlock.create(
                    blockId,
                    id,
                    start,
                    end,
                    timezone: zone.name,
                  ))
              .change({
                'start': wireTime(start),
                'end': wireTime(end),
                'timezone': zone.name,
                'all_day': true,
                'historical': false,
                'reminders': <int>[],
                'reminder_at': at.map(wireTime).toList(),
              });
      if (task.encoded != current?.encoded) changes.add(task);
      if (block.encoded != oldBlock?.encoded) changes.add(block);
    }
    return changes;
  }

  Future<void> delete(Birthday birthday) => repo.commitComputed(() async {
    final all = await repo.db.entities();
    final ids = all
        .where((e) => e.kind == 'task' && e.data['series_id'] == birthday.id)
        .map((e) => e.id)
        .toSet();
    return all
        .where(
          (e) =>
              e.id == birthday.id ||
              ids.contains(e.id) ||
              ({'block', 'session', 'snooze'}.contains(e.kind) &&
                  ids.contains(e.data['task_id'])),
        )
        .map((e) => e.tombstone())
        .toList();
  });
}
