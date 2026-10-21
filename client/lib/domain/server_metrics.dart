class ServerMetrics {
  const ServerMetrics({
    required this.sampledAt,
    this.cpuPercent,
    required this.memoryTotal,
    required this.memoryUsed,
    required this.processMemory,
    required this.diskTotal,
    required this.diskAvailable,
    required this.uptimeSeconds,
  });
  final DateTime sampledAt;
  final double? cpuPercent;
  final int memoryTotal,
      memoryUsed,
      processMemory,
      diskTotal,
      diskAvailable,
      uptimeSeconds;
  factory ServerMetrics.fromJson(Map<String, dynamic> data) {
    int read(String key) {
      final value = data[key];
      if (value is! int || value < 0) {
        throw FormatException('Invalid metric: $key');
      }
      return value;
    }

    final cpu = data['cpu_percent'];
    if (cpu != null && (cpu is! num || !cpu.isFinite || cpu < 0 || cpu > 100)) {
      throw const FormatException('Invalid CPU metric');
    }
    final result = ServerMetrics(
      sampledAt: DateTime.parse(data['sampled_at'] as String),
      cpuPercent: (cpu as num?)?.toDouble(),
      memoryTotal: read('memory_total_bytes'),
      memoryUsed: read('memory_used_bytes'),
      processMemory: read('process_memory_bytes'),
      diskTotal: read('disk_total_bytes'),
      diskAvailable: read('disk_available_bytes'),
      uptimeSeconds: read('uptime_seconds'),
    );
    if (result.memoryUsed > result.memoryTotal ||
        result.diskAvailable > result.diskTotal) {
      throw const FormatException('Invalid metric totals');
    }
    return result;
  }
}
