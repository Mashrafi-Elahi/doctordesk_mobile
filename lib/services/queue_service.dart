import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'chat_service.dart';
import 'notification_service.dart';

/// Appointment lifecycle statuses. Legacy values ('in_progress', 'completed')
/// are still read and mapped through [QueueService.normalizeStatus].
class ApptStatus {
  static const requested = 'requested';
  static const proposed = 'proposed';
  static const confirmed = 'confirmed';
  static const declined = 'declined';
  static const rejected = 'rejected';
  static const cancelled = 'cancelled';
  static const checkedIn = 'checked_in';
  static const inConsultation = 'in_consultation';
  static const done = 'done';
  static const noShow = 'no_show';

  /// Holding a token and not yet called in.
  static const waiting = {confirmed, checkedIn};

  /// Shown in the desk's "Today's Queue" tab.
  static const active = ['confirmed', 'checked_in', 'in_consultation', 'in_progress'];

  static const terminal = {done, noShow, cancelled, declined, rejected};
}

/// One queue per doctor per chamber per day:
/// `queues/{chamberId}_{doctorId}_{yyyyMMdd}`.
///
/// Fields: chamberId, doctorId, date, lastNumber (last token handed out,
/// never reused), currentServing (token in consultation, 0 when idle),
/// currentAppointmentId, waitingTokens (tokens still waiting, ascending),
/// waitingCount, updatedAt.
///
/// waitingTokens holds numbers only, so a patient can work out how many people
/// are ahead without being able to read anyone else's appointment.
class QueueService {
  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  static const defaultConsultMinutes = 10;

  /// Allowed status changes. Mirrors `allowedNext()` in firestore.rules.
  static const Map<String, Set<String>> transitions = {
    ApptStatus.requested: {
      ApptStatus.proposed,
      ApptStatus.confirmed,
      ApptStatus.rejected,
      ApptStatus.cancelled,
    },
    ApptStatus.proposed: {
      ApptStatus.proposed,
      ApptStatus.confirmed,
      ApptStatus.declined,
      ApptStatus.rejected,
      ApptStatus.cancelled,
    },
    ApptStatus.confirmed: {
      ApptStatus.confirmed,
      ApptStatus.checkedIn,
      ApptStatus.inConsultation,
      ApptStatus.noShow,
      ApptStatus.cancelled,
    },
    ApptStatus.checkedIn: {
      ApptStatus.inConsultation,
      ApptStatus.noShow,
      ApptStatus.cancelled,
    },
    ApptStatus.inConsultation: {
      ApptStatus.done,
      ApptStatus.cancelled,
    },
  };

  static String normalizeStatus(Object? raw) {
    final s = (raw ?? '').toString().toLowerCase();
    return switch (s) {
      'in_progress' => ApptStatus.inConsultation,
      'completed' => ApptStatus.done,
      _ => s,
    };
  }

  static bool canTransition(Object? from, String to) {
    return transitions[normalizeStatus(from)]?.contains(to) ?? false;
  }

  static String dateKey(DateTime dt) =>
      '${dt.year}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';

  static String queueId(String chamberId, String doctorId, DateTime date) =>
      '${chamberId}_${doctorId}_${dateKey(date)}';

  static List<int> waitingTokensOf(Map<String, dynamic>? queue) {
    final raw = queue?['waitingTokens'];
    if (raw is! List) return <int>[];
    return raw.whereType<num>().map((n) => n.toInt()).toList()..sort();
  }

  /// Tokens still waiting that are lower than [token].
  static int peopleAhead(List<int> waitingTokens, int token) =>
      waitingTokens.where((t) => t < token).length;

  /// Next token for [queue]. Also honours `lastQueuePosition`, which older
  /// builds wrote, so numbers never repeat.
  static int nextToken(Map<String, dynamic>? queue) {
    final a = (queue?['lastNumber'] as num?)?.toInt() ?? 0;
    final b = (queue?['lastQueuePosition'] as num?)?.toInt() ?? 0;
    return (a > b ? a : b) + 1;
  }

