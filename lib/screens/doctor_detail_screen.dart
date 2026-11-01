import '../services/scheduling_service.dart';
import '../models/chat_message.dart';
import '../services/chat_service.dart';
import 'bmdc_verification_screen.dart';
import 'doctor_manager_screen.dart';
import '../models/user_role.dart';
import 'chat_screen.dart';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../models/doctor.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/tts_service.dart';
import '../theme/app_constants.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';
import '../widgets/auth_modal.dart';
import '../widgets/chamber_accessibility.dart';
import '../widgets/unclaimed_tag.dart';

String _reviewErrorMessage(Object error) {
  final raw = error.toString();
  if (raw.contains('permission-denied')) {
    return 'Review was blocked by Firebase rules. Deploy the latest firestore.rules, then try again.';
  }
  if (raw.contains('network')) {
    return 'Network error while saving the review. Check your connection and try again.';
  }
  return 'Failed to save review. Please try again.';
}

class DoctorDetailScreen extends StatefulWidget {
  final String doctorId;

  const DoctorDetailScreen({super.key, required this.doctorId});

  @override
  State<DoctorDetailScreen> createState() => _DoctorDetailScreenState();
}

class _DoctorDetailScreenState extends State<DoctorDetailScreen> {
  Doctor? _doctor;
  bool _isLoading = true;
  String? _error;

  List<Map<String, dynamic>> _reviews = [];
  bool _isReviewsLoading = true;

  ChatSession? _unlockedChatSession;

  Future<void> _checkChatUnlock(Doctor doctor) async {
    final uid = AuthService.currentUser?.uid;
    final docUid = doctor.claimedByUid;
    if (uid != null && docUid != null && docUid.isNotEmpty) {
      try {
        final chat = await ChatService.getUnlockedChatForDoctorAndPatient(
          doctorUid: docUid,
          patientUid: uid,
        );
        if (mounted) {
          setState(() {
            _unlockedChatSession = chat;
          });
        }
      } catch (_) {}
    }
  }
  @override
  void initState() {
    super.initState();
    _loadDoctor();
    _loadReviews();
  }

  @override
  void dispose() {
    TtsService.instance.stop();
    super.dispose();
  }

  Future<void> _loadDoctor() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final doctor = await ApiService.fetchDoctorById(widget.doctorId);
      if (!mounted) return;
      setState(() {
        _doctor = doctor;
        _isLoading = false;
      });
      _checkChatUnlock(doctor);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadReviews() async {
    setState(() => _isReviewsLoading = true);
    try {
      final reviews = await ApiService.fetchReviews(widget.doctorId);
      setState(() {
        _reviews = reviews;
        _isReviewsLoading = false;
      });
    } catch (_) {
      setState(() => _isReviewsLoading = false);
    }
  }

  String _buildAboutText(Doctor doctor) {
    final buffer = StringBuffer();
    final primarySpec = doctor.specialities.isNotEmpty
        ? doctor.specialities.first
        : 'medical professional';
    buffer.write('${doctor.name} is a $primarySpec');
    if (doctor.experienceYears > 0) {
      buffer
          .write(' with ${doctor.experienceYears.toInt()} years of experience');
    }
    buffer.write('.');
    if (doctor.education.isNotEmpty) {
      buffer.write(
          ' They hold qualifications in ${doctor.education.join(", ")}.');
    }
    if (doctor.concentrations.isNotEmpty) {
      buffer.write(
          ' Their areas of focus include ${doctor.concentrations.join(", ")}.');
    }
    return buffer.toString();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Review bottom sheet
  // ──────────────────────────────────────────────────────────────────────────

  void _openReviewSheet() async {
    final user = AuthService.currentUser;
    if (user == null || !AuthService.isSignedIn || AuthService.isGuest) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Guests can only check ratings. Please sign in as a Patient, Operator, or Doctor to rate.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        showDoctorDeskAuthModal(context, isSignUp: false);
      }
      return;
    }

    final doctorMap = _doctor != null
        ? {
            '_id': _doctor!.id,
            'id': _doctor!.id,
            'claimedByUid': _doctor!.claimedByUid,
          }
        : null;

    final canRate = await FirestoreService.checkCanReview(
      widget.doctorId,
      user.uid,
      doctorData: doctorMap,
    );

