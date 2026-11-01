import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../theme/app_constants.dart';
import '../services/appointment_queries.dart';
import '../services/auth_service.dart';
import '../services/chamber_resolver.dart';
import '../services/data_service.dart';
import '../services/firestore_service.dart';
import '../services/queue_service.dart';
import '../services/scheduling_service.dart';
import '../widgets/state_views.dart';
import '../widgets/profile_avatar_button.dart';

/// Operator Desk starts with assigned chambers. Selecting one opens a focused
/// request / queue / completed workspace without exposing document IDs.
class OperatorDeskScreen extends StatefulWidget {
  const OperatorDeskScreen({
    super.key,
    this.chamberId,
    this.doctorId,
    this.showAppBar = true,
  });

  final String? chamberId;
  final String? doctorId;
  final bool showAppBar;

  @override
  State<OperatorDeskScreen> createState() => _OperatorDeskScreenState();
}

class _DeskAssignment {
  final String chamberId;
  final String? doctorId;
  final String chamberName;
  final String? doctorName;

  const _DeskAssignment({
    required this.chamberId,
    this.doctorId,
    required this.chamberName,
    this.doctorName,
  });
}

class _OperatorDeskScreenState extends State<OperatorDeskScreen> {
  final Map<String, String> _chamberNames = {};
  final Map<String, Future<List<String>>> _doctorFutures = {};
  List<_DeskAssignment> _assignedDesks = const [];
  bool _loading = true;
  String? _error;

  bool get _isDetail => widget.chamberId != null && widget.chamberId!.isNotEmpty;
  String? get _resolvedDoctorId {
    if (widget.doctorId != null && widget.doctorId!.trim().isNotEmpty) {
      return widget.doctorId!.trim();
    }
    final docProf = AuthService.userRoles.doctorProfileId;
    if (docProf != null && docProf.trim().isNotEmpty) {
      return docProf.trim();
    }
    return null;
  }
  // Doctor mode only when the desk belongs to the signed-in user's own doctor
  // profile. An operator opening a chamber also passes a doctorId, but must use
  // the chamber-scoped queries: the rules only let operators read appointments
  // through (chamberId, doctorId), so doctor-wide queries are refused.
  bool get _isDoctorDesk {
    final own = AuthService.userRoles.doctorProfileId?.trim();
    return own != null && own.isNotEmpty && own == _resolvedDoctorId;
  }

  @override
  void initState() {
    super.initState();
    _loadAssignments();
  }

  Future<void> _loadAssignments() async {
    try {
      if (_isDoctorDesk) {
        final docId = _resolvedDoctorId!;
        // Query chambers for this doctor across all chambers using doctorIds array or ownerDoctorId
        final chSnap = await FirebaseFirestore.instance
            .collection('chambers')
            .where('doctorIds', arrayContains: docId)
            .get();
        final docChambers = <String>[];
        for (final doc in chSnap.docs) {
          docChambers.add(doc.id);
          final d = doc.data();
          final name = (d['name'] ?? d['chamberName'] ?? d['hospitalName'] ?? '').toString().trim();
          if (name.isNotEmpty) _chamberNames[doc.id] = name;
        }

        if (docChambers.isEmpty) {
          final ownerSnap = await FirebaseFirestore.instance
              .collection('chambers')
              .where('ownerDoctorId', isEqualTo: docId)
              .get();
          for (final doc in ownerSnap.docs) {
            docChambers.add(doc.id);
            final d = doc.data();
            final name = (d['name'] ?? d['chamberName'] ?? d['hospitalName'] ?? '').toString().trim();
            if (name.isNotEmpty) _chamberNames[doc.id] = name;
          }
        }

        if (docChambers.isEmpty) {
          final docSnap = await FirebaseFirestore.instance.collection('doctors').doc(docId).get();
          final chList = (docSnap.data()?['chambers'] as List?) ?? [];
          for (final c in chList) {
            if (c is Map) {
              final id = (c['id'] ?? '').toString().trim();
              final name = (c['hospitalName'] ?? c['name'] ?? '').toString().trim();
              if (id.isNotEmpty) {
                docChambers.add(id);
                if (name.isNotEmpty) _chamberNames[id] = name;
              }
            }
          }
        }

        // Re-route any pending requests on load with the doctor's doctorProfileId
        await DataService.reroutePendingRequests(doctorId: docId);

        final desks = <_DeskAssignment>[];
        for (final id in docChambers) {
          desks.add(_DeskAssignment(
            chamberId: id,
            doctorId: docId,
            chamberName: _chamberNames[id] ?? _chamberName(id),
          ));
        }

        if (!mounted) return;
        setState(() {
          _assignedDesks = desks;
          _loading = false;
          _error = null;
        });
        return;
      }

      final uid = AuthService.currentUser?.uid;
      final desks = <_DeskAssignment>[];

      if (uid != null) {
        final opQuery = await FirebaseFirestore.instance
            .collection('chamber_operators')
            .where('operatorUid', isEqualTo: uid)
            .get();

        for (final doc in opQuery.docs) {
          final d = doc.data();
          final chId = (d['chamberId'] ?? '').toString().trim();
          final docId = (d['doctorId'] ?? '').toString().trim();
          final chName = (d['chamberName'] ?? '').toString().trim();
          final docName = (d['doctorName'] ?? '').toString().trim();
          if (chId.isNotEmpty) {
            final name = chName.isNotEmpty ? chName : _chamberName(chId);
            _chamberNames[chId] = name;
            desks.add(_DeskAssignment(
              chamberId: chId,
              doctorId: docId.isNotEmpty ? docId : null,
              chamberName: name,
              doctorName: docName.isNotEmpty ? docName : null,
            ));
          }
        }
      }

      if (desks.isEmpty) {
        final profile = uid == null ? null : await DataService.fetchUserProfile(uid);
        final assigned = (profile?['operatorAssignments'] as List?)
                ?.map((value) => value.toString())
                .where((value) => value.isNotEmpty)
                .toList() ??
            AuthService.userRoles.operatorAssignments;
        final assignedDetails = (profile?['assignedChambers'] as List?) ?? const [];
        for (final detail in assignedDetails) {
          if (detail is Map) {
            final id = (detail['chamberId'] ?? detail['id'] ?? '').toString();
            final name = (detail['chamberName'] ?? detail['name'] ?? '').toString().trim();
            if (id.isNotEmpty && name.isNotEmpty) _chamberNames[id] = name;
          }
        }
        for (final chamberId in assigned) {
          if (!_chamberNames.containsKey(chamberId)) {
            final chamber = await FirebaseFirestore.instance.collection('chambers').doc(chamberId).get();
            final data = chamber.data();
            final name = (data?['name'] ?? data?['chamberName'] ?? data?['hospitalName'] ?? '').toString().trim();
            if (name.isNotEmpty) _chamberNames[chamberId] = name;
          }
          desks.add(_DeskAssignment(
            chamberId: chamberId,
            chamberName: _chamberName(chamberId),
          ));
        }
      }

      // Recompute handledBy on load, one desk at a time: operators can only
      // read appointments through (chamberId, doctorId).
      for (final desk in desks) {
        await DataService.reroutePendingRequests(
          chamberIds: [desk.chamberId],
          doctorId: desk.doctorId,
        );
      }

      if (!mounted) return;
      setState(() {
        _assignedDesks = desks;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load chamber assignments.';
      });
    }
  }

