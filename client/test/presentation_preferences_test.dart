import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/birthdays.dart';
import 'package:yggvion/l10n/messages.dart';
import 'package:yggvion/l10n/strings.dart';
import 'package:yggvion/ui/interface_scale.dart';
import 'package:yggvion/ui/notes.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting();
  });
  tearDown(() => AppLocale.use('ru'));

  test('all translations preserve arguments and never translate user text', () {
    final parameter = RegExp(r'\{\d+\}');
    for (final entry in messages.entries) {
      expect(entry.value.length, 5, reason: entry.key);
      final expected = parameter.allMatches(entry.key).map((m) => m[0]).toSet();
      for (final value in entry.value) {
        expect(value, isNotEmpty, reason: entry.key);
        expect(
          parameter.allMatches(value).map((m) => m[0]).toSet(),
          expected,
          reason: entry.key,
        );
      }
    }
    AppLocale.use('de');
    expect(tr('Название'), 'Titel');
    expect(tr('Создать: {0}', ['Название {0}']), 'Erstellen: Название {0}');
    expect(Task(Task.create('task', 'Название')).title, 'Название');
    expect(
      Note(Note.create('note', 'Название', content: 'Сохранить')).displayLabel,
      'Название',
    );
    expect(DateFormat('MMMM').format(DateTime(2026, 10)), 'Oktober');
  });

  test(
    'local presentation preferences persist without modifying entities',
    () async {
      final db = LocalDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      addTearDown(db.close);
      addTearDown(repo.dispose);
      await repo.initialize();
      final settings = repo.snapshot.settings.entity.toJson();
      await repo.setLanguage('es');
      await repo.setInterfaceScale(.7);
      await repo.setCalendarZoom(2.25);
      final reopened = Repository(db);
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.language, 'es');
      expect(reopened.interfaceScale, .7);
      expect(reopened.calendarZoom, 2.25);
      expect(reopened.snapshot.settings.entity.toJson(), settings);
      await expectLater(repo.setLanguage('invalid'), throwsArgumentError);
      await expectLater(repo.setInterfaceScale(42), throwsArgumentError);
      await expectLater(repo.setCalendarZoom(double.nan), throwsArgumentError);
      await db.setMeta('calendar_zoom', 'NaN');
      await db.setMeta('interface_scale', 'NaN');
      await db.setMeta('language', 'invalid');
      await reopened.initialize();
      expect(reopened.language, 'ru');
      expect(reopened.interfaceScale, 1);
      expect(reopened.calendarZoom, 1);
    },
  );

  test('language changes never rewrite generated birthday records', () async {
    final db = LocalDatabase(NativeDatabase.memory());
    final repo = Repository(db, clock: () => DateTime.utc(2026, 10, 19));
    addTearDown(db.close);
    addTearDown(repo.dispose);
    await repo.initialize();
    final birthdays = BirthdayService(repo);
    await birthdays.save('Аня', DateTime(1990, 10, 20));
    final before = repo.snapshot.entities.map((e) => e.encoded).toList();
    for (final language in AppLocale.supported) {
      await repo.setLanguage(language);
      await birthdays.expand(
        repo.now(),
        repo.now().add(const Duration(days: 365)),
      );
      expect(repo.snapshot.entities.map((e) => e.encoded).toList(), before);
      final task = repo.snapshot.tasks.firstWhere(
        (t) => t.entity.data['birthday_year'] == 2026,
      );
      expect(
        task.title,
        tr('{0} — день рождения · {1}', ['Аня', formatAge(36)]),
      );
      expect(task.entity.data['title'], 'Аня — день рождения · 36 лет');
    }
  });

  for (final mobile in [true, false]) {
    testInteraction('calendar zoom fits a full day and persists ($mobile)', (
      tester,
    ) async {
      final repo = await workspace(tester, mobile: mobile);
      ScrollController controller() => tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('calendar-scroll')),
          )
          .controller!;
      expect(find.byKey(const ValueKey('calendar-zoom')), findsNothing);
      await command(tester, LogicalKeyboardKey.digit5);
      final fit = find.byKey(const ValueKey('calendar-zoom-fit'));
      await tester.ensureVisible(fit);
      await settle(tester);
      await tester.tap(fit);
      await settle(tester);
      expect(repo.calendarZoom, 0);
      await command(tester, LogicalKeyboardKey.digit1);
      expect(controller().position.maxScrollExtent, closeTo(0, 1));
      await command(tester, LogicalKeyboardKey.digit5);
      final zoom = find.byKey(const ValueKey('calendar-zoom-slider'));
      await tester.ensureVisible(zoom);
      await settle(tester);
      await tester.tapAt(tester.getTopRight(zoom) + const Offset(-24, 24));
      await settle(tester);
      expect(repo.calendarZoom, 3);
      await command(tester, LogicalKeyboardKey.digit1);
      await settle(tester);
      expect(controller().position.maxScrollExtent, greaterThan(4000));
      expect(await tester.runAsync(() => repo.db.meta('calendar_zoom')), '3.0');
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in AppLocale.supported) {
    testInteraction('phone navigation and settings fit in $language', (
      tester,
    ) async {
      final repo = await workspace(tester, mobile: true);
      await tester.runAsync(() => repo.setLanguage(language));
      await settle(tester);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        Locale(language),
      );
      for (final key in [
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
      ]) {
        await command(tester, key);
        expect(tester.takeException(), isNull, reason: '$language $key');
      }
      expect(find.text(tr('Масштаб интерфейса')), findsOneWidget);
    });
  }

  for (final scale in [.5, .7, 1.0, 1.5, 2.0]) {
    testInteraction(
      'phone interface scale $scale preserves notes and navigation',
      (tester) async {
        final repo = await workspace(tester, mobile: true);
        await command(tester, LogicalKeyboardKey.digit4);
        final field = find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is NotePanel && w.noteId == 'scratchpad',
          ),
          matching: find.byWidgetPredicate(
            (w) => w is TextField && w.maxLines == null,
          ),
        );
        await tester.enterText(field, 'Сохранить мой текст');
        await settle(tester);
        final input = tester.widget<TextField>(field).controller!;
        await tester.runAsync(() => repo.setInterfaceScale(scale));
        await settle(tester);
        expect(
          tester.widget<InterfaceScale>(find.byType(InterfaceScale)).scale,
          scale,
        );
        expect(tester.widget<TextField>(field).controller, same(input));
        expect(input.text, 'Сохранить мой текст');
        expect(
          find.byKey(const ValueKey('mobile-notes-attachments')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        for (final key in [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit5,
        ]) {
          await command(tester, key);
          expect(tester.takeException(), isNull, reason: '$scale $key');
        }
      },
    );
  }
}
