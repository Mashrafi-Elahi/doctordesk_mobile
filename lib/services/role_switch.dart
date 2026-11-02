import 'package:flutter/foundation.dart';

import '../models/user_role.dart';

/// App-wide portal switching. MainShell registers its setter so any screen
/// (the avatar sheet, booking from a doctor/desk portal) can change portal
/// without going through Profile.
class RoleSwitch {
  static void Function(UserRole role)? _setter;

  /// The portal currently shown.
  static final ValueNotifier<UserRole> current = ValueNotifier(UserRole.patient);

  static void attach(void Function(UserRole role) setter) => _setter = setter;

  static void detach() => _setter = null;

  static void to(UserRole role) => _setter?.call(role);

  /// Runs [action] in the patient portal and returns to the portal the user
  /// was in, e.g. a doctor booking another doctor.
  static Future<T> asPatient<T>(Future<T> Function() action) async {
    final previous = current.value;
    if (previous != UserRole.patient) to(UserRole.patient);
    try {
      return await action();
    } finally {
      if (previous != UserRole.patient) to(previous);
    }
  }
}