    if (!canRate && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You cannot rate your own doctor profile.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ReviewSheet(
        doctorId: widget.doctorId,
        onSuccess: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Rating saved to reviews — thank you!')),
          );
          _loadReviews();
          _loadDoctor();
        },
      ),
    );
  }

  void _showBookingSheet(Doctor doctor) {
    if (!AuthService.isSignedIn || AuthService.isGuest) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please log in to book an appointment.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final roles = AuthService.userRoles;
    if (roles.doctorProfileId != null &&
        roles.doctorProfileId!.isNotEmpty &&
        roles.doctorProfileId == doctor.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You cannot book an appointment with your own profile.')),
      );
      return;
    }

    // Build (id, label) pairs -- chamberId must be the Firestore doc ID, not the name.
    final isClaimed = doctor.claimedByUid != null && doctor.claimedByUid!.trim().isNotEmpty;
    if (!isClaimed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("This doctor hasn't joined DoctorDesk yet"),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final chamberOptions = <({String id, String label})>[];
    for (final c in doctor.chambers) {
      final id = (c.id ?? '').trim();
      final label = (c.hospitalName ?? '').trim();
      if (id.isNotEmpty) {
        chamberOptions.add((id: id, label: label.isEmpty ? 'Unnamed chamber' : label));
      }
    }
    if (chamberOptions.isEmpty && doctor.chamber != null) {
      final c = doctor.chamber!;
      final id = (c.id ?? '').trim();
      final label = (c.hospitalName ?? '').trim();
      if (id.isNotEmpty) {
        chamberOptions.add((id: id, label: label.isEmpty ? 'Main Chamber' : label));
      }
    }
    if (chamberOptions.isEmpty) {
      debugPrint('[Booking] No chamber IDs found for doctor ${doctor.id}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No bookable chamber found for this doctor. Please try again later.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    String selectedChamberId = chamberOptions.first.id;
    // Today is bookable; slots already past are hidden by getFreeSlots.
    final now = DateTime.now();
    DateTime selectedDate = DateTime(now.year, now.month, now.day);
    // Optional preferred slot; the desk sees it when proposing a time.
    DateTime? preferredSlot;
    Future<FreeSlotsResult>? slotsFuture;
    String slotsKey = '';
    // Preferred date only; time and queue number are assigned upon acceptance.
    final patientNameCtrl = TextEditingController(
      text: AuthService.currentUser?.displayName?.isNotEmpty == true
          ? AuthService.currentUser!.displayName!
          : 'Patient',
    );
    bool isSubmitting = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final viewInsets = MediaQuery.of(context).viewInsets;
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + viewInsets.bottom),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Book with ${doctor.name}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: patientNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Patient Full Name',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedChamberId,
                      decoration: const InputDecoration(
                        labelText: 'Select Chamber',
                        prefixIcon: Icon(Icons.location_on_outlined),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: chamberOptions
                          .map((opt) => DropdownMenuItem(
                              value: opt.id, child: Text(opt.label)))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setSheetState(() => selectedChamberId = val);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Builder(
                      builder: (context) {
                        final selectedChamber = doctor.chambers.firstWhere(
                          (c) => c.id == selectedChamberId,
                          orElse: () => Chamber(id: selectedChamberId),
                        );
                        final schedule = SchedulingService.parseVisitingHours(selectedChamber.visitingHours);

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: Text(
                                  'Preferred Date: ${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
                              onPressed: () async {
                                bool selectable(DateTime d) =>
                                    schedule == null || schedule.isVisitingDay(d);
                                // The picker asserts its initial date is selectable.
                                var initial = selectedDate;
                                for (var i = 0; i < 14 && !selectable(initial); i++) {
                                  initial = initial.add(const Duration(days: 1));
                                }
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: initial,
                                  firstDate: DateTime.now(),
                                  lastDate: DateTime.now().add(const Duration(days: 90)),
                                  selectableDayPredicate: selectable,
                                );
                                if (picked != null) {
                                  setSheetState(() => selectedDate = picked);
                                }
                              },
                            ),
                            const SizedBox(height: 6),
                            FutureBuilder<FreeSlotsResult>(
                              // Fetched once per chamber+date, not on every
                              // chip tap.
                              future: () {
                                final key = '$selectedChamberId|${selectedDate.year}-${selectedDate.month}-${selectedDate.day}';
                                if (key != slotsKey || slotsFuture == null) {
                                  slotsKey = key;
                                  preferredSlot = null;
                                  slotsFuture = SchedulingService.getFreeSlots(
                                    chamberId: selectedChamberId,
                                    doctorId: doctor.id,
                                    date: selectedDate,
                                  );
                                }
                                return slotsFuture;
                              }(),
                              builder: (context, snap) {
                                if (snap.connectionState == ConnectionState.waiting) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 4),
                                    child: LinearProgressIndicator(minHeight: 2),
                                  );
                                }
                                final res = snap.data;
                                if (res == null) return const SizedBox.shrink();
                                if (res.emptyReason == 'Closed') {
                                  return Container(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.red.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.red.shade200),
                                    ),
                                    child: Text(
                                      'Closed on this date (${res.overrideData?['note'] ?? 'No consultations'})',
                                      style: TextStyle(color: Colors.red.shade900, fontSize: 12.5),
                                    ),
                                  );
                                }
                                if (res.emptyReason == 'Fully booked' || (res.totalCapacity > 0 && res.slotsLeft <= 0)) {
                                  return Container(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.orange.shade200),
                                    ),
                                    child: Text(
                                      'Fully booked for this date (0 slots left)',
                                      style: TextStyle(color: Colors.orange.shade900, fontSize: 12.5),
                                    ),
                                  );
                                }
                                if (res.totalCapacity > 0) {
                                  String fmt(DateTime t) {
                                    final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
                                    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour >= 12 ? 'PM' : 'AM'}';
                                  }
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 4),
                                        child: Text(
                                          'Open on ${selectedDate.day}/${selectedDate.month}',
                                          style: TextStyle(
                                            color: Colors.green.shade800,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12.5,
                                          ),
                                        ),
                                      ),
                                      if (res.slots.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        const Text('Preferred time (optional)',
                                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 6),
                                        SizedBox(
                                          height: 40,
                                          child: ListView(
                                            scrollDirection: Axis.horizontal,
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.only(right: 6),
                                                child: ChoiceChip(
                                                  label: const Text('Any time'),
                                                  selected: preferredSlot == null,
                                                  onSelected: (_) => setSheetState(() => preferredSlot = null),
                                                ),
                                              ),
                                              ...res.slots.map((slot) => Padding(
                                                    padding: const EdgeInsets.only(right: 6),
                                                    child: ChoiceChip(
                                                      label: Text(fmt(slot)),
                                                      selected: preferredSlot == slot,
                                                      onSelected: (_) => setSheetState(() => preferredSlot = slot),
                                                    ),
                                                  )),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  );
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: isSubmitting
                          ? null
                          : () async {
                              setSheetState(() => isSubmitting = true);
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                if (AuthService.userRoles.operatorAssignments
                                    .contains(selectedChamberId)) {
                                  throw StateError(
                                    'Operators cannot submit a patient request for a chamber they operate.',
                                  );
                                }
                                final scheduled = DateTime(
                                  selectedDate.year,
                                  selectedDate.month,
                                  selectedDate.day,
                                );
                                final selectedOption = chamberOptions.firstWhere(
                                  (o) => o.id == selectedChamberId,
                                  orElse: () => (id: selectedChamberId, label: 'Chamber'),
                                );
                                await FirestoreService.createAppointment(
                                  patientName:
                                      patientNameCtrl.text.trim().isNotEmpty
                                          ? patientNameCtrl.text.trim()
                                          : 'Patient',
                                  scheduledTime: scheduled,
                                  chamberId: selectedChamberId,
                                  chamberName: selectedOption.label,
                                  doctorId: doctor.id,
                                  doctorName: doctor.name,
                                  status: 'requested',
                                  preferredTime: preferredSlot,
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                          'Request sent. The chamber will propose a time for you to accept.'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              } catch (e) {
                                setSheetState(() => isSubmitting = false);
                                if (mounted) {
                                  final msg = e.toString().contains('already have a request')
                                      ? 'You already have a request for this doctor on this date.'
                                      : 'Booking error: $e';
                                  messenger.showSnackBar(
                                    SnackBar(content: Text(msg)),
                                  );
                                }
                              }
                            },
                      child: isSubmitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Confirm Appointment'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_off_rounded,
                    size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 16),
                Text(
                  'No Internet Connection',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please check your network connection and try again.',
                  style: TextStyle(color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: _loadDoctor,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final doctor = _doctor!;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Doctor Profile',
          style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        actions: [
          if (AuthService.isAdmin) ...[
            TextButton.icon(
              icon: const Icon(Icons.verified_outlined, color: Colors.white, size: 16),
              label: const Text('Verify BMDC', style: TextStyle(color: Colors.white, fontSize: 12)),
              onPressed: () async {
                final res = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BmdcVerificationScreen(
                      doctorId: doctor.id,
                      doctorName: doctor.name,
                      bmdcNumber: doctor.bmdcNumber ?? doctor.bmdcRegNumber ?? '',
                      currentStatus: doctor.verificationStatus,
                    ),
                  ),
                );
                if (res == true) {
                  _loadDoctor();
                }
              },
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. Hero Card (radius 24, gradient from primaryTint to primary) ────
            Container(
              margin: const EdgeInsets.all(AppConstants.screenPadding),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppConstants.radiusHero),
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [Theme.of(context).colorScheme.primaryContainer, Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)],
                ),
                boxShadow: AppConstants.elevatedShadow,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left column
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          doctor.name,
                          style: GoogleFonts.poppins(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (doctor.claimedByUid != null && doctor.claimedByUid!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle, size: 12, color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 4),
                                const Text(
                                  'Claimed',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (!doctor.isClaimedProfile) ...[
                          const SizedBox(height: 4),
                          const UnclaimedTag(),
                        ],
                        if (doctor.verificationStatus == 'checked_found') ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.green.shade300),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.verified, size: 12, color: Colors.green),
                                const SizedBox(width: 4),
                                Text(
                                  _bmdcCheckedLabel(doctor),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.green.shade900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (doctor.specialities.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            doctor.specialities.join(', '),
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 6),
                        StreamBuilder<List<Map<String, dynamic>>>(
                          stream: FirestoreService.reviewsStream(doctor.id),
                          builder: (context, revSnap) {
                            final realReviews = revSnap.data ?? _reviews;
                            final realCount = realReviews.length;
                            final realAvg = realCount > 0
                                ? realReviews.map((r) => (r['rating'] as num?)?.toDouble() ?? 0.0).reduce((a, b) => a + b) / realCount
                                : null;

                            if (realCount == 0) {
                              return Text(
                                'No reviews yet',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textSecondary,
                                ),
                              );
                            }

                            return Row(
                              children: [
                                const Icon(Icons.star, size: 16, color: AppColors.star),
                                const SizedBox(width: 4),
                                Text(
                                  '${realAvg!.toStringAsFixed(1)} ($realCount ${realCount == 1 ? "Review" : "Reviews"})',
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        if (doctor.chambers.isNotEmpty || doctor.chamber != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            doctor.chambers.isNotEmpty
                                ? doctor.chambers.map((c) => c.hospitalName).whereType<String>().join(', ')
                                : (doctor.chamber?.hospitalName ?? ''),
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              color: AppColors.textPrimary.withValues(alpha: 0.8),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Right: circular/large avatar area
                  // Account photo of the claiming doctor; never the BMDC
                  // certificate upload.
                  UserAvatar(
                    uid: doctor.claimedByUid,
                    name: doctor.name,
                    radius: 38,
                    ring: true,
                  ),
                ],
              ),
            ),

            // ── 2. Stat chips row (equal width, outlined, no invented numbers) ────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppConstants.screenPadding),
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: FirestoreService.reviewsStream(doctor.id),
                builder: (context, revSnap) {
                  final realReviews = revSnap.data ?? _reviews;
                  final realCount = realReviews.length;
                  return Row(
                    children: [
                      if (doctor.experienceYears > 0)
                        _buildStatChip(
                          icon: Icons.work_outline,
                          value: '${doctor.experienceYears.toInt()} Years',
                          label: 'Experience',
                        ),
                      if (doctor.experienceYears > 0 && realCount > 0)
                        const SizedBox(width: 10),
                      if (realCount > 0)
                        _buildStatChip(
                          icon: Icons.rate_review_outlined,
                          value: '$realCount',
                          label: realCount == 1 ? 'Review' : 'Reviews',
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: AppConstants.sectionGap),

            // ── 3. About {name} ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppConstants.screenPadding),
              child: _SectionCard(
                title: 'About ${doctor.name}',
                child: Text(
                  _buildAboutText(doctor),
                  style: AppTheme.body,
                ),
              ),
            ),

            // ── 4. Experience bullet list ─────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppConstants.screenPadding),
              child: _SectionCard(
                title: 'Experience',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (doctor.experienceYears > 0)
                      _buildBulletItem('Over ${doctor.experienceYears.toInt()} years of professional clinical practice'),
                    if (doctor.education.isNotEmpty)
                      _buildBulletItem('Qualified: ${doctor.education.join(", ")}'),
                    if (doctor.concentrations.isNotEmpty)
                      _buildBulletItem('Clinical Focus: ${doctor.concentrations.join(", ")}'),
                    if (doctor.verificationStatus == 'checked_found')
                      _buildBulletItem(_bmdcCheckedLabel(doctor)),
                    if (doctor.experienceYears <= 0 && doctor.education.isEmpty)
                      _buildBulletItem('Specialist medical practitioner with registered credentials'),
                  ],
                ),
              ),
            ),

            // ── 5. Specialities (filled primary chips, wrapping) ───────────
            if (doctor.specialities.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppConstants.screenPadding),
                child: _SectionCard(
                  title: 'Specialities',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: doctor.specialities.map((s) {
                      return Chip(
                        label: Text(
                          s,
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppConstants.radiusChip),
                        ),
                        side: BorderSide.none,
                      );
                    }).toList(),
                  ),
                ),
              ),

            // ── 6. Chambers (with accessibility details) ───────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppConstants.screenPadding),
              child: _SectionCard(
                title: 'Chambers',
                child: doctor.chambers.isNotEmpty
                    ? Column(
                        children: doctor.chambers.map((chamber) {
                          return Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(AppConstants.radiusCard),
                              border: Border.all(color: AppColors.borderSubtle),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.location_on_outlined,
                                        color: Theme.of(context).colorScheme.primary, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            chamber.hospitalName ?? 'Consultation Chamber',
                                            style: AppTheme.cardTitle,
                                          ),
                                          if (chamber.area != null && chamber.area!.isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              chamber.area!,
                                              style: AppTheme.body,
                                            ),
                                          ],
                                          if (chamber.location != null && chamber.location!.isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              chamber.location!,
                                              style: AppTheme.caption,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (chamber.isAccessible)
                                      const AccessibilityIcon(
                                        isAccessible: true,
                                        showLabel: true,
                                      ),
                                  ],
                                ),
                                // Accessibility detail features & disclaimer
                                if (chamber.isAccessible) ...[
                                  const SizedBox(height: 10),
                                  const Divider(height: 1),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      const Icon(Icons.info_outline, size: 14, color: AppColors.textSecondary),
                                      const SizedBox(width: 4),
                                      Text(
                                        'This is declared by the doctor.',
                                        style: AppTheme.captionSmall,
                                      ),
                                    ],
                                  ),
                                  if (chamber.accessibilityFeatures.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: chamber.accessibilityFeatures.map((feat) {
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.primaryContainer,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                                          ),
                                          child: Text(
                                            feat,
                                            style: GoogleFonts.poppins(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                              color: Theme.of(context).colorScheme.primary,
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          );
                        }).toList(),
                      )
                    : Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: Colors.grey[400]),
                          const SizedBox(width: 8),
                          Text('No chamber information available', style: AppTheme.caption),
                        ],
                      ),
              ),
            ),

            // ── 7. Patient Reviews ─────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppConstants.screenPadding),
              child: _SectionCard(
                title: 'Patient Reviews',
                child: _buildReviewsContent(),
              ),
            ),

            const SizedBox(height: 100), // Reserve bottom space for floating/fixed button
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.screenPadding),
          child: Builder(
            builder: (context) {
              final isOwnProfile = AuthService.userRoles.doctorProfileId != null &&
                  AuthService.userRoles.doctorProfileId!.isNotEmpty &&
                  AuthService.userRoles.doctorProfileId == doctor.id;
              final isPatientPortal = AuthService.activeRole == UserRole.patient || AuthService.isGuest;

              if (isOwnProfile) {
                return FilledButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DoctorManagerScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Manage profile'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppConstants.radiusButton),
                    ),
                  ),
                );
              }

              if (!isPatientPortal) {
                return const SizedBox.shrink();
              }

              final hasUnlockedChat = _unlockedChatSession != null && _unlockedChatSession!.canSendMessage;
              final isClaimed = doctor.claimedByUid != null && doctor.claimedByUid!.trim().isNotEmpty;
              final theme = Theme.of(context);

              Widget buildBookAppointmentButton({bool isExpanded = false}) {
                if (isClaimed) {
                  return FilledButton(
                    onPressed: () => _showBookingSheet(doctor),
                    style: FilledButton.styleFrom(
                      minimumSize: Size(isExpanded ? 0 : double.infinity, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppConstants.radiusButton),
                      ),
                    ),
                    child: Text(
                      'Book Appointment',
                      style: isExpanded
                          ? AppTheme.buttonText.copyWith(fontSize: 13)
                          : AppTheme.buttonText,
                    ),
                  );
                } else {
                  return OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: theme.primaryColor,
                      side: BorderSide(color: theme.primaryColor.withValues(alpha: 0.4)),
                      minimumSize: Size(isExpanded ? 0 : double.infinity, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppConstants.radiusButton),
                      ),
                    ),
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("This doctor hasn't joined DoctorDesk yet"),
                        behavior: SnackBarBehavior.floating,
                      ),
                    ),
                    child: Text(
                      'Book Appointment',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        color: theme.primaryColor,
                        fontSize: isExpanded ? 13 : 14,
                      ),
                    ),
                  );
                }
              }

              if (hasUnlockedChat) {
                return Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.success,
                          minimumSize: const Size(0, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppConstants.radiusButton),
                          ),
                        ),
                        icon: const Icon(Icons.chat, color: Colors.white, size: 18),
                        label: Text(
                          'Follow-up Chat',
                          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.white),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(
                                chatId: _unlockedChatSession!.id,
                                otherUserName: doctor.name,
                                otherUserUid: doctor.claimedByUid!,
                                isDoctor: false,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 6,
                      child: buildBookAppointmentButton(isExpanded: true),
                    ),
                  ],
                );
              }

              return buildBookAppointmentButton(isExpanded: false);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStatChip({required IconData icon, required String value, required String label}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppConstants.radiusButton),
          border: Border.all(color: Theme.of(context).colorScheme.primary, width: 1.0),
          boxShadow: AppConstants.softShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 4),
            Text(
              value,
              style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              label,
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBulletItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
          Expanded(
            child: Text(text, style: AppTheme.body),
          ),
        ],
      ),
    );
  }

  String _bmdcCheckedLabel(Doctor doctor) {
    DateTime? dt;
    final v = doctor.verifiedAt;
    if (v is Timestamp) {
      dt = v.toDate();
    } else if (v is DateTime) {
      dt = v;
    } else if (v is String) {
      dt = DateTime.tryParse(v);
    }
    if (dt != null) {
      final dateStr = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      return 'Registration checked on $dateStr';
    }
    return 'Registration checked';
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Reviews content widget
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildReviewsContent() {
    final isSignedIn = AuthService.isSignedIn && !AuthService.isGuest;
    final isOwnProfile = AuthService.userRoles.doctorProfileId != null &&
        AuthService.userRoles.doctorProfileId!.isNotEmpty &&
        AuthService.userRoles.doctorProfileId == widget.doctorId;
    final isPatientPortal = AuthService.activeRole == UserRole.patient || AuthService.isGuest;
    final canWriteReview = isPatientPortal && !isOwnProfile;

    const buttonLabel = 'Write a review';

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: FirestoreService.reviewsStream(widget.doctorId),
      builder: (context, snapshot) {
        final reviews = snapshot.data ?? _reviews;
        final isLoading = snapshot.connectionState == ConnectionState.waiting && _isReviewsLoading;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isLoading)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else if (reviews.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    Icon(Icons.rate_review_outlined,
                        size: 40, color: Colors.grey[300]),
                    const SizedBox(height: 8),
                    Text(
                      'No reviews yet',
                      style: TextStyle(color: Colors.grey[500], fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Be the first to share your experience',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                  ],
                ),
              )
            else
              Column(
                children: reviews
                    .map((review) => _ReviewCard(
                          review: review,
                          doctorId: widget.doctorId,
                          onDeleted: () {
                            _loadDoctor();
                          },
                        ))
                    .toList(),
              ),
            const SizedBox(height: 12),
            if (!isSignedIn) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.visibility_outlined,
                        size: 18, color: Colors.grey.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Guest Mode: Viewing ratings only. Sign in to rate this doctor.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          showDoctorDeskAuthModal(context, isSignUp: false),
                      child: const Text('Sign In',
                          style:
                              TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ] else if (canWriteReview) ...[
              TextButton.icon(
                onPressed: _openReviewSheet,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text(buttonLabel),
              ),
            ],
          ],
        );
      },
    );
  }

}

