import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'package:yggvion/ui/theme.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

double contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance(), b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

class FailingThemeDatabase extends LocalDatabase {
  FailingThemeDatabase() : super(NativeDatabase.memory());
  bool failThemeWrite = false;

  @override
  Future<void> setMeta(String key, String value) {
    if (failThemeWrite && key == 'light_theme') {
      throw StateError('Theme storage unavailable');
    }
    return super.setMeta(key, value);
  }
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('light palette keeps text and every available accent readable', () {
    final palette = AppPalette.light;
    for (final background in [
      palette.background,
      palette.surface,
      palette.raised,
    ]) {
      expect(contrast(palette.text, background), greaterThanOrEqualTo(7));
      expect(contrast(palette.muted, background), greaterThanOrEqualTo(4.5));
    }
    for (final color in Palette.projects) {
      final theme = appTheme(
        brightness: Brightness.light,
        accentColor: color.toARGB32(),
      );
      final accent = theme.colorScheme.primary;
      expect(contrast(accent, palette.surface), greaterThanOrEqualTo(4.5));
      expect(contrast(accent, palette.raised), greaterThanOrEqualTo(4.5));
      expect(
        contrast(theme.colorScheme.onPrimary, accent),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(accent, palette.taskSurface(accent, selected: true)),
        greaterThanOrEqualTo(4.5),
      );
      expect(palette.taskSurface(accent).a, 1);
      expect(
        appTheme(accentColor: color.toARGB32()).colorScheme.primary,
        color,
      );
    }
  });

  test(
    'theme preference persists locally and older settings remain dark',
    () async {
      final db = LocalDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      addTearDown(repo.dispose);
      await repo.initialize();
      expect(repo.lightTheme, isFalse);
      final settings = repo.snapshot.settings.entity.toJson();
      await repo.setLightTheme(true);
      expect(repo.lightTheme, isTrue);

      final reopened = Repository(db);
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.lightTheme, isTrue);
      expect(reopened.snapshot.settings.entity.toJson(), settings);
      await reopened.setLightTheme(false);
      await repo.initialize();
      expect(repo.lightTheme, isFalse);
      await db.setMeta('light_theme', 'unknown');
      await repo.initialize();
      expect(repo.lightTheme, isFalse);
    },
  );

  test(
    'a failed theme write keeps the current theme and can be retried',
    () async {
      final db = FailingThemeDatabase();
      addTearDown(db.close);
      final repo = Repository(db);
      addTearDown(repo.dispose);
      await repo.initialize();
      db.failThemeWrite = true;
      await expectLater(repo.setLightTheme(true), throwsStateError);
      expect(repo.lightTheme, isFalse);
      expect(await db.meta('light_theme'), isNull);
      db.failThemeWrite = false;
      await repo.setLightTheme(true);
      expect(repo.lightTheme, isTrue);
      expect(await db.meta('light_theme'), 'true');
    },
  );

  for (final mobile in [false, true]) {
    testInteraction(
      'theme switch updates the workspace and open dialogs (mobile: $mobile)',
      (tester) async {
        final projectColor = Palette.projects[1];
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.saveProject('Работа', projectColor.toARGB32());
            await repo.createTask(
              'Глубокая работа',
              start: repo.now(),
              end: repo.now().add(const Duration(hours: 1)),
              description:
                  '## Следующий шаг\n\nПродумать детали и записать решение.',
            );
            await repo.createTask(
              'Обсудить проект',
              projectId: repo.snapshot.projects.single.id,
              start: repo.now().add(const Duration(hours: 1)),
            );
            await repo.saveNoteContent(
              'scratchpad',
              '# План на день\n\nСосредоточиться на главном.\n\n'
                  '- Закончить макет\n- Подготовиться к встрече\n\n'
                  '> Оставить время на отдых.\n\n```yaml\nfocus: true\n```',
            );
            await repo.saveNoteContent(
              'reference',
              '## Под рукой\n\nПолезные ссылки и идеи.',
            );
          },
        );
        final accent = repo.snapshot.settings.accentColor;
        await command(tester, LogicalKeyboardKey.digit5);
        final toggle = find.byKey(const ValueKey('light-theme-toggle'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await settle(tester);
        expect(repo.lightTheme, isTrue);
        expect(Theme.of(tester.element(toggle)).brightness, Brightness.light);
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile(
            'goldens/light_settings_${mobile ? 390 : 1440}.png',
          ),
        );

        await command(tester, LogicalKeyboardKey.digit1);
        final context = tester.element(find.byType(CalendarPane));
        expect(context.palette, AppPalette.light);
        expect(
          tester.widget<Text>(find.text('Обсудить проект')).style!.color,
          AppPalette.light.accent(projectColor),
        );
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile(
            'goldens/light_workspace_${mobile ? 390 : 1440}.png',
          ),
        );

        await tester.tap(find.text('Глубокая работа'));
        await settle(tester);
        final title = find.byKey(const ValueKey('task-title'));
        await tester.enterText(title, 'Изменённый черновик');
        await tester.runAsync(() => repo.setLightTheme(false));
        await settle(tester);
        expect(Theme.of(tester.element(title)).brightness, Brightness.dark);
        await tester.runAsync(() => repo.setLightTheme(true));
        await settle(tester);
        expect(Theme.of(tester.element(title)).brightness, Brightness.light);
        expect(
          tester.widget<TextField>(title).controller!.text,
          'Изменённый черновик',
        );
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile(
            'goldens/light_task_editor_${mobile ? 390 : 1440}.png',
          ),
        );
        await tester.tap(find.byTooltip('Закрыть'));
        await settle(tester);
        expect(find.byType(TaskEditor), findsNothing);
        await command(tester, LogicalKeyboardKey.digit4);
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile('goldens/light_notes_${mobile ? 390 : 1440}.png'),
        );
        await command(tester, LogicalKeyboardKey.digit3);
        await command(tester, LogicalKeyboardKey.digit2);
        await tester.runAsync(() => repo.initialize());
        await settle(tester);
        expect(repo.lightTheme, isTrue);
        expect(repo.snapshot.settings.accentColor, accent);
        expect(repo.snapshot.projects.single.color, projectColor.toARGB32());
        await command(tester, LogicalKeyboardKey.digit5);
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await settle(tester);
        expect(repo.lightTheme, isFalse);
        expect(Theme.of(tester.element(toggle)).brightness, Brightness.dark);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
