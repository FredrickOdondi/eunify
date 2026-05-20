import 'dart:async';
import 'dart:developer';
import 'package:flutter/services.dart';
import './relay_service.dart';

class NotificationMirrorService {
  static final NotificationMirrorService instance = NotificationMirrorService._();
  NotificationMirrorService._();

  static const MethodChannel _controlChannel = MethodChannel('com.eunify.client/notification_control');
  static const EventChannel _eventsChannel = EventChannel('com.eunify.client/notification_events');

  RelayService? _relayService;
  StreamSubscription? _eventSub;
  bool isMirroringEnabled = false;

  void setRelayService(RelayService service) {
    _relayService = service;
  }

  Future<bool> isPermissionGranted() async {
    try {
      final res = await _controlChannel.invokeMethod<bool>('isNotificationListenerGranted');
      return res ?? false;
    } catch (e) {
      log('NotificationMirrorService: permission check error → $e');
      return false;
    }
  }

  Future<void> openSettings() async {
    try {
      await _controlChannel.invokeMethod('openNotificationListenerSettings');
    } catch (e) {
      log('NotificationMirrorService: open settings error → $e');
    }
  }

  void startMirroring() {
    if (_eventSub != null) return;
    isMirroringEnabled = true;
    _eventSub = _eventsChannel.receiveBroadcastStream().listen((event) {
      if (!isMirroringEnabled) return;
      try {
        final map = Map<String, dynamic>.from(event as Map);
        
        if (map['is_media'] == true) {
           _relayService?.sendSignalingMessage('MEDIA_UPDATE', map);
           return;
        }

        log('NotificationMirrorService: intercepted alert → ${map['title']}');
        _relayService?.sendSignalingMessage('ACTION_MIRROR_NOTIFICATION', map);
      } catch (e) {
        log('NotificationMirrorService: event stream parse error → $e');
      }
    }, onError: (err) {
      log('NotificationMirrorService: event stream error → $err');
    });
    log('NotificationMirrorService: mirroring engine listening to native broadcast channels.');
  }

  void stopMirroring() {
    isMirroringEnabled = false;
    _eventSub?.cancel();
    _eventSub = null;
    log('NotificationMirrorService: mirroring engine stopped.');
  }

  Future<bool> replyToNotification(String notificationId, String replyText) async {
    try {
      final res = await _controlChannel.invokeMethod<bool>('replyToNotification', {
        'notification_id': notificationId,
        'reply_text': replyText,
      });
      log('NotificationMirrorService: reverse quick reply invocation returned → $res');
      return res ?? false;
    } catch (e) {
      log('NotificationMirrorService: reply invocation error → $e');
      return false;
    }
  }

  Future<bool> controlMedia(String action) async {
    try {
      final res = await _controlChannel.invokeMethod<bool>('controlMedia', {
        'action': action,
      });
      log('NotificationMirrorService: reverse media control invocation ($action) returned → $res');
      return res ?? false;
    } catch (e) {
      log('NotificationMirrorService: media control invocation error → $e');
      return false;
    }
  }

  Future<void> refreshMedia() async {
    try {
      await _controlChannel.invokeMethod('refreshMedia');
      log('NotificationMirrorService: requested proactive media state refresh from native.');
    } catch (e) {
      log('NotificationMirrorService: refresh media error → $e');
    }
  }
}
