import 'package:flutter/material.dart';
import 'user_avatar.dart';
import '../models/user_role.dart';
import '../screens/profile_screen.dart';

class ProfileAvatarButton extends StatelessWidget {
  final UserRole role;

  const ProfileAvatarButton({
    super.key,
    this.role = UserRole.patient,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: IconButton(
        tooltip: 'Profile',
        icon: const UserAvatar.me(radius: 16, ring: true),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ProfileScreen(role: role),
            ),
          );
        },
      ),
    );
  }
}
