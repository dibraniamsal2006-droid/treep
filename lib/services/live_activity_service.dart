import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TreepLiveActivityContent {
  const TreepLiveActivityContent({
    required this.journeyId,
    required this.lineLabel,
    required this.destinationLabel,
    required this.directionLabel,
    required this.referenceTime,
    required this.alarmTime,
    required this.arrivalTime,
    this.phase = 'tracking',
    this.alarmId,
    this.alarmSessionId,
    this.alarmRevision,
  });

  final String journeyId;
  final String lineLabel;
  final String destinationLabel;
  final String directionLabel;
  final DateTime referenceTime;
  final DateTime alarmTime;
  final DateTime arrivalTime;
  final String phase;
  final String? alarmId;
  final String? alarmSessionId;
  final int? alarmRevision;

  Map<String, Object> toMap() => {
    'journeyId': journeyId,
    'lineLabel': lineLabel,
    'destinationLabel': destinationLabel,
    'directionLabel': directionLabel,
    'referenceTimeMs': referenceTime.millisecondsSinceEpoch,
    'alarmTimeMs': alarmTime.millisecondsSinceEpoch,
    'arrivalTimeMs': arrivalTime.millisecondsSinceEpoch,
    'phase': phase,
    if (alarmId != null) 'alarmId': alarmId!,
    if (alarmSessionId != null) 'alarmSessionId': alarmSessionId!,
    if (alarmRevision != null) 'alarmRevision': alarmRevision!,
  };
}

class LiveActivityOperationResult {
  const LiveActivityOperationResult({
    required this.succeeded,
    required this.supported,
    required this.enabled,
    this.activityId,
    this.action,
    this.failure,
  });

  final bool succeeded;
  final bool supported;
  final bool enabled;
  final String? activityId;
  final String? action;
  final String? failure;
}

abstract interface class LiveActivityGateway {
  Future<LiveActivityOperationResult> startOrUpdate(
    TreepLiveActivityContent content,
  );

  Future<LiveActivityOperationResult> end({String? activityId});
}

class MethodChannelLiveActivityGateway implements LiveActivityGateway {
  const MethodChannelLiveActivityGateway();

  static const MethodChannel _channel = MethodChannel('treep/live_activity');

  @override
  Future<LiveActivityOperationResult> startOrUpdate(
    TreepLiveActivityContent content,
  ) => _invoke('startOrUpdate', content.toMap());

  @override
  Future<LiveActivityOperationResult> end({String? activityId}) => _invoke(
    'end',
    <String, Object>{if (activityId != null) 'activityId': activityId},
  );

  Future<LiveActivityOperationResult> _invoke(
    String method,
    Map<String, Object> arguments,
  ) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(method, arguments);
      if (raw is! Map) {
        return LiveActivityOperationResult(
          succeeded: false,
          supported: false,
          enabled: false,
          failure: '$method returned malformed data',
        );
      }
      final value = Map<String, dynamic>.from(raw);
      return LiveActivityOperationResult(
        succeeded: value['succeeded'] == true,
        supported: value['supported'] == true,
        enabled: value['enabled'] == true,
        activityId: value['activityId']?.toString(),
        action: value['action']?.toString(),
        failure: value['failure']?.toString(),
      );
    } catch (error) {
      debugPrint('[live-activity] $method failed: $error');
      return LiveActivityOperationResult(
        succeeded: false,
        supported: false,
        enabled: false,
        failure: error.toString(),
      );
    }
  }
}
