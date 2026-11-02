import 'dart:async';

import '../services/role_switch.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_constants.dart';
import '../theme/app_theme.dart';
import '../widgets/app_role_and_nav.dart';
import '../widgets/auth_modal.dart';
import '../widgets/first_time_checkin_dialog.dart';
import '../services/auth_service.dart';
import '../services/app_language.dart';
import 'home_screen.dart';
import 'feed_screen.dart';
import 'appointment_screen.dart';
import 'doctor_manager_screen.dart';
import 'operator_desk_screen.dart';
import 'inbox_screen.dart';
import 'profile_screen.dart';
import 'admin_console_screen.dart';
import '../widgets/app_drawer.dart';

class MainShell extends StatefulWidget {
  final UserRole initialRole;

  const MainShell({
    super.key,
    this.initialRole = UserRole.patient,
  });

  @override
  State<MainShell> createState() => MainShellState();
}

class MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  late UserRole _currentRole;
  UserRoles _userRoles = const UserRoles();
  StreamSubscription<User?>? _authSubscription;
  bool _showedVerificationNotice = false;
  String? _rolesUid;
  bool _rolesLoaded = false;

  @override
  void initState() {
    super.initState();
    _currentRole = widget.initialRole;
    RoleSwitch.current.value = _currentRole;
    RoleSwitch.attach(setRole);
    _refreshRoles();
    _authSubscription = AuthService.authStateChanges.listen((_) {
      _refreshRoles();
      _showEmailVerificationNotice();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AuthService.isSignedIn && !AuthService.isGuest) {
        _showInitialAuthPrompt();
      }
    });
  }

  void _showEmailVerificationNotice() {
    if (_showedVerificationNotice || !AuthService.needsEmailVerification) {
      return;
    }
    _showedVerificationNotice = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Verify your email address to secure your DoctorDesk account.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  Future<void> _refreshRoles() async {
    final roles = await AuthService.fetchUserRoles();
    // Startup may have fallen back to patient before roles arrived; the
    // first load restores the portal the user last chose.
    final lastChosen = _rolesLoaded ? null : await AuthService.lastChosenRole();
    if (mounted) {
      // A different account signing in starts in its own main portal instead
      // of inheriting the previous account's role.
      final uid = AuthService.currentUser?.uid;
      final sameUser = !_rolesLoaded || _rolesUid == uid;
      _rolesUid = uid;
      _rolesLoaded = true;
      setState(() {
        _userRoles = roles;
        _currentRole = sameUser
            ? _roleFor(roles, preferred: lastChosen ?? _currentRole)
            : _roleFor(roles, preferred: null);
      });
      RoleThemeController.setRole(_currentRole);
      RoleSwitch.current.value = _currentRole;
      if (!sameUser && uid != null) AuthService.saveRole(_currentRole);
    }
  }

  UserRole _roleFor(UserRoles roles, {required UserRole? preferred}) {
    final available = <UserRole>[
      UserRole.patient,
      if (roles.isDoctor) UserRole.doctor,
      if (roles.isOperator) UserRole.operator,
      if (roles.isAdmin) UserRole.admin,
    ];
    if (preferred != null && available.contains(preferred)) {
      return preferred;
    }
    if (roles.isAdmin) return UserRole.admin;
    if (roles.isDoctor) return UserRole.doctor;
    if (roles.isOperator) return UserRole.operator;
    return UserRole.patient;
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    RoleSwitch.detach();
    super.dispose();
  }

  void setRole(UserRole role) {
    if (!AuthService.isRoleGranted(role)) return;
    setState(() {
      _currentRole = role;
      _userRoles = AuthService.userRoles;
      // If the middle tab becomes hidden and was selected, switch to Home
      if (!AppBottomNavConfig.showThirdTab(_currentRole, _userRoles) &&
          _currentIndex == 2) {
        _currentIndex = 0;
      }
    });
    RoleThemeController.setRole(role);
    RoleSwitch.current.value = role;
    AuthService.saveRole(role);
  }

  void switchToTab(int index, {String? searchQuery}) {
    setState(() {
      _currentIndex = index;
    });
  }

  void _showInitialAuthPrompt() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: Colors.white,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Cancel / Close button at top right
                  Align(
                    alignment: Alignment.topRight,
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                  Center(
                    child: Image.asset(
                      'assets/images/logo.png',
                      height: 64,
                      width: 64,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      semanticLabel: 'DoctorDesk logo',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Welcome to DoctorDesk',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Sign in to access your role-specific desk, chambers, and health records, or continue as a guest.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.grey[600], fontSize: 13, height: 1.35),
                  ),
                  const SizedBox(height: 18),
                  AuthEntryButtons(
                    onLogIn: () {
                      Navigator.pop(ctx);
                      _showAuthModal(isSignUp: false);
                    },
                    onSignUp: () {
                      Navigator.pop(ctx);
                      _showAuthModal(isSignUp: true);
                    },
                    onGoogleSignIn: () async {
                      try {
                        final cred = await AuthService.signInWithGoogle();
                        if (cred != null) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          await _refreshRoles();
                          if (mounted) {
                            setState(() {});
                            await showFirstTimeCheckinDialog(context);
                          }
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Google Sign-in failed: ${e.toString().replaceAll("Exception:", "").trim()}'),
                            ),
                          );
                        }
                      }
                    },
                    onContinueAsGuest: () async {
                      await AuthService.setGuestMode(true);
                      if (ctx.mounted) Navigator.pop(ctx);
                      setRole(UserRole.patient);
                      switchToTab(0);
                      if (mounted) {
                        setState(() {});
                        await showFirstTimeCheckinDialog(context);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showAuthModal({bool isSignUp = false}) {
    showDoctorDeskAuthModal(
      context,
      isSignUp: isSignUp,
      onAuthenticated: () async {
        await _refreshRoles();
        if (mounted) {
          setState(() {});
          await showFirstTimeCheckinDialog(context);
        }
      },
    );
  }

  Widget _getMiddleScreen() => switch (_currentRole) {
        AppRole.patient => const AppointmentScreen(),
        AppRole.doctor => const DoctorManagerScreen(),
        AppRole.operator => const OperatorDeskScreen(),
        AppRole.admin => AdminConsoleScreen(onRoleChanged: setRole),
      };

  @override
  Widget build(BuildContext context) {
    final showThirdTab =
        AppBottomNavConfig.showThirdTab(_currentRole, _userRoles);

    // Build the dynamic pages and navigation destinations list
    final List<Widget> pages = [
      HomeScreen(role: _currentRole, onTabSwitch: switchToTab),
      const FeedScreen(),
      if (showThirdTab) _getMiddleScreen(),
      const InboxScreen(),
      ProfileScreen(
        role: _currentRole,
        onRoleChanged: setRole,
        onTabSwitch: switchToTab,
      ),
    ];

    // Ensure selected index is clamped within bounds
    final selectedIndex = _currentIndex.clamp(0, pages.length - 1);

    final List<_NavItem> navItems = [
      _NavItem(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: tr('Home'),
      ),
      _NavItem(
        icon: Icons.dynamic_feed_outlined,
        selectedIcon: Icons.dynamic_feed,
        label: tr('Feed'),
      ),
      if (showThirdTab)
        _NavItem(
          icon: AppBottomNavConfig.thirdTabIcon(_currentRole),
          selectedIcon:
              AppBottomNavConfig.thirdTabSelectedIcon(_currentRole),
          label: AppBottomNavConfig.thirdTabLabel(_currentRole),
        ),
      _NavItem(
        icon: Icons.chat_bubble_outline,
        selectedIcon: Icons.chat_bubble,
        label: tr('Inbox'),
      ),
      _NavItem(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: tr('Profile'),
      ),
    ];

    final currentTheme = AppTheme.themeForRole(_currentRole);

    return Theme(
      data: currentTheme,
      child: Scaffold(
      drawer: AppDrawer(
        currentRole: _currentRole,
        onRoleChanged: setRole,
      ),
      body: IndexedStack(
        index: selectedIndex,
        children: pages,
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
          decoration: BoxDecoration(
            color: currentTheme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppConstants.radiusHero),
            boxShadow: AppConstants.softShadow,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: navItems.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              final isSelected = index == selectedIndex;

              return Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      setState(() {
                        _currentIndex = index;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isSelected ? item.selectedIcon : item.icon,
                            size: 22,
                            color: isSelected
                                ? currentTheme.colorScheme.primary
                                : AppColors.textNav,
                          ),
                          const SizedBox(height: 3),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              item.label,
                              maxLines: 1,
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: isSelected
                                    ? currentTheme.colorScheme.primary
                                    : AppColors.textNav,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}
