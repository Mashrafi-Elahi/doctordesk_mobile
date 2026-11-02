import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'models/user_role.dart';
import 'services/auth_service.dart';
import 'services/specialty_matcher.dart';
import 'services/app_language.dart';
import 'screens/onboarding_screen.dart';
import 'screens/main_shell.dart';
import 'theme/app_theme.dart';

import 'package:flutter/rendering.dart';
import 'services/tts_service.dart';
import 'services/notification_service.dart';
import 'screens/notifications_screen.dart';

/// Lets notification popups navigate without a widget context.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Runs alongside Firebase start-up instead of before it.
  final specialties = SpecialtyMatcher.load();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase init error: $e');
  }

  await AuthService.loadGuestMode();
  // On a cold start the signed-in user can arrive a moment after init; read
  // the saved portal only once it is known.
  await AuthService.authStateChanges.first
      .timeout(const Duration(seconds: 2), onTimeout: () => null);
  // Cached roles open the app at once and refresh in the background; only a
  // first launch waits on the network, and never more than 4 seconds.
  if (await AuthService.loadCachedRoles()) {
    unawaited(AuthService.fetchUserRoles());
  } else {
    await AuthService.fetchUserRoles()
        .timeout(const Duration(seconds: 4), onTimeout: () => AuthService.userRoles);
  }
  await AppLanguage.load();
  await specialties;

  final prefs = await SharedPreferences.getInstance();
  final bool hasSeenOnboarding = prefs.getBool('hasSeenOnboarding') ?? false;
  final UserRole initialRole = await AuthService.getSavedRole();
  RoleThemeController.setRole(initialRole);

  runApp(MyApp(
    hasSeenOnboarding: hasSeenOnboarding,
    initialRole: initialRole,
  ));
  // Not needed for the first frame.
  unawaited(TtsService.instance.init());
  unawaited(NotificationService.initPopups(onTap: _openNotificationPopup));
}

Future<void> _openNotificationPopup(AppNotification notification) async {
  // Don't wait on Firestore here: offline, the update only completes once it
  // reaches the server, and the tap should navigate straight away.
  unawaited(
      NotificationService.markAsRead(notification.id, notification.userId));
  final context = appNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  final opened = await openNotificationTarget(context, notification);
  if (!opened && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
    );
  }
}

class TtsNavigationObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    TtsService.instance.stop();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    TtsService.instance.stop();
  }
}

class MyApp extends StatelessWidget {
  final bool hasSeenOnboarding;
  final UserRole initialRole;

  const MyApp({
    super.key,
    required this.hasSeenOnboarding,
    this.initialRole = UserRole.patient,
  });

  @override
  Widget build(BuildContext context) {
    // App-level theme follows the active role so dialogs, bottom sheets and
    // pushed screens use the same colours as the shell.
    return ValueListenableBuilder<UserRole>(
      valueListenable: RoleThemeController.activeRole,
      builder: (context, role, _) => _buildApp(AppTheme.themeForRole(role)),
    );
  }

  Widget _buildApp(ThemeData theme) {
    return MaterialApp(
      title: 'DocDesk',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: theme,
      locale: Locale(AppLanguage.code.value),
      supportedLocales: const [Locale('en'), Locale('bn')],
      navigatorObservers: [TtsNavigationObserver()],
      builder: (context, child) {
        return ValueListenableBuilder<bool>(
          valueListenable: TtsService.instance.isReadAloudEnabled,
          builder: (context, isReadAloud, _) {
            if (!isReadAloud) return child ?? const SizedBox.shrink();
            return _ReadAloudGestureWrapper(child: child ?? const SizedBox.shrink());
          },
        );
      },
      home: ValueListenableBuilder<String>(
        valueListenable: AppLanguage.code,
        builder: (_, __, ___) => hasSeenOnboarding
            ? MainShell(initialRole: initialRole)
            : const OnboardingScreen(),
      ),
    );
  }
}

class _ReadAloudGestureWrapper extends StatefulWidget {
  final Widget child;
  const _ReadAloudGestureWrapper({required this.child});

  @override
  State<_ReadAloudGestureWrapper> createState() => _ReadAloudGestureWrapperState();
}

class _ReadAloudGestureWrapperState extends State<_ReadAloudGestureWrapper> {
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  void _handleTap(PointerDownEvent event) {
    final now = DateTime.now();
    final isDoubleTap = _lastTapTime != null &&
        now.difference(_lastTapTime!).inMilliseconds < 350 &&
        _lastTapPosition != null &&
        (event.position - _lastTapPosition!).distance < 40;

    _lastTapTime = now;
    _lastTapPosition = event.position;

    if (!isDoubleTap) {
      // Single tap: Read aloud target element's semantics label or text
      final text = _findTextAt(event.position);
      if (text != null && text.isNotEmpty) {
        TtsService.instance.speak(text);
      }
    }
  }

  String? _findTextAt(Offset globalPosition) {
    try {
      final hitTestResult = HitTestResult();
      WidgetsBinding.instance.hitTestInView(hitTestResult, globalPosition, View.of(context).viewId);
      for (final entry in hitTestResult.path) {
        final target = entry.target;
        if (target is RenderParagraph) {
          final text = target.text.toPlainText().trim();
          if (text.isNotEmpty) return text;
        }
        if (target is RenderObject) {
          final semantics = target.debugSemantics;
          if (semantics != null) {
            if (semantics.label.trim().isNotEmpty) return semantics.label.trim();
            if (semantics.value.trim().isNotEmpty) return semantics.value.trim();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleTap,
      child: widget.child,
    );
  }
}
