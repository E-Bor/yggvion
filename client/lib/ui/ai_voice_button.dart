import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/ai_service.dart';
import 'providers.dart';
import 'theme.dart';

class AiVoiceButton extends ConsumerStatefulWidget {
  const AiVoiceButton({super.key, this.compact = false});
  final bool compact;

  @override
  ConsumerState<AiVoiceButton> createState() => _AiVoiceButtonState();
}

class _AiVoiceButtonState extends ConsumerState<AiVoiceButton> {
  AiService? capture;
  Future<void>? starting;
  bool held = false, ready = false, finishing = false;

  void begin({bool keepFocus = false}) {
    final ai = ref.read(aiProvider);
    if (capture != null ||
        finishing ||
        ai == null ||
        !ai.enabled ||
        ai.stopping ||
        ai.recording) {
      return;
    }
    if (!keepFocus) FocusManager.instance.primaryFocus?.unfocus();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {
      capture = ai;
      held = true;
      ready = false;
    });
    starting = guard(context, () async {
      try {
        await HapticFeedback.mediumImpact();
        if (!mounted || !held) return;
        await ai.startRecording();
        // Releasing during a permission prompt cancels the recording.
        if (!mounted || !held || !ai.recording) return;
        ready = true;
      } catch (_) {
        held = false;
        capture = null;
        rethrow;
      } finally {
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> end({required bool send}) async {
    final ai = capture;
    if (!held || ai == null) return;
    final shouldSend = send && ready;
    setState(() {
      held = false;
      finishing = true;
    });
    await guard(context, () async {
      try {
        if (shouldSend) {
          await ai.finishRecording();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Голосовое отправлено. Предложение появится в AI.',
                ),
                duration: Duration(seconds: 3),
              ),
            );
          }
        } else {
          await ai.cancelRecording();
        }
      } finally {
        // A late permission response must finish before another capture starts.
        await starting;
        capture = null;
        ready = false;
        finishing = false;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    held = false;
    final ai = capture;
    if (ai != null && !finishing) {
      unawaited(
        ai.cancelRecording().catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              context: ErrorDescription('while cancelling a voice recording'),
            ),
          );
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ai = ref.watch(aiProvider);
    if (ai == null || !ai.enabled) return const SizedBox.shrink();
    final size = widget.compact ? 40.0 : 54.0;
    final active = held && ready && ai.recording;
    final loading = (held && !ready) || finishing;
    final seconds = ai.recordingSeconds;
    final clock =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final accent = context.accentColor;
    final expansion = held ? size * .175 : 0.0;
    return Semantics(
      button: true,
      label: 'Голосовое сообщение',
      hint: 'Удерживайте, чтобы записать. Отпустите, чтобы отправить.',
      // Screen readers cannot pair a semantic long press with a release.
      onTap: finishing ? null : () => held ? end(send: true) : begin(),
      child: Tooltip(
        message: 'Удерживайте, чтобы записать',
        triggerMode: TooltipTriggerMode.manual,
        child: Focus(
          onFocusChange: (focused) {
            if (!focused && held) end(send: false);
          },
          onKeyEvent: (_, event) {
            if (event.logicalKey == LogicalKeyboardKey.space) {
              if (event is KeyDownEvent) begin(keepFocus: true);
              if (event is KeyUpEvent) end(send: true);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape && held) {
              end(send: false);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            key: const ValueKey('ai-record'),
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onLongPressStart: (_) => begin(),
            onLongPressEnd: (_) => end(send: true),
            onLongPressCancel: () => end(send: false),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Удерживайте микрофон и говорите. Отпустите, чтобы отправить.',
                ),
                duration: Duration(seconds: 2),
              ),
            ),
            child: SizedBox.square(
              dimension: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Scale the surface without moving/replacing the gesture
                  // target. The captured pointer stays active outside it.
                  AnimatedScale(
                    scale: held ? 1.35 : 1,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: AnimatedContainer(
                      key: const ValueKey('ai-record-surface'),
                      duration: const Duration(milliseconds: 160),
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        color: active ? accent : Palette.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: accent.withValues(alpha: active ? 1 : .35),
                        ),
                        boxShadow: widget.compact
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: .2),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                      ),
                      child: Center(
                        child: loading
                            ? SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: accent,
                                ),
                              )
                            : Icon(
                                active
                                    ? Icons.mic_rounded
                                    : Icons.mic_none_rounded,
                                color: active ? Palette.background : accent,
                                size: widget.compact ? 21 : 24,
                              ),
                      ),
                    ),
                  ),
                  if (held)
                    Positioned(
                      right: size + expansion + 12,
                      top: 0,
                      child: IgnorePointer(
                        child: Container(
                          key: const ValueKey('ai-recording-status'),
                          width: math.min(
                            224,
                            MediaQuery.sizeOf(context).width -
                                size -
                                expansion -
                                52,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Palette.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Palette.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                active
                                    ? 'Запись  $clock'
                                    : ready
                                    ? 'Отправлено в AI'
                                    : 'Подключаем микрофон…',
                                style: TextStyle(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (active)
                                const Text(
                                  'Отпустите, чтобы отправить',
                                  style: TextStyle(
                                    color: Palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
