import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'chamber_resolver.dart';
import 'chat_service.dart';
import 'notification_service.dart';
import 'queue_service.dart';

class ParsedSchedule {
  final TimeOfDay start;
  final TimeOfDay end;
  final List<int> visitingDays; // 1 = Mon ... 7 = Sun (matches DateTime.weekday)

  const ParsedSchedule({
    required this.start,
    required this.end,
    this.visitingDays = const [1, 2, 3, 4, 6, 7], // Default Sat–Thu in BD
  });

  bool isVisitingDay(DateTime date) {
    if (visitingDays.isEmpty) return true;
    return visitingDays.contains(date.weekday);
  }
}

class FreeSlotsResult {
  final List<DateTime> slots;
  final String? emptyReason; // 'Fully booked', 'Closed', 'Not a visiting day', 'Visiting hours not set'
  final List<DateTime> nextVisitingDates;
  final int totalCapacity;
  final int confirmedCount;
  final Map<String, dynamic>? overrideData;

  const FreeSlotsResult({
    required this.slots,
    this.emptyReason,
    this.nextVisitingDates = const [],
    this.totalCapacity = 0,
    this.confirmedCount = 0,
    this.overrideData,
  });

  bool get hasSlots => slots.isNotEmpty;
  int get slotsLeft => (totalCapacity - confirmedCount).clamp(0, totalCapacity);
}

