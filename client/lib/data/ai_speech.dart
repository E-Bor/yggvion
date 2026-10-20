import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:whisper_ggml/whisper_ggml.dart';

abstract interface class AiSpeechTranscriber {
  Future<String> transcribe(String modelPath, String recordingPath);
}

/// Runs only after a complete voice message has been saved to disk.
class WhisperFileTranscriber implements AiSpeechTranscriber {
  @override
  Future<String> transcribe(String modelPath, String recordingPath) async {
    final temporary = await Directory.systemTemp.createTemp('yggvion-speech-');
    try {
      final prepared = '${temporary.path}/speech.wav';
      final hasSpeech = await Isolate.run(
        () => prepareSpeechAudio(recordingPath, prepared),
      );
      if (!hasSpeech) return '';
      final response = await const Whisper(model: WhisperModel.small)
          .transcribe(
            modelPath: modelPath,
            transcribeRequest: TranscribeRequest(
              audio: prepared,
              language: 'ru',
              threads: Platform.numberOfProcessors.clamp(1, 4),
              isNoTimestamps: true,
              noContext: true,
              maxContext: 0,
              suppressNonSpeechTokens: false,
              keepModelLoaded: false,
            ),
          );
      return speechText(response.text);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

/// Accept only the recorder's bounded, mono PCM WAV format. Strip silence
/// before inference without loading the model while the microphone is open.
Future<bool> prepareSpeechAudio(String source, String destination) async {
  final file = File(source);
  if (await file.length() > 16000 * 2 * 125 + 4096) {
    throw const FormatException('Голосовое сообщение слишком длинное');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.take(4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('Не удалось прочитать голосовое сообщение');
  }
  final data = ByteData.sublistView(bytes);
  Uint8List? pcm;
  var validFormat = false;
  for (var offset = 12; offset + 8 <= bytes.length;) {
    final kind = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final length = data.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (start + length > bytes.length) {
      throw const FormatException(
        'Запись оборвалась, запишите сообщение ещё раз',
      );
    }
    if (kind == 'fmt ' && length >= 16) {
      validFormat =
          data.getUint16(start, Endian.little) == 1 &&
          data.getUint16(start + 2, Endian.little) == 1 &&
          data.getUint32(start + 4, Endian.little) == 16000 &&
          data.getUint16(start + 14, Endian.little) == 16;
    } else if (kind == 'data') {
      pcm = Uint8List.sublistView(bytes, start, start + length);
    }
    offset = start + length + length % 2;
  }
  if (!validFormat || pcm == null || pcm.length.isOdd) {
    throw const FormatException('Неподдерживаемый формат записи');
  }
  final gate = SpeechAudioGate();
  final accepted = BytesBuilder(copy: false);
  for (var i = 0; i < pcm.length; i += 32000) {
    for (final frame in gate.add(
      Uint8List.sublistView(pcm, i, math.min(i + 32000, pcm.length)),
    )) {
      accepted.add(frame);
    }
  }
  for (final frame in gate.finish()) {
    accepted.add(frame);
  }
  if (!gate.hasSpeech) return false;
  final audio = accepted.takeBytes();
  final header = ByteData(44);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  tag(36, 'data');
  header.setUint32(4, audio.length + 36, Endian.little);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  header.setUint32(40, audio.length, Endian.little);
  final output = File(destination).openWrite();
  try {
    output.add(header.buffer.asUint8List());
    output.add(audio);
    await output.flush();
  } finally {
    await output.close();
  }
  return true;
}

/// Bounds the audio sent to Whisper, independently of microphone chunk size.
/// This is an energy filter, not a speech classifier. Whisper's native
/// adaptive noise gate still runs on the retained audio.
class SpeechAudioGate {
  static const sampleRate = 16000;
  static const _frameSamples = 320; // 20 ms
  static const _frameBytes = _frameSamples * 2;
  static const _preRollFrames = 15; // preserve the beginning of a word
  static const _tailFrames = 15; // preserve quiet endings and short pauses
  static const _minimumVoiceFrames = 10; // reject clicks / brief impulses
  static const _rmsThreshold = .003; // about -50 dBFS

  final _pending = Queue<Uint8List>();
  final _voiceWindow = Queue<bool>();
  Uint8List _frame = Uint8List(_frameBytes);
  int _offset = 0, _voiceFrames = 0, _tail = 0;
  int _samples = 0, _lastVoiceSample = 0;
  int get voiceRevision => _lastVoiceSample;
  Duration get trailingSilence => Duration(
    microseconds: (_samples - _lastVoiceSample) * 1000000 ~/ sampleRate,
  );
  bool hasSpeech = false;

  List<Uint8List> add(Uint8List bytes) {
    final output = <Uint8List>[];
    var offset = 0;
    while (offset < bytes.length) {
      final count = math.min(_frameBytes - _offset, bytes.length - offset);
      _frame.setRange(_offset, _offset + count, bytes, offset);
      _offset += count;
      offset += count;
      if (_offset == _frameBytes) {
        _process(_frame, output);
        _frame = Uint8List(_frameBytes);
        _offset = 0;
      }
    }
    return output;
  }

  void _process(Uint8List frame, List<Uint8List> output) {
    final data = ByteData.sublistView(frame);
    var sum = 0.0, squares = 0.0;
    for (var i = 0; i < _frameSamples; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768;
      sum += sample;
      squares += sample * sample;
    }
    // A microphone's DC offset is not voice energy.
    final mean = sum / _frameSamples;
    final rms = math.sqrt(math.max(0, squares / _frameSamples - mean * mean));
    final voiced = rms >= _rmsThreshold;
    _samples += _frameSamples;
    if (voiced) _lastVoiceSample = _samples;
    if (_tail > 0) {
      output.add(frame);
      _tail = voiced ? _tailFrames : _tail - 1;
      return;
    }
    _pending.add(frame);
    if (_pending.length > _preRollFrames) _pending.removeFirst();
    _voiceWindow.add(voiced);
    if (voiced) _voiceFrames++;
    if (_voiceWindow.length > _preRollFrames && _voiceWindow.removeFirst()) {
      _voiceFrames--;
    }
    if (_voiceFrames >= _minimumVoiceFrames) {
      hasSpeech = true;
      output.addAll(_pending);
      _pending.clear();
      _voiceWindow.clear();
      _voiceFrames = 0;
      _tail = _tailFrames;
    }
  }

  /// Flush only a previously accepted utterance, never a short noise burst.
  List<Uint8List> finish() {
    final output = <Uint8List>[];
    if (_tail > 0 && _offset >= 2) {
      output.add(Uint8List.sublistView(_frame, 0, _offset - _offset % 2));
    }
    _offset = 0;
    _pending.clear();
    _voiceWindow.clear();
    _voiceFrames = 0;
    _tail = 0;
    return output;
  }
}

String speechText(String value) => value
    .replaceAll(
      RegExp(
        r'\[(?:blank_audio|silence|no speech|music|noise|inaudible|'
        r'тишина|музыка|шум|неразборчиво)\]|<\|[^|]*\|>',
        caseSensitive: false,
      ),
      '',
    )
    .trim();
