import 'package:flutter/material.dart';
import 'user_avatar.dart';
import '../models/user_role.dart';
import '../services/auth_service.dart';
import '../services/role_switch.dart';
import '../screens/profile_screen.dart';

/// Top-bar avatar. With more than one portal it opens a quick switcher
/// (like switching between a page and your profile); otherwise it opens
/// the profile.
class ProfileAvatarButton extends StatelessWidget {
  final UserRole role;

  const ProfileAvatarButton({
    super.key,
    this.role = UserRole.patient,
  });

  static String _label(UserRole r) => switch (r) {
        UserRole.patient => 'Patient',
        UserRole.doctor => 'Doctor',
        UserRole.operator => 'Chamber desk',
        UserRole.admin => 'Admin',
      };

  static IconData _icon(UserRole r) => switch (r) {
        UserRole.patient => Icons.person_outline,
        UserRole.doctor => Icons.medical_services_outlined,
        UserRole.operator => Icons.storefront_outlined,
        UserRole.admin => Icons.admin_panel_settings_outlined,
      };

  void _openProfile(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(role: RoleSwitch.current.value)),
    );
  }

  Future<void> _openSwitcher(BuildContext context) async {
    final roles = AuthService.userRoles.availableRoles;
    final current = RoleSwitch.current.value;
    final picked = await showModalBottomSheet<UserRole?>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Switch portal', style: TextStyle(fontWeight: FontWeight.w700))),
            for (final r in roles)
              ListTile(
                leading: Icon(_icon(r)),
                title: Text(_label(r)),
                trailing: r == current ? const Icon(Icons.check_circle, color: Colors.green) : null,
                onTap: () => Navigator.pop(sheet, r),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const UserAvatar.me(radius: 14),
              title: const Text('View profile'),
              onTap: () {
                Navigator.pop(sheet);
                _openProfile(context);
              },
            ),
          ],
        ),
      ),
    );
    if (picked != null && picked != current && context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      RoleSwitch.to(picked);
    }
  }

  /// Opens the switcher (several portals) or the profile (one portal).
  static void openFor(BuildContext context) {
    const button = ProfileAvatarButton();
    AuthService.userRoles.hasMultipleRoles
        ? button._openSwitcher(context)
        : button._openProfile(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: IconButton(
        tooltip: 'Switch portal or open profile',
        icon: const UserAvatar.me(radius: 16, ring: true),
        onPressed: () => AuthService.userRoles.hasMultipleRoles
            ? _openSwitcher(context)
            : _openProfile(context),
      ),
    );
  }
}