// ════════════════════════════════════════════════════════════════════════════
// Review card
// ════════════════════════════════════════════════════════════════════════════

class _ReviewCard extends StatelessWidget {
  final Map<String, dynamic> review;
  final String? doctorId;
  final VoidCallback? onDeleted;

  const _ReviewCard({
    required this.review,
    this.doctorId,
    this.onDeleted,
  });

  String _formatDate(String? isoString) {
    if (isoString == null || isoString.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoString);
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final int rating = (review['rating'] as num?)?.toInt() ?? 0;
    final String comment = (review['comment'] as String?) ?? '';
    final bool isProofVerified = review['isProofVerified'] == true;
    final String? proofImageUrl = review['proofImageUrl'] as String?;
    final String dateStr = _formatDate(review['createdAt'] as String?);
    final String raterName = (review['raterName'] as String?)?.isNotEmpty == true
        ? (review['raterName'] as String)
        : 'Patient';
    final String? raterRole = review['raterRole'] as String?;
    final currentUid = AuthService.currentUser?.uid;
    final canDelete = (review['userId'] != null && review['userId'] == currentUid) ||
        (review['patientUid'] != null && review['patientUid'] == currentUid) ||
        AuthService.userRoles.isAdmin;


    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppConstants.cardGap),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppConstants.radiusCard),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserAvatar(
                uid: (review['userId'] ?? review['patientUid'])?.toString(),
                name: raterName,
                radius: 16,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            raterName,
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (raterRole == 'doctor') ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Specialist',
                              style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (dateStr.isNotEmpty)
                      Text(
                        dateStr,
                        style: AppTheme.captionSmall,
                      ),
                  ],
                ),
              ),
              Row(
                children: List.generate(5, (i) {
                  return Icon(
                    i < rating ? Icons.star : Icons.star_border,
                    size: 16,
                    color: AppColors.star,
                  );
                }),
              ),
              if (canDelete) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
                  tooltip: 'Delete review',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Delete Review'),
                        content: const Text('Are you sure you want to delete this review?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true && doctorId != null) {
                      final reviewId = review['id'] ?? '${doctorId}_$currentUid';
                      await ApiService.deleteReview(doctorId!, reviewId);
                      onDeleted?.call();
                    }
                  },
                ),
              ],
            ],
          ),
          if (isProofVerified) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.check_circle, size: 13, color: AppColors.success),
                const SizedBox(width: 4),
                Text('Verified visit prescription', style: AppTheme.captionSmall.copyWith(color: AppColors.success, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              comment,
              style: AppTheme.body,
            ),
          ],
          if (proofImageUrl != null && proofImageUrl.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                proofImageUrl,
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Claim bottom sheet (multi-step)
// ════════════════════════════════════════════════════════════════════════════

/// Claiming is intentionally exposed only from Profile > Are you a Doctor.
/// This reusable sheet is kept separate from the doctor detail route.
class ProfileDoctorClaimSheet extends StatefulWidget {
  final String doctorId;
  final String doctorName;
  final VoidCallback onSuccess;

  const ProfileDoctorClaimSheet({
    super.key,
    required this.doctorId,
    required this.doctorName,
    required this.onSuccess,
  });

  @override
  State<ProfileDoctorClaimSheet> createState() => _ProfileDoctorClaimSheetState();
}

class _ProfileDoctorClaimSheetState extends State<ProfileDoctorClaimSheet> {
  final _bmdcController = TextEditingController();
  File? _certFile;
  double? _uploadProgress;
  String? _certDownloadUrl;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _bmdcController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadCert() async {
    final uid = AuthService.currentUser!.uid;
    final picker = ImagePicker();
    final XFile? picked =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;

    setState(() {
      _certFile = File(picked.path);
      _uploadProgress = 0;
      _certDownloadUrl = null;
    });

    final ref = FirebaseStorage.instance.ref('claims/$uid/certificate.jpg');
    final task = ref.putFile(_certFile!);

    task.snapshotEvents.listen((snapshot) {
      if (!mounted) return;
      setState(() {
        _uploadProgress = snapshot.bytesTransferred / snapshot.totalBytes;
      });
    });

    final snap = await task;
    final url = await snap.ref.getDownloadURL();
    if (!mounted) return;
    setState(() {
      _certDownloadUrl = url;
      _uploadProgress = null;
    });
  }

  Future<void> _submit() async {
    final bmdcNum = _bmdcController.text.trim();
    if (bmdcNum.isEmpty) return;

    setState(() => _isSubmitting = true);
    try {
      await ApiService.claimDoctor(
        widget.doctorId,
        bmdcRegNumber: bmdcNum,
        claimedByUid: AuthService.currentUser!.uid,
        certificateImageUrl: _certDownloadUrl,
      );
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSuccess();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to submit claim: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets;
    final bmdcFilled = _bmdcController.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Claim this profile',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Step 1: BMDC number
          Text('Step 1: BMDC Registration',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: Colors.grey[600])),
          const SizedBox(height: 8),
          TextField(
            controller: _bmdcController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'BMDC Registration Number',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),

          const SizedBox(height: 20),

          // Step 2: Certificate upload
          Text('Step 2: Upload document (recommended)',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: Colors.grey[600])),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton.outlined(
                icon: const Icon(Icons.upload_file),
                onPressed: _uploadProgress != null ? null : _pickAndUploadCert,
                tooltip: 'Upload certificate or ID photo',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _uploadProgress != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(value: _uploadProgress),
                          const SizedBox(height: 4),
                          Text(
                            '${((_uploadProgress ?? 0) * 100).toStringAsFixed(0)}% uploaded',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
                      )
                    : _certDownloadUrl != null
                        ? Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(_certFile!,
                                    width: 48, height: 48, fit: BoxFit.cover),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.check_circle,
                                  color: Colors.green, size: 20),
                              const SizedBox(width: 4),
                              Text('Uploaded',
                                  style: TextStyle(
                                      color: Colors.green[700], fontSize: 13)),
                            ],
                          )
                        : Text(
                            'Upload certificate or ID photo (recommended)',
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 13),
                          ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Submit button
          SizedBox(
            width: double.infinity,
            child: _isSubmitting
                ? const Center(child: CircularProgressIndicator())
                : FilledButton(
                    onPressed: bmdcFilled ? _submit : null,
                    child: const Text('Submit Claim'),
                  ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Review bottom sheet
// ════════════════════════════════════════════════════════════════════════════

class _ReviewSheet extends StatefulWidget {
  final String doctorId;
  final VoidCallback onSuccess;

  const _ReviewSheet({required this.doctorId, required this.onSuccess});

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  int _selectedRating = 0;
  final _commentController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selectedRating == 0) return;
    setState(() => _isSubmitting = true);
    try {
      await ApiService.submitReview(
        widget.doctorId,
        patientUid: AuthService.currentUser!.uid,
        rating: _selectedRating,
        comment: _commentController.text.trim(),
      );
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSuccess();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_reviewErrorMessage(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Share your experience',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      AuthService.userRoles.isDoctor
                          ? 'Rating as Doctor Specialist (Peer review)'
                          : (AuthService.userRoles.isOperator
                              ? 'Rating as Chamber Operator'
                              : 'Rating as Verified Patient'),
                      style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.amber.shade900,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Star selector
            Text('Your rating',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 8),
            Row(
              children: List.generate(5, (i) {
                final starValue = i + 1;
                return GestureDetector(
                  onTap: () => setState(() => _selectedRating = starValue),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      starValue <= _selectedRating
                          ? Icons.star
                          : Icons.star_border,
                      color: Colors.amber[700],
                      size: 36,
                    ),
                  ),
                );
              }),
            ),

            const SizedBox(height: 16),

            // Comment
            Text('Comment (optional)',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 8),
            TextField(
              controller: _commentController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Describe your experience…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),

            const SizedBox(height: 16),

            // Submit
            SizedBox(
              width: double.infinity,
              child: _isSubmitting
                  ? const Center(child: CircularProgressIndicator())
                  : FilledButton(
                      onPressed: _selectedRating > 0 ? _submit : null,
                      child: const Text('Submit Rating'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Shared helper widgets
// ════════════════════════════════════════════════════════════════════════════

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppConstants.sectionGap),
      padding: const EdgeInsets.all(AppConstants.screenPadding),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppConstants.radiusCard),
        boxShadow: AppConstants.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTheme.sectionTitle,
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