  String _chamberName(String chamberId) {
    final cached = _chamberNames[chamberId];
    if (cached != null && cached.isNotEmpty && !cached.startsWith('chamber-')) {
      return cached;
    }
    final res = ChamberResolver.getCached(chamberId);
    return res != 'Chamber' ? res : 'Chamber';
  }

  Future<List<String>> _doctorsFor(String chamberId) =>
      _doctorFutures.putIfAbsent(chamberId, () => DataService.fetchChamberDoctors(chamberId, chamberName: _chamberNames[chamberId]));

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const LoadingView(message: 'Loading your chambers…')
        : _error != null
            ? ErrorStateView(message: _error!, onRetry: _loadAssignments)
            : _assignedDesks.isEmpty
                ? EmptyStateView(
                    icon: Icons.storefront_outlined,
                    title: _isDoctorDesk
                        ? 'No chambers yet'
                        : 'No chamber assignments',
                    message: _isDoctorDesk
                        ? 'Add a chamber in the Chambers tab'
                        : 'No chamber assignments are available for this operator.',
                  )
                : _isDetail
                    ? _ChamberDeskDetail(
                        chamberId: widget.chamberId!,
                        chamberName: _chamberName(widget.chamberId!),
                        doctorId: widget.doctorId,
                        isDoctorDesk: _isDoctorDesk,
                      )
                    : _ChamberSelectionList(
                        desks: _assignedDesks,
                        doctorsFor: _doctorsFor,
                        isDoctorDesk: _isDoctorDesk,
                      );

    if (!widget.showAppBar) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isDetail ? _chamberName(widget.chamberId!) : 'Chamber Desk'),
        actions: const [
          ProfileAvatarButton(),
          SizedBox(width: 8),
        ],
      ),
      body: body,
    );
  }
}

class _ChamberSelectionList extends StatelessWidget {
  const _ChamberSelectionList({
    required this.desks,
    required this.doctorsFor,
    this.isDoctorDesk = false,
  });

  final List<_DeskAssignment> desks;
  final Future<List<String>> Function(String) doctorsFor;
  final bool isDoctorDesk;

  @override
  Widget build(BuildContext context) {
    if (desks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            isDoctorDesk
                ? 'Add a chamber in the Chambers tab'
                : 'No chamber assignments are available for this operator.',
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Assigned chambers', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('Open a chamber to manage requests and today\'s queue.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        for (final desk in desks)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ChamberCard(
              desk: desk,
              doctors: doctorsFor(desk.chamberId),
              isDoctorDesk: isDoctorDesk,
            ),
          ),
      ],
    );
  }
}

class _ChamberCard extends StatelessWidget {
  const _ChamberCard({
    required this.desk,
    required this.doctors,
    this.isDoctorDesk = false,
  });

  final _DeskAssignment desk;
  final Future<List<String>> doctors;
  final bool isDoctorDesk;

