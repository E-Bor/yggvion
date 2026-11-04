import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  setUpAll(tz.initializeTimeZones);
  final now = DateTime.utc(2026, 10, 19, 12);

  Entity done(String id, DateTime? at, {String projectId = ''}) => Task.create(
    id,
    id,
    projectId: projectId,
  ).change({'status': 'done', if (at != null) 'completed_at': wireTime(at)});

  test('all board statuses distinguish unassigned tasks from all projects', () {
    for (final status in TaskStatus.values) {
      final snapshot = Snapshot([
        ...Repository.workspaceDefaults('UTC'),
        for (final id in ['project', 'personal', 'legacy'])
          Task.create(id, id, projectId: id == 'project' ? 'p' : '').change({
            'status': status.wire,
            'completed_at': wireTime(now),
            if (id == 'legacy') 'project_id': null,
          }),
      ]);
      expect(
        snapshot.boardTasks(status, now).map((task) => task.id),
        unorderedEquals(['project', 'personal', 'legacy']),
      );
      expect(
        snapshot.boardTasks(status, now, projectId: '').map((task) => task.id),
        unorderedEquals(['personal', 'legacy']),
      );
      expect(
        snapshot.boardTasks(status, now, projectId: 'p').map((task) => task.id),
        ['project'],
      );
    }
  });

  test('Done shows seven calendar days and keeps undated tasks in history', () {
    final boundary = DateTime.utc(2026, 10, 13);
    final snapshot = Snapshot([
      ...Repository.workspaceDefaults('UTC'),
      done('older', boundary.subtract(const Duration(microseconds: 1))),
      done('boundary', boundary),
      done('newest', now),
      done('undated', null),
      done('invalid-date', null).change({'completed_at': 'unknown'}),
    ]);
    expect(snapshot.boardTasks(TaskStatus.done, now).map((t) => t.id), [
      'newest',
      'boundary',
    ]);
    expect(
      snapshot
          .boardTasks(TaskStatus.done, now.add(const Duration(days: 1)))
          .map((t) => t.id),
      ['newest'],
    );
    expect(
      snapshot.boardTasks(TaskStatus.done, now, doneDays: 30).map((t) => t.id),
      ['newest', 'boundary', 'older'],
    );
    expect(
      snapshot
          .boardTasks(TaskStatus.done, now, doneDays: null)
          .map((t) => t.id),
      ['newest', 'boundary', 'older', 'invalid-date', 'undated'],
    );
    expect(snapshot.task('older')!.done, isTrue);
    expect(snapshot.task('undated')!.done, isTrue);
    expect(
      () => snapshot.boardTasks(TaskStatus.done, now, doneDays: 0),
      throwsRangeError,
    );
  });

  test('Done cutoff follows the app timezone and daylight-saving changes', () {
    for (final scenario in [
      (
        zone: 'Europe/Moscow',
        now: DateTime.utc(2026, 10, 19, 22), // October 20 locally
        boundary: DateTime.utc(2026, 10, 13, 21), // October 14, midnight
      ),
      (
        zone: 'America/New_York',
        now: DateTime.utc(2026, 3, 9, 16), // Noon, after DST began
        boundary: DateTime.utc(2026, 3, 3, 5), // Midnight, before DST
      ),
    ]) {
      final snapshot = Snapshot([
        ...Repository.workspaceDefaults(scenario.zone),
        done('included', scenario.boundary),
        done(
          'excluded',
          scenario.boundary.subtract(const Duration(microseconds: 1)),
        ),
      ]);
      expect(
        snapshot.boardTasks(TaskStatus.done, scenario.now).map((t) => t.id),
        ['included'],
        reason: scenario.zone,
      );
    }
  });

  test(
    'Done filters projects and never shows recurring, proposed or deleted tasks',
    () {
      final snapshot = Snapshot([
        ...Repository.workspaceDefaults('UTC'),
        done('project', now, projectId: 'p'),
        done('personal', now),
        done('repeat', now).change({'series_id': 'series'}),
        done('birthday', now).change({'birthday_date': '1990-10-19'}),
        done('proposal', now).change({
          'proposal': {'pending': true},
        }),
        done('deleted', now).tombstone(),
        Task.create('todo', 'В работе', projectId: 'p'),
      ]);
      expect(
        snapshot
            .boardTasks(TaskStatus.done, now, projectId: 'p')
            .map((t) => t.id),
        ['project'],
      );
      expect(
        snapshot
            .boardTasks(TaskStatus.done, now, projectId: '')
            .map((t) => t.id),
        ['personal'],
      );
      expect(
        snapshot
            .boardTasks(TaskStatus.done, now, doneDays: null)
            .map((t) => t.id),
        ['personal', 'project'],
      );
      expect(
        snapshot.boardTasks(TaskStatus.todo, now, projectId: 'p').single.id,
        'todo',
      );
    },
  );
}
