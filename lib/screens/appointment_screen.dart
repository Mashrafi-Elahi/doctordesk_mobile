import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_constants.dart';
import '../services/api_service.dart';
import '../services/data_service.dart';
import '../services/auth_service.dart';
import '../services/app_language.dart';
import '../services/chamber_resolver.dart';
import '../services/queue_service.dart';
import '../widgets/state_views.dart';
import '../widgets/profile_avatar_button.dart';
import 'doctors_screen.dart';

/// Appointments Screen
class AppointmentScreen extends StatefulWidget {
  final int initialTabIndex;

  const AppointmentScreen({super.key, this.initialTabIndex = 0});

  @override
  State<AppointmentScreen> createState() => _AppointmentScreenState();
}

const _pastStatuses = {'done', 'completed'};

class _AppointmentScreenState extends State<AppointmentScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      initialIndex: widget.initialTabIndex.clamp(0, 1),
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Appointments')),
          actions: const [
            ProfileAvatarButton(),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(52),
            child: Container(
              height: 42,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TabBar(
                isScrollable: false,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                labelColor: theme.colorScheme.primary,
                labelStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
                unselectedLabelColor: Colors.white,
                unselectedLabelStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
                dividerColor: Colors.transparent,
                tabs: [
                  Tab(text: tr('Upcoming')),
                  Tab(text: tr('Past Visits')),
                ],
              ),
            ),
          ),
        ),
        body: StreamBuilder<User?>(
          stream: AuthService.authStateChanges,
          initialData: AuthService.currentUser,
          builder: (context, authSnapshot) {
            if (authSnapshot.connectionState == ConnectionState.waiting &&
                !authSnapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final user = authSnapshot.data;
            if (user == null) {
              return const TabBarView(
                children: [
                  _EmptyState(
                    icon: Icons.calendar_today_outlined,
                    title: 'Sign in to view appointments',
                    subtitle: 'Sign in to see and manage your doctor bookings.',
                  ),
                  _EmptyState(
                    icon: Icons.history_outlined,
                    title: 'No past appointments yet',
                    subtitle:
                        'Your visit history will show up here after consultations.',
                  ),
                ],
              );
            }

            final currentUid = user.uid;
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('appointments')
                    .where('userId', isEqualTo: currentUid)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return ErrorStateView.fromError(snapshot.error,
                        what: 'your appointments',
                        onRetry: () => setState(() {}));
                  }
                  if (!snapshot.hasData) {
                    return const LoadingView(message: 'Loading appointments…');
                  }
                  final docs = snapshot.data?.docs ?? [];
                  final upcoming = docs.where((d) {
                    final status =
                        d.data()['status']?.toString().toLowerCase() ?? '';
                    // 'done' is the terminal status the desk sets; 'completed' is legacy.
                    return !_pastStatuses.contains(status) &&
                        !ApptStatus.terminal.contains(status);
                  }).toList();

                  final past = docs.where((d) {
                    final status =
                        d.data()['status']?.toString().toLowerCase() ?? '';
                    return _pastStatuses.contains(status);
                  }).toList();

                  return TabBarView(
                    children: [
                      upcoming.isEmpty
                          ? const _EmptyState(
                              icon: Icons.calendar_today_outlined,
                              title: 'No upcoming appointments',
                              subtitle:
                                  'Book a doctor from the Home or Doctors directory to see it here.',
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 16, 16, 160),
                              itemCount: upcoming.length,
                              itemBuilder: (ctx, i) {
                                final data = upcoming[i].data();
                                final docName = data['doctorName'] ??
                                    data['doctorId'] ??
                                    'Specialist Doctor';
                                final patient =
                                    data['patientName'] ?? 'Patient';
                                final status = QueueService.normalizeStatus(data['status'] ?? 'waiting');
                                final isRequested = status == ApptStatus.requested;
                                final isProposed = status == ApptStatus.proposed;
                                final pos = (data['queuePosition'] as num?)?.toInt();
                                final hasToken = pos != null &&
                                    (status == ApptStatus.confirmed ||
                                        status == ApptStatus.checkedIn ||
                                        status == ApptStatus.inConsultation);
                                final ts = isProposed ? data['proposedTime'] : data['scheduledTime'];
                                String dateStr = 'Scheduled';
                                if (ts is Timestamp) {
                                  final dt = ts.toDate();
                                  if (isRequested) {
                                    dateStr = 'Preferred Date: ${dt.day}/${dt.month}/${dt.year}';
                                  } else {
                                    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
                                    final p = dt.hour >= 12 ? 'PM' : 'AM';
                                    dateStr =
                                        '${isProposed ? 'Proposed: ' : ''}${dt.day}/${dt.month}/${dt.year} at $h:${dt.minute.toString().padLeft(2, '0')} $p';
                                  }
                                }

                                return Card(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16)),
                                  elevation: 1,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            CircleAvatar(
                                              backgroundColor: theme
                                                  .colorScheme.primaryContainer,
                                              child: Icon(Icons.person,
                                                  color: theme
                                                      .colorScheme.primary),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    docName,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 16),
                                                  ),
                                                  FutureBuilder<String>(
                                                    future: ChamberResolver.resolveChamberName(
                                                      chamberId: (data['chamberId'] ?? '').toString(),
                                                      storedName: data['chamberName']?.toString(),
                                                      doctorId: data['doctorId']?.toString(),
                                                    ),
                                                    initialData: ChamberResolver.getCached(data['chamberId']?.toString()),
                                                    builder: (ctx, snap) => Text(
                                                      'Chamber: ${snap.data ?? 'Chamber'}',
                                                      style: TextStyle(
                                                          color: Colors.grey[600],
                                                          fontSize: 13),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 4),
                                              decoration: BoxDecoration(
                                                color: status == 'requested'
                                                    ? Colors.amber.shade50
                                                    : status == 'confirmed'
                                                        ? Colors.green.shade50
                                                        : Colors.blue.shade50,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                border: Border.all(
                                                  color: status == 'requested'
                                                      ? Colors.amber.shade300
                                                      : status == 'confirmed'
                                                          ? Colors.green.shade300
                                                          : Colors.blue.shade200,
                                                ),
                                              ),
                                              child: Text(
                                                _statusLabel(status),
                                                style: TextStyle(
                                                  color: status == 'requested'
                                                      ? Colors.amber.shade900
                                                      : status == 'confirmed'
                                                          ? Colors.green.shade800
                                                          : Colors.blue.shade800,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const Divider(height: 24),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                const Icon(Icons.calendar_today,
                                                    size: 14,
                                                    color: Colors.grey),
                                                const SizedBox(width: 6),
                                                Text(dateStr,
                                                    style: const TextStyle(
                                                        fontSize: 13)),
                                              ],
                                            ),
                                            if (hasToken)
                                              Text(
                                                'Token #$pos',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color:
                                                      theme.colorScheme.primary,
                                                  fontSize: 13,
                                                ),
                                              ),
                                          ],
                                        ),
                                        if (hasToken)
                                          _LiveQueueLine(
                                            queueId: (data['queueId'] ?? '').toString(),
                                            token: pos,
                                            status: status,
                                          ),
                                        if (isProposed)
                                          _ProposalActions(appointmentId: upcoming[i].id),
                                        const SizedBox(height: 6),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              'Patient: $patient',
                                              style: TextStyle(
                                                  fontSize: 12.5,
                                                  color: Colors.grey.shade700),
                                            ),
                                            if (const {ApptStatus.requested, ApptStatus.proposed, ApptStatus.confirmed}
                                                .contains(status))
                                              TextButton(
                                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                                onPressed: () async {
                                                  final apptDocId = (upcoming[i].id).toString();
                                                  final ok = await showDialog<bool>(
                                                    context: context,
                                                    builder: (c) => AlertDialog(
                                                      title: const Text('Cancel Appointment?'),
                                                      content: const Text('Are you sure you want to cancel this booking?'),
                                                      actions: [
                                                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
                                                        FilledButton(
                                                          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                                                          onPressed: () => Navigator.pop(c, true),
                                                          child: const Text('Cancel Appointment'),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  if (ok == true) {
                                                    try {
                                                      await DataService.cancelAppointmentByPatient(apptDocId);
                                                    } catch (e) {
                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                          SnackBar(content: Text(friendlyErrorMessage(e))),
                                                        );
                                                      }
                                                    }
                                                  }
                                                },
                                                child: const Text('Cancel', style: TextStyle(color: Colors.red, fontSize: 12)),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                      past.isEmpty
                          ? const _EmptyState(
                              icon: Icons.history_outlined,
                              title: 'No past appointments yet',
                              subtitle:
                                  'Your visit history will show up here after consultations.',
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 16, 16, 160),
                              itemCount: past.length,
                              itemBuilder: (ctx, i) {
                                final data = past[i].data();
                                final docName = data['doctorName'] ?? 'Doctor';
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  child: ListTile(
                                    leading: const Icon(Icons.check_circle,
                                        color: Colors.green),
                                    title: Text(docName),
                                    subtitle: FutureBuilder<String>(
                                      future: ChamberResolver.resolveChamberName(
                                        chamberId: (data['chamberId'] ?? '').toString(),
                                        storedName: data['chamberName']?.toString(),
                                        doctorId: data['doctorId']?.toString(),
                                      ),
                                      initialData: ChamberResolver.getCached(data['chamberId']?.toString()),
                                      builder: (ctx, snap) => Text(
                                        'Chamber: ${snap.data ?? 'Chamber'}',
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ],
                  );
                },
              );
          },
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null,
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DoctorsScreen()),
            );
          },
          tooltip: 'Browse Doctors & Book',
          icon: const Icon(Icons.search),
          label: const Text('Book a doctor'),
        ),
      ),
    );
  }
}

