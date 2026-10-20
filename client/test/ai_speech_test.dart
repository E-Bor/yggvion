import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/data/ai_speech.dart';

Uint8List pcm(
  int milliseconds, {
  double voice = 0,
  double noise = 0,
  int dc = 0,
}) {
  final random = math.Random(42);
  final data = ByteData(milliseconds * 16 * 2);
  for (var i = 0; i < data.lengthInBytes ~/ 2; i++) {
    final value =
        voice * math.sin(i * 2 * math.pi * 220 / 16000) +
        noise * (random.nextDouble() * 2 - 1);
    data.setInt16(
      i * 2,
      (value * 32767 + dc).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

Future<void> wav(File file, Uint8List pcm) async {
  final header = ByteData(44);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    for (var i = 0; i < entry.value.length; i++) {
      header.setUint8(entry.key + i, entry.value.codeUnitAt(i));
    }
  }
  header.setUint32(4, pcm.length + 36, Endian.little);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  header.setUint32(40, pcm.length, Endian.little);
  await file.writeAsBytes([...header.buffer.asUint8List(), ...pcm]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('audio gate', () {
    test('silence, low background noise and DC never reach the decoder', () {
      for (final audio in [pcm(30000), pcm(30000, noise: .002, dc: 800)]) {
        final gate = SpeechAudioGate();
        expect(gate.add(audio), isEmpty);
        expect(gate.finish(), isEmpty);
        expect(gate.hasSpeech, isFalse);
      }
    });
    test(
      'a short click or repeated isolated clicks do not count as speech',
      () {
        final gate = SpeechAudioGate();
        for (var i = 0; i < 20; i++) {
          expect(gate.add(pcm(40, voice: .7)), isEmpty);
          expect(gate.add(pcm(400)), isEmpty);
        }
        expect(gate.finish(), isEmpty);
        expect(gate.hasSpeech, isFalse);
      },
    );
    test(
      'quiet speech keeps its onset and ending; long pauses are bounded',
      () {
        final gate = SpeechAudioGate();
        expect(gate.add(pcm(2000)), isEmpty);
        final voice = pcm(600, voice: .006);
        final first = BytesBuilder()
          ..add(gate.add(voice).expand((f) => f).toList());
        expect(gate.hasSpeech, isTrue);
        expect(first.toBytes().sublist(first.length - voice.length), voice);
        final tail = gate.add(pcm(5000)).expand((f) => f).toList();
        expect(tail.length, 300 * 32);
        expect(gate.add(pcm(500, voice: .006)), isNotEmpty);
      },
    );
    test('short pauses within a word do not prevent activation', () {
      final gate = SpeechAudioGate();
      expect(gate.add(pcm(100, voice: .01)), isEmpty);
      expect(gate.add(pcm(60)), isEmpty);
      expect(gate.add(pcm(100, voice: .01)), isNotEmpty);
    });
    test(
      'odd, unaligned chunks preserve samples and the final partial frame',
      () {
        final source = BytesBuilder()
          ..add(pcm(600))
          ..add(pcm(613, voice: .01));
        final bytes = source.takeBytes();
        final whole = SpeechAudioGate(), fragmented = SpeechAudioGate();
        final expected = <int>[
          ...whole.add(bytes).expand((f) => f),
          ...whole.finish().expand((f) => f),
        ];
        final actual = <int>[];
        for (var offset = 0; offset < bytes.length; offset += 73) {
          actual.addAll(
            fragmented
                .add(
                  Uint8List.sublistView(
                    bytes,
                    offset,
                    math.min(bytes.length, offset + 73),
                  ),
                )
                .expand((f) => f),
          );
        }
        actual.addAll(fragmented.finish().expand((f) => f));
        expect(actual, expected);
        expect(
          actual.sublist(actual.length - 13 * 32),
          bytes.sublist(bytes.length - 13 * 32),
        );
      },
    );
    test('sound annotations are removed without censoring dictated words', () {
      expect(speechText(' [BLANK_AUDIO] [Music] <|nospeech|> '), '');
      expect(speechText('[шум] Купить молоко. [тишина]'), 'Купить молоко.');
      expect(speechText('Редактор субтитров'), 'Редактор субтитров');
      expect(speechText('Заметка [важно]'), 'Заметка [важно]');
    });
  });

  group('recorded WAV preprocessing', () {
    late Directory dir;
    late File source, output;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('yggvion-wav-test-');
      source = File('${dir.path}/recording.wav');
      output = File('${dir.path}/prepared.wav');
    });
    tearDown(() => dir.delete(recursive: true));
    test('silent recording is rejected before loading a model', () async {
      await wav(source, pcm(1000));
      expect(await prepareSpeechAudio(source.path, output.path), isFalse);
      expect(await output.exists(), isFalse);
    });
    test(
      'completed recording preserves quiet speech and removes long silence',
      () async {
        await wav(
          source,
          Uint8List.fromList([
            ...pcm(2000),
            ...pcm(600, voice: .01),
            ...pcm(4000),
          ]),
        );
        expect(await prepareSpeechAudio(source.path, output.path), isTrue);
        expect(await output.length(), lessThan(await source.length()));
        expect(
          await prepareSpeechAudio(output.path, '${dir.path}/again.wav'),
          isTrue,
        );
        expect(await source.exists(), isTrue);
      },
    );
    test('truncated and unsupported recordings fail visibly', () async {
      await source.writeAsString('not a WAV');
      await expectLater(
        prepareSpeechAudio(source.path, output.path),
        throwsFormatException,
      );
      await wav(source, pcm(1000, voice: .01));
      final bytes = await source.readAsBytes();
      ByteData.sublistView(bytes).setUint16(22, 2, Endian.little);
      await source.writeAsBytes(bytes);
      await expectLater(
        prepareSpeechAudio(source.path, output.path),
        throwsFormatException,
      );
    });
  });
  final model = Platform.environment['YGGVION_TEST_WHISPER_MODEL'];
  final library = Platform.environment['YGGVION_TEST_WHISPER_LIBRARY'];
  final recording = Platform.environment['YGGVION_TEST_WHISPER_WAV'];
  test(
    'native file transcription understands the recorded Russian command',
    () async {
      DynamicLibrary.open(library!);
      final text = (await WhisperFileTranscriber().transcribe(
        model!,
        recording!,
      )).toLowerCase();
      expect(text, contains('понедельник'));
      expect(text, matches(RegExp(r'пятнадцать|15')));
      expect(text, isNot(contains('субтитр')));
    },
    skip: model == null || library == null || recording == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
