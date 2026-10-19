import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/clipboard.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/providers.dart';

class TestProgress extends Fake implements ReadProgress {}

class TestVirtualFile extends Fake implements VirtualFileReceiver {}

class TestClipboardFile extends Fake implements DataReaderFile {
  TestClipboardFile(this.chunks, {this.fileName, this.fileSize});
  final List<Uint8List> chunks;
  @override
  final String? fileName;
  @override
  final int? fileSize;
  bool closed = false;
  @override
  Stream<Uint8List> getStream() => Stream.fromIterable(chunks);
  @override
  void close() => closed = true;
}

class TestClipboardItem extends Fake implements ClipboardDataReader {
  TestClipboardItem({
    this.values = const {},
    this.files = const {},
    this.error,
    this.virtual = false,
  });
  final Map<ValueFormat, Object> values;
  final Map<FileFormat, TestClipboardFile> files;
  final Object? error;
  final bool virtual;
  @override
  Future<T?> readValue<T extends Object>(ValueFormat<T> format) async =>
      values[format] as T?;
  @override
  List<DataFormat> getFormats(List<DataFormat> allFormats) =>
      allFormats.where(files.containsKey).toList();
  @override
  Future<VirtualFileReceiver?> getVirtualFileReceiver({
    FileFormat? format,
  }) async => virtual ? TestVirtualFile() : null;
  @override
  Future<String?> getSuggestedName() async => null;
  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) {
    if (error != null) {
      scheduleMicrotask(() => onError!(error!));
      return TestProgress();
    }
    final file = format == null ? files.values.firstOrNull : files[format];
    if (file == null) return null;
    scheduleMicrotask(() => onFile(file));
    return TestProgress();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Repository repo;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(tz.initializeTimeZones);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'yggvion-clipboard-test-',
    );
    messenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => directory.path,
    );
    repo = Repository(LocalDatabase(NativeDatabase.memory()));
    await repo.initialize();
  });
  tearDown(() async {
    await repo.db.close();
    repo.dispose();
    await directory.delete(recursive: true);
    messenger.setMockMethodCallHandler(pathChannel, null);
  });

  AttachmentClipboard clipboard(List<TestClipboardItem> items) =>
      AttachmentClipboard(repo, reader: () async => ClipboardReader(items));

  test(
    'copied files of arbitrary types and names are stored locally, with file URLs taking precedence over text',
    () async {
      final config = File('${directory.path}/config.custom-extension');
      final archive = File('${directory.path}/a[1].zip');
      await config.writeAsString('local configuration');
      await archive.writeAsBytes([1, 2, 3]);
      final result = await clipboard([
        TestClipboardItem(
          values: {Formats.fileUri: config.uri, Formats.plainText: config.path},
        ),
        TestClipboardItem(values: {Formats.fileUri: archive.uri}),
      ]).read();
      expect(result!.hasAttachments, isTrue);
      expect(result.text, contains('[config.custom-extension](attachment:'));
      expect(result.text, contains('[a1.zip](attachment:'));
      expect(result.text, isNot(contains(directory.path)));
      final rows = await repo.db.customSelect('SELECT * FROM files').get();
      expect(rows, hasLength(2));
      for (final row in rows) {
        final path = row.read<String>('path');
        expect(path, startsWith('${directory.path}/attachments/'));
        expect(await File(path).exists(), isTrue);
        expect(row.read<int>('uploaded'), 0);
      }
      await config.delete();
      expect(
        await File(rows.first.read<String>('path')).readAsString(),
        'local configuration',
      );
    },
  );

  test(
    'binary image and PDF representations become attachments without duplicate text alternatives',
    () async {
      final image = TestClipboardFile([
        Uint8List.fromList([1, 2, 3]),
      ]);
      final pdf = TestClipboardFile([
        Uint8List.fromList([4, 5, 6]),
      ]);
      final result = await clipboard([
        TestClipboardItem(
          files: {Formats.png: image},
          values: {Formats.plainText: 'image alternative'},
        ),
        TestClipboardItem(files: {Formats.pdf: pdf}),
      ]).read();
      expect(result!.text, contains('![Вложение.png](attachment:'));
      expect(result.text, contains('[Вложение.pdf](attachment:'));
      expect(result.text, isNot(contains('image alternative')));
      expect(image.closed && pdf.closed, isTrue);
      expect(
        await repo.db.customSelect('SELECT * FROM files').get(),
        hasLength(2),
      );
    },
  );

  test(
    'text stays verbatim, HTML alternatives are ignored, URLs are not downloaded',
    () async {
      const text = '  config: true\n\n  nested: value\n';
      final result = await clipboard([
        TestClipboardItem(
          values: {Formats.plainText: text},
          files: {Formats.htmlFile: TestClipboardFile([])},
        ),
      ]).read();
      expect(result!.text, text);
      expect(result.hasAttachments, isFalse);
      final url = await clipboard([
        TestClipboardItem(
          values: {
            Formats.uri: NamedUri(Uri.parse('https://example.com/file.pdf')),
          },
        ),
      ]).read();
      expect(url!.text, 'https://example.com/file.pdf');
      expect(url.hasAttachments, isFalse);
      expect(await repo.db.customSelect('SELECT * FROM files').get(), isEmpty);
      expect(await clipboard([]).read(), isNull);
      expect(
        await clipboard([
          TestClipboardItem(
            error: StateError('Private metadata must not be read as a file'),
          ),
        ]).read(),
        isNull,
      );
    },
  );

  test(
    'known and streamed oversized attachments fail without stored files',
    () async {
      final known = TestClipboardFile(
        [],
        fileSize: Repository.maxAttachmentBytes + 1,
      );
      await expectLater(
        clipboard([
          TestClipboardItem(files: {Formats.pdf: known}),
        ]).read(),
        throwsArgumentError,
      );
      expect(known.closed, isTrue);
      final chunk = Uint8List(1024 * 1024);
      final unknown = TestClipboardFile(List.filled(51, chunk));
      await expectLater(
        clipboard([
          TestClipboardItem(files: {Formats.pdf: unknown}),
        ]).read(),
        throwsArgumentError,
      );
      expect(unknown.closed, isTrue);
      expect(await repo.db.customSelect('SELECT * FROM files').get(), isEmpty);
    },
  );

  test(
    'unreadable clipboard files and failed streams propagate errors',
    () async {
      await expectLater(
        clipboard([
          TestClipboardItem(
            error: StateError('Access denied'),
            files: {Formats.pdf: TestClipboardFile([])},
          ),
        ]).read(),
        throwsStateError,
      );
      await expectLater(
        repo.attachStream(
          Stream.error(StateError('Broken stream')),
          '../error.pdf',
        ),
        throwsStateError,
      );
      await expectLater(
        clipboard([
          TestClipboardItem(
            values: {
              Formats.fileUri: File('${directory.path}/missing.txt').uri,
            },
          ),
        ]).read(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await repo.db.customSelect('SELECT * FROM files').get(), isEmpty);
    },
  );

  test('stream filenames cannot escape the attachment directory', () async {
    final result = await repo.attachStream(
      Stream.value([9, 8, 7]),
      '../../folder\\safe.pdf',
    );
    expect(result, startsWith('[safe.pdf](attachment:'));
    final row = await repo.db.customSelect('SELECT * FROM files').getSingle();
    expect(row.read<String>('name'), 'safe.pdf');
    expect(await File(row.read<String>('path')).readAsBytes(), [9, 8, 7]);
  });

  test(
    'native file representations work without direct filesystem access',
    () async {
      const unknown = SimpleFileFormat(
        fallbackFormats: ['application/x-custom'],
      );
      final virtual = TestClipboardFile([
        Uint8List.fromList([5, 4, 3]),
      ], fileName: 'document.custom');
      final pdf = TestClipboardFile([
        Uint8List.fromList([8, 7, 6]),
      ]);
      final result = await clipboard([
        TestClipboardItem(
          virtual: true,
          files: {unknown: virtual},
          values: {
            Formats.fileUri: Uri.file('/unavailable/document.custom'),
            Formats.plainText: 'Document',
          },
        ),
        TestClipboardItem(
          files: {Formats.pdf: pdf},
          values: {Formats.fileUri: Uri.file('/unavailable/file.pdf')},
        ),
      ]).read();
      expect(result!.text, contains('[document.custom](attachment:'));
      expect(result.text, contains('[file.pdf](attachment:'));
      expect(
        await repo.db.customSelect('SELECT * FROM files').get(),
        hasLength(2),
      );
    },
  );

  Future<void> finishPaste(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  for (final source in [false, true]) {
    testWidgets(
      'keyboard paste replaces the selection and keeps surrounding Markdown (source: $source)',
      (tester) async {
        var value = 'Before middle after';
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appProvider.overrideWith((ref) => repo),
              clipboardProvider.overrideWithValue(
                clipboard([
                  TestClipboardItem(values: {Formats.plainText: '**new**'}),
                ]),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, set) => LiveMarkdownEditor(
                    value: value,
                    onChanged: (next) => set(() => value = next),
                  ),
                ),
              ),
            ),
          ),
        );
        if (source) {
          await tester.tap(find.byTooltip('Исходный Markdown'));
        } else {
          await tester.tap(find.text(value));
        }
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(find.byType(TextField));
        await tester.tap(find.byType(TextField));
        field.controller!.selection = const TextSelection(
          baseOffset: 7,
          extentOffset: 13,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await finishPaste(tester);
        expect(value, 'Before **new** after');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'paste button attaches a file, preserves the caret, and reports failures without changing text',
    (tester) async {
      final file = File('${directory.path}/notes.txt');
      await tester.runAsync(() => file.writeAsString('attachment text'));
      var value = 'Before after';
      var fail = false;
      final service = AttachmentClipboard(
        repo,
        reader: () async {
          if (fail) throw StateError('Clipboard unavailable');
          return ClipboardReader([
            TestClipboardItem(values: {Formats.fileUri: file.uri}),
          ]);
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appProvider.overrideWith((ref) => repo),
            clipboardProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, set) => LiveMarkdownEditor(
                  value: value,
                  onChanged: (next) => set(() => value = next),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(value));
      await tester.pumpAndSettle();
      tester.widget<TextField>(find.byType(TextField)).controller!.selection =
          const TextSelection.collapsed(offset: 7);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Вставить из буфера обмена'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await finishPaste(tester);
      expect(value, startsWith('Before \n\n[notes.txt](attachment:'));
      expect(value, endsWith('\n\nafter'));
      final before = value;
      fail = true;
      await tester.tap(find.byTooltip('Вставить из буфера обмена'));
      await finishPaste(tester);
      expect(value, before);
      expect(find.textContaining('Clipboard unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reference note remains read-only and never reads the clipboard',
    (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appProvider.overrideWith((ref) => repo),
            clipboardProvider.overrideWithValue(
              AttachmentClipboard(
                repo,
                reader: () async {
                  reads++;
                  return ClipboardReader([]);
                },
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveMarkdownEditor(
                value: 'Reference',
                readOnly: true,
                onChanged: (_) => fail('Read-only note changed'),
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Вставить из буфера обмена'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(reads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
