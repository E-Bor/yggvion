import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import '../domain/note_links.dart';
import 'providers.dart';
import 'theme.dart';

/// An inline picker keeps the Markdown field and keyboard focused, including
/// when a suggestion is tapped on a phone. It never submits the parent form.
class WikiAutocomplete extends ConsumerStatefulWidget {
  const WikiAutocomplete({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.child,
    this.readOnly = false,
    this.noteId,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final Widget child;
  final bool readOnly;
  final String? noteId;
  @override
  ConsumerState<WikiAutocomplete> createState() => _WikiAutocompleteState();
}

class _WikiAutocompleteState extends ConsumerState<WikiAutocomplete> {
  final panelKey = GlobalKey();
  final scroll = ScrollController();
  WikiNoteIndex? index;
  WikiQuery? query;
  String? dismissedText;
  int highlighted = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
    widget.focusNode.addListener(changed);
  }

  void changed() {
    if (!mounted) return;
    final value = widget.controller.value;
    final next =
        !widget.readOnly &&
            widget.focusNode.hasFocus &&
            value.selection.isValid &&
            value.selection.isCollapsed &&
            value.text != dismissedText
        ? WikiQuery.at(value.text, value.selection.extentOffset)
        : null;
    final opening = query == null && next != null;
    setState(() {
      if (query?.query != next?.query || query?.start != next?.start) {
        highlighted = 0;
      }
      query = next;
      if (value.text != dismissedText) dismissedText = null;
    });
    if (opening) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final panel = panelKey.currentContext;
        if (mounted && panel != null) {
          Scrollable.ensureVisible(
            panel,
            duration: const Duration(milliseconds: 120),
            alignment: 1,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        }
      });
    }
  }

  List<Note> options() {
    if (query == null) return [];
    final snapshot = ref.read(appProvider).snapshot;
    if (!identical(index?.snapshot, snapshot)) index = WikiNoteIndex(snapshot);
    return index!.search(query!.query, excludeId: widget.noteId);
  }

  void choose(Note note) {
    final value = widget.controller.value;
    final current = WikiQuery.at(value.text, value.selection.extentOffset);
    final latest = ref.read(appProvider).snapshot.note(note.id);
    if (widget.readOnly || current == null || latest == null) return;
    final link = WikiNoteIndex(ref.read(appProvider).snapshot).linkFor(latest);
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(current.start, current.end, link),
      selection: TextSelection.collapsed(offset: current.start + link.length),
    );
    widget.onChanged(widget.controller.text);
    widget.focusNode.requestFocus();
  }

  KeyEventResult keyEvent(FocusNode node, KeyEvent event) {
    if (query == null ||
        event is KeyUpEvent ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        dismissedText = widget.controller.text;
        query = null;
      });
      return KeyEventResult.handled;
    }
    final notes = options();
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      if (notes.isNotEmpty) {
        setState(
          () => highlighted =
              (highlighted + (key == LogicalKeyboardKey.arrowDown ? 1 : -1))
                  .clamp(0, notes.length - 1),
        );
        if (scroll.hasClients) {
          scroll.jumpTo(
            (highlighted * 50.0).clamp(0, scroll.position.maxScrollExtent),
          );
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      if (notes.isNotEmpty) {
        choose(notes[highlighted.clamp(0, notes.length - 1)]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    widget.focusNode.removeListener(changed);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (query != null) ref.watch(appProvider);
    final notes = options();
    return Focus(
      canRequestFocus: false,
      onKeyEvent: keyEvent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.child,
          if (query != null && !widget.readOnly)
            TextFieldTapRegion(
              groupId: widget.focusNode,
              child: Container(
                key: panelKey,
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Palette.raised,
                  border: Border.all(color: Palette.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ConstrainedBox(
                  key: const ValueKey('wiki-suggestions'),
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 9, 12, 5),
                        child: Text(
                          'Ссылка на заметку',
                          style: TextStyle(fontSize: 11, color: Palette.muted),
                        ),
                      ),
                      if (notes.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'Заметок не найдено',
                            style: TextStyle(fontSize: 13),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            controller: scroll,
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemExtent: 50,
                            itemCount: notes.length,
                            itemBuilder: (context, i) {
                              final note = notes[i];
                              return ListTile(
                                key: ValueKey('wiki-option-${note.id}'),
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                selected: i == highlighted,
                                selectedTileColor: context.accentColor
                                    .withValues(alpha: .12),
                                leading: Icon(
                                  Icons.description_outlined,
                                  size: 18,
                                  color: i == highlighted
                                      ? context.accentColor
                                      : Palette.muted,
                                ),
                                minLeadingWidth: 20,
                                title: Text(
                                  index!.labels[note.id]!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                subtitle: Text(
                                  index!.folderLabel(note),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onTap: () => choose(note),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