class SchedulingService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static String dateKey(DateTime dt) {
    return '${dt.year}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
  }

  static String timeKey(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}${dt.minute.toString().padLeft(2, '0')}';
  }

  static String slotId(String doctorId, DateTime dt) {
    return '${doctorId}_${dateKey(dt)}_${timeKey(dt)}';
  }

  static int capacity(TimeOfDay start, TimeOfDay end, int slotMinutes) {
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;
    if (endMinutes <= startMinutes || slotMinutes <= 0) return 0;
    return (endMinutes - startMinutes) ~/ slotMinutes;
  }

  static List<DateTime> generateSlots(
    DateTime date,
    TimeOfDay start,
    TimeOfDay end,
    int slotMinutes,
  ) {
    final s = DateTime(date.year, date.month, date.day, start.hour, start.minute);
    final e = DateTime(date.year, date.month, date.day, end.hour, end.minute);
    final diff = e.difference(s).inMinutes;
    if (diff <= 0 || slotMinutes <= 0) return [];
    final n = diff ~/ slotMinutes;
    return List.generate(n, (i) => s.add(Duration(minutes: i * slotMinutes)));
  }

  static List<int> _parseVisitingDays(String text) {
    final lower = text.toLowerCase();

    if (lower.contains('everyday') || lower.contains('daily') || lower.contains('all days')) {
      return [1, 2, 3, 4, 5, 6, 7];
    }

    final dayMap = <String, int>{
      'sat': DateTime.saturday,
      'saturday': DateTime.saturday,
      'sun': DateTime.sunday,
      'sunday': DateTime.sunday,
      'mon': DateTime.monday,
      'monday': DateTime.monday,
      'tue': DateTime.tuesday,
      'tues': DateTime.tuesday,
      'tuesday': DateTime.tuesday,
      'wed': DateTime.wednesday,
      'wednesday': DateTime.wednesday,
      'thu': DateTime.thursday,
      'thur': DateTime.thursday,
      'thurs': DateTime.thursday,
      'thursday': DateTime.thursday,
      'fri': DateTime.friday,
      'friday': DateTime.friday,
    };

    final rangeRegex = RegExp(
      r'\b(sat|saturday|sun|sunday|mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday)\b'
      r'\s*(?:–|—|-|\bto\b)\s*'
      r'\b(sat|saturday|sun|sunday|mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday)\b',
      caseSensitive: false,
    );
    final rangeMatch = rangeRegex.firstMatch(lower);
    if (rangeMatch != null) {
      final startDayKey = rangeMatch.group(1)!.toLowerCase();
      final endDayKey = rangeMatch.group(2)!.toLowerCase();
      final startDay = dayMap[startDayKey];
      final endDay = dayMap[endDayKey];

      if (startDay != null && endDay != null) {
        const weekCycle = [
          DateTime.saturday,
          DateTime.sunday,
          DateTime.monday,
          DateTime.tuesday,
          DateTime.wednesday,
          DateTime.thursday,
          DateTime.friday,
        ];
        final startIndex = weekCycle.indexOf(startDay);
        final endIndex = weekCycle.indexOf(endDay);
        if (startIndex != -1 && endIndex != -1) {
          final days = <int>[];
          var idx = startIndex;
          while (true) {
            days.add(weekCycle[idx]);
            if (idx == endIndex) break;
            idx = (idx + 1) % weekCycle.length;
          }
          return days;
        }
      }
    }

    final tokenRegex = RegExp(
      r'\b(sat|saturday|sun|sunday|mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday)\b',
      caseSensitive: false,
    );
    final matches = tokenRegex.allMatches(lower);
    if (matches.isNotEmpty) {
      final days = <int>{};
      for (final m in matches) {
        final key = m.group(1)!.toLowerCase();
        final day = dayMap[key];
        if (day != null) days.add(day);
      }
      if (days.isNotEmpty) {
        return days.toList();
      }
    }

    return [
      DateTime.saturday,
      DateTime.sunday,
      DateTime.monday,
      DateTime.tuesday,
      DateTime.wednesday,
      DateTime.thursday,
    ];
  }

  static ParsedSchedule? parseVisitingHours(dynamic input) {
    if (input == null) return null;

    if (input is Map) {
      final startStr = (input['start'] ?? '17:00').toString();
      final endStr = (input['end'] ?? '21:00').toString();
      final rawDays = input['days'];
      List<int> days = const [1, 2, 3, 4, 6, 7];
      if (rawDays is List && rawDays.isNotEmpty) {
        days = rawDays.map((e) => (e as num).toInt()).toList();
      }
      final sParts = startStr.split(':');
      final eParts = endStr.split(':');
      final start = TimeOfDay(
        hour: int.tryParse(sParts[0]) ?? 17,
        minute: sParts.length > 1 ? (int.tryParse(sParts[1]) ?? 0) : 0,
      );
      final end = TimeOfDay(
        hour: int.tryParse(eParts[0]) ?? 21,
        minute: eParts.length > 1 ? (int.tryParse(eParts[1]) ?? 0) : 0,
      );
      return ParsedSchedule(start: start, end: end, visitingDays: days);
    }

    final clean = input.toString().trim();
    if (clean.isEmpty) return null;

    final days = _parseVisitingDays(clean);

    final regex = RegExp(
      r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:–|—|-|\bto\b)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(clean);
    if (match != null) {
      int startH = int.parse(match.group(1)!);
      int startM = match.group(2) != null ? int.parse(match.group(2)!) : 0;
      final startPeriod = match.group(3)?.toLowerCase();

      int endH = int.parse(match.group(4)!);
      int endM = match.group(5) != null ? int.parse(match.group(5)!) : 0;
      final endPeriod = match.group(6)?.toLowerCase();

      if (startPeriod == 'pm' && startH < 12) startH += 12;
      if (startPeriod == 'am' && startH == 12) startH = 0;
      if (endPeriod == 'pm' && endH < 12) endH += 12;
      if (endPeriod == 'am' && endH == 12) endH = 0;

      if (startPeriod == null && endPeriod == 'pm') {
        if (startH < 12 && startH >= 1 && endH >= 12) {
          startH += 12;
        }
      }

      if (startPeriod == null && endPeriod == null) {
        if (startH >= 1 && startH <= 7 && endH <= 11 && endH > startH) {
          startH += 12;
          endH += 12;
        }
      }

      if (startH * 60 + startM >= endH * 60 + endM) {
        return null;
      }

      return ParsedSchedule(
        start: TimeOfDay(hour: startH, minute: startM),
        end: TimeOfDay(hour: endH, minute: endM),
        visitingDays: days,
      );
    }

    return null;
  }

  static Map<String, dynamic> structuredVisitingHours(String text) {
    final clean = text.trim();
    final schedule = parseVisitingHours(clean);
    if (schedule != null) {
      final startStr = '${schedule.start.hour.toString().padLeft(2, '0')}:${schedule.start.minute.toString().padLeft(2, '0')}';
      final endStr = '${schedule.end.hour.toString().padLeft(2, '0')}:${schedule.end.minute.toString().padLeft(2, '0')}';
      return {
        'days': schedule.visitingDays,
        'start': startStr,
        'end': endStr,
        'display': clean.isNotEmpty ? clean : 'Visiting hours not set',
      };
    }
    return {
      'days': const [1, 2, 3, 4, 6, 7],
      'start': '17:00',
      'end': '21:00',
      'display': clean.isNotEmpty ? clean : 'Visiting hours not set',
    };
  }

  /// Bookings are open for today plus the next 14 days, for patients and
  /// desks alike.
  static const int bookingWindowDays = 15;

  static DateTime get today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static DateTime get lastBookableDate =>
      today.add(const Duration(days: bookingWindowDays - 1));

  /// The days of the booking window, starting today.
  static List<DateTime> get bookingWindow => List.generate(
      bookingWindowDays, (i) => today.add(Duration(days: i)));

  /// Day overrides for every date in the booking window, keyed by [dateKey].
  static Future<Map<String, Map<String, dynamic>>> getWindowOverrides(
      String chamberId) async {
    if (chamberId.isEmpty) return {};
    try {
      final ids = bookingWindow.map((d) => '${chamberId}_${dateKey(d)}').toList();
      final snap = await _db
          .collection('chamber_day_overrides')
          .where(FieldPath.documentId, whereIn: ids)
          .get();
      return {
        for (final doc in snap.docs)
          doc.id.substring(chamberId.length + 1): doc.data(),
      };
    } catch (_) {
      return {};
    }
  }

  /// Whether [day] can be booked: inside the window, not closed or full,
  /// a visiting day (or opened for that date by the desk), and, for today,
  /// before the chamber closes.
  static bool isBookableDay(
    DateTime day, {
    ParsedSchedule? schedule,
    Map<String, Map<String, dynamic>> overrides = const {},
  }) {
    final d = DateTime(day.year, day.month, day.day);
    if (d.isBefore(today) || d.isAfter(lastBookableDate)) return false;

    final override = overrides[dateKey(d)];
    final status = (override?['status'] ?? '').toString().toLowerCase();
    if (status == 'closed' || status == 'full') return false;
    if (status != 'open' && schedule != null && !schedule.isVisitingDay(d)) {
      return false;
    }

    if (d == today) {
      var end = schedule?.end;
      if (override?['endHour'] != null && override?['endMinute'] != null) {
        end = TimeOfDay(
          hour: (override!['endHour'] as num).toInt(),
          minute: (override['endMinute'] as num).toInt(),
        );
      }
      if (end != null &&
          !DateTime.now().isBefore(DateTime(d.year, d.month, d.day, end.hour, end.minute))) {
        return false;
      }
    }
    return true;
  }

  /// First bookable day on or after [from], or null if the window has none.
  static DateTime? firstBookableDay({
    DateTime? from,
    ParsedSchedule? schedule,
    Map<String, Map<String, dynamic>> overrides = const {},
  }) {
    final start = from ?? today;
    for (final d in bookingWindow) {
      if (d.isBefore(DateTime(start.year, start.month, start.day))) continue;
      if (isBookableDay(d, schedule: schedule, overrides: overrides)) return d;
    }
    return null;
  }

  static Future<Map<String, dynamic>?> getDayOverride(String chamberId, DateTime date) async {
    try {
      final docId = '${chamberId}_${dateKey(date)}';
      final snap = await _db.collection('chamber_day_overrides').doc(docId).get();
      if (snap.exists) return snap.data();
    } catch (_) {}
    return null;
  }

  static Future<FreeSlotsResult> getFreeSlots({
    required String chamberId,
    required String doctorId,
    required DateTime date,
    int? defaultSlotMinutes,
  }) async {
    final chamber = await ChamberResolver.resolveChamberRecord(
      chamberId: chamberId,
      doctorId: doctorId,
    );

    final schedule = parseVisitingHours(chamber?.visitingHoursStructured ?? chamber?.visitingHours);

    final overrideData = await getDayOverride(chamberId, date);
    final overrideStatus = (overrideData?['status'] ?? '').toString().toLowerCase();

    if (overrideStatus == 'closed') {
      return FreeSlotsResult(
        slots: const [],
        emptyReason: 'Closed',
        overrideData: overrideData,
      );
    }

    if (schedule == null && overrideData == null) {
      return const FreeSlotsResult(
        slots: [],
        emptyReason: 'Visiting hours not set',
      );
    }

    // Check visiting day if no override explicitly opened it
    final isVisiting = schedule?.isVisitingDay(date) ?? true;
    if (!isVisiting && overrideStatus != 'open') {
      final nextDates = getNextVisitingDates(
        schedule: schedule,
        startDate: date,
      );
      return FreeSlotsResult(
        slots: const [],
        emptyReason: 'Not a visiting day',
        nextVisitingDates: nextDates,
      );
    }

    // Determine effective window
    TimeOfDay start = schedule?.start ?? const TimeOfDay(hour: 17, minute: 0);
    TimeOfDay end = schedule?.end ?? const TimeOfDay(hour: 21, minute: 0);
    int slotMinutes = defaultSlotMinutes ?? chamber?.slotMinutes ?? 10;

    if (overrideData != null) {
      if (overrideData['startHour'] != null && overrideData['startMinute'] != null) {
        start = TimeOfDay(
          hour: (overrideData['startHour'] as num).toInt(),
          minute: (overrideData['startMinute'] as num).toInt(),
        );
      }
      if (overrideData['endHour'] != null && overrideData['endMinute'] != null) {
        end = TimeOfDay(
          hour: (overrideData['endHour'] as num).toInt(),
          minute: (overrideData['endMinute'] as num).toInt(),
        );
      }
      if (overrideData['slotMinutes'] != null) {
        slotMinutes = (overrideData['slotMinutes'] as num).toInt().clamp(5, 15);
      }
    }

    final totalCap = capacity(start, end, slotMinutes);
    if (totalCap == 0) {
      return FreeSlotsResult(
        slots: const [],
        emptyReason: 'Visiting hours not set',
        totalCapacity: 0,
        confirmedCount: 0,
        overrideData: overrideData,
      );
    }
    if (overrideStatus == 'full') {
      return FreeSlotsResult(
        slots: const [],
        emptyReason: totalCap > 0 ? 'Fully booked' : 'Visiting hours not set',
        totalCapacity: totalCap,
        confirmedCount: totalCap,
        overrideData: overrideData,
      );
    }

    final allSlots = generateSlots(date, start, end, slotMinutes);
    final dKey = dateKey(date);

    final reservedDocSlots = await _db
        .collection('doctor_slots')
        .where('doctorId', isEqualTo: doctorId)
        .where('date', isEqualTo: dKey)
        .get();

    final takenTimeKeys = <String>{};
    for (final doc in reservedDocSlots.docs) {
      final t = doc.data()['startTime'];
      if (t is Timestamp) {
        takenTimeKeys.add(timeKey(t.toDate()));
      }
    }

    final now = DateTime.now();
    final isToday = date.year == now.year && date.month == now.month && date.day == now.day;

    final free = allSlots.where((slot) {
      if (takenTimeKeys.contains(timeKey(slot))) return false;
      if (isToday && slot.isBefore(now)) return false;
      return true;
    }).toList();

    final confirmedCount = takenTimeKeys.length;
    final emptyReason = free.isEmpty
        ? (totalCap == 0
            ? 'Visiting hours not set'
            : (confirmedCount >= totalCap ? 'Fully booked' : 'No available slots today'))
        : null;

    return FreeSlotsResult(
      slots: free,
      emptyReason: emptyReason,
      totalCapacity: totalCap,
      confirmedCount: confirmedCount,
      overrideData: overrideData,
    );
  }

  static List<DateTime> getNextVisitingDates({
    ParsedSchedule? schedule,
    required DateTime startDate,
    int count = 3,
  }) {
    final results = <DateTime>[];
    DateTime curr = startDate.add(const Duration(days: 1));
    while (results.length < count && results.length < 14) {
      if (schedule == null || schedule.isVisitingDay(curr)) {
        results.add(DateTime(curr.year, curr.month, curr.day));
      }
      curr = curr.add(const Duration(days: 1));
    }
    return results;
  }

  static Future<void> acceptAppointment({
    required String appointmentId,
    required DateTime slot,
    required String actorUid,
  }) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    final targetDateKey = dateKey(slot);

    String resolvedPatientUid = '';
    String resolvedPatientName = 'Patient';
    String resolvedDoctorName = 'Doctor';
    String resolvedChamberName = 'Chamber';
    String doctorId = '';
    String chamberId = 'chamber';
    int assignedQueue = 1;
    (DocumentReference<Map<String, dynamic>>, Map<String, dynamic>)? consultChat;

    await _db.runTransaction((tx) async {
      final apptSnap = await tx.get(apptRef);
      if (!apptSnap.exists) throw StateError('Appointment not found.');
      final appt = apptSnap.data()!;

      doctorId = (appt['doctorId'] ?? '').toString();
      chamberId = (appt['chamberId'] ?? 'chamber').toString();
      resolvedPatientUid = (appt['userId'] ?? '').toString();
      resolvedPatientName = (appt['patientName'] ?? 'Patient').toString();
      resolvedDoctorName = (appt['doctorName'] ?? 'Doctor').toString();

      if (!QueueService.canTransition(appt['status'], ApptStatus.confirmed)) {
        throw StateError('This appointment can no longer be confirmed.');
      }

      final targetSlotDocId = slotId(doctorId, slot);
      final slotRef = _db.collection('doctor_slots').doc(targetSlotDocId);
      final overrideRef = _db.collection('chamber_day_overrides').doc('${chamberId}_$targetDateKey');

      final slotSnap = await tx.get(slotRef);
      final override = await tx.get(overrideRef);

      // Resolve the doctor's auth UID now: transactions must do every read
      // before the first write.
      String doctorAuthUid = '';
      if (doctorId.isNotEmpty) {
        final docSnap = await tx.get(_db.collection('doctors').doc(doctorId));
        if (docSnap.exists) {
          doctorAuthUid = (docSnap.data()?['claimedByUid'] ?? '').toString();
        }
      }

      if (override.exists) {
        final st = (override.data()?['status'] ?? '').toString().toLowerCase();
        if (st == 'closed' || st == 'full') {
          throw StateError('This date is closed or fully booked.');
        }
      }

      if (slotSnap.exists && slotSnap.data()?['appointmentId'] != appointmentId) {
        throw StateError('That slot is already taken by another appointment.');
      }

      // Last read-then-write step: every other read is done above.
      assignedQueue = await QueueService.assignToken(
        tx,
        appt: appt,
        appointmentId: appointmentId,
        slot: slot,
      );

      final oldSlot = appt['slotId']?.toString();
      if (oldSlot != null && oldSlot.isNotEmpty && oldSlot != targetSlotDocId) {
        tx.delete(_db.collection('doctor_slots').doc(oldSlot));
      }

      tx.set(slotRef, {
        'doctorId': doctorId,
        'chamberId': chamberId,
        'appointmentId': appointmentId,
        'date': targetDateKey,
        'startTime': Timestamp.fromDate(slot),
        'createdAt': FieldValue.serverTimestamp(),
      });

      tx.update(apptRef, {
        'status': 'confirmed',
        'scheduledTime': Timestamp.fromDate(slot),
        'queuePosition': assignedQueue,
        'queueId': QueueService.queueId(chamberId, doctorId, slot),
        'slotId': targetSlotDocId,
        'confirmedAt': FieldValue.serverTimestamp(),
        'updatedBy': actorUid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // One consult chat per doctor+patient, re-opened for this visit. Desk
      // staff are never added: doctor and desk talk in the staff chat.
      if (resolvedPatientUid.isNotEmpty && doctorAuthUid.isNotEmpty) {
        consultChat = (
          _db.collection('chats').doc(ChatService.generateChatId(resolvedPatientUid, doctorAuthUid)),
          ChatService.consultChatOnConfirm(
            patientUid: resolvedPatientUid,
            doctorUid: doctorAuthUid,
            patientName: resolvedPatientName,
            doctorName: resolvedDoctorName,
            doctorId: doctorId,
            chamberId: chamberId,
            appointmentId: appointmentId,
            visit: slot,
          ),
        );
      }
    });

    // Best effort: a refused chat write must never undo the confirmation.
    if (consultChat != null) {
      try {
        await consultChat!.$1.set(consultChat!.$2, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Consult chat not opened: $e');
      }
    }
    resolvedChamberName = await ChamberResolver.resolveChamberName(
      chamberId: chamberId,
      doctorId: doctorId,
    );

    if (resolvedPatientUid.isNotEmpty) {
      try {
        final timeStr = '${slot.hour > 12 ? slot.hour - 12 : (slot.hour == 0 ? 12 : slot.hour)}:${slot.minute.toString().padLeft(2, '0')} ${slot.hour >= 12 ? 'PM' : 'AM'}';
        final dateStr = '${slot.day}/${slot.month}/${slot.year}';
        await NotificationService.createNotification(
          userId: resolvedPatientUid,
          title: 'Appointment Confirmed! 🎉',
          body: 'Confirmed $dateStr at $timeStr, queue #$assignedQueue, $resolvedDoctorName, $resolvedChamberName',
          type: 'appointment_confirmed',
          relatedId: appointmentId,
        );
      } catch (_) {}
    }
    await ChatService.postAppointmentEvent(
      doctorId: doctorId,
      appointmentId: appointmentId,
      text: '✅ Confirmed: $resolvedPatientName · token #$assignedQueue · ${_eventTime(slot)} · $resolvedChamberName',
    );
  }

  /// "3 Nov, 5:30 PM" for chat event messages.
  static String _eventTime(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
    return '${t.day} ${months[t.month - 1]}, $h:${t.minute.toString().padLeft(2, '0')} ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String eventTime(DateTime t) => _eventTime(t);

  static Future<void> rescheduleAppointment({
    required String appointmentId,
    required DateTime newSlot,
    required String actorUid,
  }) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    final targetDateKey = dateKey(newSlot);

    String resolvedPatientUid = '';
    String resolvedDoctorName = 'Doctor';
    DateTime? oldTime;

    await _db.runTransaction((tx) async {
      final apptSnap = await tx.get(apptRef);
      if (!apptSnap.exists) throw StateError('Appointment not found.');
      final appt = apptSnap.data()!;

      final doctorId = (appt['doctorId'] ?? '').toString();
      final chamberId = (appt['chamberId'] ?? 'chamber').toString();
      resolvedPatientUid = (appt['userId'] ?? '').toString();
      resolvedDoctorName = (appt['doctorName'] ?? 'Doctor').toString();

      final oldTs = appt['scheduledTime'];
      if (oldTs is Timestamp) oldTime = oldTs.toDate();

      final targetSlotDocId = slotId(doctorId, newSlot);
      final slotRef = _db.collection('doctor_slots').doc(targetSlotDocId);
      final overrideRef = _db.collection('chamber_day_overrides').doc('${chamberId}_$targetDateKey');

      final slotSnap = await tx.get(slotRef);
      final override = await tx.get(overrideRef);

      if (override.exists) {
        final st = (override.data()?['status'] ?? '').toString().toLowerCase();
        if (st == 'closed' || st == 'full') {
          throw StateError('This date is closed or fully booked.');
        }
      }

      if (slotSnap.exists && slotSnap.data()?['appointmentId'] != appointmentId) {
        throw StateError('That slot is already taken by another appointment.');
      }

      if (!QueueService.canTransition(appt['status'], ApptStatus.confirmed)) {
        throw StateError('Only requested or confirmed appointments can be rescheduled.');
      }
      // Keeps the token for a same-day move; a new day means a new token.
      final token = await QueueService.assignToken(
        tx,
        appt: appt,
        appointmentId: appointmentId,
        slot: newSlot,
      );

      final oldSlot = appt['slotId']?.toString();
      if (oldSlot != null && oldSlot.isNotEmpty && oldSlot != targetSlotDocId) {
        tx.delete(_db.collection('doctor_slots').doc(oldSlot));
      }

      tx.set(slotRef, {
        'doctorId': doctorId,
        'chamberId': chamberId,
        'appointmentId': appointmentId,
        'date': targetDateKey,
        'startTime': Timestamp.fromDate(newSlot),
        'createdAt': FieldValue.serverTimestamp(),
      });

      tx.update(apptRef, {
        'status': 'confirmed',
        'scheduledTime': Timestamp.fromDate(newSlot),
        'queuePosition': token,
        'queueId': QueueService.queueId(chamberId, doctorId, newSlot),
        'slotId': targetSlotDocId,
        'updatedBy': actorUid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

    });

    if (resolvedPatientUid.isNotEmpty) {
      try {
        String formatT(DateTime dt) =>
            '${dt.day}/${dt.month} ${dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour)}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}';
        final oldStr = oldTime != null ? formatT(oldTime!) : 'previous time';
        final newStr = formatT(newSlot);

        await NotificationService.createNotification(
          userId: resolvedPatientUid,
          title: 'Appointment Rescheduled 🕒',
          body: 'Rescheduled from $oldStr to $newStr with $resolvedDoctorName.',
          type: 'appointment_rescheduled',
          relatedId: appointmentId,
        );
      } catch (_) {}
    }
  }

  static Future<void> releaseSlotAndLock(String appointmentId) async {
    try {
      final apptRef = _db.collection('appointments').doc(appointmentId);
      final apptSnap = await apptRef.get();
      if (!apptSnap.exists) return;
      final data = apptSnap.data() ?? {};

      final slotId = data['slotId']?.toString();
      if (slotId != null && slotId.isNotEmpty) {
        try {
          await _db.collection('doctor_slots').doc(slotId).delete();
        } catch (_) {}
      }

      final activeKey = data['activeBookingKey']?.toString();
      if (activeKey != null && activeKey.isNotEmpty) {
        try {
          await _db.collection('active_bookings').doc(activeKey).delete();
        } catch (_) {}
      } else {
        final patientUid = (data['userId'] ?? '').toString();
        final doctorId = (data['doctorId'] ?? '').toString();
        final chamberId = (data['chamberId'] ?? '').toString();
        final ts = data['scheduledTime'];
        if (patientUid.isNotEmpty && doctorId.isNotEmpty && ts is Timestamp) {
          final dt = ts.toDate();
          final dKey = '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")}';
          final fallbackKey = '${patientUid}_${doctorId}_${chamberId}_$dKey';
          try {
            await _db.collection('active_bookings').doc(fallbackKey).delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
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
  }) async {
    final dKey = dateKey(date);
    final docId = '${chamberId}_$dKey';
    final ref = _db.collection('chamber_day_overrides').doc(docId);

    final data = <String, dynamic>{
      'chamberId': chamberId,
      'doctorId': doctorId,
      'date': dKey,
      'updatedBy': actorUid,
      'updatedAt': FieldValue.serverTimestamp(),
      if (startTime != null) 'startHour': startTime.hour,
      if (startTime != null) 'startMinute': startTime.minute,
      if (endTime != null) 'endHour': endTime.hour,
      if (endTime != null) 'endMinute': endTime.minute,
      if (slotMinutes != null) 'slotMinutes': slotMinutes,
      if (status != null) 'status': status,
      if (note != null) 'note': note,
    };

    await ref.set(data, SetOptions(merge: true));
  }

  static Future<List<DocumentSnapshot<Map<String, dynamic>>>> getAffectedAppointments({
    required String chamberId,
    String? doctorId,
    required DateTime date,
    required TimeOfDay newStartTime,
  }) async {
    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final threshold = DateTime(date.year, date.month, date.day, newStartTime.hour, newStartTime.minute);

    // Operators may only read appointments through (chamberId, doctorId), so
    // the doctor filter is required for the rules to allow this query.
    Query<Map<String, dynamic>> query =
        _db.collection('appointments').where('chamberId', isEqualTo: chamberId);
    if (doctorId != null && doctorId.isNotEmpty) {
      query = query.where('doctorId', isEqualTo: doctorId);
    }
    final snap = await query
        .where('status', isEqualTo: 'confirmed')
        .where('scheduledTime', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('scheduledTime', isLessThan: Timestamp.fromDate(endOfDay))
        .get();

    return snap.docs.where((doc) {
      final ts = doc.data()['scheduledTime'];
      if (ts is Timestamp) {
        return ts.toDate().isBefore(threshold);
      }
      return false;
    }).toList();
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
    required String actorUid,
  }) async {
    final date = specificDate ?? DateTime.now();
    final dKey = dateKey(date);

    final overrideDocId = '${chamberId}_$dKey';
    final overrideSnap = await _db.collection('chamber_day_overrides').doc(overrideDocId).get();
    if (overrideSnap.exists) {
      final st = (overrideSnap.data()?['status'] ?? '').toString().toLowerCase();
      if ((st == 'closed' || st == 'full') && !allowOverrideClosedOrFull) {
        throw StateError('This date is marked as ${st.toUpperCase()}. Please confirm an override to proceed.');
      }
    }

    final chamberRec = await ChamberResolver.resolveChamberRecord(
      chamberId: chamberId,
      doctorId: doctorId,
    );
    final resolvedChamberName = chamberRec?.name ?? 'Chamber';

    String resolvedDoctorName = 'Specialist Doctor';
    try {
      final docSnap = await _db.collection('doctors').doc(doctorId).get();
      if (docSnap.exists) {
        resolvedDoctorName = (docSnap.data()?['name'] ?? resolvedDoctorName).toString();
      }
    } catch (_) {}

    DateTime scheduledSlot;
    bool reserveSlotLock = false;

    if (specificSlot != null) {
      scheduledSlot = specificSlot;
      reserveSlotLock = true;
    } else {
      final freeRes = await getFreeSlots(
        chamberId: chamberId,
        doctorId: doctorId,
        date: date,
      );
      if (freeRes.slots.isNotEmpty) {
        scheduledSlot = freeRes.slots.first;
        reserveSlotLock = true;
      } else {
        scheduledSlot = DateTime.now();
        reserveSlotLock = false;
      }
    }

    final slotDocId = slotId(doctorId, scheduledSlot);
    final slotLockRef = _db.collection('doctor_slots').doc(slotDocId);
    final queueRef = _db.collection('queues').doc(QueueService.queueId(chamberId, doctorId, date));
    final apptRef = _db.collection('appointments').doc();

    int assignedQueuePos = 1;

    await _db.runTransaction((tx) async {
      if (reserveSlotLock) {
        final lockSnap = await tx.get(slotLockRef);
        if (lockSnap.exists) {
          throw StateError('Slot ${scheduledSlot.hour}:${scheduledSlot.minute.toString().padLeft(2, "0")} is already reserved.');
        }
      }

      final queueSnap = await tx.get(queueRef);
      assignedQueuePos = QueueService.nextToken(queueSnap.data());

      tx.set(
        queueRef,
        {
          ...QueueService.joinWrite(
            queueSnap.data(),
            chamberId: chamberId,
            doctorId: doctorId,
            date: dKey,
            token: assignedQueuePos,
            appointmentId: apptRef.id,
          ),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      final isWalkIn = specificDate == null;
      final data = <String, dynamic>{
        'patientName': patientName.trim(),
        if (patientPhone != null && patientPhone.trim().isNotEmpty)
          'patientPhone': patientPhone.trim(),
        'chamberId': chamberId,
        'chamberName': resolvedChamberName,
        'doctorId': doctorId,
        'doctorName': resolvedDoctorName,
        // A walk-in is standing at the desk, so they are already checked in.
        'status': isWalkIn ? ApptStatus.checkedIn : ApptStatus.confirmed,
        if (isWalkIn) 'checkedInAt': FieldValue.serverTimestamp(),
        'source': isWalkIn ? 'walk_in' : 'offline',
        'operatorNote': operatorNote?.trim() ?? '',
        'queuePosition': assignedQueuePos,
        'queueId': queueRef.id,
        'scheduledTime': Timestamp.fromDate(scheduledSlot),
        'slotMinutes': chamberRec?.slotMinutes ?? 10,
        'createdBy': actorUid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      tx.set(apptRef, data);

      if (reserveSlotLock) {
        tx.set(slotLockRef, {
          'appointmentId': apptRef.id,
          'doctorId': doctorId,
          'chamberId': chamberId,
          'date': dKey,
          'startTime': Timestamp.fromDate(scheduledSlot),
          'source': isWalkIn ? 'walk_in' : 'offline',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });

    return {
      'appointmentId': apptRef.id,
      'queuePosition': assignedQueuePos,
      'scheduledTime': scheduledSlot,
    };
  }
}
