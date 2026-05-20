import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/supabase_config.dart';
import '../main.dart';
import '../models/app_state.dart';
import '../models/history_item.dart';
import './camera_service.dart';
import './notification_mirror_service.dart';
import './notification_service.dart';
import './biometric_service.dart';
import './webrtc_service.dart';

/// Manages the Supabase Realtime subscription and foreground task keepalive.
class RelayService {
  final AppState _appState;
  RealtimeChannel? _channel;

  RelayService(this._appState);

  // ---------------------------------------------------------------------------
  // Foreground Task Setup
  // ---------------------------------------------------------------------------

  static void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'eunify_channel',
        channelName: 'Eunify Relay Service',
        channelDescription: 'Listening for tabs from Mac...',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> startForegroundTask() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: 'Eunify Active',
        notificationText: 'Listening for tabs from Mac...',
        callback: startCallback,
      );
    }
  }

  Future<void> stopForegroundTask() async {
    await FlutterForegroundTask.stopService();
  }

  // ---------------------------------------------------------------------------
  // Supabase Realtime Subscription
  // ---------------------------------------------------------------------------

  Future<void> connect(String roomId) async {
    log('EunifyRelay: Attempting to connect to Room ID: $roomId');
    await startForegroundTask();

    final supabase = Supabase.instance.client;

    _channel = supabase.channel('eunify_room_$roomId');

    WebRTCService.instance.setRelayService(this);
    CameraService.instance.setRelayService(this);
    NotificationMirrorService.instance.setRelayService(this);
    NotificationMirrorService.instance.startMirroring();

    _channel!
        .onBroadcast(
          event: 'ACTION_LAUNCH_URL',
          callback: (payload) {
            final flat = _flatten(payload);
            log('EunifyRelay: received broadcast: $flat');
            _handlePayload(flat);
          },
        )
        .onBroadcast(
          event: 'ACTION_COPY_TEXT',
          callback: (payload) {
            final flat = _flatten(payload);
            log('EunifyRelay: received text copy broadcast: $flat');
            _handleCopyText(flat);
          },
        )
        .onBroadcast(
          event: 'ACTION_WEBRTC_OFFER',
          callback: (payload) {
            log('EunifyRelay: intercepted WebRTC session offer broadcast');
            WebRTCService.instance.handleOffer(payload);
          },
        )
        .onBroadcast(
          event: 'ACTION_WEBRTC_ICE_CANDIDATE',
          callback: (payload) {
            WebRTCService.instance.handleIceCandidate(payload);
          },
        )
        .onBroadcast(
          event: 'ACTION_FILE_TRANSFER_START',
          callback: (payload) {
            WebRTCService.instance.handleFileStart(payload);
          },
        )
        .onBroadcast(
          event: 'ACTION_FILE_CHUNK',
          callback: (payload) {
            WebRTCService.instance.handleFileChunk(payload);
          },
        )
        .onBroadcast(
          event: 'ACTION_START_CAMERA',
          callback: (payload) {
            log('EunifyRelay: START CAMERA command received');
            _handleCameraCommand('START');
          },
        )
        .onBroadcast(
          event: 'ACTION_STOP_CAMERA',
          callback: (payload) {
            log('EunifyRelay: STOP CAMERA command received');
            _handleCameraCommand('STOP');
          },
        )
        .onBroadcast(
          event: 'ACTION_FLIP_CAMERA',
          callback: (payload) {
            log('EunifyRelay: FLIP CAMERA command received');
            _handleCameraCommand('FLIP');
          },
        )
        .onBroadcast(
          event: 'ACTION_TOGGLE_FLASH',
          callback: (payload) {
            log('EunifyRelay: TOGGLE FLASH command received');
            _handleCameraCommand('FLASH');
          },
        )
        .onBroadcast(
          event: 'ACTION_CAPTURE_PHOTO',
          callback: (payload) {
            log('EunifyRelay: CAPTURE PHOTO command received');
            _handleCameraCommand('CAPTURE');
          },
        )
        .onBroadcast(
          event: 'ACTION_START_RECORDING',
          callback: (payload) {
            log('EunifyRelay: START RECORDING command received');
            _handleCameraCommand('START_RECORD');
          },
        )
        .onBroadcast(
          event: 'ACTION_STOP_RECORDING',
          callback: (payload) {
            log('EunifyRelay: STOP RECORDING command received');
            _handleCameraCommand('STOP_RECORD');
          },
        )
        .onBroadcast(
          event: 'ACTION_SET_AUDIO_SOURCE',
          callback: (payload) {
            final flat = _flatten(payload);
            final source = flat['source'] as String? ?? 'Mac';
            log('EunifyRelay: SET AUDIO SOURCE command received → $source');
            CameraService.instance.setEnableAudio(source == 'Phone');
          },
        )
        .onBroadcast(
          event: 'ACTION_NOTIFICATION_REPLY',
          callback: (payload) async {
            log('EunifyRelay: raw reply payload received: $payload');
            final flat = _flatten(payload);
            final notifId = flat['notification_id']?.toString();
            final replyText = flat['reply_text']?.toString();
            
            if (notifId != null && replyText != null) {
              log('EunifyRelay: executing quick reply for $notifId -> $replyText');
              final success = await NotificationMirrorService.instance.replyToNotification(notifId, replyText);
              log('EunifyRelay: reply execution status: $success');
            } else {
              log('EunifyRelay: failed to extract reply data from flat payload: $flat');
            }
          },
        )
        .onBroadcast(
          event: 'CLIENT_UNLOCK_CHALLENGE',
          callback: (payload) {
            final flat = _flatten(payload);
            log('EunifyRelay: received unlock challenge: $flat');
            _handleUnlockChallenge(flat);
          },
        )
        .onBroadcast(
          event: 'MEDIA_CONTROL',
          callback: (payload) {
            final flat = _flatten(payload);
            final action = flat['action'] as String?;
            log('EunifyRelay: received media control request: $action');
            if (action != null) {
              NotificationMirrorService.instance.controlMedia(action);
            }
          },
        )
        .onBroadcast(
          event: 'MEDIA_REFRESH',
          callback: (payload) {
            log('EunifyRelay: received media refresh request from Mac');
            NotificationMirrorService.instance.refreshMedia();
          },
        )
        .subscribe((status, [error]) async {
          log('EunifyRelay: channel status → $status');
          if (status.toString().toLowerCase().contains('subscribed')) {
            try {
              final email = Supabase.instance.client.auth.currentUser?.email;
              await _channel?.sendBroadcastMessage(
                event: 'CLIENT_CONNECTED',
                payload: {
                  'device': 'android',
                  'email': email ?? 'guest@eunify.local',
                },
              );
              log('EunifyRelay: sent CLIENT_CONNECTED broadcast');
            } catch (e) {
              log('EunifyRelay: broadcast error → $e');
            }
          }
          if (error != null) {
            log('EunifyRelay: channel error → $error');
          }
        });
  }

  Future<void> disconnect() async {
    try {
      await sendSignalingMessage('CLIENT_LOGGED_OUT', {'device': 'android'});
    } catch (_) {}
    await _channel?.unsubscribe();
    _channel = null;
    NotificationMirrorService.instance.stopMirroring();
    await stopForegroundTask();
    _appState.disconnect();
  }

  Future<void> _handleUnlockChallenge(Map<String, dynamic> payload) async {
    final challenge = payload['challenge'] as String?;
    if (challenge == null) return;

    // Trigger biometric prompt
    final signature = await BiometricService.instance.authenticateAndSign(challenge);

    if (signature != null) {
      // Send back the signed challenge
      await sendSignalingMessage('CLIENT_UNLOCK_SIGNATURE', {
        'signature': signature,
        'challenge': challenge,
      });
      log('EunifyRelay: sent signed unlock challenge back to Mac.');
    }
  }

  Future<void> ensureConnected() async {
    if (_channel != null) return;
    final roomId = _appState.roomId;
    if (roomId != null && roomId.isNotEmpty) {
      log('EunifyRelay: auto-restoring channel for room $roomId');
      await connect(roomId);
    }
  }

  Future<void> broadcastClientPresence() async {
    if (_channel == null) return;
    try {
      final email = Supabase.instance.client.auth.currentUser?.email;
      await _channel?.sendBroadcastMessage(
        event: 'CLIENT_CONNECTED',
        payload: {
          'device': 'android',
          'email': email ?? 'guest@eunify.local',
        },
      );
      log('EunifyRelay: broadcasted explicit CLIENT_CONNECTED presence');
    } catch (_) {}
  }

  Future<void> sendReverseUrl(String urlString) async {
    await ensureConnected();
    if (_channel == null) {
      log('EunifyRelay: cannot send reverse URL, channel is null');
      return;
    }
    try {
      await _channel!.sendBroadcastMessage(
        event: 'HOST_LAUNCH_URL',
        payload: {
          'url': urlString.trim(),
          'device': 'android',
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
      log('EunifyRelay: successfully broadcasted reverse URL → $urlString');
    } catch (e) {
      log('EunifyRelay: reverse broadcast error → $e');
    }
  }

  Future<void> sendSignalingMessage(String eventType, Map<String, dynamic> payload) async {
    await ensureConnected();
    if (_channel == null) return;
    try {
      await _channel!.sendBroadcastMessage(
        event: eventType,
        payload: {
          'event': eventType,
          'payload': payload,
          'device': 'android',
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
      log('EunifyRelay: transmitted protocol signaling map → $eventType');
      log('EunifyRelay: payload structure → ${jsonEncode(payload)}');
    } catch (e) {
      log('EunifyRelay: signaling broadcast error → $e');
    }
  }

  Future<void> sendReverseFileStart(String fileName, int fileSize, int totalChunks) async {
    await sendSignalingMessage('CLIENT_FILE_TRANSFER_START', {
      'file_name': fileName,
      'file_size': fileSize,
      'chunk_count': totalChunks,
    });
  }

  Future<void> sendReverseFileChunk(String base64Chunk) async {
    await sendSignalingMessage('CLIENT_FILE_CHUNK', {
      'chunk': base64Chunk,
    });
  }

  // ---------------------------------------------------------------------------
  // Payload Handling
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _flatten(Map<String, dynamic> data) {
    if (data.containsKey('payload') && data['payload'] is Map) {
      return _flatten(Map<String, dynamic>.from(data['payload'] as Map));
    }
    return data;
  }

  void _handlePayload(Map<String, dynamic> payload) {
    try {
      // The payload is already flattened by the caller
      final urlString = payload['url'] as String?;
      if (urlString == null || urlString.isEmpty) return;

      _appState.addHistoryItem(urlString, isSnippet: false);
      _launchUrl(urlString);
    } catch (e) {
      log('EunifyRelay: payload parse error → $e');
    }
  }

  Future<void> _launchUrl(String urlString) async {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return;

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      try {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      } catch (e) {
        log('EunifyRelay: launch fallback error → $e');
      }
    }
  }

  Future<void> _handleCopyText(Map<String, dynamic> payload) async {
    try {
      // The payload is already flattened by the caller
      final textContent = payload['text'] as String?;
      if (textContent == null || textContent.isEmpty) return;

      _appState.addHistoryItem(textContent, isSnippet: true);

      // Trigger Approach B: Audible Heads-Up system banner alert
      NotificationService().showSnippetNotification(textContent);

      // Wake device and pull app window focus to foreground to bypass Android 10+ ClipboardManager blocks
      FlutterForegroundTask.launchApp();
      await Future.delayed(const Duration(milliseconds: 300));
      await Clipboard.setData(ClipboardData(text: textContent));

      // Show premium minimal AMOLED/green custom feedback toast notice
      final messenger = scaffoldMessengerKey.currentState;
      if (messenger != null) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676).withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    color: Color(0xFF00E676),
                    size: 16,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Copied from Mac',
                    style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF1E1E1E),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: const Color(0xFF00E676).withOpacity(0.3)),
            ),
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      log('EunifyRelay: copy text error → $e');
    }
  }

  void _handleCameraCommand(String action) {
    log('EunifyRelay: Executing camera action → $action');
    
    _appState.setCameraActive(action != 'STOP');
    
    // Switch to the main UI thread and bring app to foreground
    FlutterForegroundTask.launchApp();
    
    // Provide visual feedback via SnackBar and Notification
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger != null) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Camera Action: $action',
            style: const TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.bold),
          ),
          backgroundColor: action == 'STOP' ? Colors.red : const Color(0xFF00E676),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    NotificationService().showSnippetNotification('Camera $action Requested');
    
    switch (action) {
      case 'START':
        CameraService.instance.startStreaming();
        break;
      case 'STOP':
        CameraService.instance.stopStreaming();
        break;
      case 'FLIP':
        CameraService.instance.flipCamera();
        break;
      case 'FLASH':
        CameraService.instance.toggleFlash();
        break;
      case 'CAPTURE':
        CameraService.instance.takePhoto();
        break;
      case 'START_RECORD':
        CameraService.instance.startRecording();
        break;
      case 'STOP_RECORD':
        CameraService.instance.stopRecording();
        break;
    }
  }
}

