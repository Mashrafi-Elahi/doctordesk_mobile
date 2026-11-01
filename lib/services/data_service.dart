import 'package:flutter/material.dart';
import 'scheduling_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/doctor.dart';
import 'api_service.dart';
import 'firestore_config.dart';
import 'firestore_service.dart';

/// Unified data service for DoctorDesk.
/// Automatically selects between Cloud Firestore and Node.js/Express backend
/// using the compile-time flag `USE_FIRESTORE`.
class DataService {
  static bool get isFirestore => FirestoreConfig.useFirestore;

  // --- DOCTOR DIRECTORY & DISCOVERY ---

  static Future<Map<String, dynamic>> fetchDoctors({
    int page = 1,
    int limit = 20,
    String? search,
    String? speciality,
  }) {
    if (isFirestore) {
      return FirestoreService.fetchDoctors(
        page: page,
        limit: limit,
        search: search,
        speciality: speciality,
      );
    }
    return ApiService.fetchDoctors(
      page: page,
      limit: limit,
      search: search,
      speciality: speciality,
    );
  }

  static Future<Doctor> fetchDoctorById(String id) {
    if (isFirestore) {
      return FirestoreService.fetchDoctorById(id);
    }
    return ApiService.fetchDoctorById(id);
  }

  static Future<List<Map<String, dynamic>>> fetchSpecialities() {
    if (isFirestore) {
      return FirestoreService.fetchSpecialities();
    }
    return ApiService.fetchSpecialities();
  }

  static Future<List<Doctor>> fetchNearbyDoctors({
    required double lat,
    required double lng,
    int radiusKm = 8,
    String? speciality,
    String? areaFilter,
    int page = 1,
    int limit = 20,
  }) {
    if (isFirestore) {
      return FirestoreService.fetchNearbyDoctors(
        lat: lat,
        lng: lng,
        radiusKm: radiusKm,
        speciality: speciality,
        areaFilter: areaFilter,
        page: page,
        limit: limit,
      );
    }
    return ApiService.fetchNearbyDoctors(
      lat: lat,
      lng: lng,
      radiusKm: radiusKm,
      speciality: speciality,
      areaFilter: areaFilter,
      page: page,
      limit: limit,
    );
  }

  static Future<List<Map<String, dynamic>>> fetchGeocodeSuggestions(
      String query) {
    if (isFirestore) {
      return FirestoreService.fetchGeocodeSuggestions(query);
    }
    return ApiService.fetchGeocodeSuggestions(query);
  }

  // --- JOURNAL & FEELINGS ---

  static Future<Map<String, dynamic>?> fetchTodayFeeling() {
    if (isFirestore) {
      return FirestoreService.fetchTodayFeeling();
    }
    return ApiService.fetchTodayFeeling();
  }

  static Future<bool> logFeeling({
    required String feeling,
    String? note,
    String? gratitudeText,
  }) {
    if (isFirestore) {
      return FirestoreService.logFeeling(
        feeling: feeling,
        note: note,
        gratitudeText: gratitudeText,
      );
    }
    return ApiService.logFeeling(
      feeling: feeling,
      note: note,
      gratitudeText: gratitudeText,
    );
  }

  static Future<List<Map<String, dynamic>>> fetchJournalEntries() {
    if (isFirestore) {
      return FirestoreService.fetchJournalEntries();
    }
    return ApiService.fetchJournalEntries();
  }

  // --- REVIEWS & BMDC CLAIMS ---

  static Future<List<Map<String, dynamic>>> fetchReviews(String doctorId) {
    if (isFirestore) {
      return FirestoreService.fetchReviews(doctorId);
    }
    return ApiService.fetchReviews(doctorId);
  }

  static Future<Map<String, dynamic>> submitReview(
    String doctorId, {
    required String patientUid,
    required int rating,
    String comment = '',
    String? proofImageUrl,
  }) {
    if (isFirestore) {
      return FirestoreService.submitReview(
        doctorId,
        patientUid: patientUid,
        rating: rating,
        comment: comment,
        proofImageUrl: proofImageUrl,
      );
    }
    return ApiService.submitReview(
      doctorId,
      patientUid: patientUid,
      rating: rating,
      comment: comment,
      proofImageUrl: proofImageUrl,
    );
  }

