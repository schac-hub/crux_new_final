import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_links/app_links.dart';
import 'utils/logger.dart' as crux;
import 'services/notification_service.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/consent_screen.dart';
import 'screens/guest_join_screen.dart';
import 'screens/meeting_screen.dart';
import 'models/user_model.dart';
import 'providers/auth_provider.dart' show CruxAuthProvider;
import 'providers/meeting_provider.dart';
import 'providers/meeting_state_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/locale_provider.dart';
import 'routes/app_routes.dart';
import 'theme/colors.dart';
import 'theme/theme.dart';
import 'widgets/elegant_toast.dart';
import 'wallpaper/wallpaper_manager.dart';
import 'wallpaper/app_background.dart';
import 'wallpaper/wallpaper_provider.dart';
import 'utils/meeting_notification_manager.dart';
import 'video/virtual_background_controller.dart';

const _flutterUnsupportedLocales = {'ha', 'yo', 'mg', 'wo'};

Locale _materialFallback(Locale locale) =>
    _flutterUnsupportedLocales.contains(locale.languageCode)
        ? const Locale('fr')
        : locale;

class _FallbackMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _FallbackMaterialLocalizationsDelegate();

  static const instance = _FallbackMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      GlobalMaterialLocalizations.delegate.load(_materialFallback(locale));

  @override
  bool shouldReload(_FallbackMaterialLocalizationsDelegate old) => false;
}

class _FallbackCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _FallbackCupertinoLocalizationsDelegate();

  static const instance = _FallbackCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      GlobalCupertinoLocalizations.delegate.load(_materialFallback(locale));

  @override
  bool shouldReload(_FallbackCupertinoLocalizationsDelegate old) => false;
}

const List<LocalizationsDelegate<dynamic>> _localizationsDelegates = [
  _FallbackMaterialLocalizationsDelegate.instance,
  _FallbackCupertinoLocalizationsDelegate.instance,
  GlobalWidgetsLocalizations.delegate,
];

void main() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    crux.logger.e(
      'Flutter Framework Error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 1. Initialisation indispensable de Firebase
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );

      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: 40 * 1024 * 1024,
      );

      crux.logger.i('Firebase initialized');
    } catch (e) {
      crux.logger.e('Firebase init error', error: e);
      runApp(
        _ErrorApp(
          title: 'Firebase Error',
          message: e.toString(),
        ),
      );
      return;
    }

    // 2. Initialisation optionnelle isolée
    try {
      await WallpaperManager().init();
    } catch (e) {
      crux.logger.e('WallpaperManager init error (non-fatal)', error: e);
    }

    try {
      NotificationService()
          .initialize()
          .catchError(
            (e) => crux.logger.e(
              'Notification init failed',
              error: e,
            ),
          );

      MeetingNotificationManager.instance
          .initialize()
          .catchError(
            (e) => crux.logger.e(
              'Meeting reminders init failed',
              error: e,
            ),
          );
    } catch (e) {
      crux.logger.e(
        'Notification Service crash (non-fatal)',
        error: e,
      );
    }

    runApp(const MyApp());
  }, (error, stack) {
    crux.logger.e(
      'Global App Crash',
      error: error,
      stackTrace: stack,
    );

    runApp(
      _ErrorApp(
        title: 'Startup Error',
        message: error.toString(),
      ),
    );
  });
}

class _ErrorApp extends StatelessWidget {
  final String title;
  final String message;

  const _ErrorApp({
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0C1A),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.bug_report_rounded,
                  color: Colors.redAccent,
                  size: 80,
                ),
                const SizedBox(height: 24),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _getUXFriendlyMessage(message),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Quitter'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white10,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      onPressed: () {
                        runApp(const MyApp());
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Réessayer'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getUXFriendlyMessage(String msg) {
    if (msg.contains('DefaultFirebaseOptions')) {
      return 'Configuration serveur manquante. Veuillez réinstaller l\'application.';
    }

    if (msg.contains('network')) {
      return 'Connexion impossible. Vérifiez votre accès Internet.';
    }

    if (msg.contains('api-key')) {
      return 'Clé API invalide. Contactez le support.';
    }

    if (msg.contains('project-not-found')) {
      return 'Projet Firebase introuvable.';
    }

