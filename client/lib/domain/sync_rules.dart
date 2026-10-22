import '../data/repository.dart';
import 'models.dart';
import 'package:collection/collection.dart';

/// Content-dependent reconciliation belongs to trusted devices, not the relay.
Future<bool> reconcileEncryptedRecords(
  Repository repo, {
  int restoredThrough = 0,
  DateTime? snapshotCreated,
}) async {
  var changed = false;
  await repo.commitComputed(() async {
    final all = await repo.db.entities(includeDeleted: true);
    final byId = {for (final e in all) e.id: e};
    final changes = <String, Entity>{};
    if (snapshotCreated != null) {
      for (final e in all.where(
        (e) =>
            e.kind == 'session' &&
            !e.deleted &&
            e.data['end'] == null &&
            e.seq > 0 &&
            e.seq <= restoredThrough,
      )) {
        final start = parseTime(e.data['start']);
        changes[e.id] = e.change({
          'end': wireTime(
            snapshotCreated.isAfter(start)
                ? snapshotCreated
                : start.add(const Duration(microseconds: 1)),
          ),
        });
      }
    }
    for (final e in all.where((e) => e.kind == 'task' && !e.deleted)) {
      final task = Task(e);
      if (task.seriesId.isEmpty) continue;
      final series = byId[task.seriesId];
      if (series == null) continue;
      final occurrence = DateTime.tryParse(task.occurrence);
      final cutoff = DateTime.tryParse(
        series.data['cancelled_from'] as String? ?? '',
      );
      final exceptions = (series.data['exceptions'] as List? ?? [])
          .whereType<String>();
      final cancelled =
          series.deleted ||
          (occurrence != null &&
              ((cutoff != null && !occurrence.isBefore(cutoff)) ||
                  exceptions.any(
                    (s) =>
                        DateTime.tryParse(s)?.isAtSameMomentAs(occurrence) ==
                        true,
                  )));
      if (cancelled) changes[e.id] = e.tombstone();
    }
    for (final e in all.where(
      (e) => !e.deleted && {'block', 'session', 'snooze'}.contains(e.kind),
    )) {
      final parent = changes[e.data['task_id']] ?? byId[e.data['task_id']];
      if (parent == null) continue;
      if (parent.deleted &&
          (parent.data['series_id'] as String? ?? '').isNotEmpty) {
        changes[e.id] = e.tombstone();
      } else if (e.kind == 'session' &&
          !changes.containsKey(e.id) &&
          e.data['end'] == null &&
          e.data['discarded'] != true &&
          (parent.deleted || parent.data['status'] == 'done')) {
        final start = parseTime(e.data['start']);
        final end =
            DateTime.tryParse(parent.data['completed_at'] as String? ?? '') ??
            repo.now();
        changes[e.id] = e.change({
          'end': wireTime(
            end.isAfter(start)
                ? end
                : start.add(const Duration(microseconds: 1)),
          ),
        });
      }
    }
    final running =
        all
            .where(
              (e) =>
                  e.kind == 'session' &&
                  !e.deleted &&
                  e.data['end'] == null &&
                  e.data['discarded'] != true &&
                  !changes.containsKey(e.id),
            )
            .toList()
          ..sort((a, b) {
            final order = parseTime(
              a.data['start'],
            ).compareTo(parseTime(b.data['start']));
            return order != 0 ? order : a.id.compareTo(b.id);
          });
    if (running.length > 1) {
      final latest = running.last;
      for (final prior in running.take(running.length - 1)) {
        final start = parseTime(prior.data['start']);
        final end = prior.data['device_id'] == latest.data['device_id']
            ? parseTime(latest.data['start'])
            : repo.now();
        changes[prior.id] = prior.change({
          'end': wireTime(
            end.isAfter(start)
                ? end
                : start.add(const Duration(microseconds: 1)),
          ),
          '_auto_close_base': prior.version,
        });
      }
    }
    changed = changes.isNotEmpty;
    return changes.values.toList();
  });
  return changed;
}

bool concurrentTimerClosure(Entity local, Entity remote) {
  if (local.kind != 'session' ||
      remote.deleted ||
      local.deleted ||
      local.data['_auto_close_base'] != remote.version - 1 ||
      local.data['_auto_close_base'] != remote.data['_auto_close_base'] ||
      local.data['end'] == null ||
      remote.data['end'] == null) {
    return false;
  }
  final a = Map<String, dynamic>.from(local.data)..remove('end');
  final b = Map<String, dynamic>.from(remote.data)..remove('end');
  return const DeepCollectionEquality().equals(a, b);
}
