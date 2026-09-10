import 'package:flutter/material.dart';
import '../screens/splash_screen.dart';
import '../screens/login_screen.dart';
import '../screens/home_screen.dart';
import '../screens/meeting_screen.dart';
import '../screens/schedule_meeting_screen.dart';
import '../screens/setting_screen.dart';
import '../screens/signup_screen.dart';
import '../screens/privacy_policy_screen.dart';
import '../screens/terms_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/pro_screen.dart';
import '../models/user_model.dart';
import '../wallpaper/wallpaper_picker_screen.dart';

class AppRoutes {
  static const String splash = '/';
  static const String login = '/login';
  static const String signup = '/signup';
  static const String home = '/home';
  static const String meeting = '/meeting';

  /// CORRECTIF : la route de planification n'existait pas, donc le bouton
  /// « Planifier » de l'accueil retombait sur la réunion instantanée.
  static const String schedule = '/schedule';

  static const String settings = '/settings';
  static const String privacy = '/privacy';
  static const String terms = '/terms';
  static const String profile = '/profile';
  static const String wallpaper = '/wallpaper';
  static const String pro = '/pro';

  static Route<dynamic> generateRoute(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashScreen());

      case login:
        return MaterialPageRoute(builder: (_) => const LoginScreen());

      case signup:
        return MaterialPageRoute(builder: (_) => const SignUpScreen());

      case home:
        final user = routeSettings.arguments as UserModel?;
        return MaterialPageRoute(
          builder:
              (_) => HomeScreen(
                user:
                    user ?? UserModel(uid: '', email: '', name: 'Utilisateur'),
              ),
        );

      case meeting:
        final args = routeSettings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder:
              (_) => MeetingScreen(
                meetingId: args?['meetingId'] ?? '',
                meetingName: args?['meetingName'] ?? 'Réunion',
                meetingCode: args?['meetingCode'], // ← AJOUT
                userId: args?['userId'] ?? '',
                userName: args?['userName'] ?? 'Utilisateur',
                userEmail: args?['userEmail'],
                isHost: args?['isHost'] ?? false,
              ),
        );

      case schedule:
        // `arguments` accepte un DateTime (créneau pré-sélectionné depuis un
        // calendrier) ou null.
        final initial = routeSettings.arguments;
        return MaterialPageRoute(
          builder:
              (_) => ScheduleMeetingScreen(
                initialStart: initial is DateTime ? initial : null,
              ),
        );

      case settings:
        return MaterialPageRoute(builder: (_) => const SettingsScreen());

      case privacy:
        return MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen());

      case terms:
        return MaterialPageRoute(builder: (_) => const TermsScreen());

      case profile:
        return MaterialPageRoute(builder: (_) => const ProfileScreen());

      case wallpaper:
        return MaterialPageRoute(builder: (_) => const WallpaperPickerScreen());

      case pro:
        return MaterialPageRoute(builder: (_) => const ProScreen());

      default:
        return MaterialPageRoute(builder: (_) => const SplashScreen());
    }
  }
}
