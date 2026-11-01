import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/auth_service.dart';

/// One avatar for every person in the app.
///
/// Shows the person's Google profile photo when there is one (Firebase Auth
/// `photoURL` for the signed-in user, `users/{uid}.photoUrl` for everyone
/// else), otherwise their initials on the role tint.
class UserAvatar extends StatelessWidget {
  final String? uid;
  final String? name;
  final String? photoUrl;
  final double radius;

  /// Draws a thin ring so the avatar separates from a coloured header.
  final bool ring;
  final bool _isMe;

  const UserAvatar({
    super.key,
    this.uid,
    this.name,
    this.photoUrl,
    this.radius = 20,
    this.ring = false,
  }) : _isMe = false;

  /// The signed-in user.
  const UserAvatar.me({super.key, this.radius = 20, this.ring = false})
      : uid = null,
        name = null,
        photoUrl = null,
        _isMe = true;

  @override
  Widget build(BuildContext context) {
    if (!_isMe) return _build(context, null);
    // Rebuild when the signed-in account (or its photo/name) changes; the
    // widget is usually const, so a parent rebuild alone won't refresh it.
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.userChanges(),
      initialData: AuthService.currentUser,
      builder: (context, snap) => _build(context, snap.data),
    );
  }

  Widget _build(BuildContext context, User? user) {
    final displayName = _isMe ? (user?.displayName ?? user?.email) : name;
    final resolvedUid = _isMe ? user?.uid : uid;
    final direct = _isMe ? user?.photoURL : photoUrl;

    if (direct != null && direct.trim().isNotEmpty) {
      return _circle(context, direct, displayName);
    }
    if (resolvedUid == null || resolvedUid.isEmpty) {
      return _circle(context, null, displayName);
    }
    return FutureBuilder<String?>(
      future: UserPhotoCache.photoFor(resolvedUid),
      builder: (context, snap) => _circle(context, snap.data, displayName),
    );
  }

  Widget _circle(BuildContext context, String? url, String? displayName) {
    final colors = Theme.of(context).colorScheme;
    final initials = _initials(displayName);
    final hasUrl = url != null && url.trim().isNotEmpty;

    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: colors.primaryContainer,
      foregroundImage: hasUrl ? NetworkImage(_sized(url, radius)) : null,
      // Keeps the initials visible if the photo fails to load.
      onForegroundImageError: hasUrl ? (_, __) {} : null,
      child: initials.isEmpty
          ? Icon(Icons.person_outline,
              size: radius, color: colors.onPrimaryContainer)
          : Text(
              initials,
              style: GoogleFonts.poppins(
                fontSize: radius * 0.72,
                fontWeight: FontWeight.w600,
                color: colors.onPrimaryContainer,
              ),
            ),
    );

    final labelled = Semantics(
      label: displayName == null ? 'Profile picture' : '$displayName profile picture',
      image: true,
      child: avatar,
    );
    if (!ring) return labelled;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: labelled,
    );
  }

  static String _initials(String? raw) {
    if (raw == null) return '';
    final cleaned = raw
        .split('@')
        .first
        .replaceAll(RegExp(r'^(dr\.?|prof\.?|asst\.?|assoc\.?)\s+', caseSensitive: false), '')
        .trim();
    final parts = cleaned.split(RegExp(r'[\s._-]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  /// Google photo URLs end in `=s96-c`; ask for a size that stays sharp.
  static String _sized(String url, double radius) {
    if (!url.contains('googleusercontent.com')) return url;
    final px = (radius * 2 * 3).clamp(64, 400).round();
    if (RegExp(r'=s\d+(-c)?$').hasMatch(url)) {
      return url.replaceFirst(RegExp(r'=s\d+(-c)?$'), '=s$px-c');
    }
    return url;
  }
}

/// Looks up `users/{uid}.photoUrl` once per uid per session.
class UserPhotoCache {
  UserPhotoCache._();

  static final Map<String, Future<String?>> _cache = {};

  static Future<String?> photoFor(String uid) {
    return _cache.putIfAbsent(uid, () async {
      try {
        final snap =
            await FirebaseFirestore.instance.collection('users').doc(uid).get();
        final url = snap.data()?['photoUrl']?.toString();
        return (url == null || url.trim().isEmpty) ? null : url;
      } catch (_) {
        // Guests can't read user docs; fall back to initials.
        return null;
      }
    });
  }

  static void clear() => _cache.clear();
}