    return 'Une erreur inattendue empêche l\'application de démarrer.';
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => CruxAuthProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => MeetingProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => MeetingStateProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => LocaleProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => VirtualBackgroundController(),
        ),
        ChangeNotifierProvider(
          create: (_) => WallpaperProvider(),
        ),
      ],
      child: Consumer3<ThemeProvider, LocaleProvider, WallpaperProvider>(
        builder: (
          context,
          themeProvider,
          localeProvider,
          wallpaper,
          _,
        ) {
          return MaterialApp(
            navigatorKey: MyApp._navigatorKey,
            title: 'CRUX',
            debugShowCheckedModeBanner: false,
            supportedLocales: LocaleProvider.languages.values.toList(),
            locale: localeProvider.locale,
            localizationsDelegates: _localizationsDelegates,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeProvider.themeMode,
            onGenerateRoute: AppRoutes.generateRoute,
            builder: (context, child) => AppBackground(
              config: wallpaper.config,
              child: child ?? const SizedBox.shrink(),
            ),
            home: const AuthWrapper(),
          );
        },
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool? _termsAccepted;
  late final Stream<User?> _authStream;
  String? _pendingMeetingId;
  StreamSubscription<Uri>? _deepLinkSubscription;
  final _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    _authStream = FirebaseAuth.instance.authStateChanges();
    _loadTerms();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _deepLinkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    try {
      _deepLinkSubscription = _appLinks.uriLinkStream.listen(
        (uri) => _handleDeepLink(uri),
      );

      final initialUri = await _appLinks.getInitialLink();

      if (initialUri != null) {
        _handleDeepLink(initialUri);
      }
    } catch (e) {
      crux.logger.w(
        'Deep link error',
        error: e,
      );
    }
  }

  void _handleDeepLink(Uri uri) {
    if (!mounted) return;

    String? meetingId;

    if (uri.scheme == 'crux' && uri.host == 'join') {
      meetingId = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.first
          : null;
    } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments[uri.pathSegments.length - 2] == 'join') {
      meetingId = uri.pathSegments.last;
    }

    if (meetingId == null || meetingId.isEmpty) return;

    final mid = meetingId.trim().toUpperCase();

    _pendingMeetingId = mid;

    final current = FirebaseAuth.instance.currentUser;

    if (current != null && !current.isAnonymous) {
      _joinMeetingAsAuthenticatedUser(mid);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GuestJoinScreen(
            meetingId: mid,
          ),
        ),
      );
    }
  }

  Future<void> _joinMeetingAsAuthenticatedUser(
    String meetingId,
  ) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('meetings')
          .doc(meetingId)
          .get();

      if (!mounted) return;

      if (!doc.exists) {
        ElegantToast.show(
          context,
          title: 'Erreur',
          message: 'Réunion introuvable',
          type: ElegantToastType.error,
        );
        return;
      }

      final data = doc.data();

      if (data == null) {
        if (mounted) {
          ElegantToast.show(
            context,
            title: 'Erreur',
            message: 'Données réunion corrompues',
            type: ElegantToastType.error,
          );
        }
        return;
      }

      final current = FirebaseAuth.instance.currentUser;

      if (current == null) {
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GuestJoinScreen(
                meetingId: meetingId,
              ),
            ),
          );
        }
        return;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MeetingScreen(
            meetingId: meetingId,
            meetingName: data['title'] as String? ?? 'Réunion',
            userId: current.uid,
            userName: current.displayName ??
                current.email ??
                'Invité',
            userEmail: current.email,
            isHost: false,
          ),
        ),
      );
    } catch (e) {
      crux.logger.e(
        '_joinMeetingAsAuthenticatedUser error',
        error: e,
      );

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GuestJoinScreen(
              meetingId: meetingId,
            ),
          ),
        );
      }
    }
  }

  Future<void> _loadTerms() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!mounted) return;

      setState(() {
        _termsAccepted =
            prefs.getBool('crux_terms_accepted') ?? false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _termsAccepted = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_termsAccepted == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0A0F),
        body: Center(
          child: CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 3,
          ),
        ),
      );
    }

    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0A0A0F),
            body: Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
                strokeWidth: 3,
              ),
            ),
          );
        }

        if (_pendingMeetingId != null) {
          final mid = _pendingMeetingId!;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;

            setState(() => _pendingMeetingId = null);

            final current =
                FirebaseAuth.instance.currentUser;

            if (current != null && !current.isAnonymous) {
              _joinMeetingAsAuthenticatedUser(mid);
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GuestJoinScreen(
                    meetingId: mid,
                  ),
                ),
              );
            }
          });
        }

        final user = snapshot.data;

        if (user == null) {
          return const LoginScreen();
        }

        final userModel = UserModel(
          uid: user.uid,
          name: user.displayName ??
              user.email?.split('@')[0] ??
              'Utilisateur',
          email: user.email ?? '',
        );

        if (_termsAccepted == true) {
          return HomeScreen(user: userModel);
        }

        return ConsentScreen(user: userModel);
      },
    );
  }
}
