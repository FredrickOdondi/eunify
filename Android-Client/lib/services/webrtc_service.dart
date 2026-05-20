import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';

import './notification_service.dart';
import './relay_service.dart';

class WebRTCService extends ChangeNotifier {
  static final WebRTCService instance = WebRTCService._();
  WebRTCService._();

  RelayService? relayService;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  // Progression States
  String? currentFileName;
  int totalBytes = 0;
  int receivedBytes = 0;
  bool isTransferring = false;
  final List<String> receivedFiles = [];
  final List<int> _fileBuffer = [];

  void setRelayService(RelayService service) {
    relayService = service;
  }

  Future<void> handleOffer(Map<String, dynamic> payload) async {
    final inner = payload['payload'] as Map<String, dynamic>?;
    final sdpStr = inner?['sdp'] as String?;
    if (sdpStr == null) return;

    log('WebRTCService: Processing incoming session offer...');
    await _createPeerConnection();

    final sessionDescription = RTCSessionDescription(sdpStr, 'offer');
    await _peerConnection?.setRemoteDescription(sessionDescription);

    final answer = await _peerConnection?.createAnswer({});
    if (answer != null) {
      await _peerConnection?.setLocalDescription(answer);
      relayService?.sendSignalingMessage('ACTION_WEBRTC_ANSWER', {'sdp': answer.sdp});
      log('WebRTCService: Transmitted session answer back to Mac.');
    }
  }

  Future<void> handleIceCandidate(Map<String, dynamic> payload) async {
    final inner = payload['payload'] as Map<String, dynamic>?;
    final candidateStr = inner?['candidate'] as String?;
    final sdpMid = inner?['sdpMid'] as String?;
    final sdpMLineIndex = inner?['sdpMLineIndex'] as int?;

    if (candidateStr != null && sdpMid != null && sdpMLineIndex != null) {
      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);
      await _peerConnection?.addCandidate(candidate);
    }
  }

  void handleFileStart(Map<String, dynamic> payload) {
    final inner = payload['payload'] as Map<String, dynamic>? ?? payload;
    currentFileName = inner['file_name'] as String? ?? 'shared_media.bin';
    totalBytes = inner['file_size'] as int? ?? 0;
    receivedBytes = 0;
    isTransferring = true;
    _fileBuffer.clear();
    notifyListeners();
    log('WebRTCService: Prepared staging buffer for $currentFileName ($totalBytes bytes)');
  }

  void handleFileChunk(Map<String, dynamic> payload) {
    final inner = payload['payload'] as Map<String, dynamic>? ?? payload;
    final chunkB64 = inner['chunk'] as String?;
    if (chunkB64 == null || !isTransferring) return;

    try {
      final bytes = base64Decode(chunkB64);
      _fileBuffer.addAll(bytes);
      receivedBytes = _fileBuffer.length;
      notifyListeners();

      if (totalBytes > 0 && receivedBytes >= totalBytes) {
        _finalizeFile();
      }
    } catch (e) {
      log('WebRTCService: base64 chunk decode error → $e');
    }
  }

  Future<void> _createPeerConnection() async {
    if (_peerConnection != null) {
      await _peerConnection?.close();
      _peerConnection = null;
    }

    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan'
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      relayService?.sendSignalingMessage('ACTION_WEBRTC_ICE_CANDIDATE', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection?.onDataChannel = (RTCDataChannel channel) {
      log('WebRTCService: Remote DataChannel connected → ${channel.label}');
      _dataChannel = channel;
      _dataChannel?.onMessage = _handleDataChannelMessage;
    };
  }

  void _handleDataChannelMessage(RTCDataChannelMessage message) {
    if (message.isBinary) {
      _fileBuffer.addAll(message.binary);
      receivedBytes = _fileBuffer.length;
      notifyListeners();

      if (totalBytes > 0 && receivedBytes >= totalBytes) {
        _finalizeFile();
      }
    } else {
      // Could be textual control frames
      try {
        final map = jsonDecode(message.text);
        if (map['type'] == 'ACTION_FILE_TRANSFER_START') {
          handleFileStart(map);
        }
      } catch (_) {}
    }
  }

  Future<void> _finalizeFile() async {
    log('WebRTCService: Chunk stream assembly complete. Committing file to storage...');
    isTransferring = false;
    final name = currentFileName ?? 'downloaded_media_${DateTime.now().millisecondsSinceEpoch}';

    try {
      Directory? dir;
      if (Platform.isAndroid) {
        // Save safely inside the dedicated external app storage sandbox to prevent Scoped Storage access denial drops
        dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      } else {
        dir = await getApplicationDocumentsDirectory();
      }

      if (dir != null) {
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(_fileBuffer);
        receivedFiles.insert(0, file.path);
        log('WebRTCService: File committed successfully to → ${file.path}');
        
        NotificationService().showSnippetNotification('📁 File Received: $name');
      }
    } catch (e) {
      log('WebRTCService: Storage error committing assembly payload → $e');
    }

    currentFileName = null;
    _fileBuffer.clear();
    notifyListeners();
  }
}