  static Future<bool> checkCanReview(
    String doctorId,
    String patientUid, {
    Map<String, dynamic>? doctorData,
  }) {
    if (isFirestore) {
      return FirestoreService.checkCanReview(doctorId, patientUid,
          doctorData: doctorData);
    }
    return ApiService.checkCanReview(doctorId, patientUid,
        doctorData: doctorData);
  }

  static Future<Map<String, dynamic>> claimDoctor(
    String doctorId, {
    required String bmdcRegNumber,
    required String claimedByUid,
    String? certificateImageUrl,
  }) {
    if (isFirestore) {
      return FirestoreService.claimDoctor(
        doctorId,
        bmdcRegNumber: bmdcRegNumber,
        claimedByUid: claimedByUid,
        certificateImageUrl: certificateImageUrl,
      );
    }
    return ApiService.claimDoctor(
      doctorId,
      bmdcRegNumber: bmdcRegNumber,
      claimedByUid: claimedByUid,
      certificateImageUrl: certificateImageUrl,
    );
  }

  // --- USERS & PROFILES ---

  static Future<Map<String, dynamic>?> fetchUserProfile(String uid) {
    if (isFirestore) {
      return FirestoreService.fetchUserProfile(uid);
    }
    return ApiService.fetchUserProfile(uid);
  }

  static Future<Map<String, dynamic>?> syncUser({
    required String uid,
    String? email,
    String? name,
    String? phone,
    String? role,
    bool isDoctor = false,
    String? photoUrl,
  }) {
    if (isFirestore) {
      return FirestoreService.syncUser(
        uid: uid,
        email: email,
        name: name,
        phone: phone,
        role: role,
        isDoctor: isDoctor,
        photoUrl: photoUrl,
      );
    }
    return ApiService.syncUser(
      uid: uid,
      email: email,
      name: name,
      phone: phone,
      role: role,
      isDoctor: isDoctor,
      photoUrl: photoUrl,
    );
  }

  static Future<List<Map<String, dynamic>>> fetchDoctorApplications() {
    if (isFirestore) {
      return FirestoreService.fetchDoctorApplications();
    }
    return ApiService.fetchDoctorApplications();
  }

  static Future<void> setDoctorRole({
    required String uid,
    required bool isDoctor,
    bool isBmdcVerified = false,
    String? doctorProfileId,
    String? nid,
    String? bmdcNumber,
  }) {
    if (isFirestore) {
      return FirestoreService.setDoctorRole(
        uid: uid,
        isDoctor: isDoctor,
        isBmdcVerified: isBmdcVerified,
        doctorProfileId: doctorProfileId,
        nid: nid,
        bmdcNumber: bmdcNumber,
      );
    }
    return ApiService.setDoctorRole(
      uid: uid,
      isDoctor: isDoctor,
      isBmdcVerified: isBmdcVerified,
      doctorProfileId: doctorProfileId,
      nid: nid,
      bmdcNumber: bmdcNumber,
    );
  }

  static Future<String> approveDoctorApplication({required String uid}) {
    if (!isFirestore) {
      throw UnsupportedError('Doctor approval requires the Firestore backend.');
    }
    return FirestoreService.approveDoctorApplication(uid: uid);
  }

  static Future<void> applyForDoctorRole({
    required String uid,
    required String phone,
    String? name,
    String? nid,
    String? bmdcNumber,
    String? speciality,
  }) {
    if (isFirestore) {
      return FirestoreService.applyForDoctorRole(
        uid: uid,
        phone: phone,
        name: name,
        nid: nid,
        bmdcNumber: bmdcNumber,
        speciality: speciality,
      );
    }
    return ApiService.applyForDoctorRole(
      uid: uid,
      phone: phone,
      name: name,
      nid: nid,
      bmdcNumber: bmdcNumber,
      speciality: speciality,
    );
  }

  // --- REAL-TIME FEED, VIDEOS & COMMUNITY Q&A ---

  static Stream<QuerySnapshot<Map<String, dynamic>>> feedPostsStream(
      {String? typeFilter}) {
    if (isFirestore) {
      return FirestoreService.feedPostsStream(typeFilter: typeFilter);
    }
    return ApiService.feedPostsStream(typeFilter: typeFilter);
  }