/// Standalone Health Calendar Screen accessible from Home's Calendar link
class HealthCalendarScreen extends StatelessWidget {
  const HealthCalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Health Calendar'),
        actions: const [
          ProfileAvatarButton(),
        ],
      ),
      body: const _HealthCalendarTab(),
    );
  }
}

class _HealthCalendarTab extends StatefulWidget {
  const _HealthCalendarTab();

  @override
  State<_HealthCalendarTab> createState() => _HealthCalendarTabState();
}

class _HealthCalendarTabState extends State<_HealthCalendarTab> {
  DateTime _currentMonth = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  final Map<String, String> _dayToFeeling = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  String _dateKey(DateTime dt) =>
      "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";

  Future<void> _loadEntries() async {
    setState(() => _isLoading = true);
    final entries = await ApiService.fetchJournalEntries();
    if (mounted) {
      final map = <String, String>{};
      for (final item in entries) {
        final raw = item['createdAt'] ?? item['date'];
        if (raw != null) {
          final dt = DateTime.tryParse(raw.toString());
          if (dt != null) {
            final key = _dateKey(dt.toLocal());
            if (!map.containsKey(key)) {
              map[key] = (item['feeling'] ?? '').toString().toLowerCase();
            }
          }
        }
      }
      setState(() {
        _dayToFeeling.clear();
        _dayToFeeling.addAll(map);
        _isLoading = false;
      });
    }
  }

