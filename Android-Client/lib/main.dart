import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/supabase_config.dart';
import 'models/app_state.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/scanner_screen.dart';
import 'screens/splash_screen.dart';
import 'services/relay_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Transparent status bar
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Init Supabase
  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  // Init foreground task
  RelayService.initForegroundTask();

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const EunifyApp(),
    ),
  );
}

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class EunifyApp extends StatelessWidget {
  const EunifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final relayService = RelayService(context.read<AppState>());

    return MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'Eunify',
      debugShowCheckedModeBanner: false,
      themeMode: context.watch<AppState>().themeMode,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C853),
          brightness: Brightness.light,
          surface: Colors.white,
          background: const Color(0xFFF8F9FA),
        ),
        textTheme: GoogleFonts.outfitTextTheme(
          ThemeData.light().textTheme,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
          surface: Colors.black,
          background: Colors.black,
        ),
        textTheme: GoogleFonts.outfitTextTheme(
          ThemeData.dark().textTheme,
        ),
        useMaterial3: true,
      ),
      home: WithForegroundTask(
        child: _RootRouter(relayService: relayService),
      ),
    );
  }
}

class _RootRouter extends StatefulWidget {
  final RelayService relayService;
  const _RootRouter({required this.relayService});

  @override
  State<_RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<_RootRouter> {
  bool _showSplash = true;
  bool _isRecoveringPassword = false;
  late final StreamSubscription<AuthState> _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (mounted) {
        if (data.event == AuthChangeEvent.passwordRecovery) {
          _isRecoveringPassword = true;
        }
        widget.relayService.broadcastClientPresence();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = context.watch<AppState>().isConnected;
    final isAuth = Supabase.instance.client.auth.currentUser != null;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 600),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(animation),
            child: child,
          ),
        );
      },
      child: _showSplash
          ? SplashScreen(
              key: const ValueKey('splash'),
              onFinished: () {
                setState(() => _showSplash = false);
              },
            )
          : (_isRecoveringPassword
              ? ResetPasswordScreen(
                  key: const ValueKey('reset_password'),
                  onPasswordUpdated: () {
                    setState(() {
                      _isRecoveringPassword = false;
                    });
                  },
                )
              : (!isAuth
                  ? AuthScreen(
                      key: const ValueKey('auth'),
                      onAuthenticated: () {
                        widget.relayService.broadcastClientPresence();
                        setState(() {});
                      },
                    )
                  : (isConnected
                      ? DashboardScreen(key: const ValueKey('dashboard'), relayService: widget.relayService)
                      : ScannerScreen(key: const ValueKey('scanner'), relayService: widget.relayService)))),
    );
  }
}
