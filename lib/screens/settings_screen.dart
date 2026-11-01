import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/user_avatar.dart';
import '../models/doctor.dart';
import '../models/user_role.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/tts_service.dart';
import '../theme/app_constants.dart';
import '../widgets/auth_modal.dart';
import '../services/app_language.dart';
import '../widgets/read_aloud_setting_tile.dart';

class SettingsScreen extends StatefulWidget {
  final UserRole role;
  final String? initialSection;

  const SettingsScreen({
    super.key,
    this.role = UserRole.patient,
    this.initialSection,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;
  bool _dailyMoodReminder = true;
  bool _queueSoundAlerts = true;
  bool _autoConfirmAppointments = false;
  String _language = 'English';
  String _consultationSlot = '20 mins';
  Future<Doctor?>? _doctorFuture;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    final doctorId = AuthService.userRoles.doctorProfileId;
    if (widget.role == UserRole.doctor &&
        doctorId != null &&
        doctorId.isNotEmpty) {
      _doctorFuture = DataService.fetchDoctorById(doctorId)
          .then<Doctor?>((d) => d)
          .catchError((_) => null);
    }
  }

  static bool _isVerified(Doctor? d) =>
      d != null &&
      (d.isBmdcVerified ||
          d.verificationStatus == 'verified' ||
          d.verificationStatus == 'checked_found');

  static String _bmdcOf(Doctor? d) {
    final reg = d?.bmdcRegNumber ?? d?.bmdcNumber;
    return (reg == null || reg.trim().isEmpty) ? 'Not provided' : reg;
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _notificationsEnabled = prefs.getBool('setting_notifications') ?? true;
        _dailyMoodReminder = prefs.getBool('setting_mood_reminder') ?? true;
        _queueSoundAlerts = prefs.getBool('setting_queue_sounds') ?? true;
        _autoConfirmAppointments =
            prefs.getBool('setting_auto_confirm') ?? false;
        _language = prefs.getString('setting_language') ?? 'English';
        _consultationSlot = prefs.getString('setting_slot') ?? '20 mins';
      });
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _saveString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Widget build(BuildContext context) {
    final isSignedIn = AuthService.isSignedIn;

    final title = switch (widget.role) {
      UserRole.doctor => 'Practice Settings',
      UserRole.operator => 'Chamber Desk Settings',
      UserRole.admin => 'Admin Settings',
      UserRole.patient => 'Settings',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
          children: [
          // Account Status Card
          Card(
            elevation: 0.5,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const UserAvatar.me(radius: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isSignedIn
                              ? (AuthService.currentUser?.displayName ??
                                  'Active Account')
                              : 'Guest Patient Mode',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isSignedIn
                              ? (AuthService.currentUser?.email ?? 'Logged In')
                              : 'Limited offline session • Sign in to sync data',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  if (!isSignedIn)
                    TextButton(
                      onPressed: () {
                        showDoctorDeskAuthModal(
                          context,
                          onAuthenticated: () async {
                            if (mounted) setState(() {});
                          },
                        );
                      },
                      child: const Text('Sign In'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Role-specific sections
          if (widget.role == UserRole.doctor) ...[
            _buildSectionHeader('DOCTOR & PRACTICE VERIFICATION'),
            Card(
              child: Column(
                children: [
                  FutureBuilder<Doctor?>(
                    future: _doctorFuture,
                    builder: (context, snap) {
                      final doctor = snap.data;
                      final loading =
                          snap.connectionState == ConnectionState.waiting;
                      final verified = _isVerified(doctor);
                      return ListTile(
                        leading: Icon(
                            verified ? Icons.verified : Icons.pending_outlined,
                            color: verified
                                ? AppColors.success
                                : AppColors.textSecondary),
                        title: const Text('BMDC Verification Status'),
                        subtitle: Text(loading
                            ? 'Loading…'
                            : doctor == null
                                ? 'No linked doctor profile'
                                : 'BMDC Reg: ${_bmdcOf(doctor)}'),
                        trailing: loading
                            ? null
                            : Chip(
                                label: Text(verified ? 'VERIFIED' : 'PENDING',
                                    style: const TextStyle(
                                        fontSize: 10, color: Colors.white)),
                                backgroundColor: verified
                                    ? AppColors.success
                                    : AppColors.textSecondary,
                                visualDensity: VisualDensity.compact,
                              ),
                        onTap: doctor == null
                            ? null
                            : () => _showBmdcDetailsDialog(context, doctor),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: const Text('Default Consultation Slot'),
                    subtitle: Text(_consultationSlot),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickSlotDialog(context),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.rule_folder_outlined),
                    title: const Text('Auto-confirm Patient Bookings'),
                    subtitle: const Text(
                        'Accept bookings directly into schedule queue'),
                    value: _autoConfirmAppointments,
                    onChanged: (val) {
                      setState(() => _autoConfirmAppointments = val);
                      _saveBool('setting_auto_confirm', val);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (widget.role == UserRole.operator) ...[
            _buildSectionHeader('OPERATOR DESK PREFERENCES'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.volume_up_outlined),
                    title: const Text('Queue Call & Bell Sound'),
                    subtitle: const Text(
                        'Audio chime when calling next patient token'),
                    value: _queueSoundAlerts,
                    onChanged: (val) {
                      setState(() => _queueSoundAlerts = val);
                      _saveBool('setting_queue_sounds', val);
                    },
                  ),
                  const Divider(height: 1),
                  const ListTile(
                    leading: Icon(Icons.meeting_room_outlined),
                    title: Text('Desk Station'),
                    subtitle: Text('Popular Diagnostic Desk 01 (Central)'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // General Notifications
          _buildSectionHeader('NOTIFICATIONS & ALERTS'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Push Notifications'),
                  subtitle: const Text(
                      'Receive appointment and serial queue updates'),
                  value: _notificationsEnabled,
                  onChanged: (val) {
                    setState(() => _notificationsEnabled = val);
                    _saveBool('setting_notifications', val);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.spa_outlined),
                  title: const Text('Daily Health & Mood Check-in'),
                  subtitle: const Text(
                      'Gentle daily reminder to record your wellness streak'),
                  value: _dailyMoodReminder,
                  onChanged: (val) {
                    setState(() => _dailyMoodReminder = val);
                    _saveBool('setting_mood_reminder', val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Accessibility Section
          _buildSectionHeader('ACCESSIBILITY'),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppConstants.radiusCard),
            ),
            child: const ReadAloudSettingTile(),
          ),
          const SizedBox(height: 16),

          // Preferences & Localization
          _buildSectionHeader('PREFERENCES'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.language_outlined),
                  title: Text(tr('Language')),
                  subtitle: Text(_language == 'English'
                      ? 'English (US)'
                      : 'বাংলা (Bengali)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickLanguageDialog(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('Clear Local Health Cache'),
                  subtitle: const Text('Reset offline search and mood cache'),
                  onTap: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('hasSeenOnboarding');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Local cache cleared successfully.'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // About & Legal
          _buildSectionHeader('ABOUT DOCDESK'),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('App Version'),
                  subtitle:
                      Text('DocDesk v1.0.4 • Bangladesh Healthcare Network'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Privacy & Medical Disclaimer'),
                  subtitle: const Text(
                      'Health recommendations are smart AI and clinical guides'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Medical Disclaimer'),
                        content: const Text(
                          'DocDesk provides verified doctor directory discovery, chamber queue management, and smart specialty recommendations.\n\nInformation provided in the app is not a substitute for formal clinical diagnosis. Always consult certified medical practitioners for emergencies.',
                          style: TextStyle(fontSize: 13, height: 1.4),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Understood'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: GoogleFonts.poppins(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  void _showBmdcDetailsDialog(BuildContext context, Doctor doctor) {
    final verified = _isVerified(doctor);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(verified ? Icons.verified : Icons.pending_outlined,
                color: verified ? AppColors.success : AppColors.textSecondary),
            const SizedBox(width: 8),
            const Text('BMDC Verification'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Doctor Name: ${doctor.name}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('BMDC Registration: ${_bmdcOf(doctor)}'),
            if (doctor.education.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Qualification: ${doctor.education.join(', ')}'),
            ],
            const SizedBox(height: 4),
            Text('Status: ${verified ? 'Verified by admin review' : 'Awaiting admin review'}'),
            const SizedBox(height: 8),
            Text(
              verified
                  ? 'Your profile shows the verified badge in directory search and on appointments.'
                  : 'The verified badge appears once an admin checks your registration against the BM&DC register.',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _pickSlotDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Consultation Duration'),
        children: ['15 mins', '20 mins', '30 mins', '45 mins'].map((slot) {
          return SimpleDialogOption(
            onPressed: () {
              setState(() => _consultationSlot = slot);
              _saveString('setting_slot', slot);
              Navigator.pop(ctx);
            },
            child: Text(slot),
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
              setState(() => _language = 'English');
              AppLanguage.setLanguage('English');
              TtsService.instance.setLocale('en');
              Navigator.pop(ctx);
            },
            child: const Text('English (US)'),
          ),
          SimpleDialogOption(
            onPressed: () {
              setState(() => _language = 'Bengali');
              AppLanguage.setLanguage('Bengali');
              TtsService.instance.setLocale('bn');
              Navigator.pop(ctx);
            },
            child: const Text('বাংলা (Bengali)'),
          ),
        ],
      ),
    );
  }
}
