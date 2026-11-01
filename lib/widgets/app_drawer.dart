import 'package:flutter/material.dart';
import 'user_avatar.dart';
import '../models/user_role.dart';
import '../services/auth_service.dart';
import '../screens/settings_screen.dart';
import '../screens/profile_screen.dart';

class AppDrawer extends StatelessWidget {
  final UserRole currentRole;
  final ValueChanged<UserRole>? onRoleChanged;

  const AppDrawer({
    super.key,
    this.currentRole = UserRole.patient,
    this.onRoleChanged,
  });

  String _getDisplayName() {
    final user = AuthService.currentUser;
    if (user?.displayName != null && user!.displayName!.isNotEmpty) {
      return user.displayName!;
    }
    switch (currentRole) {
      case UserRole.doctor:
        return 'Dr. Rafiqul Islam';
      case UserRole.operator:
        return 'Popular Diagnostic Desk';
      case UserRole.admin:
        return 'System Administrator';
      case UserRole.patient:
        return AuthService.isSignedIn ? 'Demo Patient' : 'DocDesk Guest';
    }
  }

  String _getEmailOrSubtitle() {
    final user = AuthService.currentUser;
    if (user?.email != null && user!.email!.isNotEmpty) {
      return user.email!;
    }
    switch (currentRole) {
      case UserRole.doctor:
        return 'Active Doctor • BMDC Verified';
      case UserRole.operator:
        return 'Chamber Desk Operator';
      case UserRole.admin:
        return 'Admin • Backend Controller';
      case UserRole.patient:
        return AuthService.isSignedIn ? 'Patient Account' : 'Guest Account';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayName = _getDisplayName();
    final emailOrSubtitle = _getEmailOrSubtitle();

    return Drawer(
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            decoration: BoxDecoration(
              color: colorScheme.primary,
            ),
            accountName: Text(
              displayName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            accountEmail: Text(emailOrSubtitle),
            otherAccountsPictures: [
              CircleAvatar(
                backgroundColor: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Image.asset('assets/images/logo.png'),
                ),
              ),
            ],
            currentAccountPicture: const UserAvatar.me(radius: 36, ring: true),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Home'),
            onTap: () {
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Account & Roles'),
            subtitle: Text('Current: ${currentRole.name.toUpperCase()}'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(
                    role: currentRole,
                    onRoleChanged: onRoleChanged,
                  ),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(role: currentRole),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Help & Support'),
            onTap: () {
              Navigator.pop(context);
            },
          ),
          const Spacer(),
          if (AuthService.isSignedIn) ...[
            const Divider(),
            ListTile(
              leading: Icon(Icons.logout, color: colorScheme.error),
              title: Text('Sign Out', style: TextStyle(color: colorScheme.error)),
              onTap: () async {
                Navigator.pop(context);
                await AuthService.signOut();
                onRoleChanged?.call(UserRole.patient);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Signed out successfully')),
                  );
                }
              },
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
