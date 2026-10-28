import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/app_logo.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'package:yggvion/ui/theme.dart';
import 'interaction_test.dart' show workspace, settle, testInteraction, command;

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

  for (final mobile in [false, true]) {
    testInteraction(
      'accent changes navigation, controls, calendar and open editor without restarting (mobile: $mobile)',
      (tester) async {
        final projectColor = Palette.projects[3];
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.saveProject('Работа', projectColor.toARGB32());
            await repo.createTask('Личная задача', start: repo.now());
            await repo.createTask(
              'Задача проекта',
              projectId: repo.snapshot.projects.single.id,
              start: repo.now().add(const Duration(hours: 1)),
            );
            await repo.saveNote(
              'reference',
              'Под рукой',
              '> Рабочий ритм\n\nОставить место для глубокого фокуса.',
            );
          },
        );
        await command(tester, LogicalKeyboardKey.digit5);
        expect(find.text('Акцентный цвет'), findsOneWidget);
        expect(find.text('Цвет задач без проекта'), findsNothing);
        final choice = find.descendant(
          of: find.byKey(const ValueKey('accent-color-picker')),
          matching: find.byKey(const ValueKey('color-choice-4')),
        );
        await tester.ensureVisible(choice);
        await settle(tester);
        await tester.tap(choice);
        await settle(tester);
        final rose = Palette.projects[4];
        expect(repo.snapshot.settings.accentColor, rose.toARGB32());
        await command(tester, LogicalKeyboardKey.digit1);
        final calendar = find.byType(CalendarPane);
        expect(Theme.of(tester.element(calendar)).colorScheme.primary, rose);
        expect(
          tester.widget<Text>(find.text('Личная задача')).style!.color,
          rose,
        );
        expect(
          tester.widget<Text>(find.text('Задача проекта')).style!.color,
          projectColor,
        );
        if (mobile) {
          expect(
            tester.widget<Icon>(find.byIcon(Icons.today_outlined)).color,
            rose,
          );
        } else {
          final today = find.descendant(
            of: find.byType(CalendarToolbar),
            matching: find.text('Сегодня'),
          );
          expect(DefaultTextStyle.of(tester.element(today)).style.color, rose);
        }
        if (!mobile) {
          expect(
            tester
                .widget<Image>(
                  find.descendant(
                    of: find.byType(AppLogo),
                    matching: find.byType(Image),
                  ),
                )
                .color,
            rose,
          );
          expect(
            tester
                .widget<ListTile>(find.byKey(const ValueKey('nav-today')))
                .selectedColor,
            rose,
          );
          final button = find
              .ancestor(
                of: find.text('Задача'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              )
              .first;
          expect(
            tester
                .widget<Material>(
                  find
                      .descendant(of: button, matching: find.byType(Material))
                      .first,
                )
                .color,
            rose,
          );
          expect(find.byType(MarkdownPreview), findsWidgets);
        }
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile('goldens/accent_rose_${mobile ? 390 : 1440}.png'),
        );

        await command(tester, LogicalKeyboardKey.keyN);
        final title = find.byKey(const ValueKey('task-title'));
        await tester.enterText(title, 'Несохранённый черновик');
        // A synced setting must also recolor an already open dialog, preserving
        // its draft. Reload uses the same persisted record as app startup.
        final lavender = Palette.projects[1];
        await tester.runAsync(() async {
          await repo.commit([
            repo.snapshot.settings.entity.change({
              'task_color': lavender.toARGB32(),
            }),
          ]);
          await repo.reload();
        });
        await settle(tester);
        expect(find.byType(TaskEditor), findsOneWidget);
        final field = tester.widget<TextField>(title);
        expect(field.controller!.text, 'Несохранённый черновик');
        expect(field.decoration!.focusedBorder!.borderSide.color, lavender);
        final editorTheme = Theme.of(tester.element(title));
        expect(editorTheme.colorScheme.primary, lavender);
        expect(editorTheme.colorScheme.secondary, lavender);
        expect(editorTheme.textSelectionTheme.cursorColor, lavender);
        expect(editorTheme.textSelectionTheme.selectionHandleColor, lavender);
        expect(repo.snapshot.projects.single.color, projectColor.toARGB32());
        await tester.tap(find.byTooltip('Закрыть'));
        await settle(tester);
        if (!mobile) {
          expect(
            tester
                .widget<Image>(
                  find.descendant(
                    of: find.byType(AppLogo),
                    matching: find.byType(Image),
                  ),
                )
                .color,
            lavender,
          );
        }
        expect(find.byType(TaskEditor), findsNothing);
        expect(
          tester.widget<Text>(find.text('Личная задача')).style!.color,
          lavender,
        );
        await command(tester, LogicalKeyboardKey.digit5);
        expect(
          tester
              .widget<ColorPalettePicker>(
                find.byKey(const ValueKey('accent-color-picker')),
              )
              .value,
          lavender.toARGB32(),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
