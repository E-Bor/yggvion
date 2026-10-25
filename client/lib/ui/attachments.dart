import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/attachments.dart';
import '../data/sync.dart';
import 'markdown_editor.dart';
import 'providers.dart';
import 'theme.dart';

void openAttachments(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const AttachmentsPage()));

class AttachmentsPage extends ConsumerStatefulWidget {
  const AttachmentsPage({super.key});
  @override
  ConsumerState<AttachmentsPage> createState() => _AttachmentsPageState();
}

class _AttachmentsPageState extends ConsumerState<AttachmentsPage> {
  late Future<List<AttachmentEntry>> entries;
  String query = '';
  bool images = true;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    entries = ref.read(appProvider).attachmentInventory();
  }

  void reload() {
    final next = ref.read(appProvider).attachmentInventory();
    setState(() {
      entries = next;
    });
  }

  Future<void> clean(List<AttachmentEntry> unused) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Удалить неиспользуемые вложения?'),
        content: Text(
          'Файлов: ${unused.length}. Перед удалением ещё раз проверим ссылки в заметках, событиях и несохранённых конфликтах. Удаление синхронизируется между устройствами.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => busy = true);
    try {
      await guard(context, () async {
        final count = await ref
            .read(syncProvider)
            .deleteUnusedAttachments(unused.map((file) => file.id).toSet());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                count == unused.length
                    ? 'Удалено файлов: $count'
                    : 'Удалено: $count. Остальные файлы используются или были изменены.',
              ),
            ),
          );
        }
      });
    } finally {
      if (mounted) {
        setState(() => busy = false);
        reload();
      }
    }
  }

  String size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ'
      : bytes >= 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} КБ'
      : '$bytes Б';

  Future<void> preview(AttachmentEntry file) => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: MarkdownPreview(
            text:
                '${file.image ? '!' : ''}[${file.name.replaceAll(RegExp(r'[\[\]\n\r]'), '')}](attachment:${file.id})',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );

  Widget imageGrid(List<AttachmentEntry> files) {
    final zone = tz.getLocation(
      ref.read(appProvider).snapshot.settings.timezone,
    );
    final groups = <DateTime?, List<AttachmentEntry>>{};
    for (final file in files) {
      final date = file.addedAt == null
          ? null
          : tz.TZDateTime.from(file.addedAt!, zone);
      final day = date == null
          ? null
          : DateTime(date.year, date.month, date.day);
      (groups[day] ??= []).add(file);
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final columns = ((bounds.maxWidth - 40) / 200).floor().clamp(2, 5);
        final width = (bounds.maxWidth - 40 - (columns - 1) * 12) / columns;
        return CustomScrollView(
          key: const PageStorageKey('attachment-images'),
          slivers: [
            for (final group in groups.entries) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    group.key == null
                        ? 'Ранее'
                        : DateFormat('d MMMM yyyy', 'ru').format(group.key!),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.palette.muted,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    mainAxisExtent: width * .8 + 50,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (_, index) => imageTile(group.value[index]),
                    childCount: group.value.length,
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        );
      },
    );
  }

  Widget imageTile(AttachmentEntry file) => Material(
    key: ValueKey('attachment-${file.id}'),
    color: context.palette.raised,
    borderRadius: BorderRadius.circular(14),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => preview(file),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (file.path != null)
                  Image.file(
                    File(file.path!),
                    key: ValueKey('thumbnail-${file.id}'),
                    fit: BoxFit.cover,
                    cacheWidth: 512,
                    cacheHeight: 512,
                    frameBuilder: (_, child, frame, loaded) =>
                        loaded || frame != null
                        ? child
                        : imagePlaceholder('Загрузка изображения'),
                    errorBuilder: (_, error, stack) =>
                        imagePlaceholder('Не удалось прочитать изображение'),
                  )
                else
                  imagePlaceholder('Ожидает синхронизации'),
                if (file.unused)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton.filledTonal(
                      tooltip: 'Удалить вложение',
                      style: IconButton.styleFrom(
                        backgroundColor: context.palette.surface.withValues(
                          alpha: .9,
                        ),
                        minimumSize: const Size(36, 36),
                        padding: const EdgeInsets.all(8),
                      ),
                      onPressed: busy ? null : () => clean([file]),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  size(file.size),
                  style: TextStyle(fontSize: 10, color: context.palette.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget imagePlaceholder(String message) => Center(
    child: Tooltip(
      message: message,
      child: Icon(Icons.image_outlined, size: 32, color: context.palette.muted),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Вложения'),
      actions: [
        IconButton(
          tooltip: 'Обновить',
          onPressed: busy ? null : reload,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: FutureBuilder<List<AttachmentEntry>>(
          future: entries,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Не удалось загрузить вложения: ${snapshot.error}'),
                    TextButton(
                      onPressed: reload,
                      child: const Text('Повторить'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snapshot.data!;
            final shown = all
                .where(
                  (file) =>
                      file.image == images &&
                      file.name.toLowerCase().contains(query.toLowerCase()),
                )
                .toList();
            final unused = all.where((file) => file.unused).toList();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: true,
                          label: Text('Картинки'),
                          icon: Icon(Icons.image_outlined),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text('Файлы'),
                          icon: Icon(Icons.insert_drive_file_outlined),
                        ),
                      ],
                      selected: {images},
                      onSelectionChanged: (value) =>
                          setState(() => images = value.single),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: (value) => setState(() => query = value),
                          decoration: InputDecoration(
                            hintText: images ? 'Найти картинку' : 'Найти файл',
                            prefixIcon: const Icon(Icons.search_rounded),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        tooltip: 'Действия с вложениями',
                        enabled: !busy,
                        onSelected: (_) => clean(unused),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'clean',
                            enabled: unused.isNotEmpty,
                            child: Text(
                              'Очистить неиспользуемые · ${unused.length}',
                            ),
                          ),
                        ],
                        icon: const Icon(Icons.more_horiz_rounded),
                      ),
                    ],
                  ),
                ),
                if (busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text(
                            query.isNotEmpty
                                ? (images
                                      ? 'Картинки не найдены'
                                      : 'Файлы не найдены')
                                : (images
                                      ? 'Пока нет картинок'
                                      : 'Пока нет файлов'),
                            style: TextStyle(color: context.palette.muted),
                          ),
                        )
                      : images
                      ? imageGrid(shown)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          itemCount: shown.length,
                          separatorBuilder: (_, index) =>
                              const Divider(height: 1),
                          itemBuilder: (_, index) {
                            final file = shown[index];
                            return ListTile(
                              key: ValueKey('attachment-${file.id}'),
                              leading: Icon(
                                file.image
                                    ? Icons.image_outlined
                                    : Icons.insert_drive_file_outlined,
                                color: context.accentColor,
                              ),
                              title: Text(
                                file.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${size(file.size)} · ${file.unused ? 'Без ссылок' : 'Ссылок: ${file.references}'}',
                              ),
                              onTap: () => preview(file),
                              trailing: file.unused
                                  ? IconButton(
                                      tooltip: 'Удалить вложение',
                                      onPressed: busy
                                          ? null
                                          : () => clean([file]),
                                      icon: Icon(
                                        Icons.delete_outline_rounded,
                                        color: context.palette.muted,
                                      ),
                                    )
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
