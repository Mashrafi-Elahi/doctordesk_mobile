import 'consultation_management_screen.dart';
import 'operator_desk_screen.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/doctor_claim_dialog.dart';
import '../widgets/user_avatar.dart';
import '../theme/app_constants.dart';
import '../theme/app_theme.dart';
import '../widgets/app_role_and_nav.dart';
import '../widgets/auth_modal.dart';
import '../widgets/first_time_checkin_dialog.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/app_language.dart';
import '../services/tts_service.dart';
import 'settings_screen.dart';
import 'admin_console_screen.dart';
import 'chamber_discovery_screen.dart';
import '../services/firestore_service.dart';
import '../services/chamber_resolver.dart';
import '../widgets/health_documents_widget.dart';

class ProfileScreen extends StatefulWidget {
  final UserRole role;
  final ValueChanged<UserRole>? onRoleChanged;
  final ValueChanged<int>? onTabSwitch;

  const ProfileScreen({
    super.key,
    this.role = UserRole.patient,
    this.onRoleChanged,
    this.onTabSwitch,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool get _isSignedIn => AuthService.isSignedIn;
  UserRoles _userRoles = AuthService.userRoles;
  Map<String, dynamic>? _userProfile;
  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _loadUserRoles();
    _authSubscription = AuthService.authStateChanges.listen((user) {
      if (!mounted) return;
      if (user == null) {
        setState(() {
          _userProfile = null;
          _userRoles = const UserRoles();
        });
      } else {
        _loadUserRoles();
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadUserRoles() async {
    final uid = AuthService.currentUser?.uid;
    if (uid != null) {
      _userProfile = await DataService.fetchUserProfile(uid);
    } else {
      _userProfile = null;
    }
    final roles = await AuthService.fetchUserRoles();
    if (mounted) {
      setState(() {
        _userRoles = roles;
      });
    }
  }

  Future<void> _showEditProfileDialog() async {
    final uid = AuthService.currentUser?.uid;
    if (uid == null) return;

    final firstNameCtrl =
        TextEditingController(text: _userProfile?['firstName'] ?? '');
    final lastNameCtrl =
        TextEditingController(text: _userProfile?['lastName'] ?? '');
    final usernameCtrl = TextEditingController(
      text: _userProfile?['username'] ??
          AuthService.currentUser?.displayName ??
          '',
    );
    final phoneCtrl = TextEditingController(
      text:
          _userProfile?['phone'] ?? AuthService.currentUser?.phoneNumber ?? '',
    );
    final designationCtrl =
        TextEditingController(text: _userProfile?['designation'] ?? '');
    final degreesCtrl =
        TextEditingController(text: _userProfile?['degrees'] ?? '');
    final bmdcCtrl =
        TextEditingController(text: _userProfile?['bmdcRegNumber'] ?? '');

    final isDoctorRole = _userRoles.isDoctor || widget.role == UserRole.doctor;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Profile Details',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: firstNameCtrl,
                decoration: const InputDecoration(
                    labelText: 'First Name',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: lastNameCtrl,
                decoration: const InputDecoration(
                    labelText: 'Last Name',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: usernameCtrl,
                decoration: const InputDecoration(
                    labelText: 'Username / Display Name',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                    labelText: 'Phone Number',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: designationCtrl,
                decoration: const InputDecoration(
                    labelText: 'Designation (e.g. Consultant / Patient)',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
              if (isDoctorRole) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: degreesCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Degrees (e.g. MBBS, FCPS)',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: bmdcCtrl,
                  decoration: const InputDecoration(
                      labelText: 'BMDC Registration ID',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save Details'),
          ),
        ],
      ),
    );

    if (saved == true && mounted) {
      try {
        final fName = firstNameCtrl.text.trim();
        final lName = lastNameCtrl.text.trim();
        final rawUName = usernameCtrl.text.trim();
        final fullName = '$fName $lName'.trim().isNotEmpty
            ? '$fName $lName'.trim()
            : (rawUName.isNotEmpty ? rawUName : 'User');

        String cleanUsername = rawUName;
        if (rawUName.isNotEmpty && rawUName != _userProfile?['username']) {
          final res = await FirestoreService.updateUsername(uid: uid, newUsername: rawUName);
          if (res['success'] != true) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(res['error'] ?? 'Username unavailable.'),
                  backgroundColor: AppColors.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            return;
          }
          cleanUsername = res['username'] ?? rawUName;
        }

        final updates = <String, dynamic>{
          'firstName': fName,
          'lastName': lName,
          if (cleanUsername.isNotEmpty) 'username': cleanUsername,
          'name': fullName,
          'phone': phoneCtrl.text.trim(),
          'designation': designationCtrl.text.trim(),
        };

        if (isDoctorRole) {
          updates['degrees'] = degreesCtrl.text.trim();
          updates['bmdcRegNumber'] = bmdcCtrl.text.trim();
        }

        await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .set(updates, SetOptions(merge: true));

        if (fullName.isNotEmpty) {
          await AuthService.currentUser?.updateDisplayName(fullName);
        }

        await _loadUserRoles();
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Profile details updated successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error updating profile: $e')));
        }
      }
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final passCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Password',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'New Password (min 6 chars)',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Confirm New Password',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (passCtrl.text.trim().length < 6) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('Password must be at least 6 characters.')));
                return;
              }
              if (passCtrl.text.trim() != confirmCtrl.text.trim()) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Passwords do not match.')));
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Update Password'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      try {
        await AuthService.currentUser?.updatePassword(passCtrl.text.trim());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Password updated successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Could not change password: ${e.toString().replaceAll("Exception:", "").trim()}')),
          );
        }
      }
    }
  }

  String _getRoleDisplayName() {
    if (!_isSignedIn) {
      return switch (widget.role) {
        UserRole.doctor => 'Doctor',
        UserRole.operator => 'Chamber Operator',
        UserRole.admin => 'Administrator',
        UserRole.patient => 'Guest Patient',
      };
    }
    final user = AuthService.currentUser;
    final profileName = _userProfile?['name']?.toString().trim();
    if (profileName != null && profileName.isNotEmpty) return profileName;
    if (user?.displayName != null && user!.displayName!.isNotEmpty) {
      return user.displayName!;
    }
    if (user?.email != null && user!.email!.isNotEmpty) {
      return user.email!.split('@').first;
    }
    return switch (widget.role) {
      UserRole.doctor => 'Doctor',
      UserRole.operator => 'Chamber Operator',
      UserRole.admin => 'Administrator',
      UserRole.patient => 'Guest Patient',
    };
  }

  String _getRoleSubtitle() {
    if (!_isSignedIn) {
      return 'Sign in to access your role-specific desk, chambers, and records';
    }
    return switch (widget.role) {
      UserRole.doctor => 'BMDC Verified Specialist • Active Doctor Account',
      UserRole.operator => 'Live Chamber Queue Desk • Active Operator Account',
      UserRole.admin => 'Backend Controller • Database & Server Operations',
      UserRole.patient =>
        tr('Medical records, mood journal, and appointments synced'),
    };
  }

  void _showAuthModal(BuildContext context, {bool isSignUp = false}) {
    showDoctorDeskAuthModal(
      context,
      isSignUp: isSignUp,
      onAuthenticated: () async {
        await _loadUserRoles();
        if (mounted) setState(() {});
        if (context.mounted) {
          await showFirstTimeCheckinDialog(context);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.role) {
      UserRole.doctor => 'Doctor Profile & Chambers',
      UserRole.operator => 'Chamber Desk Profile',
      UserRole.admin => 'Administrator Profile',
      UserRole.patient => 'Patient Profile',
    };

    final emailOrPhone = !_isSignedIn
        ? _getRoleSubtitle()
        : (AuthService.currentUser?.email?.isNotEmpty == true
            ? AuthService.currentUser!.email!
            : (AuthService.currentUser?.phoneNumber?.isNotEmpty == true
                ? AuthService.currentUser!.phoneNumber!
                : _getRoleSubtitle()));

    final List<_SettingsItem> settingsItems = [
      if (_isSignedIn) ...[
        _SettingsItem(
          icon: Icons.person_outline,
          title: 'Profile Details',
          onTap: _showEditProfileDialog,
        ),
        _SettingsItem(
          icon: Icons.lock_reset_outlined,
          title: 'Change Password',
          onTap: _showChangePasswordDialog,
        ),
      ],
      if (widget.role == UserRole.patient)
        _SettingsItem(
          icon: Icons.settings_outlined,
          title: 'Settings',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const SettingsScreen(role: UserRole.patient)),
          ),
        )
      else if (widget.role == UserRole.doctor)
        _SettingsItem(
          icon: Icons.tune_outlined,
          title: 'Practice Settings',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const SettingsScreen(role: UserRole.doctor)),
          ),
        )
      else if (widget.role == UserRole.operator)
        _SettingsItem(
          icon: Icons.desk_outlined,
          title: 'Desk Settings',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const SettingsScreen(role: UserRole.operator)),
          ),
        ),
      _SettingsItem(
        icon: Icons.store_mall_directory_outlined,
        title: 'Chambers Directory & Desk Discovery',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ChamberDiscoveryScreen()),
        ),
      ),
      _SettingsItem(
        icon: Icons.notifications_outlined,
        title: 'Notifications',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => SettingsScreen(
                    role: widget.role,
                    initialSection: 'notifications',
                  )),
        ),
      ),
      _SettingsItem(
        icon: Icons.language_outlined,
        title: 'Language',
        onTap: () => _pickLanguageDialog(context),
      ),
      _SettingsItem(
        icon: Icons.help_outline,
        title: 'Help & FAQ',
        onTap: () => _showHelpDialog(context),
      ),
      _SettingsItem(
        icon: Icons.shield_outlined,
        title: 'Terms & Privacy',
        onTap: () => _showTermsDialog(context),
      ),
      if (_userRoles.isDoctor)
        _SettingsItem(
          icon: Icons.video_call_outlined,
          title: 'Doctor Telehealth & Consultations',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ConsultationManagementScreen(
                isDoctor: true,
                doctorProfileId: _userProfile?['doctorProfileId'] as String?,
              ),
            ),
          ),
        ),
      _SettingsItem(
        icon: Icons.chat_outlined,
        title: 'My Online Consultations & Chats',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ConsultationManagementScreen(
              isDoctor: _userRoles.isDoctor,
              doctorProfileId: _userProfile?['doctorProfileId'] as String?,
            ),
          ),
        ),
      ),
      if (_userRoles.isAdmin)
        _SettingsItem(
          icon: Icons.admin_panel_settings_outlined,
          title: 'Admin Console & Database Control',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  AdminConsoleScreen(onRoleChanged: widget.onRoleChanged),
            ),
          ),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            const SizedBox(height: 8),
            // Top Hero
            Center(
              child: Column(
                children: [
                  const UserAvatar.me(radius: 48),
                  const SizedBox(height: 12),
                  Text(
                    _getRoleDisplayName(),
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600,
                      fontSize: 18,
                      color: AppColors.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Text(
                      emailOrPhone,
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (widget.role == UserRole.doctor) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.08),
                        borderRadius:
                            BorderRadius.circular(AppConstants.radiusChip),
                        border: Border.all(color: AppColors.success, width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle,
                              size: 16, color: AppColors.success),
                          const SizedBox(width: 6),
                          Text(
                            'BMDC & NID Verified Specialist',
                            style: GoogleFonts.poppins(
                              color: AppColors.success,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),

                  // Multi-role Switcher
                  if (_isSignedIn && _userRoles.hasMultipleRoles) ...[
                    RoleSwitcher(
                      roles: _userRoles,
                      current: widget.role,
                      onSwitch: (newRole) async {
                        if (!AuthService.isRoleGranted(newRole)) return;
                        await AuthService.saveRole(newRole);
                        widget.onRoleChanged?.call(newRole);
                        if (mounted) setState(() {});
                      },
                    ),
                    const SizedBox(height: 16),
                  ],

                  // If signed out: Auth Entry Buttons
                  if (!_isSignedIn) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: AuthEntryButtons(
                        onLogIn: () => _showAuthModal(context, isSignUp: false),
                        onSignUp: () => _showAuthModal(context, isSignUp: true),
                        onGoogleSignIn: () async {
                          try {
                            final cred = await AuthService.signInWithGoogle();
                            if (cred != null) {
                              await _loadUserRoles();
                              if (mounted) setState(() {});
                            }
                          } catch (e) {
                            if (context.mounted) {
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
                          widget.onRoleChanged?.call(UserRole.patient);
                          widget.onTabSwitch?.call(0);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Continuing as Guest Patient. You can search doctors and check symptoms freely.'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),

            // Role-specific section
            if (widget.role == UserRole.patient) ...[
              const HealthDocumentsWidget(),
              const SizedBox(height: 16),
              if (_isSignedIn && !_userRoles.isDoctor) ...[
                Card(
                  color: AppColors.surface,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppConstants.radiusCard),
                    side: const BorderSide(
                        color: AppColors.borderSubtle, width: 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppConstants.screenPadding),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                          child: Icon(Icons.medical_services_outlined,
                              color: Theme.of(context).colorScheme.primary, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Are you a Doctor?',
                                  style: AppTheme.cardTitle),
                              const SizedBox(height: 2),
                              Text(
                                  'Apply for BMDC verification & directory listing.',
                                  style: AppTheme.caption),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                  AppConstants.radiusButton),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            if (await showDoctorClaimDialog(context)) await _loadUserRoles();
                          },
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ] else if (widget.role == UserRole.doctor) ...[
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppConstants.radiusCard),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppConstants.screenPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Practice Overview', style: AppTheme.sectionTitle),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Chambers', style: AppTheme.caption),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_userRoles.chamberCount > 0 ? _userRoles.chamberCount : (_userProfile?['chamberCount'] ?? 1)}',
                                    style: GoogleFonts.poppins(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("Today's Patients",
                                      style: AppTheme.caption),
                                  const SizedBox(height: 4),
                                  Text(
                                    '0',
                                    style: GoogleFonts.poppins(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                  AppConstants.radiusButton),
                            ),
                          ),
                          onPressed: () {
                            widget.onTabSwitch?.call(2);
                          },
                          child: const Text('Manage Practice'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ] else if (widget.role == UserRole.operator) ...[
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppConstants.radiusCard),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppConstants.screenPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Assigned Chambers & Live Queues', style: AppTheme.sectionTitle),
                      const SizedBox(height: 6),
                      Text(
                        'Live waiting counts for today across all your assigned desks.',
                        style: AppTheme.caption,
                      ),
                      const SizedBox(height: 14),
                      const _OperatorDeskSummary(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Settings List Card
            _buildSettingsGroup(settingsItems),

            // Log Out Button
            if (_isSignedIn) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error, width: 1),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppConstants.radiusButton),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.logout, size: 18),
                  label: Text(
                    'Log Out',
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.error,
                    ),
                  ),
                  onPressed: () async {
                    await AuthService.signOut();
                    widget.onRoleChanged?.call(UserRole.patient);
                    if (context.mounted) {
                      setState(() {
                        _userRoles = const UserRoles();
                        _userProfile = null;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content:
                              Text('Logged out. You are now browsing as guest.'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsGroup(List<_SettingsItem> items) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppConstants.radiusCard),
        boxShadow: AppConstants.softShadow,
      ),
      child: Column(
        children: items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          final isLast = index == items.length - 1;

          return Column(
            children: [
              Material(
                color: Colors.transparent,
                child: ListTile(
                  leading: Icon(item.icon, color: Theme.of(context).colorScheme.primary, size: 22),
                  title: Text(
                    item.title,
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      size: 20, color: AppColors.textSecondary),
                  onTap: item.onTap,
                ),
              ),
              if (!isLast)
                Divider(
                  height: 1,
                  indent: 56,
                  endIndent: 16,
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  void _pickLanguageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose Language'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              AppLanguage.setLanguage('English');
              TtsService.instance.setLocale('en');
              Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('English (US)'),
          ),
          SimpleDialogOption(
            onPressed: () {
              AppLanguage.setLanguage('Bengali');
              TtsService.instance.setLocale('bn');
              Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('বাংলা (Bengali)'),
          ),
        ],
      ),
    );
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help & FAQ'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'How do I find a doctor?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 4),
              Text(
                'Use the search bar on Home to search by name or enter symptoms to automatically find the right specialist.',
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 12),
              Text(
                'What is Read Aloud mode?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 4),
              Text(
                'When enabled in Accessibility settings, tapping an item reads it aloud, and double-tapping opens it.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _showTermsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Terms & Privacy'),
        content: const Text(
          'DoctorDesk provides verified doctor discovery, chamber queue management, and health records synchronization.\n\nMedical recommendations are algorithmic guides and do not replace professional medical diagnosis.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }
}

class _SettingsItem {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _SettingsItem({
    required this.icon,
    required this.title,
    required this.onTap,
  });
}

/// The operator's desks, from chamber_operators (the same source the Desk tab
/// uses), with the chamber's current name. The old users.operatorAssignments
/// list kept showing chambers after the operator left them.
class _OperatorDeskSummary extends StatelessWidget {
  const _OperatorDeskSummary();

  @override
  Widget build(BuildContext context) {
    final uid = AuthService.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('chamber_operators')
          .where('operatorUid', isEqualTo: uid)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const LinearProgressIndicator(minHeight: 2);
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const Text(
            'No chambers assigned. A doctor assigns you to their desk from their Manage tab.',
            style: TextStyle(fontSize: 12.5),
          );
        }
        return Column(
          children: [
            for (final d in docs)
              FutureBuilder<String>(
                future: ChamberResolver.resolveChamberName(
                  chamberId: (d.data()['chamberId'] ?? '').toString(),
                  doctorId: d.data()['doctorId']?.toString(),
                ),
                builder: (context, name) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.business_outlined),
                  title: Text(name.data ?? (d.data()['chamberName'] ?? 'Chamber').toString()),
                  subtitle: Text((d.data()['doctorName'] ?? 'Doctor').toString()),
                  trailing: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const OperatorDeskScreen()),
                    ),
                    child: const Text('Open desk'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
