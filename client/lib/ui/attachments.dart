import '../l10n/strings.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/attachments.dart';
import '../data/sync.dart';
import 'attachment_viewer.dart';
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
  final pages = PageController();
  String query = '';
  bool images = true;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    entries = ref.read(appProvider).attachmentInventory();
  }

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  Widget attachmentList(List<AttachmentEntry> all, bool showImages) {
    final shown = all
        .where(
          (file) =>
              file.image == showImages &&
              file.name.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    if (shown.isEmpty) {
      return Center(
        child: Text(
          query.isNotEmpty
              ? (showImages
                    ? tr("Картинки не найдены")
                    : tr("Файлы не найдены"))
              : (showImages ? tr("Пока нет картинок") : tr("Пока нет файлов")),
          style: TextStyle(color: context.palette.muted),
        ),
      );
    }
    if (showImages) return imageGrid(shown);
    return ListView.separated(
      key: const PageStorageKey('attachment-files'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: shown.length,
      separatorBuilder: (_, index) => const Divider(height: 1),
      itemBuilder: (_, index) {
        final file = shown[index];
        return ListTile(
          key: ValueKey('attachment-${file.id}'),
          leading: Icon(
            Icons.insert_drive_file_outlined,
            color: context.accentColor,
          ),
          title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${size(file.size)} · ${file.unused ? tr("Без ссылок") : tr("Ссылок: {0}", [file.references])}',
          ),
          onTap: () => preview(file),
          trailing: file.unused
              ? IconButton(
                  tooltip: tr("Удалить вложение"),
                  onPressed: busy ? null : () => clean([file]),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: context.palette.muted,
                  ),
                )
              : null,
        );
      },
    );
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
        title: Text(tr("Удалить неиспользуемые вложения?")),
        content: Text(
          tr(
            "Файлов: {0}. Перед удалением ещё раз проверим ссылки в заметках, событиях и несохранённых конфликтах. Удаление синхронизируется между устройствами.",
            [unused.length],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(tr("Отмена")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(tr("Удалить")),
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
                    ? tr("Удалено файлов: {0}", [count])
                    : tr(
                        "Удалено: {0}. Остальные файлы используются или были изменены.",
                        [count],
                      ),
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
      ? tr("{0} МБ", [(bytes / (1024 * 1024)).toStringAsFixed(1)])
      : bytes >= 1024
      ? tr("{0} КБ", [(bytes / 1024).toStringAsFixed(0)])
      : tr("{0} Б", [bytes]);

  Future<void> preview(AttachmentEntry file) =>
      openAttachment(context, file.id);

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
                        ? tr("Ранее")
                        : DateFormat(
                            'd MMMM yyyy',
                            AppLocale.language,
                          ).format(group.key!),
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
                        : imagePlaceholder(tr("Загрузка изображения")),
                    errorBuilder: (_, error, stack) => imagePlaceholder(
                      tr("Не удалось прочитать изображение"),
                    ),
                  )
                else
                  imagePlaceholder(tr("Ожидает синхронизации")),
                if (file.unused)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton.filledTonal(
                      tooltip: tr("Удалить вложение"),
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
      title: Text(tr("Вложения")),
      actions: [
        IconButton(
          tooltip: tr("Обновить"),
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
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tr("Не удалось загрузить вложения")),
                    TextButton(onPressed: reload, child: Text(tr("Повторить"))),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snapshot.data!;
            final unused = all.where((file) => file.unused).toList();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(tr("Картинки")),
                          icon: Icon(Icons.image_outlined),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text(tr("Файлы")),
                          icon: Icon(Icons.insert_drive_file_outlined),
                        ),
                      ],
                      selected: {images},
                      onSelectionChanged: (value) => pages.animateToPage(
                        value.single ? 0 : 1,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                      ),
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
                            hintText: images
                                ? tr("Найти картинку")
                                : tr("Найти файл"),
                            prefixIcon: const Icon(Icons.search_rounded),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        tooltip: tr("Действия с вложениями"),
                        enabled: !busy,
                        onSelected: (_) => clean(unused),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'clean',
                            enabled: unused.isNotEmpty,
                            child: Text(
                              tr("Очистить неиспользуемые · {0}", [
                                unused.length,
                              ]),
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
                  child: PageView.builder(
                    key: const ValueKey('attachment-tabs'),
                    controller: pages,
                    itemCount: 2,
                    onPageChanged: (index) =>
                        setState(() => images = index == 0),
                    itemBuilder: (_, index) => attachmentList(all, index == 0),
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
