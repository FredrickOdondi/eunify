import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import './relay_service.dart';

class CameraService extends ChangeNotifier {
  static final CameraService instance = CameraService._();
  CameraService._();

  CameraController? _controller;
  RelayService? _relayService;
  bool _isStreaming = false;
  int _frameSkipCounter = 0;
  int _currentCameraIndex = 0;
  bool _isProcessingFrame = false;
  bool _enableAudio = false;

  CameraController? get controller => _controller;

  void setEnableAudio(bool enable) {
    _enableAudio = enable;
    if (_isStreaming) {
      // Restart stream to apply audio changes
      stopStreaming().then((_) => startStreaming());
    }
  }

  void setRelayService(RelayService service) {
    _relayService = service;
  }

  Future<void> startStreaming() async {
    if (_isStreaming) return;

    try {
      final cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) {
        log('CameraService: Camera permission denied');
        return;
      }

      if (_enableAudio) {
        final audioStatus = await Permission.microphone.request();
        if (!audioStatus.isGranted) {
          log('CameraService: Microphone permission denied');
          // We can still stream video without audio if denied
        }
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      _controller = CameraController(
        cameras[_currentCameraIndex],
        ResolutionPreset.low,
        enableAudio: _enableAudio,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();
      _isStreaming = true;
      notifyListeners();

      _controller!.startImageStream((CameraImage image) {
        if (!_isStreaming || _isProcessingFrame) return;
        
        _frameSkipCounter++;
        if (_frameSkipCounter % 4 != 0) return;

        _isProcessingFrame = true;
        _processAndSendFrame(image).then((_) => _isProcessingFrame = false);
      });

      log('CameraService: Live stream started');
    } catch (e) {
      log('CameraService: Start error → $e');
      _isStreaming = false;
    }
  }

  Future<void> stopStreaming() async {
    _isStreaming = false;
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _controller = null;
    notifyListeners();
  }

  Future<void> flipCamera() async {
    final cameras = await availableCameras();
    if (cameras.length < 2) return;

    _currentCameraIndex = (_currentCameraIndex + 1) % cameras.length;
    
    if (_isStreaming) {
      await stopStreaming();
      await startStreaming();
    }
  }

  Future<void> toggleFlash() async {
    if (_controller == null) return;
    try {
      final currentMode = _controller!.value.flashMode;
      final nextMode = currentMode == FlashMode.torch ? FlashMode.off : FlashMode.torch;
      await _controller!.setFlashMode(nextMode);
      log('CameraService: Flash toggled to $nextMode');
    } catch (e) {
      log('CameraService: Flash toggle error → $e');
    }
  }

  Future<void> takePhoto() async {
    if (_controller == null) return;
    try {
      final XFile photo = await _controller!.takePicture();
      final bytes = await photo.readAsBytes();
      
      _relayService?.sendSignalingMessage('CLIENT_FILE_TRANSFER_START', {
        'file_name': 'eunify_capture_${DateTime.now().millisecondsSinceEpoch}.jpg',
        'file_size': bytes.length,
      });
      
      const int chunkSize = 16000;
      for (int i = 0; i < bytes.length; i += chunkSize) {
        int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        final chunk = bytes.sublist(i, end);
        _relayService?.sendSignalingMessage('CLIENT_FILE_CHUNK', {
          'chunk': base64Encode(chunk),
        });
      }
      
      log('CameraService: Photo captured and beamed to Mac');
    } catch (e) {
      log('CameraService: Photo capture error → $e');
    }
  }

  Future<void> startRecording() async {
    if (_controller == null) return;
    try {
      await _controller!.startVideoRecording();
      log('CameraService: Video recording started');
    } catch (e) {
      log('CameraService: Start recording error → $e');
    }
  }

  Future<void> stopRecording() async {
    if (_controller == null) return;
    try {
      final XFile video = await _controller!.stopVideoRecording();
      final bytes = await video.readAsBytes();
      
      _relayService?.sendSignalingMessage('CLIENT_FILE_TRANSFER_START', {
        'file_name': 'eunify_record_${DateTime.now().millisecondsSinceEpoch}.mp4',
        'file_size': bytes.length,
      });
      
      const int chunkSize = 16000;
      for (int i = 0; i < bytes.length; i += chunkSize) {
        int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        final chunk = bytes.sublist(i, end);
        _relayService?.sendSignalingMessage('CLIENT_FILE_CHUNK', {
          'chunk': base64Encode(chunk),
        });
      }
      
      log('CameraService: Video recording saved and beamed to Mac');
    } catch (e) {
      log('CameraService: Stop recording error → $e');
    }
  }

  Future<void> _processAndSendFrame(CameraImage image) async {
    if (_relayService == null) return;

    try {
      final cameras = await availableCameras();
      final bool isFront = cameras[_currentCameraIndex].lensDirection == CameraLensDirection.front;
      
      // RUNNING DIRECTLY ON MAIN THREAD FOR MAXIMUM SPEED
      final List<int> jpegBytes = _encodeToLowResJpeg(image, isFront);
      
      if (jpegBytes.isEmpty) return;
      
      final String base64Frame = base64Encode(jpegBytes);
      
      _relayService?.sendSignalingMessage('CLIENT_CAMERA_FRAME', {
        'frame': base64Frame,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      log('CameraService: Frame transmission error → $e');
    }
  }

  List<int> _encodeToLowResJpeg(CameraImage image, bool isFront) {
    try {
      final int width = image.width;
      final int height = image.height;
      
      final img.Image resImage = img.Image(width: width, height: height);
      
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];
      
      final yBuffer = yPlane.bytes;
      final uBuffer = uPlane.bytes;
      final vBuffer = vPlane.bytes;
      
      final int yRowStride = yPlane.bytesPerRow;
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel!;
      
      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          final int yIndex = h * yRowStride + w;
          final int uvIndex = (h ~/ 2) * uvRowStride + (w ~/ 2) * uvPixelStride;
          
          final int y = yBuffer[yIndex];
          final int u = uBuffer[uvIndex] - 128;
          final int v = vBuffer[uvIndex] - 128;
          
          int r = (y + 1.402 * v).round().clamp(0, 255);
          int g = (y - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
          int b = (y + 1.772 * u).round().clamp(0, 255);
          
          resImage.setPixelRgb(w, h, r, g, b);
        }
      }
      
      // Rotate and Compress
      img.Image rotated = img.copyRotate(resImage, angle: isFront ? 270 : 90);
      if (isFront) {
        rotated = img.copyFlip(rotated, direction: img.FlipDirection.horizontal);
      }
      
      final thumbnail = img.copyResize(rotated, width: 480);
      return img.encodeJpg(thumbnail, quality: 50);
    } catch (e) {
      return [];
    }
  }
}