  @override
  Widget build(BuildContext context) {
    final docId = desk.doctorId ?? (isDoctorDesk ? AuthService.userRoles.doctorProfileId : null);
    final queueQuery = isDoctorDesk && docId != null
        ? AppointmentQueries.todayQueueForDoctor(docId)
        : AppointmentQueries.todayQueueForChamber(desk.chamberId, doctorId: desk.doctorId);

    final requestsQuery = isDoctorDesk && docId != null
        ? AppointmentQueries.pendingRequestsForDoctor(docId)
        : AppointmentQueries.pendingRequestsForChamber(desk.chamberId, doctorId: desk.doctorId);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: queueQuery.snapshots(),
      builder: (context, queueSnapshot) {
        final waiting = queueSnapshot.data?.docs.length ?? 0;
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: requestsQuery.snapshots(),
          builder: (context, reqSnapshot) {
            final requestCount = reqSnapshot.data?.docs.length ?? 0;
            return Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
                leading: const CircleAvatar(child: Icon(Icons.local_hospital_outlined)),
                title: Text(desk.chamberName, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 5),
                    if (desk.doctorName != null && desk.doctorName!.isNotEmpty)
                      Text(
                        desk.doctorName!,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      FutureBuilder<List<String>>(
                        future: doctors,
                        builder: (context, snapshot) {
                          final doctorNames = snapshot.data ?? const [];
                          if (doctorNames.isEmpty) {
                            return const Text('No doctors listed');
                          }
                          final countLabel = '${doctorNames.length} ${doctorNames.length == 1 ? "doctor" : "doctors"}';
                          return Text(
                            '$countLabel: ${doctorNames.join(", ")}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          );
                        },
                      ),
                    const SizedBox(height: 7),
                    Text('$requestCount requests, $waiting waiting', style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OperatorDeskScreen(
                      chamberId: desk.chamberId,
                      doctorId: desk.doctorId,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ChamberDeskDetail extends StatelessWidget {
  const _ChamberDeskDetail({
    required this.chamberId,
    required this.chamberName,
    this.doctorId,
    this.isDoctorDesk = false,
  });

  final String chamberId;
  final String chamberName;
  final String? doctorId;
  final bool isDoctorDesk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docId = doctorId ?? (isDoctorDesk ? AuthService.userRoles.doctorProfileId : null);
    final requestsQuery = isDoctorDesk && docId != null
        ? AppointmentQueries.pendingRequestsForDoctor(docId)
        : AppointmentQueries.pendingRequestsForChamber(chamberId, doctorId: doctorId);

    final queueQuery = isDoctorDesk && docId != null
        ? AppointmentQueries.todayQueueForDoctor(docId)
        : AppointmentQueries.todayQueueForChamber(chamberId, doctorId: doctorId);

    final doneQuery = isDoctorDesk && docId != null
        ? AppointmentQueries.completedForDoctor(docId)
        : AppointmentQueries.completedForChamber(chamberId, doctorId: doctorId);

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          // 2.7 Desk Header: Visiting hours, slot length, capacity, and action buttons
          _ChamberScheduleHeader(
            chamberId: chamberId,
            chamberName: chamberName,
            doctorId: doctorId,
          ),
          TabBar(
            labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: theme.colorScheme.primary,
            tabs: const [
              Tab(text: 'Requests'),
              Tab(text: "Today's Queue"),
              Tab(text: 'Done'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _AppointmentList(
                  query: requestsQuery,
                  view: _DeskView.requests,
                  chamberId: chamberId,
                ),
                _AppointmentList(
                  query: queueQuery,
                  view: _DeskView.queue,
                  chamberId: chamberId,
                ),
                _AppointmentList(
                  query: doneQuery,
                  view: _DeskView.done,
                  chamberId: chamberId,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChamberScheduleHeader extends StatelessWidget {
  final String chamberId;
  final String chamberName;
  final String? doctorId;

  const _ChamberScheduleHeader({
    required this.chamberId,
    required this.chamberName,
    this.doctorId,
  });

  String _formatTime(TimeOfDay t) {
    final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
    final p = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $p';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    final dKey = SchedulingService.dateKey(today);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('chamber_day_overrides')
          .doc('${chamberId}_$dKey')
          .snapshots(),
      builder: (context, overrideSnap) {
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: AppointmentQueries.todayQueueForChamber(chamberId, doctorId: doctorId).snapshots(),
          builder: (context, queueSnap) {
            return FutureBuilder<ChamberRecord?>(
              future: ChamberResolver.resolveChamberRecord(
                chamberId: chamberId,
                doctorId: doctorId,
              ),
              builder: (context, chamberSnap) {
                final chamber = chamberSnap.data;
                final overrideData = overrideSnap.data?.data();

                final schedule = SchedulingService.parseVisitingHours(chamber?.visitingHours);
                TimeOfDay start = schedule?.start ?? const TimeOfDay(hour: 17, minute: 0);
                TimeOfDay end = schedule?.end ?? const TimeOfDay(hour: 21, minute: 0);
                int slotMinutes = chamber?.slotMinutes ?? 10;
                String status = 'open';

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
                  if (overrideData['status'] != null) {
                    status = overrideData['status'].toString().toLowerCase();
                  }
                }

                final totalCap = SchedulingService.capacity(start, end, slotMinutes);
                final confirmedCount = queueSnap.data?.docs.length ?? 0;

                final String headerText;
                if (totalCap == 0 || (schedule == null && overrideData == null)) {
                  headerText = 'Visiting hours not set for this chamber';
                } else if (status == 'closed') {
                  headerText = 'Today: Closed (${_formatTime(start)} to ${_formatTime(end)})';
                } else if (status == 'full' || (totalCap > 0 && confirmedCount >= totalCap)) {
                  headerText = 'Today: Fully booked';
                } else {
                  headerText = 'Today ${_formatTime(start)} to ${_formatTime(end)} · $slotMinutes min per patient';
                }

                return Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.1))),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            status == 'closed'
                                ? Icons.do_not_disturb_on
                                : status == 'full'
                                    ? Icons.event_busy
                                    : Icons.access_time_filled,
                            size: 18,
                            color: status == 'closed'
                                ? Colors.red
                                : status == 'full'
                                    ? Colors.orange
                                    : theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              headerText,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: status == 'closed'
                                    ? Colors.red.shade800
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ActionChip(
                              avatar: const Icon(Icons.person_add_alt_1, size: 14),
                              label: const Text('Add walk-in'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _showWalkInDialog(context),
                            ),
                            const SizedBox(width: 6),
                            ActionChip(
                              avatar: const Icon(Icons.edit_calendar, size: 14),
                              label: const Text('Change today\'s hours'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _showChangeHoursDialog(context, start, end, slotMinutes),
                            ),
                            const SizedBox(width: 6),
                            if (status != 'full')
                              ActionChip(
                                avatar: const Icon(Icons.block, size: 14),
                                label: const Text('Mark full'),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _setDayStatus(context, 'full'),
                              ),
                            if (status != 'closed') ...[
                              const SizedBox(width: 6),
                              ActionChip(
                                avatar: const Icon(Icons.close, size: 14, color: Colors.red),
                                label: const Text('Close day'),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _showCloseDayDialog(context),
                              ),
                            ],
                            if (status == 'closed' || status == 'full') ...[
                              const SizedBox(width: 6),
                              ActionChip(
                                avatar: const Icon(Icons.refresh, size: 14, color: Colors.green),
                                label: const Text('Reopen'),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _setDayStatus(context, 'open'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _setDayStatus(BuildContext context, String status, {String? note}) async {
    try {
      final actorUid = AuthService.currentUser?.uid ?? 'system';
      await SchedulingService.setDayOverride(
        chamberId: chamberId,
        doctorId: doctorId ?? '',
        date: DateTime.now(),
        status: status,
        note: note,
        actorUid: actorUid,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Day marked as $status.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating day status: $e')),
        );
      }
    }
  }

  Future<void> _showWalkInDialog(BuildContext context) async {
    final doctors = await DataService.fetchChamberDoctorDetails(chamberId, chamberName: chamberName);
    if (!context.mounted) return;

    if (doctors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No doctors are currently listed for this chamber.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    String selectedDoctorId = doctorId != null && doctorId!.isNotEmpty
        ? doctorId!
        : (doctors.first['doctorId'] as String);
    String selectedMode = 'walk_in';
    DateTime selectedDate = DateTime.now();
    DateTime? selectedSlot;
    List<DateTime> availableSlots = [];
    bool loadingSlots = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.person_add_alt_1),
                const SizedBox(width: 8),
                Text(selectedMode == 'walk_in' ? 'Add Walk-in' : 'Offline Booking'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'walk_in', label: Text('Today Walk-in')),
                        ButtonSegment(value: 'offline', label: Text('Specific Date')),
                      ],
                      selected: {selectedMode},
                      onSelectionChanged: (val) async {
                        setDialogState(() {
                          selectedMode = val.first;
                          selectedSlot = null;
                        });
                        if (selectedMode == 'offline') {
                          setDialogState(() => loadingSlots = true);
                          final res = await SchedulingService.getFreeSlots(
                            chamberId: chamberId,
                            doctorId: selectedDoctorId,
                            date: selectedDate,
                          );
                          setDialogState(() {
                            availableSlots = res.slots;
                            loadingSlots = false;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Patient Name *',
                        hintText: 'Enter patient full name',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number (optional)',
                        hintText: '01XXXXXXXXX',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: selectedDoctorId,
                      decoration: const InputDecoration(labelText: 'Assign Doctor'),
                      items: doctors.map((d) {
                        return DropdownMenuItem<String>(
                          value: d['doctorId'] as String,
                          child: Text(d['name'] as String),
                        );
                      }).toList(),
                      onChanged: (val) async {
                        if (val != null) {
                          setDialogState(() {
                            selectedDoctorId = val;
                            selectedSlot = null;
                          });
                          if (selectedMode == 'offline') {
                            setDialogState(() => loadingSlots = true);
                            final res = await SchedulingService.getFreeSlots(
                              chamberId: chamberId,
                              doctorId: selectedDoctorId,
                              date: selectedDate,
                            );
                            setDialogState(() {
                              availableSlots = res.slots;
                              loadingSlots = false;
                            });
                          }
                        }
                      },
                    ),
                    if (selectedMode == 'offline') ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Date: ${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.calendar_today, size: 14),
                            label: const Text('Pick Date'),
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: dialogCtx,
                                initialDate: selectedDate,
                                firstDate: DateTime.now(),
                                lastDate: DateTime.now().add(const Duration(days: 60)),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  selectedDate = picked;
                                  selectedSlot = null;
                                  loadingSlots = true;
                                });
                                final res = await SchedulingService.getFreeSlots(
                                  chamberId: chamberId,
                                  doctorId: selectedDoctorId,
                                  date: picked,
                                );
                                setDialogState(() {
                                  availableSlots = res.slots;
                                  loadingSlots = false;
                                });
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (loadingSlots)
                        const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
                      else if (availableSlots.isEmpty)
                        const Text('No free slots found. Patient will be placed in queue without a locked slot.', style: TextStyle(fontSize: 12, color: Colors.orange))
                      else ...[
                        const Text('Select Free Slot (Optional):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: availableSlots.map((slot) {
                            final h = slot.hour > 12 ? slot.hour - 12 : (slot.hour == 0 ? 12 : slot.hour);
                            final p = slot.hour >= 12 ? 'PM' : 'AM';
                            final label = '$h:${slot.minute.toString().padLeft(2, "0")} $p';
                            return ChoiceChip(
                              label: Text(label, style: const TextStyle(fontSize: 11)),
                              selected: selectedSlot == slot,
                              onSelected: (val) {
                                setDialogState(() => selectedSlot = val ? slot : null);
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                    const SizedBox(height: 10),
                    TextField(
                      controller: noteCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Reason / Note (optional)',
                        hintText: 'e.g. Walk-in follow-up consultation',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter patient name.')),
                    );
                    return;
                  }

                  final targetDate = selectedMode == 'offline' ? selectedDate : DateTime.now();
                  final dKey = SchedulingService.dateKey(targetDate);
                  final overrideSnap = await FirebaseFirestore.instance
                      .collection('chamber_day_overrides')
                      .doc('${chamberId}_$dKey')
                      .get();
                  bool allowOverride = false;
                  if (overrideSnap.exists) {
                    final st = (overrideSnap.data()?['status'] ?? '').toString().toLowerCase();
                    if (st == 'closed' || st == 'full') {
                      if (!dialogCtx.mounted) return;
                      final confirm = await showDialog<bool>(
                        context: dialogCtx,
                        builder: (confirmCtx) => AlertDialog(
                          title: Text('Date is $st'.toUpperCase()),
                          content: Text('This chamber is marked as $st for ${targetDate.day}/${targetDate.month}. Do you want to proceed and add this patient anyway?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(confirmCtx, false), child: const Text('No, cancel')),
                            FilledButton(onPressed: () => Navigator.pop(confirmCtx, true), child: const Text('Yes, add anyway')),
                          ],
                        ),
                      );
                      if (confirm != true) return;
                      allowOverride = true;
                    }
                  }

                  try {
                    final res = await DataService.createWalkInAppointment(
                      chamberId: chamberId,
                      doctorId: selectedDoctorId,
                      patientName: name,
                      patientPhone: phoneCtrl.text.trim(),
                      operatorNote: noteCtrl.text.trim(),
                      specificDate: selectedMode == 'offline' ? selectedDate : null,
                      specificSlot: selectedSlot,
                      allowOverrideClosedOrFull: allowOverride,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Patient added to queue as #${res["queuePosition"]}!'),
                          backgroundColor: AppColors.success,
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to add patient: $e')),
                      );
                    }
                  }
                },
                child: const Text('Add to Queue'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showCloseDayDialog(BuildContext context) async {
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close Today?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('No new appointments can be booked or accepted for today.'),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason / Note (optional)',
                hintText: 'e.g. Doctor in emergency surgery',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Close Day'),
          ),
        ],
      ),
    );

    if (ok == true && context.mounted) {
      await _setDayStatus(context, 'closed', note: noteCtrl.text.trim());
    }
  }

  Future<void> _showChangeHoursDialog(
    BuildContext context,
    TimeOfDay currentStart,
    TimeOfDay currentEnd,
    int currentSlotMinutes,
  ) async {
    TimeOfDay pickedStart = currentStart;
    TimeOfDay pickedEnd = currentEnd;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return AlertDialog(
            title: const Text('Change Today\'s Hours'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Start Time'),
                  trailing: TextButton(
                    onPressed: () async {
                      final t = await showTimePicker(context: dialogCtx, initialTime: pickedStart);
                      if (t != null) setDialogState(() => pickedStart = t);
                    },
                    child: Text(_formatTime(pickedStart), style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('End Time'),
                  trailing: TextButton(
                    onPressed: () async {
                      final t = await showTimePicker(context: dialogCtx, initialTime: pickedEnd);
                      if (t != null) setDialogState(() => pickedEnd = t);
                    },
                    child: Text(_formatTime(pickedEnd), style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogCtx, true), child: const Text('Save Hours')),
            ],
          );
        },
      ),
    );

    if (confirmed != true || !context.mounted) return;

    // Check for affected patients confirmed before the new start time. This is
    // advisory, so a failed lookup must not stop the hours being saved.
    var affected = <DocumentSnapshot<Map<String, dynamic>>>[];
    try {
      affected = await SchedulingService.getAffectedAppointments(
        chamberId: chamberId,
        doctorId: doctorId ?? AuthService.userRoles.doctorProfileId,
        date: DateTime.now(),
        newStartTime: pickedStart,
      );
    } catch (e) {
      debugPrint('Affected-appointments check failed: $e');
    }

    if (affected.isNotEmpty && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${affected.length} Confirmed Patient(s) Affected'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('The following patient(s) were scheduled before the new start time. Please review and reschedule them:'),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: affected.length,
                    itemBuilder: (c, i) {
                      final d = affected[i].data()!;
                      final pName = d['patientName'] ?? 'Patient';
                      final ts = d['scheduledTime'];
                      final tStr = ts is Timestamp ? '${ts.toDate().hour}:${ts.toDate().minute.toString().padLeft(2, '0')}' : 'Time';
                      return ListTile(
                        dense: true,
                        title: Text(pName),
                        subtitle: Text('Scheduled: $tStr (Queue #${d['queuePosition'] ?? '-'})'),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got It')),
          ],
        ),
      );
    }

    try {
      final actorUid = AuthService.currentUser?.uid ?? 'system';
      await SchedulingService.setDayOverride(
        chamberId: chamberId,
        doctorId: doctorId ?? '',
        date: DateTime.now(),
        startTime: pickedStart,
        endTime: pickedEnd,
        status: 'open',
        actorUid: actorUid,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Today\'s hours updated.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyErrorMessage(e, what: 'today\'s hours'))),
        );
      }
    }
  }
}

enum _DeskView { requests, queue, done }

class _AppointmentList extends StatefulWidget {
  const _AppointmentList({
    required this.query,
    required this.view,
    required this.chamberId,
  });

  final Query<Map<String, dynamic>> query;
  final _DeskView view;
  final String chamberId;

  @override
  State<_AppointmentList> createState() => _AppointmentListState();
}

class _AppointmentListState extends State<_AppointmentList> {
  // Held in state so parent rebuilds don't re-subscribe, and Retry can.
  late Stream<QuerySnapshot<Map<String, dynamic>>> _stream;

  _DeskView get view => widget.view;
  String get chamberId => widget.chamberId;

  @override
  void initState() {
    super.initState();
    _stream = widget.query.snapshots();
  }

  @override
  void didUpdateWidget(covariant _AppointmentList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chamberId != widget.chamberId ||
        oldWidget.view != widget.view) {
      _stream = widget.query.snapshots();
    }
  }

  void _retry() => setState(() => _stream = widget.query.snapshots());

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ErrorStateView.fromError(snapshot.error,
              onRetry: _retry, what: 'appointments');
        }
        if (!snapshot.hasData) return const LoadingView();
        final rawDocs = snapshot.data!.docs;
        if (rawDocs.isEmpty) {
          return switch (view) {
            _DeskView.requests => const EmptyStateView(
                icon: Icons.inbox_outlined,
                title: 'No appointment requests',
                message: 'New patient bookings for this chamber appear here instantly.',
              ),
            _DeskView.queue => const EmptyStateView(
                icon: Icons.people_outline,
                title: 'No patients waiting today',
                message: 'Accepted requests join this queue in order.',
              ),
            _DeskView.done => const EmptyStateView(
                icon: Icons.task_alt,
                title: 'No completed visits today',
              ),
          };
        }

        // Today's Queue sorted strictly by queuePosition
        final docs = rawDocs.toList();
        if (view == _DeskView.queue) {
          docs.sort((a, b) {
            final posA = (a.data()['queuePosition'] as num? ?? 99999).toInt();
            final posB = (b.data()['queuePosition'] as num? ?? 99999).toInt();
            return posA.compareTo(posB);
          });
        }

        // Queue view leads with the "now serving / call next" bar.
        final lead = view == _DeskView.queue ? 1 : 0;
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length + lead,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            if (index < lead) return _NowServingBar(docs: docs);
            final doc = docs[index - lead];
            return _AppointmentRow(
              reference: doc.reference,
              data: doc.data(),
              view: view,
              chamberId: chamberId,
            );
          },
        );
      },
    );
  }
}

class _AppointmentRow extends StatelessWidget {
  const _AppointmentRow({
    required this.reference,
    required this.data,
    required this.view,
    required this.chamberId,
  });

  final DocumentReference<Map<String, dynamic>> reference;
  final Map<String, dynamic> data;
  final _DeskView view;
  final String chamberId;

  DateTime? get _scheduledTime {
    final value = data['scheduledTime'];
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  String get _patientName {
    final value = data['patientName']?.toString().trim() ?? '';
    return value.isEmpty ? 'Patient' : value;
  }

  String get _doctorName {
    final value = data['doctorName']?.toString().trim() ?? '';
    return value.isEmpty ? 'Doctor not specified' : value;
  }

  String _format12Hour(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final p = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:${dt.minute.toString().padLeft(2, '0')} $p';
  }

  String _timeLabel() {
    final time = _scheduledTime;
    if (time == null) return 'Time not selected';
    return _format12Hour(time);
  }

  String _dateOnlyLabel() {
    final time = _scheduledTime;
    if (time == null) return 'Date not specified';
    return '${time.day}/${time.month}/${time.year}';
  }

  DateTime? get _preferredTime {
    final value = data['preferredTime'];
    return value is Timestamp ? value.toDate() : null;
  }

  /// Loads free slots for the request's date and lets the desk pick one.
  Future<DateTime?> _pickSlot(BuildContext context,
      {required String title, required String confirmLabel}) async {
    final doctorId = (data['doctorId'] ?? '').toString();
    final date = _scheduledTime ?? DateTime.now();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    FreeSlotsResult? freeResult;
    try {
      freeResult = await SchedulingService.getFreeSlots(
        chamberId: chamberId,
        doctorId: doctorId,
        date: date,
      );
    } catch (_) {}

    if (context.mounted) Navigator.pop(context);
    if (!context.mounted) return null;

    // The slot already held for this appointment stays available to it.
    final proposed = data['proposedTime'];
    final slots = <DateTime>[
      ...?freeResult?.slots,
      if (proposed is Timestamp &&
          !(freeResult?.slots.contains(proposed.toDate()) ?? false))
        proposed.toDate(),
    ]..sort();

    if (slots.isEmpty) {
      final reason = (freeResult?.totalCapacity ?? 0) == 0
          ? 'Visiting hours not set for this chamber'
          : (freeResult?.emptyReason ?? 'No slots available');
      final next = freeResult?.nextVisitingDates ?? const [];
      final nextText = next.isEmpty
          ? ''
          : '\nNext visiting dates: ${next.map((d) => "${d.day}/${d.month}").join(', ')}';
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('No free slot on ${_dateOnlyLabel()}'),
          content: Text('$reason.$nextText'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return null;
    }

    final preferred = _preferredTime;
    DateTime selectedSlot = slots.firstWhere(
      (s) => preferred != null && s == preferred,
      orElse: () => slots.first,
    );
    if (!context.mounted) return null;

    return showDialog<DateTime>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('$title (${date.day}/${date.month}/${date.year})'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (preferred != null) ...[
                    Text('Patient prefers ${_format12Hour(preferred)}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                  ],
                  const Text('Select an available free time slot:'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: slots.map((slot) {
                      return ChoiceChip(
                        label: Text(_format12Hour(slot)),
                        selected: slot == selectedSlot,
                        onSelected: (val) {
                          if (val) setDialogState(() => selectedSlot = slot);
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(dlgCtx, selectedSlot),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirms straight away (e.g. agreed over the phone) and issues a token.
  Future<void> _accept(BuildContext context) async {
    // Captured up front: the row leaves the list as soon as its status
    // changes, so its context is gone by the time the write finishes.
    final messenger = ScaffoldMessenger.of(context);
    final selected = await _pickSlot(context,
        title: 'Confirm now', confirmLabel: 'Confirm & give token');
    if (selected == null) return;
    try {
      await DataService.confirmAppointment(
        appointmentId: reference.id,
        confirmedTime: selected,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Appointment confirmed and token issued.')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not confirm. ${friendlyErrorMessage(error)}')),
      );
    }
  }

  /// Offers a time; the patient accepts (and gets a token) or declines.
  Future<void> _propose(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final doctorId = (data['doctorId'] ?? '').toString();
    final selected = await _pickSlot(context,
        title: 'Propose a time', confirmLabel: 'Send to patient');
    if (selected == null) return;
    try {
      await QueueService.proposeTime(
        appointmentId: reference.id,
        slot: selected,
        slotDocId: SchedulingService.slotId(doctorId, selected),
      );
      messenger.showSnackBar(SnackBar(
          content: Text('Proposed ${_format12Hour(selected)}. Waiting for $_patientName to accept.')));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not propose. ${friendlyErrorMessage(error)}')),
      );
    }
  }

  Future<void> _reject(BuildContext context) async {
    // Captured up front: the row leaves the list as soon as its status
    // changes, so its context is gone by the time the write finishes.
    final messenger = ScaffoldMessenger.of(context);
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reject request'),
        content: TextField(
          controller: reason,
          autofocus: true,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Reason required'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () {
              if (reason.text.trim().isEmpty) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('A rejection reason is mandatory.')),
                );
                return;
              }
              Navigator.pop(dialogContext, true);
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await DataService.rejectAppointment(appointmentId: reference.id, reason: reason.text.trim());
      messenger.showSnackBar(const SnackBar(content: Text('Appointment rejected.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not reject. ${friendlyErrorMessage(error)}')));
    }
  }

  Future<void> _startVisit(BuildContext context) async {
    // Captured up front: the row leaves the list as soon as its status
    // changes, so its context is gone by the time the write finishes.
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FirestoreService.markAppointmentInProgress(reference.id);
      messenger.showSnackBar(SnackBar(content: Text('$_patientName is now in consultation.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not start visit. ${friendlyErrorMessage(error)}')));
    }
  }

  Future<void> _checkIn(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await QueueService.checkIn(reference.id);
      messenger.showSnackBar(SnackBar(content: Text('$_patientName checked in.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not check in. ${friendlyErrorMessage(error)}')));
    }
  }

  Future<void> _noShow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Mark as no-show?'),
        content: Text("$_patientName will be removed from today's queue."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('No-show')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await QueueService.finishVisit(reference.id, outcome: ApptStatus.noShow);
      await SchedulingService.releaseSlotAndLock(reference.id);
      messenger.showSnackBar(SnackBar(content: Text('$_patientName marked as no-show.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not update. ${friendlyErrorMessage(error)}')));
    }
  }

  Future<void> _markDone(BuildContext context) async {
    // Captured up front: the row leaves the list as soon as its status
    // changes, so its context is gone by the time the write finishes.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chatUnlocked = await FirestoreService.markAppointmentCompletedAndUnlockChat(reference.id);
      {
        messenger.showSnackBar(SnackBar(
          content: Text(chatUnlocked
              ? 'Visit marked done. Follow-up chat unlocked.'
              : 'Visit marked done.'),
        ));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not complete. ${friendlyErrorMessage(error)}')));
    }
  }

  String _proposedLabel() {
    final p = data['proposedTime'];
    return p is Timestamp ? _format12Hour(p.toDate()) : '';
  }

  @override
  Widget build(BuildContext context) {
    final queuePosition = (data['queuePosition'] as num?)?.toInt();
    final status = QueueService.normalizeStatus(data['status']);
    final isRequest = view == _DeskView.requests;
    final scheduledDate = _scheduledTime ?? DateTime.now();
    final targetDateKey = SchedulingService.dateKey(scheduledDate);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: isRequest
          ? FirebaseFirestore.instance
              .collection('chamber_day_overrides')
              .doc('${chamberId}_$targetDateKey')
              .snapshots()
          : null,
      builder: (context, overrideSnap) {
        final overrideStatus = (overrideSnap.data?.data()?['status'] ?? '').toString().toLowerCase();
        final isDateClosed = overrideStatus == 'closed';

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      child: isRequest
                          ? const Icon(Icons.hourglass_empty, size: 16)
                          : Text(queuePosition == null ? '–' : '#$queuePosition'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(_patientName, style: const TextStyle(fontWeight: FontWeight.w700)),
                              if (data['source'] == 'walk_in' || data['source'] == 'offline') ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.blue.shade300),
                                  ),
                                  child: Text(
                                    data['source'] == 'walk_in' ? 'Walk-in' : 'Offline',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.blue.shade800,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (isDateClosed)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.red.shade200),
                              ),
                              child: Text(
                                'Date Closed',
                                style: TextStyle(fontSize: 10, color: Colors.red.shade900, fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      isRequest ? _dateOnlyLabel() : _timeLabel(),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(_doctorName, style: Theme.of(context).textTheme.bodySmall),
                if (isRequest) ...[
                  if (status == ApptStatus.proposed) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Proposed ${_proposedLabel()} · waiting for patient',
                      style: TextStyle(color: Colors.orange.shade900, fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ] else if (_preferredTime != null) ...[
                    const SizedBox(height: 6),
                    Text('Prefers ${_format12Hour(_preferredTime!)}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (!isDateClosed) ...[
                        Expanded(
                          child: FilledButton(
                            onPressed: () => _propose(context),
                            child: Text(status == ApptStatus.proposed ? 'Change time' : 'Propose time'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _accept(context),
                            child: const Text('Confirm now'),
                          ),
                        ),
                      ],
                      IconButton(
                        onPressed: () => _reject(context),
                        tooltip: 'Reject',
                        icon: const Icon(Icons.close, color: Colors.red),
                      ),
                    ],
                  ),
                ] else if (view == _DeskView.queue) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: switch (status) {
                      ApptStatus.inConsultation => [
                          _ConsultTimer(data: data),
                          FilledButton.icon(
                            onPressed: () => _markDone(context),
                            icon: const Icon(Icons.check_circle_outline, size: 18),
                            label: const Text('Done'),
                          ),
                        ],
                      ApptStatus.checkedIn => [
                          const _StatusPill(icon: Icons.how_to_reg, label: 'Arrived'),
                          TextButton(onPressed: () => _noShow(context), child: const Text('No-show')),
                          FilledButton.tonalIcon(
                            onPressed: () => _startVisit(context),
                            icon: const Icon(Icons.play_arrow_rounded, size: 18),
                            label: const Text('Call in'),
                          ),
                        ],
                      _ => [
                          TextButton(onPressed: () => _noShow(context), child: const Text('No-show')),
                          OutlinedButton.icon(
                            onPressed: () => _checkIn(context),
                            icon: const Icon(Icons.how_to_reg, size: 18),
                            label: const Text('Check in'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () => _startVisit(context),
                            icon: const Icon(Icons.play_arrow_rounded, size: 18),
                            label: const Text('Call in'),
                          ),
                        ],
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}


/// Top of Today's Queue: who is in, how many wait, and the next token to call.
/// Checked-in patients are called before ones who have not arrived yet.
class _NowServingBar extends StatelessWidget {
  const _NowServingBar({required this.docs});

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;

  static int _token(QueryDocumentSnapshot<Map<String, dynamic>> d) =>
      (d.data()['queuePosition'] as num?)?.toInt() ?? 1 << 30;

  static String _status(QueryDocumentSnapshot<Map<String, dynamic>> d) =>
      QueueService.normalizeStatus(d.data()['status']);

  Future<void> _callNext(
      BuildContext context, QueryDocumentSnapshot<Map<String, dynamic>> next) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await QueueService.startConsultation(next.id);
      messenger.showSnackBar(SnackBar(
          content: Text('Token #${_token(next)} called in.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(
          content: Text('Could not call next. ${friendlyErrorMessage(error)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = docs.where((d) => _status(d) == ApptStatus.inConsultation).toList();
    final waiting = docs.where((d) => ApptStatus.waiting.contains(_status(d))).toList()
      ..sort((a, b) {
        final arrived = (_status(a) == ApptStatus.checkedIn ? 0 : 1)
            .compareTo(_status(b) == ApptStatus.checkedIn ? 0 : 1);
        return arrived != 0 ? arrived : _token(a).compareTo(_token(b));
      });
    final next = waiting.isEmpty ? null : waiting.first;
    final doctorId = docs.isEmpty ? '' : (docs.first.data()['doctorId'] ?? '').toString();
    final isThisDoctor = doctorId.isNotEmpty &&
        AuthService.userRoles.doctorProfileId == doctorId;

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Now serving', style: theme.textTheme.labelMedium),
                      Text(
                        current.isEmpty ? '—' : '#${_token(current.first)}',
                        style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${waiting.length} waiting', style: theme.textTheme.titleSmall),
                    if (next != null)
                      Text('Next: #${_token(next)}', style: theme.textTheme.bodySmall),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (doctorId.isNotEmpty)
                  Flexible(child: _AvgConsultChip(doctorId: doctorId, editable: isThisDoctor)),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: current.isEmpty && next != null ? () => _callNext(context, next) : null,
                  icon: const Icon(Icons.campaign_outlined, size: 18),
                  label: Text(current.isNotEmpty ? 'In progress' : 'Call next'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Average consult length used for autoAdvanceAt. Only the doctor can change it.
class _AvgConsultChip extends StatelessWidget {
  const _AvgConsultChip({required this.doctorId, required this.editable});

  final String doctorId;
  final bool editable;

  Future<void> _edit(BuildContext context, int current) async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Average consultation'),
        children: [5, 10, 15, 20, 30]
            .map((m) => ListTile(
                  title: Text('$m minutes'),
                  trailing: m == current ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(c, m),
                ))
            .toList(),
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await FirebaseFirestore.instance.collection('doctors').doc(doctorId).update({
        'avgConsultMinutes': picked,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save. ${friendlyErrorMessage(error)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('doctors').doc(doctorId).snapshots(),
      builder: (context, snap) {
        final minutes = (snap.data?.data()?['avgConsultMinutes'] as num?)?.toInt() ??
            QueueService.defaultConsultMinutes;
        final label = Text('~$minutes min / patient');
        const icon = Icon(Icons.timer_outlined, size: 16);
        // Operators see the value; only the doctor gets a tappable chip.
        return editable
            ? ActionChip(avatar: icon, label: label, onPressed: () => _edit(context, minutes))
            : Chip(avatar: icon, label: label, visualDensity: VisualDensity.compact);
      },
    );
  }
}

/// Elapsed time for the patient in consultation. Turns red once past
/// autoAdvanceAt; the visit is never ended automatically.
class _ConsultTimer extends StatefulWidget {
  const _ConsultTimer({required this.data});

  final Map<String, dynamic> data;

  @override
  State<_ConsultTimer> createState() => _ConsultTimerState();
}

class _ConsultTimerState extends State<_ConsultTimer> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = widget.data['startedAt'];
    final due = widget.data['autoAdvanceAt'];
    final now = DateTime.now();
    final minutes = started is Timestamp ? now.difference(started.toDate()).inMinutes : 0;
    final overrun = due is Timestamp && now.isAfter(due.toDate());
    final color = overrun ? Colors.red.shade700 : Theme.of(context).colorScheme.primary;
    return Chip(
      avatar: Icon(overrun ? Icons.warning_amber_rounded : Icons.medical_services_outlined,
          size: 16, color: Colors.white),
      label: Text(overrun ? 'Overrunning · $minutes min' : 'In consultation · $minutes min'),
      labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      backgroundColor: color,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Read-only status label in a queue row (not a button).
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: Colors.green.shade700),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
