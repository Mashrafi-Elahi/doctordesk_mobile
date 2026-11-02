import '../services/scheduling_service.dart';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../services/chamber_resolver.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_role.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../widgets/user_avatar.dart';
import '../widgets/state_views.dart';
import '../widgets/profile_avatar_button.dart';
import '../widgets/chamber_accessibility.dart';
import '../theme/app_constants.dart';
import '../theme/app_theme.dart';
import 'operator_desk_screen.dart';

/// Doctor's Manage Tab — 3 complete sections:
/// 1. Patient Queue (today's live line, serial numbers, reorderable queue)
/// 2. Chamber Cards (fetched from Firebase, cached locally, assign/remove operators)
/// 3. Patient Reviews (real-time reviews, patient feedback, prescription proof verification)
class DoctorManagerScreen extends StatefulWidget {
  const DoctorManagerScreen({super.key});

  @override
  State<DoctorManagerScreen> createState() => _DoctorManagerScreenState();
}

class _DoctorManagerScreenState extends State<DoctorManagerScreen> {
  String? _doctorProfileId;
  String _doctorName = 'Doctor Specialist';
  bool _isLoadingDoctor = true;
  List<Map<String, dynamic>> _chambers = [];

  @override
  void initState() {
    super.initState();
    _loadDoctorProfile();
  }

  Future<void> _loadDoctorProfile() async {
    setState(() => _isLoadingDoctor = true);
    final user = AuthService.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isLoadingDoctor = false);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'doctor_chambers_${user.uid}';

    // 1. Load local cache first for instant rendering without blocking
    final cached = prefs.getString(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      try {
        final List decoded = jsonDecode(cached);
        _chambers = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
    }

    // 2. Fetch updates from Firestore for this user
    try {
      final profile = await FirestoreService.fetchUserProfile(user.uid);
      String? docId = profile?['doctorProfileId']?.toString();

      if (docId == null || docId.isEmpty) {
        final querySnap = await FirebaseFirestore.instance
            .collection('doctors')
            .where('claimedByUid', isEqualTo: user.uid)
            .limit(1)
            .get();
        if (querySnap.docs.isNotEmpty) {
          docId = querySnap.docs.first.id;
        }
      }

      if (docId != null && docId.isNotEmpty) {
        _doctorProfileId = docId;
        final docSnap = await FirebaseFirestore.instance.collection('doctors').doc(docId).get();
        if (docSnap.exists) {
          final data = docSnap.data() ?? {};
          _doctorName = (data['name'] as String?) ?? user.displayName ?? 'Doctor Specialist';
          final rawChambers = (data['chambers'] as List?) ?? [];
          final fetched = rawChambers.map((c) => Map<String, dynamic>.from(c as Map)).toList();
          // The chamber doc owns hours and fee; the copy on the doctor may be
          // stale or missing them (which showed a 5–9 PM default).
          for (final c in fetched) {
            final id = (c['id'] ?? '').toString();
            if (id.isEmpty) continue;
            final rec = await ChamberResolver.resolveChamberRecord(chamberId: id, doctorId: docId);
            if (rec == null) continue;
            if ((rec.visitingHours ?? '').isNotEmpty) c['visitingHours'] = rec.visitingHours;
            if (rec.name.isNotEmpty) c['hospitalName'] = rec.name;
          }
          // Who runs each desk now lives only in chamber_operators (public
          // docs no longer carry it); the doctor may read their own.
          final desks = await FirebaseFirestore.instance
              .collection('chamber_operators')
              .where('doctorId', isEqualTo: docId)
              .get();
          for (final c in fetched) {
            final match = desks.docs.where((d) => d.data()['chamberId'] == c['id']);
            if (match.isEmpty) continue;
            final op = match.first.data();
            c['hasOperator'] = true;
            c['operatorUid'] = op['operatorUid'];
            c['operatorName'] = op['operatorName'];
          }
          _chambers = fetched;
          await prefs.setString(cacheKey, jsonEncode(_chambers));
        }
      } else {
        // No linked profile (e.g. an admin): never invent doctor_{uid}, or
        // the account starts owning chambers and receiving their events.
        _doctorProfileId = null;
        _doctorName = user.displayName ?? 'Dr. Specialist';
      }
    } catch (e) {
      debugPrint('Error syncing doctor chambers from Firestore: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingDoctor = false);
      }
    }
  }

