import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/app_state.dart';
import '../services/relay_service.dart';

class ScannerScreen extends StatefulWidget {
  final RelayService relayService;
  const ScannerScreen({super.key, required this.relayService});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _hasPermission = false;
  bool _isProcessing = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (mounted) {
      setState(() => _hasPermission = status.isGranted);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;
    final barcode = capture.barcodes.firstOrNull;
    final rawValue = barcode?.rawValue;
    if (rawValue == null) return;

    if (rawValue.startsWith('eunify://connect?room=')) {
      setState(() => _isProcessing = true);
      final roomId = rawValue.substring('eunify://connect?room='.length);
      _connect(roomId);
    }
  }

  Future<void> _connect(String roomId) async {
    final appState = context.read<AppState>();
    await widget.relayService.connect(roomId);
    appState.connect(roomId);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: !_hasPermission
          ? _buildPermissionDenied()
          : Stack(
              children: [
                // Full-screen camera preview
                MobileScanner(
                  controller: _scannerController,
                  onDetect: _onDetect,
                ),

                // Dark gradient vignette top
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 200,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.85),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // Dark gradient vignette bottom
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 200,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.85),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // Header
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Eunify',
                          style: GoogleFonts.outfit(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Continuity Bridge',
                          style: GoogleFonts.outfit(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Animated scan box
                Center(
                  child: AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Container(
                        width: 260,
                        height: 260,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white
                                .withOpacity(_pulseAnimation.value),
                            width: 2.5,
                          ),
                        ),
                        child: Stack(
                          children: [
                            // Corner accents
                            ..._buildCornerAccents(),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // Bottom instruction
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 48),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isProcessing) ...[
                            const CircularProgressIndicator(
                              color: Color(0xFF00E676),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Connecting...',
                              style: GoogleFonts.outfit(
                                fontSize: 16,
                                color: Colors.white70,
                              ),
                            ),
                          ] else ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.15),
                                ),
                              ),
                              child: Text(
                                'Scan the QR code on your Mac',
                                style: GoogleFonts.outfit(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Open Eunify on macOS and point your\ncamera at the QR code',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                color: Colors.white38,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 20),
                            TextButton.icon(
                              onPressed: () {
                                context.read<AppState>().skipConnection();
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white70,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: BorderSide(color: Colors.white.withOpacity(0.12)),
                                ),
                                backgroundColor: Colors.white.withOpacity(0.03),
                              ),
                              icon: const Icon(LucideIcons.compass, size: 16, color: Color(0xFF00E676)),
                              label: Text(
                                'Skip to Dashboard',
                                style: GoogleFonts.outfit(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  List<Widget> _buildCornerAccents() {
    const color = Color(0xFF00E676);
    const size = 22.0;
    const thickness = 3.5;

    Widget corner({
      required Alignment alignment,
      required BorderRadius radius,
      required Border border,
    }) =>
        Align(
          alignment: alignment,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: border,
            ),
          ),
        );

    return [
      corner(
        alignment: Alignment.topLeft,
        radius: const BorderRadius.only(topLeft: Radius.circular(8)),
        border: const Border(
          top: BorderSide(color: color, width: thickness),
          left: BorderSide(color: color, width: thickness),
        ),
      ),
      corner(
        alignment: Alignment.topRight,
        radius: const BorderRadius.only(topRight: Radius.circular(8)),
        border: const Border(
          top: BorderSide(color: color, width: thickness),
          right: BorderSide(color: color, width: thickness),
        ),
      ),
      corner(
        alignment: Alignment.bottomLeft,
        radius: const BorderRadius.only(bottomLeft: Radius.circular(8)),
        border: const Border(
          bottom: BorderSide(color: color, width: thickness),
          left: BorderSide(color: color, width: thickness),
        ),
      ),
      corner(
        alignment: Alignment.bottomRight,
        radius: const BorderRadius.only(bottomRight: Radius.circular(8)),
        border: const Border(
          bottom: BorderSide(color: color, width: thickness),
          right: BorderSide(color: color, width: thickness),
        ),
      ),
    ];
  }

  Widget _buildPermissionDenied() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.camera,
                size: 64, color: isDark ? Colors.white38 : Colors.black38),
            const SizedBox(height: 24),
            Text(
              'Camera Access Required',
              style: GoogleFonts.outfit(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Eunify needs camera access to scan the QR code on your Mac.',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(fontSize: 15, color: isDark ? Colors.white54 : Colors.black54),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: openAppSettings,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: isDark ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'Open Settings',
                style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