  static Future<String> createFeedPost({
    required String type,
    required String title,
    String? content,
    String? youtubeUrl,
    String? imageUrl,
    String? authorName,
    String? authorRole,
    bool isBmdcVerified = false,
  }) {
    if (isFirestore) {
      return FirestoreService.createFeedPost(
        type: type,
        title: title,
        content: content,
        youtubeUrl: youtubeUrl,
        imageUrl: imageUrl,
        authorName: authorName,
        authorRole: authorRole,
        isBmdcVerified: isBmdcVerified,
      );
    }
    return ApiService.createFeedPost(
      type: type,
      title: title,
      content: content,
      youtubeUrl: youtubeUrl,
      imageUrl: imageUrl,
      authorName: authorName,
      authorRole: authorRole,
      isBmdcVerified: isBmdcVerified,
    );
  }

  static Future<void> answerQuestion({
    required String postId,
    required String answerContent,
    String? doctorName,
    String? doctorRole,
  }) {
    if (isFirestore) {
      return FirestoreService.answerQuestion(
        postId: postId,
        answerContent: answerContent,
        doctorName: doctorName,
        doctorRole: doctorRole,
      );
    }
    return ApiService.answerQuestion(
      postId: postId,
      answerContent: answerContent,
      doctorName: doctorName,
      doctorRole: doctorRole,
    );
  }

