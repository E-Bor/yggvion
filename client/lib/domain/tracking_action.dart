/// A lock-screen interaction saved by the OS before Flutter is resumed.
/// Session IDs make replay safe if the process exits before acknowledging it.
class TrackingAction {
  TrackingAction.fromMap(Map<dynamic, dynamic> value)
    : id = value['id'] as String,
      taskId = value['taskId'] as String,
      deviceId = value['deviceId'] as String,
      action = value['action'] as String,
      at = DateTime.fromMillisecondsSinceEpoch(
        value['atMs'] as int,
        isUtc: true,
      ),
      sessionIds = List<String>.from(value['sessionIds'] as List),
      newSessionId = value['newSessionId'] as String? {
    if (id.isEmpty ||
        taskId.isEmpty ||
        deviceId.isEmpty ||
        !const ['pause', 'resume', 'stop'].contains(action) ||
        (action == 'resume' &&
            (newSessionId == null || newSessionId!.isEmpty))) {
      throw const FormatException('Invalid lock-screen timer action');
    }
  }

  final String id, taskId, deviceId, action;
  final DateTime at;
  final List<String> sessionIds;
  final String? newSessionId;
}
