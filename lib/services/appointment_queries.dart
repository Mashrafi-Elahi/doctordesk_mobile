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
        // Doctor and desk both see every request for the doctor; no
        // handledBy split (it hid desk-routed requests from the doctor).
        // Ordered on the client (oldest first) to avoid another index.
        .where('status', whereIn: const ['requested', 'proposed']);
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
        .where('status', whereIn: const ['requested', 'proposed']);
  }

  /// Active appointments scheduled in [from, to), filtered by chamber and/or
  /// doctor. Every desk queue view goes through here so they share indexes.
  static Query<Map<String, dynamic>> activeBetween({
    String? chamberId,
    String? doctorId,
    required DateTime from,
    required DateTime to,
  }) {
    Query<Map<String, dynamic>> q = _db.collection('appointments');
    if (chamberId != null && chamberId.isNotEmpty) {
      q = q.where('chamberId', isEqualTo: chamberId);
    }
    if (doctorId != null && doctorId.isNotEmpty) {
      q = q.where('doctorId', isEqualTo: doctorId);
    }
    return q
        .where('status', whereIn: ApptStatus.active)
        .where('scheduledTime', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .where('scheduledTime', isLessThan: Timestamp.fromDate(to))
        .orderBy('scheduledTime');
  }

  /// Active queue on one [day] for a chamber (optionally one doctor there).
  static Query<Map<String, dynamic>> queueForChamberOnDay(String chamberId, DateTime day,
      {String? doctorId}) {
    final start = DateTime(day.year, day.month, day.day);
    return activeBetween(
      chamberId: chamberId,
      doctorId: doctorId,
      from: start,
      to: start.add(const Duration(days: 1)),
    );
  }

  /// Active queue on one [day] for a doctor across all chambers.
  static Query<Map<String, dynamic>> queueForDoctorOnDay(String doctorProfileId, DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    return activeBetween(
      doctorId: doctorProfileId,
      from: start,
      to: start.add(const Duration(days: 1)),
    );
  }

  /// Today's active queue for an operator chamber and doctor.
  static Query<Map<String, dynamic>> todayQueueForChamberAndDoctor(
          String chamberId, String doctorId) =>
      queueForChamberOnDay(chamberId, DateTime.now(), doctorId: doctorId);

  /// Today's active queue for an operator chamber.
  static Query<Map<String, dynamic>> todayQueueForChamber(String chamberId, {String? doctorId}) =>
      queueForChamberOnDay(chamberId, DateTime.now(), doctorId: doctorId);

  /// Today's active queue for a doctor across all chambers.
  static Query<Map<String, dynamic>> todayQueueForDoctor(String doctorProfileId) =>
      queueForDoctorOnDay(doctorProfileId, DateTime.now());

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
    // counts only requests that need the doctor or desk.
    return pendingRequestsForDoctor(doctorProfileId)
        .snapshots()
        .map((s) => s.docs.where((d) => d.data()['status'] == 'requested').length);
  }
}