  static Future<void> addPostComment({
    required String postId,
    required String comment,
    String? authorName,
    String? authorRole,
  }) {
    if (isFirestore) {
      return FirestoreService.addPostComment(
        postId: postId,
        comment: comment,
        authorName: authorName,
        authorRole: authorRole,
      );
    }
    return ApiService.addPostComment(
      postId: postId,
      comment: comment,
      authorName: authorName,
      authorRole: authorRole,
    );
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> postCommentsStream(
      String postId) {
    if (isFirestore) {
      return FirestoreService.postCommentsStream(postId);
    }
    return ApiService.postCommentsStream(postId);
  }

  static Future<void> deleteFeedPost(String postId) {
    if (isFirestore) {
      return FirestoreService.deleteFeedPost(postId);
    }
    return ApiService.deleteFeedPost(postId);
  }

  static Future<void> deleteDoctorAnswer(String postId) {
    if (isFirestore) {
      return FirestoreService.deleteDoctorAnswer(postId);
    }
    return Future.value();
  }

  static Future<void> deletePostComment(String postId, String commentId) {
    if (isFirestore) {
      return FirestoreService.deletePostComment(postId, commentId);
    }
    return Future.value();
  }

  // --- MODERATOR MANAGEMENT ---

  static Future<void> setModeratorRole({
    required String uid,
    required bool isModerator,
  }) {
    if (isFirestore) {
      return FirestoreService.setModeratorRole(
        uid: uid,
        isModerator: isModerator,
      );
    }
    return ApiService.setModeratorRole(
      uid: uid,
      isModerator: isModerator,
    );
  }

  static Future<List<Map<String, dynamic>>> fetchModerators() {
    if (isFirestore) {
      return FirestoreService.fetchModerators();
    }
    return ApiService.fetchModerators();
  }

  // --- SPECIALTY ACCURACY FEEDBACK ---

  static Future<void> submitSpecialtyFeedback({
    required String inputText,
    required String matchedSpecialty,
    required String source,
    required bool liked,
    String language = 'unknown',
  }) {
    if (isFirestore) {
      return FirestoreService.submitSpecialtyFeedback(
        inputText: inputText,
        matchedSpecialty: matchedSpecialty,
        source: source,
        liked: liked,
        language: language,
      );
    }
    return ApiService.submitSpecialtyFeedback(
      inputText: inputText,
      matchedSpecialty: matchedSpecialty,
      source: source,
      liked: liked,
      language: language,
    );
  }

  // --- APPOINTMENTS & QUEUE MANAGEMENT ---

  static Future<List<Map<String, dynamic>>> fetchTodayQueue(String chamberId) {
    if (isFirestore) {
      return FirestoreService.fetchTodayQueue(chamberId);
    }
    return ApiService.fetchTodayQueue(chamberId);
  }

  static Future<Map<String, dynamic>> createAppointment({
    required String patientName,
    required DateTime scheduledTime,
    String? chamberId,
    String? chamberName,
    String? doctorId,
    String? doctorName,
    String? operatorNote,
    String status = 'waiting',
  }) {
    if (isFirestore) {
      return FirestoreService.createAppointment(
        patientName: patientName,
        scheduledTime: scheduledTime,
        chamberId: chamberId,
        chamberName: chamberName,
        doctorId: doctorId,
        doctorName: doctorName,
        operatorNote: operatorNote,
        status: status,
      );
    }
    return ApiService.createAppointment(
      patientName: patientName,
      scheduledTime: scheduledTime,
      chamberId: chamberId,
      doctorId: doctorId,
      doctorName: doctorName,
      operatorNote: operatorNote,
      status: status,
    );
  }

  static Future<void> updateAppointment(
      String id, Map<String, dynamic> updates) {
    if (isFirestore) {
      return FirestoreService.updateAppointment(id, updates);
    }
    return ApiService.updateAppointment(id, updates);
  }

  static Future<void> updateQueueOrder(List<Map<String, dynamic>> updates) {
    if (isFirestore) {
      return FirestoreService.updateQueueOrder(updates);
    }
    return ApiService.updateQueueOrder(updates);
  }

  static Future<void> deleteAppointment(String id) {
    if (isFirestore) {
      return FirestoreService.deleteAppointment(id);
    }
    return ApiService.deleteAppointment(id);
  }

  static Future<void> clearAllAppointments() {
    if (isFirestore) {
      return FirestoreService.clearAllAppointments();
    }
    return ApiService.clearAllAppointments();
  }

  static Future<Map<String, dynamic>> updateUsername({
    required String uid,
    required String newUsername,
  }) {
    if (isFirestore) {
      return FirestoreService.updateUsername(uid: uid, newUsername: newUsername);
    }
    return Future.value({'success': true, 'username': newUsername});
  }

  static Future<List<Map<String, dynamic>>> searchUsersByUsername(String query) {
    if (isFirestore) {
      return FirestoreService.searchUsersByUsername(query);
    }
    return Future.value([]);
  }

  static Future<List<Map<String, dynamic>>> fetchChambersDirectory({String? areaFilter}) {
    if (isFirestore) {
      return FirestoreService.fetchChambersDirectory(areaFilter: areaFilter);
    }
    return Future.value([]);
  }

  static Future<void> applyForDeskOperator({
    required String chamberId,
    required String chamberName,
    required String doctorId,
    required String doctorName,
    String? note,
    String? phone,
  }) {
    if (isFirestore) {
      return FirestoreService.applyForDeskOperator(
        chamberId: chamberId,
        chamberName: chamberName,
        doctorId: doctorId,
        doctorName: doctorName,
        note: note,
        phone: phone,
      );
    }
    return Future.value();
  }

  static Future<void> approveOperatorApplication({
    required String applicationId,
    required String doctorId,
    required String chamberId,
    required String applicantUid,
    required String applicantName,
    required String applicantEmail,
    required String chamberName,
  }) {
    if (isFirestore) {
      return FirestoreService.approveOperatorApplication(
        applicationId: applicationId,
        doctorId: doctorId,
        chamberId: chamberId,
        applicantUid: applicantUid,
        applicantName: applicantName,
        applicantEmail: applicantEmail,
        chamberName: chamberName,
      );
    }
    return Future.value();
  }

  static Future<void> rejectOperatorApplication(String applicationId) {
    if (isFirestore) {
      return FirestoreService.rejectOperatorApplication(applicationId);
    }
    return Future.value();
  }

  static Future<void> uploadBundledDoctorsToFirestore({
    required Function(int processed, int total, String status) onProgress,
    bool restartFromBeginning = false,
  }) {
    return FirestoreService.uploadBundledDoctorsToFirestore(
      onProgress: onProgress,
      restartFromBeginning: restartFromBeginning,
    );
  }

  static Future<Map<String, dynamic>> assignDoctorToEmail({
    required String doctorId,
    required String email,
  }) {
    return FirestoreService.assignDoctorToEmail(
      doctorId: doctorId,
      email: email,
    );
  }

  static Future<void> recordManualBmdcVerification({
    required String doctorId,
    required String registrationNumber,
    required String outcome,
    String? note,
  }) {
    return FirestoreService.recordManualBmdcVerification(
      doctorId: doctorId,
      registrationNumber: registrationNumber,
      outcome: outcome,
      note: note,
    );
  }

  static Stream<int> streamTodayWaitingCount(String chamberId, {String? doctorId}) {
    return FirestoreService.streamTodayWaitingCount(chamberId, doctorId: doctorId);
  }

  static Future<List<String>> fetchChamberDoctors(String chamberId, {String? chamberName}) {
    return FirestoreService.fetchChamberDoctors(chamberId, chamberName: chamberName);
  }

  static Future<List<Map<String, dynamic>>> fetchChamberDoctorDetails(String chamberId, {String? chamberName}) {
    return FirestoreService.fetchChamberDoctorDetails(chamberId, chamberName: chamberName);
  }

  static Future<void> confirmAppointment({
    required String appointmentId,
    required DateTime confirmedTime,
    int slotMinutes = 15,
  }) {
    return FirestoreService.confirmAppointment(
      appointmentId: appointmentId,
      confirmedTime: confirmedTime,
      slotMinutes: slotMinutes,
    );
  }

  static Future<void> rescheduleAppointment({
    required String appointmentId,
    required DateTime newTime,
    int slotMinutes = 15,
  }) {
    return FirestoreService.rescheduleAppointment(
      appointmentId: appointmentId,
      newTime: newTime,
      slotMinutes: slotMinutes,
    );
  }

  static Future<void> rejectAppointment({
    required String appointmentId,
    required String reason,
  }) {
    return FirestoreService.rejectAppointment(
      appointmentId: appointmentId,
      reason: reason,
    );
  }

  static Future<void> cancelAppointmentByPatient(String appointmentId) {
    return FirestoreService.cancelAppointmentByPatient(appointmentId);
  }

  static Future<void> reroutePendingRequests({
    List<String>? chamberIds,
    String? doctorId,
  }) {
    return FirestoreService.reroutePendingRequests(
      chamberIds: chamberIds,
      doctorId: doctorId,
    );
  }

  static Future<List<DateTime>> getFreeSlotsForDoctor({
    required String doctorId,
    required DateTime date,
    String? chamberId,
    int slotMinutes = 10,
  }) {
    return FirestoreService.getFreeSlotsForDoctor(
      doctorId: doctorId,
      date: date,
      chamberId: chamberId,
      slotMinutes: slotMinutes,
    );
  }

  static Future<FreeSlotsResult> getFreeSlots({
    required String chamberId,
    required String doctorId,
    required DateTime date,
    int? defaultSlotMinutes,
  }) {
    return SchedulingService.getFreeSlots(
      chamberId: chamberId,
      doctorId: doctorId,
      date: date,
      defaultSlotMinutes: defaultSlotMinutes,
    );
  }

  static Future<Map<String, dynamic>?> getDayOverride(String chamberId, DateTime date) {
    return SchedulingService.getDayOverride(chamberId, date);
  }

  static Future<void> setDayOverride({
    required String chamberId,
    required String doctorId,
    required DateTime date,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    int? slotMinutes,
    String? status,
    String? note,
    required String actorUid,
  }) {
    return SchedulingService.setDayOverride(
      chamberId: chamberId,
      doctorId: doctorId,
      date: date,
      startTime: startTime,
      endTime: endTime,
      slotMinutes: slotMinutes,
      status: status,
      note: note,
      actorUid: actorUid,
    );
  }

  static Future<List<DocumentSnapshot<Map<String, dynamic>>>> getAffectedAppointments({
    required String chamberId,
    String? doctorId,
    required DateTime date,
    required TimeOfDay newStartTime,
  }) {
    return SchedulingService.getAffectedAppointments(
      chamberId: chamberId,
      doctorId: doctorId,
      date: date,
      newStartTime: newStartTime,
    );
  }

  static Future<Map<String, dynamic>> createWalkInAppointment({
    required String chamberId,
    required String doctorId,
    required String patientName,
    String? patientPhone,
    String? operatorNote,
    DateTime? specificDate,
    DateTime? specificSlot,
    bool allowOverrideClosedOrFull = false,
  }) {
    final actorUid = FirestoreService.auth.currentUser?.uid ?? 'unknown_actor';
    return SchedulingService.createWalkInAppointment(
      chamberId: chamberId,
      doctorId: doctorId,
      patientName: patientName,
      patientPhone: patientPhone,
      operatorNote: operatorNote,
      specificDate: specificDate,
      specificSlot: specificSlot,
      allowOverrideClosedOrFull: allowOverrideClosedOrFull,
      actorUid: actorUid,
    );
  }

  static Future<List<Map<String, dynamic>>> fetchTestAppointments() {
    return FirestoreService.fetchTestAppointments();
  }
}
