import 'package:cloud_firestore/cloud_firestore.dart';

import 'queue_service.dart';

/// Single source of truth for all appointment-related Firestore queries.
/// Used by: operator desk, doctor queue desk, doctor home counters,
/// manage-tab badges, and patient appointments screen.
class AppointmentQueries {
  static final _db = FirebaseFirestore.instance;

  /// Pending requests for an operator assigned to a specific chamber and doctor.
  static Query<Map<String, dynamic>> pendingRequestsForChamberAndDoctor(
      String chamberId, String doctorId) {
    return _db
        .collection('appointments')
        .where('chamberId', isEqualTo: chamberId)
        .where('doctorId', isEqualTo: doctorId)
        .where('handledBy', isEqualTo: 'operator')
        .where('status', whereIn: const ['requested', 'proposed'])
        .orderBy('createdAt', descending: false);
  }

  /// Pending requests for an operator: chamberId in assigned chambers + handledBy == 'operator' + status == 'requested'.
  static Query<Map<String, dynamic>> pendingRequestsForOperator(
      List<String> chamberIds) {
    if (chamberIds.isEmpty) {
      return _db
          .collection('appointments')
          .where('status', isEqualTo: 'requested')
          .where('chamberId', isEqualTo: '__no_match__');
    }
    return _db
        .collection('appointments')
        .where('chamberId', whereIn: chamberIds)
        .where('handledBy', isEqualTo: 'operator')
        .where('status', isEqualTo: 'requested')
        .orderBy('createdAt', descending: false);
  }

  /// Pending requests for a single chamber for an operator.
  static Query<Map<String, dynamic>> pendingRequestsForChamber(
      String chamberId, {String? doctorId}) {
    if (doctorId != null && doctorId.isNotEmpty) {
      return pendingRequestsForChamberAndDoctor(chamberId, doctorId);
    }
    return _db
        .collection('appointments')
        .where('chamberId', isEqualTo: chamberId)
        .where('handledBy', isEqualTo: 'operator')
        .where('status', whereIn: const ['requested', 'proposed'])
        .orderBy('createdAt', descending: false);
  }

  /// Pending requests for a doctor: doctorId matches + handledBy == 'doctor' + status == 'requested'.
  static Query<Map<String, dynamic>> pendingRequestsForDoctor(
      String doctorProfileId) {
    return _db
        .collection('appointments')
        .where('doctorId', isEqualTo: doctorProfileId)
        .where('handledBy', isEqualTo: 'doctor')
        .where('status', whereIn: const ['requested', 'proposed'])
        .orderBy('createdAt', descending: false);
  }

  /// Today's active queue for an operator chamber and doctor:
  /// status in ApptStatus.active + scheduledTime within today.
  static Query<Map<String, dynamic>> todayQueueForChamberAndDoctor(
      String chamberId, String doctorId) {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    return _db
        .collection('appointments')
        .where('chamberId', isEqualTo: chamberId)
        .where('doctorId', isEqualTo: doctorId)
        .where('status', whereIn: ApptStatus.active)
        .where('scheduledTime',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('scheduledTime', isLessThan: Timestamp.fromDate(endOfDay))
        .orderBy('scheduledTime');
  }

  /// Today's active queue for an operator chamber.
  static Query<Map<String, dynamic>> todayQueueForChamber(String chamberId, {String? doctorId}) {
    if (doctorId != null && doctorId.isNotEmpty) {
      return todayQueueForChamberAndDoctor(chamberId, doctorId);
    }
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    return _db
        .collection('appointments')
        .where('chamberId', isEqualTo: chamberId)
        .where('status', whereIn: ApptStatus.active)
        .where('scheduledTime',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('scheduledTime', isLessThan: Timestamp.fromDate(endOfDay))
        .orderBy('scheduledTime');
  }

  /// Today's active queue for a doctor across all chambers.
  static Query<Map<String, dynamic>> todayQueueForDoctor(
      String doctorProfileId) {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    return _db
        .collection('appointments')
        .where('doctorId', isEqualTo: doctorProfileId)
        .where('status', whereIn: ApptStatus.active)
        .where('scheduledTime',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('scheduledTime', isLessThan: Timestamp.fromDate(endOfDay))
        .orderBy('scheduledTime');
  }

  /// Completed appointments for one chamber and doctor.
  static Query<Map<String, dynamic>> completedForChamberAndDoctor(
      String chamberId, String doctorId) {
    return _db
        .collection('appointments')
        .where('chamberId', isEqualTo: chamberId)
        .where('doctorId', isEqualTo: doctorId)
        .where('status', isEqualTo: 'done')
        .orderBy('scheduledTime', descending: true);
  }

  /// Completed appointments for one chamber, most recently scheduled first.
  static Query<Map<String, dynamic>> completedForChamber(String chamberId, {String? doctorId}) {
    if (doctorId != null && doctorId.isNotEmpty) {
      return completedForChamberAndDoctor(chamberId, doctorId);
    }
    return _db
        .collection('appointments')
        .where('chamberId', isEqualTo: chamberId)
        .where('status', isEqualTo: 'done')
        .orderBy('scheduledTime', descending: true);
  }

  /// Completed appointments for a doctor across all chambers.
  static Query<Map<String, dynamic>> completedForDoctor(String doctorProfileId) {
    return _db
        .collection('appointments')
        .where('doctorId', isEqualTo: doctorProfileId)
        .where('status', isEqualTo: 'done')
        .orderBy('scheduledTime', descending: true);
  }

  /// All appointments for a patient, newest first.
  static Query<Map<String, dynamic>> patientAppointments(String userId) {
    return _db
        .collection('appointments')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true);
  }

  /// Count of pending requests for operator (for badge).
  static Stream<int> pendingRequestCountForOperator(List<String> chamberIds) {
    if (chamberIds.isEmpty) return Stream.value(0);
    return pendingRequestsForOperator(chamberIds)
        .snapshots()
        .map((s) => s.docs.length);
  }

  /// Count of pending requests for doctor (for badge).
  static Stream<int> pendingRequestCountForDoctor(String doctorProfileId) {
    if (doctorProfileId.isEmpty) return Stream.value(0);
    // The list also shows 'proposed' (waiting on the patient); the badge
    // counts only requests that need the doctor.
    return pendingRequestsForDoctor(doctorProfileId)
        .snapshots()
        .map((s) => s.docs.where((d) => d.data()['status'] == 'requested').length);
  }
}
