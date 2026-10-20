import 'ai_actions.dart';

enum AiProposalState {
  queued,
  transcribing,
  interpreting,
  ready,
  clarification,
  failed,
  applied,
}

/// Device-local inbox entry. This is deliberately not a synced Entity.
class AiProposal {
  AiProposal({
    required this.id,
    required this.createdAt,
    required this.input,
    this.audio,
    this.seconds = 0,
    this.state = AiProposalState.queued,
    this.draft,
    this.error,
  });

  final String id;
  final DateTime createdAt;
  String input;
  String? audio;
  final int seconds;
  AiProposalState state;
  AiDraft? draft;
  String? error;

  bool get working => [
    AiProposalState.queued,
    AiProposalState.transcribing,
    AiProposalState.interpreting,
  ].contains(state);

  Map<String, dynamic> toJson() => {
    'id': id,
    'created_at': createdAt.toUtc().toIso8601String(),
    'input': input,
    'audio': audio,
    'seconds': seconds,
    'state': state.name,
    'error': error,
    'draft': draft?.toJson(),
  };

  factory AiProposal.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final audio = json['audio'] as String?;
    // Never let a saved filename address attachments or files outside the inbox.
    if (!RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(id) ||
        (audio != null && audio != '$id.wav')) {
      throw const FormatException('Повреждена локальная очередь AI');
    }
    return AiProposal(
      id: id,
      createdAt: DateTime.parse(json['created_at'] as String),
      input: json['input'] as String,
      audio: audio,
      seconds: json['seconds'] as int,
      state: AiProposalState.values.byName(json['state'] as String),
      error: json['error'] as String?,
      draft: json['draft'] == null
          ? null
          : AiDraft.fromJson(Map<String, dynamic>.from(json['draft'] as Map)),
    );
  }
}