  void _changeMonth(int offset) {
    setState(() {
      _currentMonth =
          DateTime(_currentMonth.year, _currentMonth.month + offset, 1);
    });
  }

  String _getMonthName(int month) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return months[month - 1];
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final colorScheme = Theme.of(context).colorScheme;
    final now = DateTime.now();

    final firstDayOfMonth =
        DateTime(_currentMonth.year, _currentMonth.month, 1);
    final daysInMonth =
        DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final leadingEmptyDays = (firstDayOfMonth.weekday - 1);
    final totalCells = leadingEmptyDays + daysInMonth;

    int goodDaysCount = 0;
    int okayDaysCount = 0;
    int lowDaysCount = 0;
    int unwellDaysCount = 0;
    for (int d = 1; d <= daysInMonth; d++) {
      final k = _dateKey(DateTime(_currentMonth.year, _currentMonth.month, d));
      final f = _dayToFeeling[k];
      if (f == 'good' || f == 'great') {
        goodDaysCount++;
      } else if (f == 'okay') {
        okayDaysCount++;
      } else if (f == 'low') {
        lowDaysCount++;
      } else if (f == 'unwell') {
        unwellDaysCount++;
      }
    }

    final selectedKey = _dateKey(_selectedDay);
    final selectedFeeling = _dayToFeeling[selectedKey];

