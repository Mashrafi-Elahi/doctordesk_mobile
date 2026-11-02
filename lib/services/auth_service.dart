import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/app_role_and_nav.dart';
import 'api_service.dart';

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const ['email', 'profile'],
  );

  static User? get currentUser => _auth.currentUser;
  static Stream<User?> get authStateChanges => _auth.authStateChanges();

  static bool get isSignedIn => currentUser != null;
  static bool get needsEmailVerification {
    final user = currentUser;
    return user?.email != null &&
        user!.email!.isNotEmpty &&
        !user.emailVerified;
  }

  static UserRoles _currentUserRoles = const UserRoles();
  static UserRoles get userRoles => _currentUserRoles;
  static bool get isAdmin => _currentUserRoles.isAdmin;

  static bool _isGuestMode = false;
  static bool get isGuest => _isGuestMode && !isSignedIn;

  static Future<void> loadGuestMode() async {
    final prefs = await SharedPreferences.getInstance();
    _isGuestMode = prefs.getBool('is_guest_mode') ?? false;
  }

  static Future<void> setGuestMode(bool value) async {
    _isGuestMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_guest_mode', value);
    if (value) {
      _currentUserRoles = const UserRoles(
        isDoctor: false,
        isOperator: false,
        isAdmin: false,
        chamberCount: 0,
      );
      await saveRole(UserRole.patient);
    }
  }

  static void enableAdminRole() {
    _currentUserRoles = UserRoles(
      isDoctor: _currentUserRoles.isDoctor,
      isOperator: _currentUserRoles.isOperator,
      isAdmin: true,
      chamberCount: _currentUserRoles.chamberCount,
      doctorProfileId: _currentUserRoles.doctorProfileId,
      operatorAssignments: _currentUserRoles.operatorAssignments,
    );
  }

  static UserRole _activeRole = UserRole.patient;
  static UserRole get activeRole => _activeRole;

  static bool isRoleGranted(UserRole role) {
    return switch (role) {
      UserRole.patient => true,
      UserRole.doctor => _currentUserRoles.isDoctor,
      UserRole.operator => _currentUserRoles.isOperator,
      UserRole.admin => _currentUserRoles.isAdmin,
    };
  }

  static Future<UserRole> getSavedRole() async {
    final prefs = await SharedPreferences.getInstance();
    final isGuest = prefs.getBool('is_guest_mode') ?? false;
    if (isGuest || currentUser == null) {
      _activeRole = UserRole.patient;
      return UserRole.patient;
    }
    final roleStr = prefs.getString('user_role');
    if (roleStr == 'admin' && _currentUserRoles.isAdmin) {
      _activeRole = UserRole.admin;
      return UserRole.admin;
    }
    if (roleStr == 'doctor' && _currentUserRoles.isDoctor) {
      _activeRole = UserRole.doctor;
      return UserRole.doctor;
    }
    if (roleStr == 'operator' && _currentUserRoles.isOperator) {
      _activeRole = UserRole.operator;
      return UserRole.operator;
    }
    _activeRole = UserRole.patient;
    return UserRole.patient;
  }

  static Future<void> saveRole(UserRole role) async {
    // Disallow switching to a role that has not been granted
    final effectiveRole = isRoleGranted(role) ? role : UserRole.patient;
    _activeRole = effectiveRole;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_role', effectiveRole.name);
  }

  /// Refreshes and returns the additive roles from database
  static String _rolesKey(String uid) => 'cached_user_roles_$uid';

  static Future<void> _cacheRoles(String uid, Map<String, dynamic> profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_rolesKey(uid), jsonEncode({
        'roles': profile['roles'],
        'chamberCount': profile['chamberCount'],
        'doctorProfileId': profile['doctorProfileId'],
        'operatorAssignments': profile['operatorAssignments'],
      }));
    } catch (_) {}
  }

  /// Roles from the last successful fetch, so startup needn't wait on the
  /// network. Returns false when there is nothing cached for this user.
  static Future<bool> loadCachedRoles() async {
    final uid = currentUser?.uid;
    if (uid == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_rolesKey(uid));
      if (raw == null) return false;
      _currentUserRoles = UserRoles.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<UserRoles> fetchUserRoles() async {
    final uid = currentUser?.uid;

    try {
      if (uid != null) {
        final profile = await ApiService.fetchUserProfile(uid);
        if (profile != null) {
          _currentUserRoles = UserRoles.fromJson(profile);
          await _cacheRoles(uid, profile);
          return _currentUserRoles;
        }
      }
    } catch (e) {
      debugPrint('Error fetching user roles: $e');
    }

    _currentUserRoles = const UserRoles(
      isDoctor: false,
      isOperator: false,
      chamberCount: 0,
    );
    return _currentUserRoles;
  }

  /// Sign in with email and password
  static Future<UserCredential?> signInWithEmailPassword(
    String email,
    String password, {
    bool isDoctor = false,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      await ApiService.syncUser(
        uid: credential.user!.uid,
        email: email.trim(),
        photoUrl: credential.user?.photoURL,
      );
      await fetchUserRoles();
      if (_currentUserRoles.isAdmin) {
        await saveRole(UserRole.admin);
      } else if (_currentUserRoles.isDoctor) {
        await saveRole(UserRole.doctor);
      } else if (_currentUserRoles.isOperator) {
        await saveRole(UserRole.operator);
      } else {
        await saveRole(UserRole.patient);
      }
      await setGuestMode(false);
      return credential;
    } catch (e) {
      debugPrint('Sign in error: $e');
      rethrow;
    }
  }

  /// Sign up with email and password
  static Future<UserCredential?> signUpWithEmailPassword(
    String email,
    String password, {
    String? name,
    String? phone,
    String? role,
    bool isDoctor = false,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      if (name != null && name.isNotEmpty) {
        await credential.user?.updateDisplayName(name);
      }
      await credential.user?.sendEmailVerification();
      await ApiService.syncUser(
        uid: credential.user!.uid,
        email: email.trim(),
        photoUrl: credential.user?.photoURL,
        name: name ?? '',
        phone: phone ?? '',
        isDoctor: isDoctor,
      );
      await fetchUserRoles();
      if (_currentUserRoles.isAdmin) {
        await saveRole(UserRole.admin);
      } else if (_currentUserRoles.isDoctor) {
        await saveRole(UserRole.doctor);
      } else {
        await saveRole(UserRole.patient);
      }
      await setGuestMode(false);
      return credential;
    } catch (e) {
      debugPrint('Sign up error: $e');
      rethrow;
    }
  }

  /// Sign in or Sign up with Google OAuth
  static Future<UserCredential?> signInWithGoogle(
      {bool isDoctor = false}) async {
    try {
      UserCredential credential;
      if (kIsWeb) {
        final googleProvider = GoogleAuthProvider();
        googleProvider.addScope('email');
        googleProvider.addScope('profile');
        credential = await _auth.signInWithPopup(googleProvider);
      } else {
        final googleUser = await _googleSignIn.signIn();
        if (googleUser == null) return null;
        final googleAuth = await googleUser.authentication;
        final firebaseCredential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        credential = await _auth.signInWithCredential(firebaseCredential);
      }

      final user = credential.user;
      if (user != null) {
        await ApiService.syncUser(
          uid: user.uid,
          email: user.email ?? '',
          name: user.displayName ?? '',
          isDoctor: isDoctor,
          photoUrl: user.photoURL,
        );
      }
      await fetchUserRoles();
      if (_currentUserRoles.isAdmin) {
        await saveRole(UserRole.admin);
      } else if (_currentUserRoles.isDoctor) {
        await saveRole(UserRole.doctor);
      } else {
        await saveRole(UserRole.patient);
      }
      await setGuestMode(false);
      return credential;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'popup-closed-by-user' || e.code == 'canceled') {
        debugPrint('Google sign in cancelled by user');
        return null;
      }
      debugPrint(
          'Google sign in FirebaseAuthException: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('Google Sign-in error: $e');
      rethrow;
    }
  }

  static Future<void> resendEmailVerification() async {
    final user = currentUser;
    if (user == null || user.email == null || user.emailVerified) return;
    await user.sendEmailVerification();
  }

  /// Always surface a generic success state in the UI so this call does not
  /// reveal whether a particular email address owns an account.
  static Future<void> sendPasswordResetEmail(String email) {
    return _auth.sendPasswordResetEmail(email: email.trim());
  }

  /// Refreshes the Firebase Auth user after they return from the email link.
  static Future<bool> refreshEmailVerification() async {
    final user = currentUser;
    if (user == null) return false;
    await user.reload();
    return currentUser?.emailVerified ?? false;
  }

  /// Trigger phone verification via SMS OTP
  static Future<void> verifyPhoneNumber({
    required String phoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(FirebaseAuthException error) onVerificationFailed,
    required void Function(PhoneAuthCredential credential)
        onVerificationCompleted,
    void Function(String verificationId)? onCodeAutoRetrievalTimeout,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber.trim(),
      verificationCompleted: onVerificationCompleted,
      verificationFailed: onVerificationFailed,
      codeSent: (String verificationId, int? resendToken) {
        onCodeSent(verificationId);
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        onCodeAutoRetrievalTimeout?.call(verificationId);
      },
      timeout: const Duration(seconds: 60),
    );
  }

  /// Complete phone verification and sign in / sign up with OTP
  static Future<UserCredential?> signInWithPhoneOtp({
    required String verificationId,
    required String smsCode,
    String? name,
    String? phone,
    String? role,
    bool isDoctor = false,
  }) async {
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );
      final userCred = await _auth.signInWithCredential(credential);

      if (name != null && name.isNotEmpty) {
        await userCred.user?.updateDisplayName(name);
      }

      await ApiService.syncUser(
        uid: userCred.user!.uid,
        email: userCred.user!.email ?? '',
        name: name ?? (userCred.user!.displayName ?? ''),
        phone: phone ?? (userCred.user!.phoneNumber ?? ''),
        role: role ?? (isDoctor ? 'doctor' : 'patient'),
        isDoctor: isDoctor,
      );

      await fetchUserRoles();
      if (_currentUserRoles.isAdmin) {
        await saveRole(UserRole.admin);
      } else if (_currentUserRoles.isDoctor) {
        await saveRole(UserRole.doctor);
      } else {
        await saveRole(UserRole.patient);
      }
      await setGuestMode(false);
      return userCred;
    } catch (e) {
      debugPrint('Phone OTP sign-in error: $e');
      rethrow;
    }
  }

  /// Log out from Firebase and reset roles
  static Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    try {
      await _auth.signOut();
    } catch (_) {}
    _currentUserRoles = const UserRoles();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_role');
    await setGuestMode(true);
  }
}
