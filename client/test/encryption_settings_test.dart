import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/ui/encryption_settings.dart';
import 'package:yggvion/ui/theme.dart';

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'password setup validates input and prevents duplicate saves at $width px',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final saved = Completer<void>();
        var calls = 0;
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showEncryptionPasswordDialog(
                      context,
                      creating: true,
                      submit: (password, current) async {
                        expect(password, 'A remembered phrase 42');
                        expect(current, isNull);
                        calls++;
                        await saved.future;
                      },
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final fields = find.byType(TextField);
        expect(fields, findsNWidgets(2));
        await tester.enterText(fields.first, 'short');
        await tester.tap(find.text('Сохранить пароль'));
        await tester.pumpAndSettle();
        expect(
          find.text('Используйте пароль или фразу от 12 до 256 символов'),
          findsOneWidget,
        );
        await tester.enterText(fields.first, 'A remembered phrase 42');
        await tester.enterText(fields.last, 'Different remembered phrase');
        await tester.tap(find.text('Сохранить пароль'));
        await tester.pumpAndSettle();
        expect(find.text('Пароли не совпадают'), findsOneWidget);
        expect(calls, 0);
        await tester.enterText(fields.last, 'A remembered phrase 42');
        await tester.tap(find.text('Сохранить пароль'));
        await tester.pump();
        expect(calls, 1);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Отмена'))
              .onPressed,
          isNull,
        );
        saved.complete();
        await tester.pumpAndSettle();
        expect(result, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'password changes retain errors and require the current password',
    (tester) async {
      bool? result;
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showEncryptionPasswordDialog(
                    context,
                    creating: true,
                    changing: true,
                    submit: (password, current) async {
                      calls++;
                      expect(password, 'New remembered phrase 43');
                      if (current != 'Old remembered phrase 42') {
                        throw const FormatException('Неверный текущий пароль');
                      }
                    },
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), 'Wrong password');
      await tester.enterText(fields.at(1), 'New remembered phrase 43');
      await tester.enterText(fields.at(2), 'New remembered phrase 43');
      await tester.tap(find.text('Сохранить пароль'));
      await tester.pumpAndSettle();
      expect(find.text('Неверный текущий пароль'), findsOneWidget);
      expect(result, isNull);
      await tester.enterText(fields.at(0), 'Old remembered phrase 42');
      await tester.tap(find.text('Сохранить пароль'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(result, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
