import '../l10n/strings.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import '../data/attachments.dart';
import 'providers.dart';
import 'theme.dart';

Future<void> openAttachment(BuildContext context, String id) {
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => AttachmentViewer(id: id)));
}

class AttachmentViewer extends ConsumerStatefulWidget {
  const AttachmentViewer({super.key, required this.id});
  final String id;
  @override
  ConsumerState<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends ConsumerState<AttachmentViewer> {
  late final Future<AttachmentEntry?> entry;
  final transformation = TransformationController();
  Offset tap = Offset.zero;
  Future<String>? text;

  @override
  void initState() {
    super.initState();
    entry = ref.read(appProvider).attachmentDetails(widget.id);
  }

  @override
  void dispose() {
    transformation.dispose();
    super.dispose();
  }

  Future<void> openFile(AttachmentEntry file) => guard(context, () async {
    if (file.path == null) {
      throw StateError(tr("Вложение ещё не загружено на это устройство"));
    }
    final result = await OpenFilex.open(file.path!);
    if (result.type != ResultType.done) throw StateError(result.message);
  });

  void zoom() {
    transformation.value = transformation.value.getMaxScaleOnAxis() > 1
        ? Matrix4.identity()
        : (Matrix4.diagonal3Values(2.5, 2.5, 1)
            ..setTranslationRaw(-tap.dx * 1.5, -tap.dy * 1.5, 0));
  }

  Widget content(AttachmentEntry file) {
    if (file.path == null) {
      return Center(
        child: Text(tr("Вложение ещё не загружено на это устройство")),
      );
    }
    if (file.image) {
      return GestureDetector(
        onDoubleTapDown: (details) => tap = details.localPosition,
        onDoubleTap: zoom,
        child: InteractiveViewer(
          key: const ValueKey('attachment-image-viewer'),
          transformationController: transformation,
          minScale: 1,
          maxScale: 6,
          child: SizedBox.expand(
            child: Image.file(
              File(file.path!),
              fit: BoxFit.contain,
              errorBuilder: (_, error, stack) => Center(
                child: Text(
                  tr("Не удалось прочитать изображение"),
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final readable = RegExp(
      r'\.(txt|md|json|ya?ml|toml|ini|conf|cfg|log|csv|xml|html?|css|js|ts|py|go|dart|sh|sql)$',
      caseSensitive: false,
    ).hasMatch(file.name);
    if (readable && file.size <= 1024 * 1024) {
      text ??= File(file.path!)
          .openRead(0, 1024 * 1024)
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      return FutureBuilder<String>(
        future: text,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(tr("Не удалось прочитать файл")));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Stack(
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    snapshot.data!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 4,
                right: 8,
                child: IconButton.filledTonal(
                  tooltip: tr("Скопировать"),
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  onPressed: () => guard(
                    context,
                    () =>
                        Clipboard.setData(ClipboardData(text: snapshot.data!)),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 64,
              color: context.accentColor,
            ),
            const SizedBox(height: 20),
            Text(file.name, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('${(file.size / math.pow(1024, 2)).toStringAsFixed(1)} MB'),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => openFile(file),
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(tr("Открыть в приложении")),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AttachmentEntry?>(
    future: entry,
    builder: (context, snapshot) {
      final file = snapshot.data;
      final image = file?.image == true;
      return Scaffold(
        key: const ValueKey('attachment-fullscreen'),
        backgroundColor: image ? Colors.black : null,
        appBar: AppBar(
          backgroundColor: image ? Colors.black : null,
          foregroundColor: image ? Colors.white : null,
          leading: IconButton(
            tooltip: tr("Закрыть"),
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            file?.name ?? tr("Вложение"),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (file?.path != null)
              IconButton(
                tooltip: tr("Открыть в приложении"),
                icon: const Icon(Icons.open_in_new_rounded),
                onPressed: () => openFile(file!),
              ),
          ],
        ),
        body: SafeArea(
          child: snapshot.connectionState != ConnectionState.done
              ? const Center(child: CircularProgressIndicator())
              : file == null || snapshot.hasError
              ? Center(child: Text(tr("Вложение недоступно")))
              : content(file),
        ),
      );
    },
  );
}