  /// Fields to write when [token] joins the waiting list.
  static Map<String, dynamic> joinWrite(
    Map<String, dynamic>? queue, {
    required String chamberId,
    required String doctorId,
    required String date,
    required int token,
    required String appointmentId,
  }) {
    final waiting = waitingTokensOf(queue);
    if (!waiting.contains(token)) waiting.add(token);
    waiting.sort();
    final last = (queue?['lastNumber'] as num?)?.toInt() ?? 0;
    return {
      'chamberId': chamberId,
      'doctorId': doctorId,
      'date': date,
      'lastNumber': token > last ? token : last,
      'currentServing': (queue?['currentServing'] as num?)?.toInt() ?? 0,
      'waitingTokens': waiting,
      'waitingCount': waiting.length,
      'lastTouchedAppointmentId': appointmentId,
    };
  }

  /// Fields to write when [token] leaves the waiting list (called in,
  /// cancelled, no-show). When nothing is waiting and nobody is in
  /// consultation the "now serving" counter resets; lastNumber is kept so
  /// tokens are never reused.
  static Map<String, dynamic> leaveWrite(
    Map<String, dynamic>? queue, {
    required int token,
    required String appointmentId,
  }) {
    final waiting = waitingTokensOf(queue)..remove(token);
    final hasCurrent =
        (queue?['currentAppointmentId'] ?? '').toString().isNotEmpty;
    return {
      'waitingTokens': waiting,
      'waitingCount': waiting.length,
      'lastTouchedAppointmentId': appointmentId,
      if (waiting.isEmpty && !hasCurrent) 'currentServing': 0,
    };
  }

  static String _uid() => FirebaseAuth.instance.currentUser?.uid ?? '';

  static DateTime? _date(Object? v) => v is Timestamp ? v.toDate() : null;

  static void _require(Map<String, dynamic> appt, String to) {
    final from = normalizeStatus(appt['status']);
    if (!canTransition(from, to)) {
      throw StateError('Cannot move an appointment from "$from" to "$to".');
    }
  }

  // ---------------------------------------------------------------------------
  // Desk actions
  // ---------------------------------------------------------------------------

  /// requested/proposed -> proposed. Reserves the slot so it can't be offered
  /// twice; the patient then accepts or declines.
  static Future<void> proposeTime({
    required String appointmentId,
    required DateTime slot,
    required String slotDocId,
  }) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    final slotRef = _db.collection('doctor_slots').doc(slotDocId);
    String patientUid = '';
    String doctorName = 'Doctor';

