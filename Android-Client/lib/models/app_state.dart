import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import 'history_item.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  bool _isConnected = false;
  String? _roomId;
  String? _lastUrl;
  ThemeMode _themeMode = ThemeMode.system;
  List<HistoryItem> _history = [];
  Timer? _syncTimer;
  bool _isCameraActive = false;
  bool _isBiometricEnabled = false;

  bool get isConnected => _isConnected;
  String? get roomId => _roomId;
  String? get lastUrl => _lastUrl;
  ThemeMode get themeMode => _themeMode;
  List<HistoryItem> get history => _history;
  bool get isCameraActive => _isCameraActive;
  bool get isBiometricEnabled => _isBiometricEnabled;

  void setCameraActive(bool active) {
    _isCameraActive = active;
    notifyListeners();
  }

  void setBiometricEnabled(bool enabled) {
    _isBiometricEnabled = enabled;
    notifyListeners();
  }


  // Scoped Storage Keys Tailored Directly to Active Account UUIDs
  String get _userId => Supabase.instance.client.auth.currentUser?.id ?? 'global';
  String get _roomKey => 'eunify_paired_room_$_userId';
  String get _historyKey => 'eunify_history_feed_$_userId';

  AppState() {
    _loadPersistedState();
    WidgetsBinding.instance.addObserver(this);

    // Continuous robust background storage synchronization loop
    // Guarantees items hit the UI feed and clipboard buffers regardless of OS lifecycle throttling
    _syncTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _syncDiskState();
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncDiskState();
    }
  }

  Future<void> reloadUserSession() async {
    await _loadPersistedState();
  }

  Future<void> _syncDiskState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // CRITICAL: Force reload disk files to bypass per-Isolate memory caching
      await prefs.reload();

      // 1. Process pending clipboard handover
      final pendingText = prefs.getString('eunify_pending_clipboard');
      if (pendingText != null && pendingText.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: pendingText));
        await prefs.remove('eunify_pending_clipboard');

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
      }

      // 1.5 Process pending URL launch handover under verified UI Foreground context
      final pendingUrl = prefs.getString('eunify_pending_url_launch');
      if (pendingUrl != null && pendingUrl.isNotEmpty) {
        await prefs.remove('eunify_pending_url_launch');
        final uri = Uri.tryParse(pendingUrl);
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

      // 2. Refresh memory history feed if disk contents changed
      final historyList = prefs.getStringList(_historyKey);
      if (historyList != null) {
        final parsed = historyList
            .map((str) {
              try {
                return HistoryItem.fromJson(str);
              } catch (_) {
                return null;
              }
            })
            .whereType<HistoryItem>()
            .toList();

        // Check if feeds differ to avoid excessive widget rebuilds
        if (_history.length != parsed.length ||
            (_history.isNotEmpty && parsed.isNotEmpty && _history.first.id != parsed.first.id)) {
          _history = parsed;
          notifyListeners();
        }
      }
    } catch (e) {
      // ignore silently during periodic execution
    }
  }

  Future<void> _checkPendingClipboardHandover() async {
    await _syncDiskState();
  }

  Future<void> _loadPersistedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final savedTheme = prefs.getString('eunify_theme_mode');
      if (savedTheme != null) {
        if (savedTheme == 'light') {
          _themeMode = ThemeMode.light;
        } else if (savedTheme == 'dark') {
          _themeMode = ThemeMode.dark;
        } else {
          _themeMode = ThemeMode.system;
        }
      }

      final savedRoom = prefs.getString(_roomKey);
      if (savedRoom != null && savedRoom.isNotEmpty) {
        _isConnected = true;
        _roomId = savedRoom;
      } else {
        _isConnected = false;
        _roomId = null;
      }

      final historyList = prefs.getStringList(_historyKey);
      if (historyList != null) {
        _history = historyList
            .map((str) {
              try {
                return HistoryItem.fromJson(str);
              } catch (_) {
                return null;
              }
            })
            .whereType<HistoryItem>()
            .toList();
      } else {
        _history = [];
      }

      notifyListeners();
    } catch (e) {
      debugPrint("Error loading persisted state: $e");
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('eunify_theme_mode', mode.name);
    } catch (e) {
      debugPrint("Error persisting theme mode: $e");
    }
  }

  Future<void> connect(String roomId) async {
    _isConnected = true;
    _roomId = roomId;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_roomKey, roomId);
    } catch (e) {
      debugPrint("Error persisting room: $e");
    }
  }

  void skipConnection() {
    _isConnected = true;
    _roomId = null;
    notifyListeners();
  }

  Future<void> disconnect() async {
    _isConnected = false;
    _roomId = null;
    _lastUrl = null;
    _history.clear();
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_roomKey);
    } catch (e) {
      debugPrint("Error clearing persisted room: $e");
    }
  }

  void setLastUrl(String url) {
    _lastUrl = url;
    notifyListeners();
  }

  Future<void> addHistoryItem(String content, {bool isSnippet = false}) async {
    _lastUrl = content;
    final item = HistoryItem(
      id: UniqueKey().toString(),
      content: content,
      type: isSnippet ? HistoryType.snippet : HistoryType.url,
      timestamp: DateTime.now(),
    );

    _history.insert(0, item);
    if (_history.length > 50) {
      _history = _history.sublist(0, 50);
    }

    notifyListeners();
    await _persistHistory();
  }

  Future<void> deleteHistoryItem(String id) async {
    _history.removeWhere((item) => item.id == id);
    notifyListeners();
    await _persistHistory();
  }

  Future<void> clearHistory() async {
    _history.clear();
    _lastUrl = null;
    notifyListeners();
    await _persistHistory();
  }

  Future<void> _persistHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serializedList = _history.map((item) => item.toJson()).toList();
      await prefs.setStringList(_historyKey, serializedList);
    } catch (e) {
      debugPrint("Error persisting history feed: $e");
    }
  }
}