// Top-level callback required by flutter_foreground_task
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_EunifyTaskHandler());
}

class _EunifyTaskHandler extends TaskHandler {
  RealtimeChannel? _bgChannel;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Force read from direct OS memory blocks

      final savedRoom = prefs.getString('eunify_paired_room');
      if (savedRoom == null || savedRoom.isEmpty) return;

      // Ensure Supabase is initialized within this separate Isolate context
      await Supabase.initialize(
        url: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

      final supabase = Supabase.instance.client;
      _bgChannel = supabase.channel('eunify_room_$savedRoom');

      _bgChannel!
          .onBroadcast(
            event: 'ACTION_LAUNCH_URL',
            callback: (payload) async {
              log('EunifyTaskIsolate: received URL broadcast: $payload');
              await _handleBgPayload(payload, isSnippet: false);
            },
          )
          .onBroadcast(
            event: 'ACTION_COPY_TEXT',
            callback: (payload) async {
              log('EunifyTaskIsolate: received text copy broadcast: $payload');
              await _handleBgPayload(payload, isSnippet: true);
            },
          )
          .subscribe((status, [error]) {
            log('EunifyTaskIsolate: channel status → $status');
          });
    } catch (e) {
      log('EunifyTaskIsolate: initialization error → $e');
    }
  }

  Future<void> _handleBgPayload(Map<String, dynamic> payload, {required bool isSnippet}) async {
    try {
      final inner = payload['payload'] as Map<String, dynamic>?;
      final content = isSnippet ? (inner?['text'] as String?) : (inner?['url'] as String?);
      if (content == null || content.isEmpty) return;

      // 1. Direct raw storage updates so the dashboard updates independently
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Synchronize disk buffers against main Isolate operations
      final historyList = prefs.getStringList('eunify_history_feed') ?? [];

      final item = HistoryItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        content: content,
        type: isSnippet ? HistoryType.snippet : HistoryType.url,
        timestamp: DateTime.now(),
      );

      historyList.insert(0, item.toJson());
      if (historyList.length > 50) {
        historyList.removeRange(50, historyList.length);
      }
      await prefs.setStringList('eunify_history_feed', historyList);

      if (isSnippet) {
        // Cache snippet string to disk for instantaneous lifecycle observer handover execution
        await prefs.setString('eunify_pending_clipboard', content);
      } else {
        // Cache URL string for instantaneous authorized Foreground UI thread delegation
        await prefs.setString('eunify_pending_url_launch', content);
      }

      // 2. Emit Approach B audible notification alerts
      await NotificationService().showSnippetNotification(content);

      // 3. Emit Approach A focus trampoline waking
      FlutterForegroundTask.launchApp();
      await Future.delayed(const Duration(milliseconds: 300));

      if (isSnippet) {
        await Clipboard.setData(ClipboardData(text: content));
      } else {
        final uri = Uri.tryParse(content);
        if (uri != null) {
          try {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {
            try {
              await launchUrl(uri, mode: LaunchMode.platformDefault);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      log('EunifyTaskIsolate: payload error → $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _bgChannel?.unsubscribe();
    _bgChannel = null;
  }
}