    await _db.runTransaction((tx) async {
      final apptSnap = await tx.get(apptRef);
      if (!apptSnap.exists) throw StateError('Appointment not found.');
      final appt = apptSnap.data()!;
      _require(appt, ApptStatus.proposed);

      final slotSnap = await tx.get(slotRef);
      if (slotSnap.exists && slotSnap.data()?['appointmentId'] != appointmentId) {
        throw StateError('That slot is already taken by another appointment.');
      }

      final doctorId = (appt['doctorId'] ?? '').toString();
      final chamberId = (appt['chamberId'] ?? '').toString();
      patientUid = (appt['userId'] ?? '').toString();
      doctorName = (appt['doctorName'] ?? doctorName).toString();

      final oldSlot = appt['slotId']?.toString();
      if (oldSlot != null && oldSlot.isNotEmpty && oldSlot != slotDocId) {
        tx.delete(_db.collection('doctor_slots').doc(oldSlot));
      }
      tx.set(slotRef, {
        'doctorId': doctorId,
        'chamberId': chamberId,
        'appointmentId': appointmentId,
        'date': dateKey(slot),
        'startTime': Timestamp.fromDate(slot),
        'createdAt': FieldValue.serverTimestamp(),
      });
      tx.update(apptRef, {
        'status': ApptStatus.proposed,
        'proposedTime': Timestamp.fromDate(slot),
        'proposedBy': _uid(),
        'queueId': queueId(chamberId, doctorId, slot),
        'slotId': slotDocId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    if (patientUid.isNotEmpty) {
      await _notify(
        patientUid,
        title: 'New time proposed',
        body: '$doctorName can see you on ${_fmt(slot)}. Open Appointments to accept or decline.',
        type: 'appointment_proposed',
        relatedId: appointmentId,
      );
    }
  }

  /// confirmed -> checked_in: patient has arrived at the chamber.
  static Future<void> checkIn(String appointmentId) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(apptRef);
      if (!snap.exists) throw StateError('Appointment not found.');
      _require(snap.data()!, ApptStatus.checkedIn);
      tx.update(apptRef, {
        'status': ApptStatus.checkedIn,
        'checkedInAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// confirmed/checked_in -> in_consultation. Only one patient per doctor's
  /// queue can be in consultation at a time.
  static Future<void> startConsultation(String appointmentId) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    String nextQueueId = '';
    String chamberId = '';
    String doctorId = '';

    await _db.runTransaction((tx) async {
      final apptSnap = await tx.get(apptRef);
      if (!apptSnap.exists) throw StateError('Appointment not found.');
      final appt = apptSnap.data()!;
      _require(appt, ApptStatus.inConsultation);

      final token = (appt['queuePosition'] as num?)?.toInt();
      if (token == null) throw StateError('This appointment has no token yet.');
      final qRef = _queueRefFor(appt);
      nextQueueId = qRef.id;
      final qSnap = await tx.get(qRef);
      final queue = qSnap.data();

      final currentId = (queue?['currentAppointmentId'] ?? '').toString();
      if (currentId.isNotEmpty && currentId != appointmentId) {
        final cur = await tx.get(_db.collection('appointments').doc(currentId));
        if (cur.exists &&
            normalizeStatus(cur.data()?['status']) == ApptStatus.inConsultation) {
          throw StateError(
              'Token #${queue?['currentServing']} is still in consultation. Mark it done first.');
        }
      }

      chamberId = (appt['chamberId'] ?? '').toString();
      doctorId = (appt['doctorId'] ?? '').toString();
      final docSnap = await tx.get(_db.collection('doctors').doc(doctorId));
      final avg = (docSnap.data()?['avgConsultMinutes'] as num?)?.toInt() ??
          defaultConsultMinutes;

      final now = DateTime.now();
      tx.update(apptRef, {
        'status': ApptStatus.inConsultation,
        'startedAt': Timestamp.fromDate(now),
        'autoAdvanceAt': Timestamp.fromDate(now.add(Duration(minutes: avg))),
        'queueId': qRef.id,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.set(
        qRef,
        {
          ...leaveWrite(queue, token: token, appointmentId: appointmentId),
          'chamberId': chamberId,
          'doctorId': doctorId,
          'date': qRef.id.split('_').last,
          'currentServing': token,
          'currentAppointmentId': appointmentId,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });

    await notifyNextInLine(chamberId: chamberId, doctorId: doctorId, queueDocId: nextQueueId);
  }

  /// in_consultation -> done, or confirmed/checked_in -> no_show / cancelled.
  /// Removes the token from the waiting list or clears "now serving".
  static Future<void> finishVisit(String appointmentId, {required String outcome}) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    await _db.runTransaction((tx) async {
      final apptSnap = await tx.get(apptRef);
      if (!apptSnap.exists) throw StateError('Appointment not found.');
      final appt = apptSnap.data()!;
      _require(appt, outcome);
      await _releaseFromQueue(tx, appt, appointmentId);
      tx.update(apptRef, {
        'status': outcome,
        if (outcome == ApptStatus.done) 'completedAt': FieldValue.serverTimestamp(),
        if (outcome == ApptStatus.cancelled) 'cancelledBy': _uid(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Gives a confirmed appointment a token in its day's queue, moving it out
  /// of a previous day's queue if the date changed. Must run inside [tx]
  /// after all other reads. Returns the token.
  static Future<int> assignToken(
    Transaction tx, {
    required Map<String, dynamic> appt,
    required String appointmentId,
    required DateTime slot,
  }) async {
    final chamberId = (appt['chamberId'] ?? '').toString();
    final doctorId = (appt['doctorId'] ?? '').toString();
    final newQueueRef = _db.collection('queues').doc(queueId(chamberId, doctorId, slot));
    final oldQueueId = (appt['queueId'] ?? '').toString();
    final oldToken = (appt['queuePosition'] as num?)?.toInt();

    final newSnap = await tx.get(newQueueRef);
    final sameQueue = oldQueueId == newQueueRef.id && oldToken != null;
    DocumentSnapshot<Map<String, dynamic>>? oldSnap;
    if (!sameQueue && oldToken != null && oldQueueId.isNotEmpty) {
      oldSnap = await tx.get(_db.collection('queues').doc(oldQueueId));
    }

    final token = sameQueue ? oldToken : nextToken(newSnap.data());
    if (oldSnap != null && oldSnap.exists) {
      tx.set(oldSnap.reference, {
        ...leaveWrite(oldSnap.data(), token: oldToken!, appointmentId: appointmentId),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    tx.set(
      newQueueRef,
      {
        ...joinWrite(newSnap.data(),
            chamberId: chamberId,
            doctorId: doctorId,
            date: dateKey(slot),
            token: token,
            appointmentId: appointmentId),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    return token;
  }

  // ---------------------------------------------------------------------------
  // Patient actions
  // ---------------------------------------------------------------------------

  /// proposed -> confirmed (takes a token) or declined (frees the slot).
  static Future<void> respondToProposal(String appointmentId, {required bool accept}) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    String patientName = 'Patient';
    String doctorId = '';
    String chamberName = '';
    DateTime? when;
    int? token;
    String? slotId;
    String? activeKey;
    (DocumentReference<Map<String, dynamic>>, Map<String, dynamic>)? consultChat;

    await _db.runTransaction((tx) async {
      final apptSnap = await tx.get(apptRef);
      if (!apptSnap.exists) throw StateError('Appointment not found.');
      final appt = apptSnap.data()!;
      final to = accept ? ApptStatus.confirmed : ApptStatus.declined;
      if (normalizeStatus(appt['status']) != ApptStatus.proposed) {
        throw StateError('This proposal is no longer open.');
      }
      patientName = (appt['patientName'] ?? patientName).toString();
      doctorId = (appt['doctorId'] ?? '').toString();
      chamberName = (appt['chamberName'] ?? '').toString();
      slotId = appt['slotId']?.toString();
      activeKey = appt['activeBookingKey']?.toString();
      when = _date(appt['proposedTime']);

      if (!accept) {
        tx.update(apptRef, {
          'status': to,
          'declinedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return;
      }
      if (when == null) throw StateError('The proposal has no time.');
      // Read before any write: the doctor's account for the consult chat.
      final doctorSnap = await tx.get(_db.collection('doctors').doc(doctorId));
      final doctorUid = (doctorSnap.data()?['claimedByUid'] ?? '').toString();
      token = await assignToken(tx, appt: appt, appointmentId: appointmentId, slot: when!);
      final patientUid = (appt['userId'] ?? '').toString();
      if (patientUid.isNotEmpty && doctorUid.isNotEmpty) {
        consultChat = (
          _db.collection('chats').doc(ChatService.generateChatId(patientUid, doctorUid)),
          ChatService.consultChatOnConfirm(
            patientUid: patientUid,
            doctorUid: doctorUid,
            patientName: patientName,
            doctorName: (appt['doctorName'] ?? 'Doctor').toString(),
            doctorId: doctorId,
            chamberId: (appt['chamberId'] ?? '').toString(),
            appointmentId: appointmentId,
            visit: when!,
          ),
        );
      }
      tx.update(apptRef, {
        'status': to,
        'scheduledTime': Timestamp.fromDate(when!),
        'queuePosition': token,
        'queueId': queueId((appt['chamberId'] ?? '').toString(),
            (appt['doctorId'] ?? '').toString(), when!),
        'confirmedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    // Best effort: a refused chat write must never undo the confirmation.
    if (consultChat != null) {
      try {
        await consultChat!.$1.set(consultChat!.$2, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Consult chat not opened: $e');
      }
    }
    if (!accept && slotId != null && slotId!.isNotEmpty) {
      try {
        await _db.collection('doctor_slots').doc(slotId).delete();
      } catch (e) {
        debugPrint('Could not free declined slot: $e');
      }
    }
    if (!accept && activeKey != null && activeKey!.isNotEmpty) {
      // Declining frees the patient to book this doctor again.
      try {
        await _db.collection('active_bookings').doc(activeKey).delete();
      } catch (_) {}
    }
    // Doctor and desk hear about it in their staff chat (with a notification).
    await ChatService.postAppointmentEvent(
      doctorId: doctorId,
      appointmentId: appointmentId,
      text: accept
          ? '✅ Confirmed by patient: $patientName · token #$token · ${when == null ? '' : _fmt(when!)}${chamberName.isEmpty ? '' : ' · $chamberName'}'
          : '↩️ Declined by patient: $patientName${when == null ? '' : ' · was ${_fmt(when!)}'}',
    );
  }

  /// Patient cancels: also gives up their place in the waiting list.
  static Future<void> cancelByPatient(String appointmentId) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    String doctorId = '';
    String patientName = 'Patient';
    await _db.runTransaction((tx) async {
      final apptSnap = await tx.get(apptRef);
      if (!apptSnap.exists) throw StateError('Appointment not found.');
      final appt = apptSnap.data()!;
      doctorId = (appt['doctorId'] ?? '').toString();
      patientName = (appt['patientName'] ?? patientName).toString();
      final from = normalizeStatus(appt['status']);
      if (!const {ApptStatus.requested, ApptStatus.proposed, ApptStatus.confirmed}
          .contains(from)) {
        throw StateError('Ask the chamber desk to cancel a visit that has started.');
      }
      await _releaseFromQueue(tx, appt, appointmentId);
      tx.update(apptRef, {
        'status': ApptStatus.cancelled,
        'cancelledBy': _uid(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    await ChatService.postAppointmentEvent(
      doctorId: doctorId,
      appointmentId: appointmentId,
      text: '❌ Cancelled by patient: $patientName',
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static DocumentReference<Map<String, dynamic>> _queueRefFor(Map<String, dynamic> appt) {
    final stored = (appt['queueId'] ?? '').toString();
    if (stored.isNotEmpty) return _db.collection('queues').doc(stored);
    final when = _date(appt['scheduledTime']) ?? DateTime.now();
    return _db.collection('queues').doc(queueId(
        (appt['chamberId'] ?? '').toString(), (appt['doctorId'] ?? '').toString(), when));
  }

  static Future<void> _releaseFromQueue(
      Transaction tx, Map<String, dynamic> appt, String appointmentId) async {
    final token = (appt['queuePosition'] as num?)?.toInt();
    if (token == null) return;
    final qRef = _queueRefFor(appt);
    final qSnap = await tx.get(qRef);
    if (!qSnap.exists) return;
    final queue = qSnap.data()!;
    final isCurrent = queue['currentAppointmentId'] == appointmentId;
    final after = {
      ...queue,
      if (isCurrent) 'currentAppointmentId': '',
    };
    tx.set(
      qRef,
      {
        ...leaveWrite(after, token: token, appointmentId: appointmentId),
        if (isCurrent) 'currentAppointmentId': '',
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// Sends "you're next" to the lowest waiting token, once.
  /// Filters on chamberId and doctorId so the desk's read rules can prove the
  /// query is allowed.
  static Future<void> notifyNextInLine({
    required String chamberId,
    required String doctorId,
    required String queueDocId,
  }) async {
    if (queueDocId.isEmpty) return;
    try {
      final next = await _db
          .collection('appointments')
          .where('chamberId', isEqualTo: chamberId)
          .where('doctorId', isEqualTo: doctorId)
          .where('queueId', isEqualTo: queueDocId)
          .where('status', whereIn: ApptStatus.waiting.toList())
          .orderBy('queuePosition')
          .limit(1)
          .get();
      if (next.docs.isEmpty) return;
      final doc = next.docs.first;
      final data = doc.data();
      final uid = (data['userId'] ?? '').toString();
      if (uid.isEmpty || data['nextNotifiedAt'] != null) return;
      await doc.reference.update({'nextNotifiedAt': FieldValue.serverTimestamp()});
      await _notify(
        uid,
        title: "You're next",
        body: 'Token #${data['queuePosition']} — please be ready at ${data['chamberName'] ?? 'the chamber'}.',
        type: 'queue_next',
        relatedId: doc.id,
      );
    } catch (e) {
      debugPrint('notifyNextInLine failed: $e');
    }
  }

  static Future<void> _notify(String uid,
      {required String title,
      required String body,
      required String type,
      required String relatedId}) async {
    try {
      await NotificationService.createNotification(
        userId: uid,
        title: title,
        body: body,
        type: type,
        relatedId: relatedId,
      );
    } catch (_) {}
  }

  static String _fmt(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final p = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day}/${dt.month}/${dt.year} $h:${dt.minute.toString().padLeft(2, '0')} $p';
  }
}
