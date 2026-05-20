import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:camera/camera.dart';
import '../services/camera_service.dart';

import '../models/app_state.dart';
import '../models/history_item.dart';
import '../services/notification_mirror_service.dart';
import '../services/relay_service.dart';
import '../services/webrtc_service.dart';

class DashboardScreen extends StatefulWidget {
  final RelayService relayService;
  const DashboardScreen({super.key, required this.relayService});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late StreamSubscription _intentSubscription;
  bool _showSharedSuccess = false;
  String? _beamedUrl;
  int _selectedPage = 0;

  @override
  void initState() {
    super.initState();

    // Ensure connection channel is active if restored from persistent state
    widget.relayService.ensureConnected();

    _checkPermissions();

    // 1. Listen to media sharing when app is already running in background/foreground
    _intentSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> value) {
        _handleSharedFiles(value);
      },
      onError: (err) {
        debugPrint("ReceiveSharingIntent stream error: $err");
      },
    );

    // 2. Get media sharing when app was completely closed
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      _handleSharedFiles(value);
    });
  }

  Future<void> _checkPermissions() async {
    // 1. Request standard notification capabilities (audio chiming / heads-up drop banners)
    final notifStatus = await Permission.notification.status;
    if (!notifStatus.isGranted) {
      await Permission.notification.request();
    }

    // 2. Request overlay capabilities (background app activity waking)
    final overlayStatus = await Permission.systemAlertWindow.status;
    if (!overlayStatus.isGranted) {
      await Permission.systemAlertWindow.request();
    }
  }

  @override
  void dispose() {
    _intentSubscription.cancel();
    super.dispose();
  }

  void _handleSharedFiles(List<SharedMediaFile> files) {
    if (files.isEmpty) return;

    // For shared text/plain target types (e.g., links exported from mobile browsers),
    // the content string is provided inside the .path attribute.
    final sharedText = files.first.path;

    // Robustly extract the URL from any surrounding metadata text
    final urlRegex = RegExp(r'(https?:\/\/[^\s]+)');
    final match = urlRegex.firstMatch(sharedText);
    final urlStr = match?.group(0) ?? (sharedText.startsWith('http') ? sharedText : null);

    if (urlStr != null && mounted) {
      final appState = context.read<AppState>();
      if (appState.roomId != null) {
        // Actively paired to a Mac room! Broadcast reverse payload.
        widget.relayService.sendReverseUrl(urlStr);
        setState(() {
          _beamedUrl = urlStr;
          _showSharedSuccess = true;
        });

        // Smoothly dismiss success overlay after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() => _showSharedSuccess = false);
          }
        });
      } else {
        // Offline preview mode: guide the user to connect first
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Please pair with Mac to broadcast shared tabs!',
              style: GoogleFonts.outfit(fontSize: 14),
            ),
            backgroundColor: Colors.amber.shade800,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }

    // Flush cache to ensure subsequent shares fire correctly
    ReceiveSharingIntent.instance.reset();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isOffline = appState.roomId == null;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Primary dashboard layout
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  _Header(appState: appState),
                  const SizedBox(height: 32),

                  // Dynamic Status card
                  _StatusCard(isOffline: isOffline),
                  const SizedBox(height: 20),

                  // Segment Mode Selector Bar
                  Container(
                    height: 48,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: (isDark ? Colors.white : Colors.black).withOpacity(0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _TabButton(
                            title: 'Tabs & Text',
                            icon: LucideIcons.layoutGrid,
                            isSelected: _selectedPage == 0,
                            onTap: () => setState(() => _selectedPage = 0),
                          ),
                        ),
                        Expanded(
                          child: _TabButton(
                            title: 'Files & Media',
                            icon: LucideIcons.folderHeart,
                            isSelected: _selectedPage == 1,
                            onTap: () => setState(() => _selectedPage = 1),
                          ),
                        ),
                        Expanded(
                          child: _TabButton(
                            title: 'Security',
                            icon: LucideIcons.shieldCheck,
                            isSelected: _selectedPage == 2,
                            onTap: () => setState(() => _selectedPage = 2),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Main content crossfade based on active page mode and pairing state
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        children: [
                          if (_selectedPage == 0) ...[
                            if (!isOffline) ...[
                              if (appState.isCameraActive) ...[
                                _CameraPreviewCard(),
                                const SizedBox(height: 20),
                              ],
                              _RoomCard(roomId: appState.roomId),
                              const SizedBox(height: 20),
                              _NotificationMirroringCard(isOffline: isOffline),
                              const SizedBox(height: 20),
                              _HistoricalFeedSection(history: appState.history),
                              const SizedBox(height: 20),
                            ] else ...[
                              _OfflineGuideCard(),
                              const SizedBox(height: 20),
                              _TipsCard(),
                              const SizedBox(height: 20),
                            ],
                          ] else if (_selectedPage == 1) ...[
                            _FilesAndMediaSection(isOffline: isOffline, relayService: widget.relayService),
                            const SizedBox(height: 20),
                          ] else ...[
                            _SecurityPage(isOffline: isOffline, relayService: widget.relayService),
                            const SizedBox(height: 20),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // Action Button
                  _ActionButton(
                    isOffline: isOffline,
                    onPressed: () async {
                      if (!isOffline) {
                        await widget.relayService.disconnect();
                      } else {
                        context.read<AppState>().disconnect();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),

          // Premium Beamed Success Overlay Animation
          if (_showSharedSuccess)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.85),
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutBack,
                    builder: (context, val, child) {
                      return Transform.scale(
                        scale: val,
                        child: Opacity(
                          opacity: val.clamp(0.0, 1.0),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 32),
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(
                              color: const Color(0xFF111118),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFF00E676).withOpacity(0.5),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF00E676).withOpacity(0.2),
                                  blurRadius: 30,
                                  spreadRadius: 5,
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  LucideIcons.checkCircle,
                                  size: 64,
                                  color: Color(0xFF00E676),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'Beamed to Mac!',
                                  style: GoogleFonts.outfit(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _beamedUrl ?? '',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.outfit(
                                    fontSize: 13,
                                    color: Colors.white60,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  final AppState appState;
  const _Header({required this.appState});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: primaryColor.withOpacity(isDark ? 0.12 : 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            LucideIcons.link,
            color: primaryColor,
            size: 24,
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Eunify',
              style: GoogleFonts.outfit(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : Colors.black87,
                letterSpacing: -0.4,
              ),
            ),
            Text(
              'Continuity Bridge',
              style: GoogleFonts.outfit(
                fontSize: 12,
                color: isDark ? Colors.white38 : Colors.black54,
              ),
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          onPressed: () async {
            await Supabase.instance.client.auth.signOut();
            appState.disconnect();
          },
          tooltip: 'Sign Out',
          icon: Icon(
            LucideIcons.logOut,
            color: Colors.redAccent.shade400,
            size: 20,
          ),
        ),
        IconButton(
          onPressed: () => _showThemeSelector(context),
          icon: Icon(
            LucideIcons.menu,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
      ],
    );
  }

  void _showThemeSelector(BuildContext context) {
    final appState = context.read<AppState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceColor = Theme.of(context).colorScheme.surface;

    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Theme Appearance',
                  style: GoogleFonts.outfit(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 16),
                _ThemeOptionTile(
                  title: 'System Default',
                  icon: LucideIcons.smartphone,
                  isSelected: appState.themeMode == ThemeMode.system,
                  onTap: () {
                    appState.setThemeMode(ThemeMode.system);
                    Navigator.pop(context);
                  },
                ),
                _ThemeOptionTile(
                  title: 'Light Mode',
                  icon: LucideIcons.sun,
                  isSelected: appState.themeMode == ThemeMode.light,
                  onTap: () {
                    appState.setThemeMode(ThemeMode.light);
                    Navigator.pop(context);
                  },
                ),
                _ThemeOptionTile(
                  title: 'AMOLED Black',
                  icon: LucideIcons.moon,
                  isSelected: appState.themeMode == ThemeMode.dark,
                  onTap: () {
                    appState.setThemeMode(ThemeMode.dark);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ThemeOptionTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeOptionTile({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: isSelected ? primaryColor : (isDark ? Colors.white54 : Colors.black54)),
      title: Text(
        title,
        style: GoogleFonts.outfit(
          fontSize: 15,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
          color: isSelected ? primaryColor : (isDark ? Colors.white : Colors.black87),
        ),
      ),
      trailing: isSelected
          ? Icon(LucideIcons.check, color: primaryColor, size: 20)
          : null,
      onTap: onTap,
    );
  }
}

class _StatusCard extends StatefulWidget {
  final bool isOffline;
  const _StatusCard({required this.isOffline});

  @override
  State<_StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<_StatusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _glowAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final color = widget.isOffline ? const Color(0xFFFFAB00) : primaryColor;
    final title = widget.isOffline ? 'Offline Preview Mode' : 'Cloud Relay Active';
    final subtitle = widget.isOffline
        ? 'Not paired. Drop events will not be received.'
        : 'Connected to Mac — ready to receive tabs';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withOpacity(widget.isOffline ? 0.3 : 0.4),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          // Pulsing glow dot
          AnimatedBuilder(
            animation: _glowAnimation,
            builder: (context, child) {
               return Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(0.1),
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(_glowAnimation.value * 0.6),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  widget.isOffline ? LucideIcons.alertCircle : LucideIcons.checkCircle,
                  color: color,
                  size: 32,
                ),
              );
            },
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black87,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OfflineGuideCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceColor = Theme.of(context).colorScheme.surface;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: (isDark ? Colors.white : Colors.black).withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.bookOpen, size: 18, color: primaryColor),
              const SizedBox(width: 8),
              Text(
                'How to Connect',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black87,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildStep(
            context: context,
            number: '1',
            title: 'Open Eunify on Mac',
            description: 'Launch the companion app on your macOS desktop to initialize the bridge.',
          ),
          const SizedBox(height: 16),
          _buildStep(
            context: context,
            number: '2',
            title: 'Scan QR Code',
            description: 'Tap "Pair with Mac" below to activate your camera and read the discovery token.',
          ),
          const SizedBox(height: 16),
          _buildStep(
            context: context,
            number: '3',
            title: 'Drag & Drop',
            description: 'Drag any URL directly into the desktop HUD to broadcast it instantly to your phone.',
          ),
        ],
      ),
    );
  }

  Widget _buildStep({required BuildContext context, required String number, required String title, required String description}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: primaryColor.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: GoogleFonts.outfit(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: primaryColor,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TipsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withOpacity(0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: (isDark ? Colors.white : Colors.black).withOpacity(0.04)),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.lightbulb, size: 20, color: Colors.amber),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Tip: Because tabs open in your primary mobile browser, your existing logins and cookies are fully preserved.',
              style: GoogleFonts.outfit(fontSize: 13, color: isDark ? Colors.white60 : Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomCard extends StatelessWidget {
  final String? roomId;
  const _RoomCard({required this.roomId});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceColor = Theme.of(context).colorScheme.surface;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: (isDark ? Colors.white : Colors.black).withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.hash, size: 16, color: isDark ? Colors.white38 : Colors.black38),
              const SizedBox(width: 6),
              Text(
                'Room ID',
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white38 : Colors.black54,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            roomId ?? 'Unknown',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 14,
              color: primaryColor,
              letterSpacing: 0.5,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _HistoricalFeedSection extends StatelessWidget {
  final List<HistoryItem> history;
  const _HistoricalFeedSection({required this.history});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        Row(
          children: [
            Icon(LucideIcons.history, size: 18, color: primaryColor),
            const SizedBox(width: 8),
            Text(
              'Historical Tab Feed',
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: primaryColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${history.length}',
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: primaryColor,
                ),
              ),
            ),
            const Spacer(),
            if (history.isNotEmpty)
              TextButton.icon(
                onPressed: () {
                  context.read<AppState>().clearHistory();
                },
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(LucideIcons.trash2, size: 14),
                label: Text(
                  'Clear All',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),

        // Content / Feed
        if (history.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (isDark ? Colors.white : Colors.black).withOpacity(0.05),
              ),
            ),
            child: Column(
              children: [
                Icon(
                  LucideIcons.inbox,
                  size: 40,
                  color: (isDark ? Colors.white : Colors.black).withOpacity(0.2),
                ),
                const SizedBox(height: 12),
                Text(
                  'History Buffer Empty',
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Dropped browser tabs and text snippets from your paired Mac will populate here.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    color: isDark ? Colors.white38 : Colors.black54,
                  ),
                ),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: history.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final item = history[index];
              return _HistoryItemCard(item: item);
            },
          ),
      ],
    );
  }
}

class _HistoryItemCard extends StatelessWidget {
  final HistoryItem item;
  const _HistoryItemCard({required this.item});

  Future<void> _handleAction(BuildContext context) async {
    if (item.type == HistoryType.snippet) {
      await Clipboard.setData(ClipboardData(text: item.content));
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.copy, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                'Snippet copied to clipboard',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1E1E1E),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      final uri = Uri.tryParse(item.content);
      if (uri == null) return;
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        try {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
        } catch (_) {}
      }
    }
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceColor = Theme.of(context).colorScheme.surface;
    final isSnippet = item.type == HistoryType.snippet;

    return Dismissible(
      key: Key(item.id),
      direction: DismissDirection.endToStart,
      onDismissed: (direction) {
        context.read<AppState>().deleteHistoryItem(item.id);
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: const Icon(LucideIcons.trash2, color: Colors.redAccent, size: 20),
      ),
      child: Material(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: primaryColor.withOpacity(isDark ? 0.25 : 0.4),
            width: 1.2,
          ),
        ),
        child: InkWell(
          onTap: () => _handleAction(context),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isSnippet ? LucideIcons.fileCode : LucideIcons.compass,
                            size: 14,
                            color: primaryColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isSnippet ? 'Snippet' : 'Web Link',
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: primaryColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '•',
                            style: TextStyle(color: (isDark ? Colors.white : Colors.black).withOpacity(0.3)),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(item.timestamp),
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              color: (isDark ? Colors.white : Colors.black).withOpacity(0.4),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.content,
                        style: isSnippet
                            ? GoogleFonts.jetBrainsMono(
                                fontSize: 13,
                                color: isDark ? Colors.white : Colors.black87,
                              )
                            : GoogleFonts.outfit(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: isDark ? Colors.white : Colors.black87,
                                decoration: TextDecoration.underline,
                                decorationColor: isDark ? Colors.white38 : Colors.black38,
                              ),
                        maxLines: isSnippet ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: primaryColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isSnippet ? LucideIcons.copy : LucideIcons.arrowUpRight,
                    color: primaryColor,
                    size: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final bool isOffline;
  final VoidCallback onPressed;
  const _ActionButton({required this.isOffline, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final bgColor = isOffline
        ? primaryColor.withOpacity(0.15)
        : Colors.red.shade900.withOpacity(0.15);
    final fgColor = isOffline ? primaryColor : Colors.red.shade700;
    final borderColor = isOffline
        ? primaryColor.withOpacity(0.4)
        : Colors.red.shade900.withOpacity(0.3);
    final icon = isOffline ? LucideIcons.camera : LucideIcons.link2Off;
    final label = isOffline ? 'Pair with Mac' : 'Disconnect';

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: bgColor,
          foregroundColor: fgColor,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: borderColor),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraPreviewCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: CameraService.instance,
      builder: (context, _) {
        final controller = CameraService.instance.controller;
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF00E676).withOpacity(0.5),
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  if (controller != null && controller.value.isInitialized)
                    CameraPreview(controller)
                  else
                    const Center(
                      child: CircularProgressIndicator(color: Color(0xFF00E676)),
                    ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    color: Colors.black54,
                    child: Text(
                      'LIVE CONTINUITY STREAM',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.outfit(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF00E676),
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TabButton extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabButton({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? primaryColor.withOpacity(isDark ? 0.2 : 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: isSelected
                ? Border.all(color: primaryColor.withOpacity(0.3))
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? primaryColor
                    : (isDark ? Colors.white54 : Colors.black54),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected
                      ? primaryColor
                      : (isDark ? Colors.white70 : Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilesAndMediaSection extends StatefulWidget {
  final bool isOffline;
  final RelayService relayService;
  const _FilesAndMediaSection({required this.isOffline, required this.relayService});

  @override
  State<_FilesAndMediaSection> createState() => _FilesAndMediaSectionState();
}

class _FilesAndMediaSectionState extends State<_FilesAndMediaSection> {
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadStatus = '';

  Future<void> _pickAndSendFile() async {
    if (widget.isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot upload files while offline.')),
      );
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final path = file.path;
      if (path == null) return;

      final fileObj = File(path);
      final bytes = await fileObj.readAsBytes();
      final totalSize = bytes.length;
      final chunkSize = 48000;
      final totalChunks = (totalSize / chunkSize).ceil();

      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
        _uploadStatus = 'Initiating transfer...';
      });

      await widget.relayService.sendReverseFileStart(file.name, totalSize, totalChunks);
      await Future.delayed(const Duration(milliseconds: 500));

      var offset = 0;
      var currentChunk = 0;
      while (offset < totalSize) {
        final end = (offset + chunkSize < totalSize) ? offset + chunkSize : totalSize;
        final chunkBytes = bytes.sublist(offset, end);
        final base64Str = base64Encode(chunkBytes);

        await widget.relayService.sendReverseFileChunk(base64Str);
        offset += chunkSize;
        currentChunk++;

        setState(() {
          _uploadProgress = offset / totalSize;
          _uploadStatus = 'Streaming chunk $currentChunk of $totalChunks...';
        });

        await Future.delayed(const Duration(milliseconds: 50));
      }

      setState(() {
        _uploadStatus = 'Transfer completed successfully!';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sent ${file.name} to Mac successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      await Future.delayed(const Duration(seconds: 1));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceColor = Theme.of(context).colorScheme.surface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section 1: Browse for Files & Media Card
        Text(
          'Send Media to Mac',
          style: GoogleFonts.outfit(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : Colors.black87,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 12),
        Material(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: primaryColor.withOpacity(0.3),
              width: 1.5,
            ),
          ),
          child: InkWell(
            onTap: _isUploading ? null : _pickAndSendFile,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: _isUploading
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: CircularProgressIndicator(
                              value: _uploadProgress > 0 ? _uploadProgress : null,
                              strokeWidth: 3,
                              color: primaryColor,
                            ),
                          )
                        : Icon(
                            LucideIcons.folderPlus,
                            size: 32,
                            color: primaryColor,
                          ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _isUploading ? 'Uploading to Mac...' : 'Browse Phone Storage',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _isUploading
                        ? _uploadStatus
                        : 'Select images, videos, or binary files to stage securely and beam over to your MacBook desktop.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      color: _isUploading ? primaryColor : (isDark ? Colors.white54 : Colors.black54),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!_isUploading)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: primaryColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(LucideIcons.uploadCloud, size: 16, color: Colors.white),
                          const SizedBox(width: 8),
                          Text(
                            'Choose File',
                            style: GoogleFonts.outfit(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),

        // Section 2: Received Files Buffer Preview
        Row(
          children: [
            Icon(LucideIcons.downloadCloud, size: 18, color: Colors.purpleAccent.shade200),
            const SizedBox(width: 8),
            Text(
              'Received Files & Media',
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Staging',
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.purpleAccent.shade200,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AnimatedBuilder(
          animation: WebRTCService.instance,
          builder: (context, child) {
            final service = WebRTCService.instance;
            final hasFiles = service.receivedFiles.isNotEmpty;
            final isTransferring = service.isTransferring;

            if (isTransferring) {
              final progress = service.totalBytes > 0 ? (service.receivedBytes / service.totalBytes) : 0.0;
              final percent = (progress * 100).toStringAsFixed(1);

              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: surfaceColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.purpleAccent.withOpacity(0.3),
                  ),
                ),
                child: Column(
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 80,
                          height: 80,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 6,
                            backgroundColor: Colors.purple.withOpacity(0.1),
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.purpleAccent),
                          ),
                        ),
                        Icon(LucideIcons.zap, color: Colors.purpleAccent.shade200, size: 28),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Streaming Binary Buffer...',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${service.currentFileName} ($percent%)',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        color: Colors.purpleAccent.shade200,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(service.receivedBytes / 1024).toStringAsFixed(1)} KB / ${(service.totalBytes / 1024).toStringAsFixed(1)} KB',
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              );
            }

            if (hasFiles) {
              return Column(
                children: service.receivedFiles.map((path) {
                  final filename = path.split('/').last;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: (isDark ? Colors.white : Colors.black).withOpacity(0.05),
                      ),
                    ),
                    child: ListTile(
                      onTap: () {
                        OpenFilex.open(path);
                      },
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      leading: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(LucideIcons.fileCheck2, color: Colors.purpleAccent.shade200),
                      ),
                      title: Text(
                        filename,
                        style: GoogleFonts.outfit(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      subtitle: Text(
                        'Tap to open file',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          color: Colors.greenAccent.shade400,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(LucideIcons.externalLink, size: 18),
                        onPressed: () {
                          OpenFilex.open(path);
                        },
                      ),
                    ),
                  );
                }).toList(),
              );
            }

            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: (isDark ? Colors.white : Colors.black).withOpacity(0.05),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    LucideIcons.fileQuestion,
                    size: 40,
                    color: (isDark ? Colors.white : Colors.black).withOpacity(0.2),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No Files Staged Yet',
                    style: GoogleFonts.outfit(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Media dropped into the designated macOS host tab will live-stream here for local previewing and saving.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      color: isDark ? Colors.white38 : Colors.black54,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _NotificationMirroringCard extends StatefulWidget {
  final bool isOffline;
  const _NotificationMirroringCard({required this.isOffline});

  @override
  State<_NotificationMirroringCard> createState() => _NotificationMirroringCardState();
}

class _NotificationMirroringCardState extends State<_NotificationMirroringCard> with WidgetsBindingObserver {
  bool _isGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatus();
    }
  }

  Future<void> _checkStatus() async {
    final granted = await NotificationMirrorService.instance.isPermissionGranted();
    if (mounted) {
      setState(() {
        _isGranted = granted;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = Theme.of(context).colorScheme.surface;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: (isDark ? Colors.white : Colors.black).withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.bellRing, size: 18, color: Colors.blueAccent),
              const SizedBox(width: 8),
              Text(
                'Desktop Notification Mirroring',
                style: GoogleFonts.outfit(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black87,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _isGranted ? Colors.green.withOpacity(0.15) : Colors.amber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _isGranted ? 'Active' : 'Setup Required',
                  style: GoogleFonts.outfit(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _isGranted ? Colors.green : Colors.amber.shade700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _isGranted
                ? 'Incoming SMS, WhatsApp, and banking alerts are securely live-streamed to your paired Mac. Native quick replies are enabled.'
                : 'Grant Notification Listener access to mirror mobile app alerts directly to your MacBook screen.',
            style: GoogleFonts.outfit(
              fontSize: 13,
              color: isDark ? Colors.white60 : Colors.black54,
              height: 1.3,
            ),
          ),
          if (!_isGranted && !widget.isOffline) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton.icon(
                onPressed: () async {
                  await NotificationMirrorService.instance.openSettings();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent.withOpacity(0.15),
                  foregroundColor: Colors.blueAccent,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(LucideIcons.settings, size: 16),
                label: Text(
                  'Open System Settings',
                  style: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SecurityPage extends StatelessWidget {
  final bool isOffline;
  final RelayService relayService;

  const _SecurityPage({required this.isOffline, required this.relayService});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = Theme.of(context).colorScheme.surface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Cloud Trust Card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: (isDark ? Colors.white : Colors.black).withOpacity(0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(LucideIcons.link2, color: Colors.blueAccent),
                  const SizedBox(width: 12),
                  Text(
                    'Cloud Link Status',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  _StatusIndicator(isActive: appState.isConnected),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Paired securely via Eunify Relay. Biometric challenges are signed locally and verified on your Mac.',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
              if (appState.isConnected && appState.isBiometricEnabled) ...[
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      relayService.sendSignalingMessage(
                        'CLIENT_UNLOCK_REQUEST',
                        {},
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purpleAccent,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(LucideIcons.fingerprint),
                    label: Text(
                      'Unlock Paired Mac',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. Biometric Handoff Card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: (isDark ? Colors.white : Colors.black).withOpacity(0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(LucideIcons.fingerprint, color: Colors.purpleAccent),
                  const SizedBox(width: 12),
                  Text(
                    'Biometric Unlock',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Switch(
                    value: appState.isBiometricEnabled,
                    activeColor: Colors.purpleAccent,
                    onChanged: isOffline ? null : (val) => appState.setBiometricEnabled(val),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Unlock your Mac by touching your phone\'s fingerprint sensor. Securely paired via Hardware TEE.',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 3. Security Info
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Icon(LucideIcons.shieldCheck, color: Colors.green, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'End-to-End Encrypted. Your Mac password never leaves the Mac Keychain.',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    color: Colors.green,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final bool isActive;
  const _StatusIndicator({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isActive ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        isActive ? 'Linked' : 'Disconnected',
        style: GoogleFonts.outfit(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: isActive ? Colors.green : Colors.orange,
        ),
      ),
    );
  }
}
