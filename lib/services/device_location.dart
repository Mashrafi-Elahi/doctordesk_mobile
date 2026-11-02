import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class DeviceLocationException implements Exception {
  final String message;
  const DeviceLocationException(this.message);

  @override
  String toString() => message;
}

/// A fresh device position that is actually in Bangladesh. Callers handle the
/// permission prompt first.
///
/// Phones that declined Google's "Location Accuracy" never get a fused fix, and
/// the old fallback to any last-known position could return a fix from another
/// country, giving "12,000 km away" results.
class DeviceLocation {
  static const _maxLastKnownAge = Duration(minutes: 15);
  static const _failureMemory = Duration(minutes: 10);

  /// When [current] last failed to get a usable fix. A phone that just failed
  /// will almost certainly fail again, so the option is hidden for a while.
  static DateTime? _lastFailureAt;

  static bool recentlyFailed({DateTime? now}) {
    final at = _lastFailureAt;
    return at != null && (now ?? DateTime.now()).difference(at) < _failureMemory;
  }

  @visibleForTesting
  static void recordFailure(DateTime at) => _lastFailureAt = at;

  @visibleForTesting
  static void resetFailure() => _lastFailureAt = null;

  /// Whether offering "use device location" can work: location services on,
  /// permission not permanently denied, and no failed fix in the last 10 min.
  static Future<bool> available() async {
    if (recentlyFailed()) return false;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      return await Geolocator.checkPermission() != LocationPermission.deniedForever;
    } catch (e) {
      debugPrint('Location availability check failed: $e');
      return false;
    }
  }

  static bool inBangladesh(double lat, double lng) =>
      lat >= 20.3 && lat <= 26.8 && lng >= 87.9 && lng <= 92.8;

  static LocationSettings _settings({required bool forceLocationManager}) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
        forceLocationManager: forceLocationManager,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.medium,
      timeLimit: Duration(seconds: 10),
    );
  }

  static Future<Position?> _try(LocationSettings settings) async {
    try {
      return await Geolocator.getCurrentPosition(locationSettings: settings);
    } catch (e) {
      debugPrint('Location attempt failed: $e');
      return null;
    }
  }

  static Future<Position> current() async {
    // Fused provider first, then Android's plain GPS/network provider, which
    // works without Google's Location Accuracy setting.
    var pos = await _try(_settings(forceLocationManager: false)) ??
        await _try(_settings(forceLocationManager: true));

    if (pos == null) {
      final last = await Geolocator.getLastKnownPosition(forceAndroidLocationManager: true);
      if (last != null && DateTime.now().difference(last.timestamp) < _maxLastKnownAge) {
        pos = last;
      }
    }

    if (pos == null || (pos.latitude == 0 && pos.longitude == 0)) {
      _lastFailureAt = DateTime.now();
      throw const DeviceLocationException(
          "Couldn't get your location. Turn on GPS and try again, or pick your area.");
    }
    if (!inBangladesh(pos.latitude, pos.longitude)) {
      _lastFailureAt = DateTime.now();
      throw const DeviceLocationException(
          'Your device location is outside Bangladesh. Pick your area instead.');
    }
    _lastFailureAt = null;
    return pos;
  }
}
