import 'dart:io';
import 'package:flutter/services.dart';

class AiModel {
  const AiModel(
    this.id,
    this.label,
    this.repository,
    this.revision,
    this.file,
    this.bytes,
    this.sha256,
    this.memoryGiB,
  );
  final String id, label, repository, revision, file, sha256;
  final int bytes, memoryGiB;
  String get url =>
      'https://huggingface.co/$repository/resolve/$revision/$file';

  double get gib => bytes / 1073741824;
}

// Immutable revisions and LFS SHA-256 values from the publishers. Only model
// weights are downloaded; executable runtimes are built into the application.
const languageModels = [
  AiModel(
    'qwen-08',
    'Qwen 3.5 · 0.8B',
    'unsloth/Qwen3.5-0.8B-GGUF',
    '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0',
    'Qwen3.5-0.8B-Q4_K_M.gguf',
    532517120,
    'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517',
    4,
  ),
  AiModel(
    'qwen-2',
    'Qwen 3.5 · 2B',
    'unsloth/Qwen3.5-2B-GGUF',
    'f6d5376be1edb4d416d56da11e5397a961aca8ae',
    'Qwen3.5-2B-Q4_K_M.gguf',
    1280835840,
    'aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223',
    6,
  ),
  AiModel(
    'qwen-4',
    'Qwen 3.5 · 4B',
    'unsloth/Qwen3.5-4B-GGUF',
    'e87f176479d0855a907a41277aca2f8ee7a09523',
    'Qwen3.5-4B-Q4_K_M.gguf',
    2740937888,
    '00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4',
    12,
  ),
  AiModel(
    'qwen-9',
    'Qwen 3.5 · 9B',
    'unsloth/Qwen3.5-9B-GGUF',
    '3885219b6810b007914f3a7950a8d1b469d598a5',
    'Qwen3.5-9B-Q4_K_M.gguf',
    5680522464,
    '03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8',
    24,
  ),
];
const speechModel = AiModel(
  'whisper-small',
  'Whisper Small',
  'ggerganov/whisper.cpp',
  '5359861c739e955e79d9a303bcbc70fb988958b1',
  'ggml-small.bin',
  487601967,
  '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b',
  2,
);

class AiHardware {
  const AiHardware({
    required this.memoryBytes,
    required this.freeBytes,
    required this.name,
    required this.mobile,
  });
  final int memoryBytes, freeBytes;
  final String name;
  final bool mobile;
  double get memoryGiB => memoryBytes / 1073741824;
  bool fits(AiModel model) => memoryBytes == 0
      ? model == languageModels.first
      : memoryGiB >= model.memoryGiB && (!mobile || model.memoryGiB <= 6);
  AiModel get recommended =>
      languageModels.where(fits).lastOrNull ?? languageModels.first;
  static Future<AiHardware> detect() async {
    Map<String, dynamic>? info;
    try {
      info = await const MethodChannel(
        'dev.yggvion/hardware',
      ).invokeMapMethod<String, dynamic>('info');
    } on MissingPluginException {
      info = null;
    }
    var memory = (info?['memory_bytes'] as num?)?.toInt() ?? 0;
    if (memory == 0 && Platform.isLinux) {
      final text = await File('/proc/meminfo').readAsString();
      final match = RegExp(r'MemTotal:\s+(\d+)').firstMatch(text);
      if (match != null) memory = int.parse(match[1]!) * 1024;
    }
    if (memory == 0 && Platform.isWindows) {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
      ]).timeout(const Duration(seconds: 10));
      if (result.exitCode == 0) {
        memory = int.tryParse('${result.stdout}'.trim()) ?? 0;
      }
    }
    return AiHardware(
      memoryBytes: memory,
      freeBytes: (info?['free_bytes'] as num?)?.toInt() ?? 0,
      name: info?['name'] as String? ?? Platform.operatingSystem,
      mobile: Platform.isIOS || Platform.isAndroid,
    );
  }
}
