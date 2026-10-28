import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/attachments.dart';
import 'package:yggvion/ui/attachments.dart';
import 'package:yggvion/ui/attachment_viewer.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

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
  testInteraction(
    'phone image opens fullscreen directly from a note without activating the keyboard',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      late Directory directory;
      late String imagePath;
      await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          directory = await Directory.systemTemp.createTemp(
            'yggvion-note-image-',
          );
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (_) async => directory.path);
          final source = File('${directory.path}/photo.png');
          await source.writeAsBytes(
            await File('assets/branding/app-icon.png').readAsBytes(),
          );
          final link = await repo.attachFile(source.path);
          final id = RegExp(r'attachment:([a-f0-9]{64})').firstMatch(link)![1]!;
          imagePath = (await repo.attachmentPath(id))!;
          await repo.saveNoteContent('scratchpad', link);
        },
      );
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });
      await tester.runAsync(
        () => precacheImage(
          FileImage(File(imagePath)),
          tester.element(find.byType(Scaffold).first),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
        await tester.pump();
        for (final builder in tester.widgetList<FutureBuilder<String?>>(
          find.byWidgetPredicate((widget) => widget is FutureBuilder<String?>),
        )) {
          await builder.future;
        }
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
      });
      await settle(tester);
      final picture = find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is FileImage,
      );
      expect(picture, findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(picture);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester
            .widget<FutureBuilder<AttachmentEntry?>>(
              find.byWidgetPredicate(
                (w) => w is FutureBuilder<AttachmentEntry?>,
              ),
            )
            .future;
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
      });
      await settle(tester);
      expect(find.byType(AttachmentViewer), findsOneWidget);
      expect(
        find.byKey(const ValueKey('attachment-image-viewer')),
        findsOneWidget,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byTooltip('Закрыть'));
      await settle(tester);
      expect(find.byType(AttachmentViewer), findsNothing);
      expect(picture, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [false, true]) {
    testInteraction(
      'attachments open from notes, preview and clean only unused files mobile=$mobile',
      (tester) async {
        late Directory dir;
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            dir = await Directory.systemTemp.createTemp(
              'yggvion-attachments-ui-',
            );
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, (_) async => dir.path);
            final used = File('${dir.path}/config.yaml');
            await used.writeAsString('config: saved');
            final link = await repo.attachFile(used.path);
            final note = await repo.createNote();
            await repo.saveNote(note.id, 'Настройки', link);
            final unused = File('${dir.path}/Черновик.txt');
            await unused.writeAsString('Temporary data');
            await repo.attachFile(unused.path);
            final first = await rootBundle.load(
              'assets/branding/logo-mask.png',
            );
            final second = await File(
              'assets/branding/app-icon.png',
            ).readAsBytes();
            final firstLink = await repo.attachStream(
              Stream.value(first.buffer.asUint8List()),
              'Дерево.png',
            );
            final secondLink = await repo.attachStream(
              Stream.value(second),
              'Щит.png',
            );
            await repo.saveNote(
              note.id,
              'Настройки',
              '$link\n\n$firstLink\n\n$secondLink',
            );
            final pictures = (await repo.attachmentInventory())
                .where((file) => file.image)
                .toList();
            await repo.commit([
              (await repo.db.entity(
                'attachment-${pictures.first.id}',
              ))!.change({'added_at': '2026-10-18T12:00:00Z'}),
            ]);
            if (mobile) {
              // Reinstallation may keep data but replace the iOS container UUID.
              final next = await Directory(
                '${dir.path}/new-container',
              ).create();
              await Directory(
                '${dir.path}/attachments',
              ).rename('${next.path}/attachments');
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, (_) async => next.path);
              await repo.initialize();
            }
          },
        );
        addTearDown(() async {
          await dir.delete(recursive: true);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        // Resolve file IO and decoding in the real async zone before the widget
        // uses the cached thumbnails; golden tests must contain actual pixels.
        await tester.runAsync(() async {
          final files = await repo.attachmentInventory();
          for (final file in files.where((entry) => entry.image)) {
            if (!tester.element(find.byType(Scaffold).first).mounted) return;
            await precacheImage(
              ResizeImage(FileImage(File(file.path!)), width: 512, height: 512),
              tester.element(find.byType(Scaffold).first),
            );
          }
        });
        await command(tester, LogicalKeyboardKey.digit4);
        await tester.runAsync(() async {
          await tester.tap(
            mobile
                ? find.byKey(const ValueKey('mobile-notes-attachments'))
                : find.text('Вложения'),
          );
          await tester.pump();
        });
        await settle(tester);
        expect(find.byType(AttachmentsPage), findsOneWidget);
        expect(find.byType(SliverGrid), findsNWidgets(2));
        expect(find.text('19 октября 2026'), findsOneWidget);
        expect(find.text('18 октября 2026'), findsOneWidget);
        expect(find.text('config.yaml'), findsNothing);
        expect(find.text('Дерево.png'), findsOneWidget);
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .where((image) => image.image != null)
              .length,
          greaterThanOrEqualTo(2),
        );
        await expectLater(
          find.byType(Scaffold).last,
          matchesGoldenFile(
            'goldens/attachment_images_${mobile ? 390 : 1440}.png',
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Дерево.png'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester
              .widget<FutureBuilder<AttachmentEntry?>>(
                find.byWidgetPredicate(
                  (w) => w is FutureBuilder<AttachmentEntry?>,
                ),
              )
              .future;
          await Future<void>.delayed(Duration.zero);
          await tester.pump();
        });
        await settle(tester);
        expect(find.byType(AttachmentViewer), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        final viewer = find.byKey(const ValueKey('attachment-image-viewer'));
        expect(viewer, findsOneWidget);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('attachment-fullscreen')))
              .width,
          mobile ? 390 : 1440,
        );
        await tester.tap(viewer);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(viewer);
        await settle(tester);
        expect(
          tester
              .widget<InteractiveViewer>(viewer)
              .transformationController!
              .value
              .getMaxScaleOnAxis(),
          greaterThan(1),
        );
        await tester.tap(find.byTooltip('Закрыть'));
        await settle(tester);
        await tester.drag(
          find.byKey(const ValueKey('attachment-tabs')),
          const Offset(-500, 0),
        );
        await settle(tester);
        expect(find.text('config.yaml'), findsOneWidget);
        expect(find.byTooltip('Удалить вложение'), findsOneWidget);
        await expectLater(
          find.byType(Scaffold).last,
          matchesGoldenFile('goldens/attachments_${mobile ? 390 : 1440}.png'),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('config.yaml'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester
              .widget<FutureBuilder<AttachmentEntry?>>(
                find.byWidgetPredicate(
                  (w) => w is FutureBuilder<AttachmentEntry?>,
                ),
              )
              .future;
          await Future<void>.delayed(Duration.zero);
          await tester.pump();
          await tester
              .widget<FutureBuilder<String>>(
                find.byWidgetPredicate((w) => w is FutureBuilder<String>),
              )
              .future;
        });
        await settle(tester);
        expect(find.byType(AttachmentViewer), findsOneWidget);
        expect(find.text('config: saved'), findsOneWidget);
        expect(find.byTooltip('Скопировать'), findsOneWidget);
        await tester.tap(find.byTooltip('Закрыть'));
        await settle(tester);
        await tester.drag(
          find.byKey(const ValueKey('attachment-tabs')),
          Offset(
            tester
                    .getSize(find.byKey(const ValueKey('attachment-tabs')))
                    .width *
                .85,
            0,
          ),
        );
        await settle(tester);
        expect(find.text('Дерево.png'), findsOneWidget);
        await tester.tap(find.text('Файлы'));
        await settle(tester);
        await tester.enterText(find.byType(TextField).last, 'несуществующий');
        await settle(tester);
        expect(find.text('Файлы не найдены'), findsOneWidget);
        await tester.enterText(find.byType(TextField).last, '');
        await settle(tester);
        await tester.runAsync(
          () => tester.tap(find.byTooltip('Действия с вложениями')),
        );
        await settle(tester);
        await tester.runAsync(
          () => tester.tap(find.text('Очистить неиспользуемые · 1')),
        );
        await settle(tester);
        await tester.runAsync(() => tester.tap(find.text('Удалить').last));
        await settle(tester);
        expect(find.text('Удалено файлов: 1'), findsOneWidget);
        final refreshed = tester
            .widget<FutureBuilder<List<AttachmentEntry>>>(
              find.byWidgetPredicate(
                (w) => w is FutureBuilder<List<AttachmentEntry>>,
              ),
            )
            .future!;
        await tester.runAsync(() => refreshed);
        await tester.pumpAndSettle();
        expect(find.text('Черновик.txt'), findsNothing);
        expect(find.text('config.yaml'), findsOneWidget);
        final entries = await tester.runAsync(() => repo.attachmentInventory());
        expect(entries!.length, 3);
        expect(entries.every((file) => file.references == 1), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