    return RefreshIndicator(
      onRefresh: _loadEntries,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Month Header with Prev / Next controls
            Card(
              elevation: 0.8,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left),
                          onPressed: () => _changeMonth(-1),
                        ),
                        Text(
                          '${_getMonthName(_currentMonth.month)} ${_currentMonth.year}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right),
                          onPressed: () => _changeMonth(1),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Weekday headers
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _WeekdayLabel('Mon'),
                        _WeekdayLabel('Tue'),
                        _WeekdayLabel('Wed'),
                        _WeekdayLabel('Thu'),
                        _WeekdayLabel('Fri'),
                        _WeekdayLabel('Sat'),
                        _WeekdayLabel('Sun'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Calendar grid
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: totalCells,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 7,
                        childAspectRatio: 1.0,
                        crossAxisSpacing: 4,
                        mainAxisSpacing: 4,
                      ),
                      itemBuilder: (context, index) {
                        if (index < leadingEmptyDays) {
                          return const SizedBox.shrink();
                        }
                        final dayNumber = index - leadingEmptyDays + 1;
                        final cellDate = DateTime(
                            _currentMonth.year, _currentMonth.month, dayNumber);
                        final key = _dateKey(cellDate);
                        final feeling = _dayToFeeling[key];

                        final isToday = cellDate.year == now.year &&
                            cellDate.month == now.month &&
                            cellDate.day == now.day;
                        final isSelected = cellDate.year == _selectedDay.year &&
                            cellDate.month == _selectedDay.month &&
                            cellDate.day == _selectedDay.day;

                        Color bgColor = Colors.transparent;
                        Color textColor = Colors.black87;
                        Color? borderColor;
                        Widget? marker;

                        if (feeling == 'good' || feeling == 'great') {
                          // GREEN MARK on good days
                          bgColor = const Color(0xFFE8F5E9);
                          textColor = const Color(0xFF2E7D32);
                          borderColor = const Color(0xFF4CAF50);
                          marker = Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: Color(0xFF2E7D32),
                              shape: BoxShape.circle,
                            ),
                          );
                        } else if (feeling == 'okay') {
                          // YELLOW / OKAY MARK
                          bgColor = const Color(0xFFFFFDE7);
                          textColor = const Color(0xFFF57F17);
                          borderColor = const Color(0xFFFBC02D);
                          marker = Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF57F17),
                              shape: BoxShape.circle,
                            ),
                          );
                        } else if (feeling == 'low') {
                          // PURPLE / LOW MOOD MARK
                          bgColor = const Color(0xFFEDE7F6);
                          textColor = const Color(0xFF5E35B1);
                          borderColor = const Color(0xFF7E57C2);
                          marker = Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: Color(0xFF5E35B1),
                              shape: BoxShape.circle,
                            ),
                          );
                        } else if (feeling == 'unwell') {
                          // RED / UNWELL MARK
                          bgColor = const Color(0xFFFFEBEE);
                          textColor = const Color(0xFFC62828);
                          borderColor = const Color(0xFFE53935);
                          marker = Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: Color(0xFFC62828),
                              shape: BoxShape.circle,
                            ),
                          );
                        }

                        if (isSelected) {
                          borderColor = colorScheme.primary;
                        } else if (isToday && borderColor == null) {
                          borderColor =
                              colorScheme.primary.withValues(alpha: 0.6);
                        }

                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            setState(() {
                              _selectedDay = cellDate;
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: bgColor,
                              borderRadius: BorderRadius.circular(12),
                              border: borderColor != null
                                  ? Border.all(
                                      color: borderColor,
                                      width: isSelected ? 2.0 : 1.2,
                                    )
                                  : null,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '$dayNumber',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight:
                                        isToday || isSelected || feeling != null
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                    color: textColor,
                                  ),
                                ),
                                if (marker != null) ...[
                                  const SizedBox(height: 2),
                                  marker,
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    // Legend
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        _legendItem(const Color(0xFF4CAF50), 'Good'),
                        _legendItem(const Color(0xFFFBC02D), 'Okay'),
                        _legendItem(const Color(0xFF7E57C2), 'Low'),
                        _legendItem(const Color(0xFFE53935), 'Unwell'),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Selected Day Card
            Card(
              elevation: 0.8,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${_getMonthName(_selectedDay.month)} ${_selectedDay.day}, ${_selectedDay.year}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        if (_selectedDay.year == now.year &&
                            _selectedDay.month == now.month &&
                            _selectedDay.day == now.day)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Today',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (selectedFeeling == 'good' ||
                        selectedFeeling == 'great') ...[
                      const Row(
                        children: [
                          Icon(Icons.check_circle,
                              color: Color(0xFF2E7D32), size: 28),
                          SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Good Health Day 🟢',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: Color(0xFF2E7D32),
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'You logged feeling healthy, energetic, and well on this day.',
                                  style: TextStyle(
                                      fontSize: 13, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ] else if (selectedFeeling == 'okay') ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFDE7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.sentiment_neutral,
                                color: Color(0xFFF57F17), size: 26),
                            SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Okay / Balanced Day 🟡',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Color(0xFFF57F17),
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    'You logged feeling steady and balanced today.',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.black87),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else if (selectedFeeling == 'low') ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEDE7F6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.psychology_outlined,
                                    color: Color(0xFF5E35B1), size: 24),
                                SizedBox(width: 8),
                                Text(
                                  'Low Mood / Overwhelmed 🟣',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: Color(0xFF5E35B1),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Mental health matters just as much as physical health. Speaking with a psychiatrist or specialist can help.',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.black87),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const DoctorsScreen(
                                          initialQuery: 'Psychiatrist'),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.psychology, size: 18),
                                label: const Text('See Psychiatrist'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF5E35B1),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else if (selectedFeeling == 'unwell') ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEBEE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.healing,
                                    color: Color(0xFFC62828), size: 24),
                                SizedBox(width: 8),
                                Text(
                                  'Felt Unwell / Needed Care 🔴',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: Color(0xFFC62828),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'You recorded feeling unwell. Would you like to consult a General Physician (GD) or Medicine doctor?',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.black87),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const DoctorsScreen(
                                          initialQuery: 'Medicine'),
                                    ),
                                  );
                                },
                                icon: const Icon(
                                    Icons.medical_services_outlined,
                                    size: 18),
                                label: const Text('See General Doctor (GD)'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFC62828),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      const Text(
                        'No health status recorded for this day.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    Text(
                      selectedFeeling != null
                          ? 'Change mood for this date:'
                          : 'Log mood for this date:',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _calendarMoodButton('great', '🌟', 'Great', selectedKey, selectedFeeling),
                        _calendarMoodButton('good', '😊', 'Good', selectedKey, selectedFeeling),
                        _calendarMoodButton('okay', '😐', 'Okay', selectedKey, selectedFeeling),
                        _calendarMoodButton('low', '😔', 'Low', selectedKey, selectedFeeling),
                        _calendarMoodButton('unwell', '🤒', 'Unwell', selectedKey, selectedFeeling),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Monthly Health Overview Card
            Card(
              elevation: 0.8,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_getMonthName(_currentMonth.month)} Health Summary',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _summaryStatCard(
                            count: goodDaysCount,
                            label: 'Good Days 🟢',
                            bgColor: const Color(0xFFE8F5E9),
                            textColor: const Color(0xFF2E7D32),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _summaryStatCard(
                            count: okayDaysCount,
                            label: 'Okay Days 🟡',
                            bgColor: const Color(0xFFFFFDE7),
                            textColor: const Color(0xFFF57F17),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _summaryStatCard(
                            count: lowDaysCount,
                            label: 'Low Mood 🟣',
                            bgColor: const Color(0xFFEDE7F6),
                            textColor: const Color(0xFF5E35B1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _summaryStatCard(
                            count: unwellDaysCount,
                            label: 'Care Needed 🔴',
                            bgColor: const Color(0xFFFFEBEE),
                            textColor: const Color(0xFFC62828),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryStatCard({
    required int count,
    required String label,
    required Color bgColor,
    required Color textColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _calendarMoodButton(
    String key,
    String emoji,
    String label,
    String dateKey,
    String? currentFeeling,
  ) {
    final isSelected = currentFeeling == key;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _onLogCalendarMood(key, dateKey),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE3F2FD) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFF1E88E5) : Colors.grey.shade300,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? const Color(0xFF1E88E5) : Colors.grey.shade800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onLogCalendarMood(String key, String dateKey) async {
    setState(() {
      _dayToFeeling[dateKey] = key;
    });

    final now = DateTime.now();
    final todayKey = _dateKey(now);
    if (dateKey == todayKey) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mood_$todayKey', key);
    }

    await ApiService.logFeeling(feeling: key);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Mood updated to ${key.toUpperCase()} for this date!'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _legendItem(Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

class _WeekdayLabel extends StatelessWidget {
  final String label;
  const _WeekdayLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) =>
      EmptyStateView(icon: icon, title: title, message: subtitle);
}

String _statusLabel(String status) => switch (status) {
      ApptStatus.requested => 'AWAITING TIME',
      ApptStatus.proposed => 'ACTION NEEDED',
      ApptStatus.confirmed => 'CONFIRMED',
      ApptStatus.checkedIn => 'CHECKED IN',
      ApptStatus.inConsultation => 'WITH DOCTOR',
      _ => status.replaceAll('_', ' ').toUpperCase(),
    };

/// "Now serving #9 · 2 ahead of you", from the doctor's day queue. Only token
/// numbers are read, never other patients' appointments.
class _LiveQueueLine extends StatelessWidget {
  const _LiveQueueLine({required this.queueId, required this.token, required this.status});

  final String queueId;
  final int token;
  final String status;

  @override
  Widget build(BuildContext context) {
    if (status == ApptStatus.inConsultation) {
      return const _QueueBanner(text: "It's your turn — please go in.", highlight: true);
    }
    if (queueId.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('queues').doc(queueId).snapshots(),
      builder: (context, snap) {
        final q = snap.data?.data();
        if (q == null) return const SizedBox.shrink();
        final serving = (q['currentServing'] as num?)?.toInt() ?? 0;
        final ahead = QueueService.peopleAhead(QueueService.waitingTokensOf(q), token);
        final aheadText = ahead == 0 ? "You're next" : '$ahead ahead of you';
        return _QueueBanner(
          text: '${serving == 0 ? 'Not started yet' : 'Now serving #$serving'} · $aheadText',
          highlight: ahead == 0,
        );
      },
    );
  }
}

class _QueueBanner extends StatelessWidget {
  const _QueueBanner({required this.text, this.highlight = false});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = highlight ? scheme.onPrimary : scheme.onPrimaryContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: highlight ? scheme.primary : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.groups_2_outlined, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
          ),
        ],
      ),
    );
  }
}

/// Accept or decline the time the chamber proposed.
class _ProposalActions extends StatefulWidget {
  const _ProposalActions({required this.appointmentId});

  final String appointmentId;

  @override
  State<_ProposalActions> createState() => _ProposalActionsState();
}

class _ProposalActionsState extends State<_ProposalActions> {
  bool _busy = false;

  Future<void> _respond(bool accept) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await QueueService.respondToProposal(widget.appointmentId, accept: accept);
      messenger.showSnackBar(SnackBar(
          content: Text(accept ? 'Confirmed. Your token is on the card.' : 'Proposed time declined.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : () => _respond(false),
              child: const Text('Decline'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : () => _respond(true),
              child: const Text('Accept time'),
            ),
          ),
        ],
      ),
    );
  }
}
