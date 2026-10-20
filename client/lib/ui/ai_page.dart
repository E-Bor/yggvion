import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../data/ai_service.dart';
import '../domain/ai_proposal.dart';
import 'ai_settings.dart';
import 'providers.dart';
import 'theme.dart';

class AiPage extends ConsumerWidget {
  const AiPage({super.key});

  Future<void> edit(BuildContext context, AiService ai, AiProposal item) async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EditCommand(item: item),
    );
    if (text != null && context.mounted) {
      await guard(context, () => ai.retry(item, input: text));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ai = ref.watch(aiProvider);
    if (ai == null || !ai.enabled) return const SizedBox.shrink();
    final items = ai.proposals;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(
          key: const ValueKey('ai-page'),
          children: [
            if (!ai.ready)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Material(
                  color: Palette.surface,
                  borderRadius: BorderRadius.circular(18),
                  child: ListTile(
                    leading: Icon(
                      Icons.download_for_offline_outlined,
                      color: context.accentColor,
                    ),
                    title: const Text('Подготовьте помощника'),
                    subtitle: const Text(
                      'Скачайте модели для обработки без интернета',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const AiSettingsPage(),
                      ),
                    ),
                  ),
                ),
              ),
            if (ai.queueError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  ai.queueError,
                  style: const TextStyle(color: Palette.pink),
                ),
              ),
            Expanded(
              child: items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 28,
                      ),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.all(17),
                            decoration: BoxDecoration(
                              color: context.accentColor.withValues(alpha: .1),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Icon(
                              Icons.auto_awesome_rounded,
                              color: context.accentColor,
                              size: 30,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Здесь появятся предложения',
                          style: TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -.8,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Удерживайте микрофон на экране «Сегодня» и говорите. Отпустите — здесь появится предложение, которое можно проверить и сохранить.',
                          style: TextStyle(color: Palette.muted, height: 1.6),
                        ),
                      ],
                    )
                  : ListView.separated(
                      key: const PageStorageKey('ai-inbox'),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      itemCount: items.length,
                      separatorBuilder: (_, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (_, i) => _ProposalCard(
                        item: items[i],
                        ai: ai,
                        onEdit: () => edit(context, ai, items[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.item,
    required this.ai,
    required this.onEdit,
  });
  final AiProposal item;
  final AiService ai;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) {
    final draft = item.draft;
    final applied = item.state == AiProposalState.applied;
    final working = item.working;
    final title = switch (item.state) {
      AiProposalState.queued =>
        ai.ready ? 'В очереди' : 'Ожидает установки моделей',
      AiProposalState.transcribing => 'Распознаём голосовое…',
      AiProposalState.interpreting => 'Готовим предложение…',
      AiProposalState.ready => switch (draft?.action) {
        'task' => 'Добавить событие',
        'note' => 'Создать заметку',
        'plan' => 'Распределить задачи',
        'statistics' => 'Статистика',
        _ => 'Предложение',
      },
      AiProposalState.clarification => 'Нужно уточнение',
      AiProposalState.failed => 'Не получилось обработать',
      AiProposalState.applied => 'Сохранено',
    };
    return Container(
      key: ValueKey('ai-proposal-${item.id}'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Palette.border, width: .6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                applied
                    ? Icons.check_circle_outline_rounded
                    : item.seconds > 0
                    ? Icons.graphic_eq_rounded
                    : Icons.chat_bubble_outline_rounded,
                size: 16,
                color: applied ? Palette.green : Palette.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${DateFormat('d MMM · HH:mm', 'ru').format(item.createdAt.toLocal())}${item.seconds > 0 ? ' · ${item.seconds} с' : ''}',
                  style: const TextStyle(color: Palette.muted, fontSize: 11),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Убрать предложение',
                onPressed: ai.applying(item.id)
                    ? null
                    : () => guard(context, () => ai.dismiss(item)),
                icon: const Icon(Icons.close_rounded, size: 17),
              ),
            ],
          ),
          if (item.input.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              item.input,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 18),
          ],
          Row(
            children: [
              if (working && item.state != AiProposalState.queued) ...[
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: context.accentColor,
                  ),
                ),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: applied ? Palette.green : context.accentColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          if (draft != null && !working) ...[
            const SizedBox(height: 10),
            SelectableText(
              draft.summary,
              style: const TextStyle(fontSize: 15, height: 1.55),
            ),
          ],
          if (item.error != null) ...[
            const SizedBox(height: 10),
            Text(
              item.error!.substring(0, item.error!.length.clamp(0, 500)),
              style: const TextStyle(
                color: Palette.pink,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
          if (!working && !applied) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                if (item.state == AiProposalState.ready &&
                    draft?.writes == true)
                  FilledButton(
                    key: ValueKey('ai-confirm-${item.id}'),
                    onPressed: ai.applying(item.id)
                        ? null
                        : () => guard(context, () => ai.confirm(item)),
                    child: Text(switch (draft!.action) {
                      'note' => 'Сохранить заметку',
                      'plan' => 'Применить план',
                      _ =>
                        draft.data['start'] == null
                            ? 'Создать задачу'
                            : 'Добавить в календарь',
                    }),
                  ),
                if (item.input.isNotEmpty)
                  OutlinedButton(
                    onPressed: ai.applying(item.id) ? null : onEdit,
                    child: Text(
                      item.state == AiProposalState.clarification
                          ? 'Уточнить'
                          : 'Изменить текст',
                    ),
                  ),
                if (item.state == AiProposalState.failed || item.error != null)
                  TextButton(
                    onPressed: ai.applying(item.id)
                        ? null
                        : () => guard(context, () => ai.retry(item)),
                    child: const Text('Повторить'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EditCommand extends StatefulWidget {
  const _EditCommand({required this.item});
  final AiProposal item;
  @override
  State<_EditCommand> createState() => _EditCommandState();
}

class _EditCommandState extends State<_EditCommand> {
  late final input = TextEditingController(text: widget.item.input);
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Уточните команду',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          if (widget.item.state == AiProposalState.clarification)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(widget.item.draft!.summary),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: input,
            autofocus: true,
            minLines: 3,
            maxLines: 7,
            maxLength: 4000,
            decoration: const InputDecoration(hintText: 'Что нужно сделать?'),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder(
            valueListenable: input,
            builder: (_, value, _) => FilledButton(
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, value.text),
              child: const Text('Предложить заново'),
            ),
          ),
        ],
      ),
    ),
  );
}