  Future<void> _removeOperator(int index) async {
    final ch = _chambers[index];
    final chamberId = ch['id']?.toString() ?? ch['name']?.toString() ?? 'chamber-1';
    final operatorUid = ch['operatorUid']?.toString() ?? '';

    try {
      if (_doctorProfileId != null) {
        await FirestoreService.removeChamberOperator(
          doctorId: _doctorProfileId!,
          chamberId: chamberId,
          operatorUid: operatorUid,
        );
      }

      setState(() {
        ch['hasOperator'] = false;
        ch['operatorUid'] = null;
        ch['operatorName'] = null;
        ch['operatorEmail'] = null;
      });

      final user = AuthService.currentUser;
      if (user != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('doctor_chambers_${user.uid}', jsonEncode(_chambers));
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Operator removed from ${ch['name']}. You are running this queue directly.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error removing operator: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_doctorName.isNotEmpty ? _doctorName : 'Doctor Management'),
          actions: const [
            ProfileAvatarButton(role: UserRole.doctor),
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
                labelColor: colorScheme.primary,
                labelStyle: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.primary,
                ),
                unselectedLabelColor: Colors.white,
                unselectedLabelStyle: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
                dividerColor: Colors.transparent,
                tabs: const [
                  Tab(text: 'Queue Desk'),
                  Tab(text: 'Chambers'),
                  Tab(text: 'Reviews'),
                ],
              ),
            ),
          ),
        ),
        body: _isLoadingDoctor
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  // Tab 1: Live Patient Queue Desk
                  OperatorDeskScreen(showAppBar: false, doctorId: _doctorProfileId ?? AuthService.userRoles.doctorProfileId),

                  // Tab 2: Chambers & Operator Assignment
                  _buildChambersSection(colorScheme),

                  // Tab 3: Patient Reviews for this Doctor
                  _buildDoctorReviewsSection(),
                ],
              ),
      ),
    );
  }

  void _showAddChamberDialog() {
    _showChamberDialog();
  }

  void _showChamberDialog({int? editIndex}) {
    final isEditing = editIndex != null;
    final Map<String, dynamic>? existing =
        isEditing ? _chambers[editIndex] : null;

    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    final areaCtrl = TextEditingController(text: existing?['area'] ?? '');
    final hoursCtrl = TextEditingController(
        text: existing?['visitingHours'] ?? '5:00 PM – 9:00 PM (Sat–Thu)');
    final slotCtrl = TextEditingController(
        text: (existing?['slotMinutes']?.toString() ?? '10'));

    final feeCtrl =
        TextEditingController(text: existing?['fee']?.toString() ?? '800');

    bool isAccessible = existing?['isAccessible'] == true;
    final List<String> selectedFeatures = List<String>.from(
        existing?['accessibilityFeatures'] as List? ?? ['Ramp']);

    const availableFeatures = [
      'Ramp',
      'Lift/Elevator',
      'Accessible washroom',
      'Ground floor',
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppConstants.radiusCard),
            ),
            title: Text(isEditing ? 'Edit Chamber Location' : 'Add Chamber Location'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: 'Hospital / Clinic Name',
                      hintText: 'e.g. Popular Diagnostic / Bup Medical',
                      fillColor: Colors.white,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppConstants.radiusInput),
                        borderSide: const BorderSide(color: AppColors.borderSubtle),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: areaCtrl,
                    decoration: InputDecoration(
                      labelText: 'Area / Location',
                      hintText: 'e.g. Mirpur, Dhaka',
                      fillColor: Colors.white,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppConstants.radiusInput),
                        borderSide: const BorderSide(color: AppColors.borderSubtle),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: hoursCtrl,
                    decoration: InputDecoration(
                      labelText: 'Visiting Hours',
                      fillColor: Colors.white,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppConstants.radiusInput),
                        borderSide: const BorderSide(color: AppColors.borderSubtle),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: slotCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Slot Duration (minutes)',
                      hintText: 'Default 10 min (allowed 5–15)',
                      fillColor: Colors.white,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppConstants.radiusInput),
                        borderSide: const BorderSide(color: AppColors.borderSubtle),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: feeCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Consultation Fee (৳)',
                      fillColor: Colors.white,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppConstants.radiusInput),
                        borderSide: const BorderSide(color: AppColors.borderSubtle),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Disability-friendly chamber toggle
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(AppConstants.radiusInput),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          title: const Text(
                            'Disability-friendly chamber',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                          subtitle: const Text(
                            'Wheelchair access, ramp or lift',
                            style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                          ),
                          value: isAccessible,
                          activeTrackColor: Theme.of(context).colorScheme.primary,
                          onChanged: (val) {
                            setDialogState(() {
                              isAccessible = val;
                              if (val && selectedFeatures.isEmpty) {
                                selectedFeatures.add('Ramp');
                              }
                            });
                          },
                        ),
                        if (isAccessible) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Divider(height: 1),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
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
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: availableFeatures.map((feat) {
                                    final isSelected = selectedFeatures.contains(feat);
                                    return FilterChip(
                                      label: Text(
                                        feat,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isSelected ? Colors.white : Theme.of(context).colorScheme.primary,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      selected: isSelected,
                                      selectedColor: Theme.of(context).colorScheme.primary,
                                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                      checkmarkColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(AppConstants.radiusChip),
                                        side: BorderSide(
                                          color: isSelected ? Theme.of(context).colorScheme.primary : AppColors.borderSubtle,
                                        ),
                                      ),
                                      onSelected: (selected) {
                                        setDialogState(() {
                                          if (selected) {
                                            selectedFeatures.add(feat);
                                          } else {
                                            selectedFeatures.remove(feat);
                                          }
                                        });
                                      },
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppConstants.radiusButton),
                  ),
                ),
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  final area = areaCtrl.text.trim();
                  if (name.isEmpty) return;

                  final rawHours = hoursCtrl.text.trim();
                  final structuredHours = SchedulingService.structuredVisitingHours(rawHours);
                  final chId = (existing?['id'] ?? 'chamber-${DateTime.now().millisecondsSinceEpoch}').toString();

                  final chamberData = {
                    'id': chId,
                    'chamberId': chId,
                    'name': name,
                    'hospitalName': name,
                    'area': area.isEmpty ? 'Dhaka' : area,
                    'visitingHours': structuredHours,
                    'visitingHoursDisplay': rawHours.isNotEmpty ? rawHours : 'Visiting hours not set',
                    'slotMinutes': (int.tryParse(slotCtrl.text.trim()) ?? 10).clamp(5, 15),
                    'fee': int.tryParse(feeCtrl.text.trim()) ?? 800,
                    if (_doctorProfileId != null) 'ownerDoctorId': _doctorProfileId,
                    if (_doctorProfileId != null) 'doctorIds': [_doctorProfileId],
                    if (_doctorProfileId != null) 'members': {_doctorProfileId!: 'owner'},
                    'aliases': [chId, name],
                    'hasOperator': existing?['hasOperator'] ?? false,
                    'operatorUid': existing?['operatorUid'],
                    'operatorName': existing?['operatorName'],
                    'operatorEmail': existing?['operatorEmail'],
                    'isAccessible': isAccessible,
                    'accessibilityFeatures': selectedFeatures,
                    'wheelchairEntrance': isAccessible,
                    'wheelchairParking': selectedFeatures.contains('Ramp'),
                    'liftAvailable': selectedFeatures.contains('Lift/Elevator'),
                    'accessibleToilet': selectedFeatures.contains('Accessible washroom'),
                  };

                  setState(() {
                    if (isEditing) {
                      _chambers[editIndex] = chamberData;
                    } else {
                      _chambers.add(chamberData);
                    }
                  });

                  final messenger = ScaffoldMessenger.of(context);
                  final nav = Navigator.of(ctx);

                  final user = AuthService.currentUser;
                  if (user != null) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('doctor_chambers_${user.uid}', jsonEncode(_chambers));
                  }

                  if (_doctorProfileId != null) {
                    try {
                      final docName = user?.displayName ?? 'Doctor Specialist';
                      await FirebaseFirestore.instance
                          .collection('doctors')
                          .doc(_doctorProfileId)
                          .set({
                            'chambers': _chambers,
                            'name': docName,
                            'name_lower': docName.toLowerCase(),
                            'claimedByUid': user?.uid,
                            'isClaimed': true,
                            'status': 'active',
                            'updatedAt': FieldValue.serverTimestamp(),
                          }, SetOptions(merge: true));

                      final chId = (chamberData['id'] ?? '').toString();
                      if (chId.isNotEmpty) {
                        await FirebaseFirestore.instance
                            .collection('chambers')
                            .doc(chId)
                            .set({
                              ...chamberData,
                              'ownerDoctorId': _doctorProfileId,
                              'doctorIds': [_doctorProfileId],
                              'members': {_doctorProfileId!: 'owner'},
                              'aliases': [chId, name],
                              'doctorId': _doctorProfileId,
                              'doctorName': docName,
                              'updatedAt': FieldValue.serverTimestamp(),
                            }, SetOptions(merge: true));
                      }
                    } catch (_) {}
                  }

                  nav.pop();
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(isEditing
                          ? '$name chamber details updated.'
                          : '$name added to your active chambers.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                child: const Text('Save Chamber'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAssignOperatorDialog(int index) async {
    final currentChamber = _chambers[index];
    final chamberId = currentChamber['id']?.toString() ?? currentChamber['name']?.toString() ?? 'chamber-1';
    final currentUser = AuthService.currentUser;

    if (!mounted) return;

    final nameCtrl = TextEditingController(text: currentChamber['operatorName'] ?? '');
    final emailCtrl = TextEditingController(text: currentChamber['operatorEmail'] ?? '');
    final usernameSearchCtrl = TextEditingController();
    String selectedUid = currentChamber['operatorUid'] ?? '';
    String selectedUsername = '';
    List<Map<String, dynamic>> searchResults = [];
    bool isSearching = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          void doSearch(String query) async {
            final trimmed = query.trim().replaceAll('@', '');
            if (trimmed.isEmpty) {
              setDialogState(() {
                searchResults = [];
                isSearching = false;
              });
              return;
            }
            setDialogState(() => isSearching = true);
            try {
              final users = await FirestoreService.searchUsersByUsername(trimmed);
              setDialogState(() {
                searchResults = users;
                isSearching = false;
              });
            } catch (_) {
              setDialogState(() => isSearching = false);
            }
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Assign Desk Operator'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Search any registered user by their unique @username to assign as desk operator.',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),

                    // Quick option: assign current user
                    if (currentUser != null)
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                          foregroundColor: Theme.of(context).colorScheme.primary,
                        ),
                        onPressed: () {
                          setDialogState(() {
                            selectedUid = currentUser.uid;
                            nameCtrl.text = currentUser.displayName?.isNotEmpty == true
                                ? currentUser.displayName!
                                : (currentUser.email?.split('@').first ?? 'Desk Operator');
                            emailCtrl.text = currentUser.email ?? '';
                            selectedUsername = currentUser.email?.split('@').first ?? 'me';
                          });
                        },
                        icon: const Icon(Icons.person_pin, size: 18),
                        label: Text(
                          'Assign My Current Account (${currentUser.email?.split('@').first ?? "me"})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 12),

                    // Search input
                    TextField(
                      controller: usernameSearchCtrl,
                      decoration: InputDecoration(
                        labelText: 'Search user by @username',
                        hintText: 'e.g. nuzhat719 or rehnuma',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: isSearching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : (usernameSearchCtrl.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    onPressed: () {
                                      usernameSearchCtrl.clear();
                                      doSearch('');
                                    },
                                  )
                                : null),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (val) => doSearch(val),
                    ),
                    const SizedBox(height: 8),

                    // Live search results
                    if (searchResults.isNotEmpty) ...[
                      const Text('Matching Users:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: searchResults.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final u = searchResults[i];
                            final uid = u['uid']?.toString() ?? '';
                            final name = u['name']?.toString() ?? 'User';
                            final uname = u['username']?.toString() ?? '';
                            final email = u['email']?.toString() ?? '';

                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: UserAvatar(uid: uid, name: name, radius: 14),
                              title: Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                uname.isNotEmpty ? '@$uname • $email' : email,
                                style: const TextStyle(fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: FilledButton.tonal(
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                ),
                                onPressed: () {
                                  setDialogState(() {
                                    selectedUid = uid;
                                    selectedUsername = uname;
                                    nameCtrl.text = name;
                                    emailCtrl.text = email;
                                  });
                                },
                                child: const Text('Select', style: TextStyle(fontSize: 11)),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else if (usernameSearchCtrl.text.isNotEmpty && !isSearching) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'No user found with username "${usernameSearchCtrl.text.trim()}".',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],

                    // Selected user card indicator
                    if (selectedUid.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16A34A).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF16A34A).withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Selected: ${nameCtrl.text}',
                                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF16A34A)),
                                  ),
                                  if (selectedUsername.isNotEmpty)
                                    Text(
                                      '@$selectedUsername',
                                      style: TextStyle(fontSize: 11, color: Colors.green.shade800),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Details input fields
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Operator Name',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: emailCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Operator Email',
                        border: OutlineInputBorder(),
                        isDense: true,
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
                  final email = emailCtrl.text.trim();
                  if (name.isEmpty) return;

                  final resolvedUid = selectedUid.isNotEmpty
                      ? selectedUid
                      : (currentUser?.uid ?? 'op_${DateTime.now().millisecondsSinceEpoch}');

                  if (_doctorProfileId != null) {
                    await FirestoreService.assignChamberOperator(
                      doctorId: _doctorProfileId!,
                      chamberId: chamberId,
                      operatorUid: resolvedUid,
                      operatorName: name,
                      operatorEmail: email,
                    );
                  }

                  setState(() {
                    _chambers[index]['hasOperator'] = true;
                    _chambers[index]['operatorUid'] = resolvedUid;
                    _chambers[index]['operatorName'] = name;
                    _chambers[index]['operatorEmail'] = email;
                  });

                  if (currentUser != null) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('doctor_chambers_${currentUser.uid}', jsonEncode(_chambers));
                  }

                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Operator $name assigned to ${_chambers[index]['name']}.')),
                    );
                  }
                },
                child: const Text('Assign Operator'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildChambersSection(ColorScheme colorScheme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildPendingOperatorApplications(colorScheme),
        if (_chambers.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.apartment_outlined, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 14),
                  Text(
                    'No Chambers Added Yet',
                    style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Add your hospital or clinic chamber location to manage your visiting hours, consultation fees, and assign desk operators.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _showAddChamberDialog,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Chamber Location'),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'My Chambers',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${_chambers.length} active chamber ${_chambers.length == 1 ? "location" : "locations"}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
              FilledButton.tonalIcon(
                onPressed: _showAddChamberDialog,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Chamber'),
              ),
            ],
          ),
        const SizedBox(height: 16),
        ..._chambers.asMap().entries.map((entry) {
          final i = entry.key;
          final chamber = entry.value;
          final hasOp = chamber['hasOperator'] == true;

          return Card(
            margin: const EdgeInsets.only(bottom: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        backgroundColor: colorScheme.primaryContainer.withValues(alpha: 0.5),
                        child: Icon(Icons.local_hospital_outlined, color: colorScheme.primary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (chamber['name'] ?? chamber['hospitalName'] ?? 'Consultation Chamber') as String,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              (chamber['area'] ?? 'Dhaka') as String,
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                      if (chamber['isAccessible'] == true) ...[
                        const AccessibilityIcon(
                          isAccessible: true,
                          showLabel: true,
                        ),
                        const SizedBox(width: 4),
                      ],
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Edit Chamber',
                        onPressed: () => _showChamberDialog(editIndex: i),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.schedule, size: 16, color: Colors.grey.shade600),
                      const SizedBox(width: 6),
                      Text(
                        (chamber['visitingHours'] ?? '5:00 PM – 9:00 PM') as String,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      const Spacer(),
                      Text(
                        '৳${chamber['fee'] ?? 800}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Operator Status Box
                  if (hasOp) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16A34A).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF16A34A).withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_outline, color: Color(0xFF16A34A), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Assigned Desk Operator',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF16A34A),
                                  ),
                                ),
                                Text(
                                  (chamber['operatorName'] ?? 'Desk Assistant') as String,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                                if (chamber['operatorEmail'] != null && (chamber['operatorEmail'] as String).isNotEmpty)
                                  Text(
                                    chamber['operatorEmail'] as String,
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => _removeOperator(i),
                            child: const Text('Remove', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Nudge/Banner: Doctor runs queue themselves
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info_outline, size: 18, color: Colors.amber.shade900),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'No operator assigned — you run this queue directly',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Assign a desk assistant or hospital receptionist to manage tickets and call patients.',
                            style: TextStyle(fontSize: 11.5, color: Colors.brown.shade700),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            onPressed: () => _showAssignOperatorDialog(i),
                            icon: const Icon(Icons.person_add_alt_1, size: 16),
                            label: const Text('Assign Operator'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
        ],
      ],
    );
  }

  Widget _buildPendingOperatorApplications(ColorScheme colorScheme) {
    final docId = _doctorProfileId ?? AuthService.userRoles.doctorProfileId;
    if (docId == null || docId.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirestoreService.operatorApplicationsStream(docId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();

        final pendingDocs = snapshot.data!.docs
            .where((d) => (d.data()['status'] ?? 'pending') == 'pending')
            .toList();

        if (pendingDocs.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.amber.shade400, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.person_add_alt_1, size: 18, color: Colors.amber.shade900),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Desk Operator Applications (${pendingDocs.length})',
                            style: GoogleFonts.poppins(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.amber.shade900,
                            ),
                          ),
                          Text(
                            'Applicants want to manage your clinic queue as desk operators',
                            style: TextStyle(fontSize: 11.5, color: Colors.brown.shade800),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                itemCount: pendingDocs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final appDoc = pendingDocs[index];
                  final data = appDoc.data();
                  final applicantName = data['applicantName']?.toString() ?? 'Applicant';
                  final applicantUsername = data['applicantUsername']?.toString() ?? '';
                  final applicantEmail = data['applicantEmail']?.toString() ?? '';
                  final applicantPhone = data['phone']?.toString() ?? '';
                  final chamberName = data['chamberName']?.toString() ?? data['chamberId']?.toString() ?? 'Chamber';
                  final chamberId = data['chamberId']?.toString() ?? '';
                  final applicantUid = data['applicantUid']?.toString() ?? '';
                  final note = data['note']?.toString() ?? '';

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            UserAvatar(uid: applicantUid, name: applicantName, radius: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    applicantName,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                                  ),
                                  if (applicantUsername.isNotEmpty)
                                    Text(
                                      '@$applicantUsername',
                                      style: TextStyle(fontSize: 11.5, color: colorScheme.primary, fontWeight: FontWeight.w600),
                                    ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                chamberName,
                                style: TextStyle(fontSize: 11, color: Colors.blue.shade800, fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (applicantEmail.isNotEmpty || applicantPhone.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              if (applicantEmail.isNotEmpty) ...[
                                const Icon(Icons.email_outlined, size: 12, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(applicantEmail, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                              if (applicantPhone.isNotEmpty) ...[
                                const SizedBox(width: 10),
                                const Icon(Icons.phone_outlined, size: 12, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(applicantPhone, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ],
                          ),
                        ],
                        if (note.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '"$note"',
                            style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: Colors.black87),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red.shade700,
                                side: BorderSide(color: Colors.red.shade300),
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                              ),
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (c) => AlertDialog(
                                    title: const Text('Decline Application?'),
                                    content: Text('Decline operator application from $applicantName?'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                      FilledButton(
                                        style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('Decline'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await FirestoreService.rejectOperatorApplication(appDoc.id);
                                  if (mounted) {
                                    messenger.showSnackBar(
                                      SnackBar(content: Text('Declined application from $applicantName.')),
                                    );
                                  }
                                }
                              },
                              child: const Text('Decline', style: TextStyle(fontSize: 12)),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.success,
                                foregroundColor: Colors.white,
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                              ),
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                try {
                                  await FirestoreService.approveOperatorApplication(
                                    applicationId: appDoc.id,
                                    doctorId: docId,
                                    chamberId: chamberId,
                                    applicantUid: applicantUid,
                                    applicantName: applicantName,
                                    applicantEmail: applicantEmail,
                                    chamberName: chamberName,
                                  );

                                  // Update local chamber in state
                                  setState(() {
                                    for (final ch in _chambers) {
                                      final id = ch['id']?.toString() ?? ch['name']?.toString();
                                      if (id == chamberId || ch['name'] == chamberName) {
                                        ch['hasOperator'] = true;
                                        ch['operatorUid'] = applicantUid;
                                        ch['operatorName'] = applicantName;
                                        ch['operatorEmail'] = applicantEmail;
                                      }
                                    }
                                  });

                                  final user = AuthService.currentUser;
                                  if (user != null) {
                                    final prefs = await SharedPreferences.getInstance();
                                    await prefs.setString('doctor_chambers_${user.uid}', jsonEncode(_chambers));
                                  }

                                  messenger.showSnackBar(
                                    SnackBar(content: Text('$applicantName is now approved and assigned to $chamberName! 🎉')),
                                  );
                                } catch (e) {
                                  messenger.showSnackBar(
                                    SnackBar(content: Text('Error approving operator: $e')),
                                  );
                                }
                              },
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Approve & Assign', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDoctorReviewsSection() {
    final docId = _doctorProfileId;
    if (docId == null || docId.isEmpty) {
      return const Center(
        child: Text('Please link or claim your doctor profile to view patient reviews.'),
      );
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: FirestoreService.reviewsStream(docId),
      builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorStateView.fromError(snapshot.error,
                what: 'reviews', onRetry: () => setState(() {}));
          }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final reviews = snapshot.data ?? [];

        double avgRating = 0;
        if (reviews.isNotEmpty) {
          double sum = 0;
          for (final r in reviews) {
            sum += (r['rating'] as num?)?.toDouble() ?? 0.0;
          }
          avgRating = sum / reviews.length;
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Rating header card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.amber.shade50,
                    child: Text(
                      avgRating > 0 ? avgRating.toStringAsFixed(1) : '-',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Overall Patient Rating',
                          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            ...List.generate(5, (i) {
                              return Icon(
                                i < avgRating.round() ? Icons.star : Icons.star_border,
                                size: 16,
                                color: Colors.amber.shade700,
                              );
                            }),
                            const SizedBox(width: 8),
                            Text(
                              '(${reviews.length} ${reviews.length == 1 ? "Review" : "Reviews"})',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Patient Feedback',
              style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            if (reviews.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.rate_review_outlined, size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 10),
                      Text(
                        'No patient reviews yet',
                        style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Reviews submitted by patients will be displayed here in real time.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...reviews.map((r) {
                final rating = (r['rating'] as num?)?.toInt() ?? 5;
                final comment = r['comment']?.toString() ?? '';
                final raterName = r['raterName']?.toString().isNotEmpty == true
                    ? r['raterName'].toString()
                    : 'Verified Patient';
                final dateStr = r['createdAt']?.toString() ?? '';
                final proofUrl = r['proofImageUrl']?.toString();
                final isVerified = r['isProofVerified'] == true;

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          UserAvatar(
                            uid: (r['userId'] ?? r['patientUid'])?.toString(),
                            name: raterName,
                            radius: 14,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  raterName,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                if (dateStr.isNotEmpty)
                                  Text(
                                    dateStr.split('T').first,
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                                  ),
                              ],
                            ),
                          ),
                          Row(
                            children: List.generate(5, (i) {
                              return Icon(
                                i < rating ? Icons.star : Icons.star_border,
                                size: 15,
                                color: Colors.amber.shade700,
                              );
                            }),
                          ),
                        ],
                      ),
                      if (isVerified) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.check_circle, size: 13, color: Colors.green),
                            const SizedBox(width: 4),
                            Text('Verified visit prescription',
                                style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ],
                      if (comment.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(comment, style: const TextStyle(fontSize: 13, height: 1.35)),
                      ],
                      if (proofUrl != null && proofUrl.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            proofUrl,
                            height: 100,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}
