import '../widgets/user_avatar.dart';
import '../models/user_role.dart';
import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/doctor.dart';
import '../services/api_service.dart';
import 'appointment_screen.dart';
import 'doctor_detail_screen.dart';
import 'doctors_screen.dart';
import 'nearby_doctors_screen.dart';
import 'profile_screen.dart';
import '../services/auth_service.dart';
import '../services/specialty_matcher.dart';
import '../services/gemini_service.dart';
import '../widgets/chamber_accessibility.dart';
import 'health_chat_screen.dart';
import 'notifications_screen.dart';
import '../services/notification_service.dart';
import '../services/update_checker.dart';
import '../theme/app_theme.dart';
import '../theme/app_constants.dart';

class HomeScreen extends StatefulWidget {
  final Function(int, {String? searchQuery})? onTabSwitch;
  final UserRole role;

  const HomeScreen({
    super.key,
    this.onTabSwitch,
    this.role = UserRole.patient,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;

  List<Map<String, dynamic>> _specialities = [];
  List<Doctor> _topDoctors = [];
  Doctor? _ownDoctor;
  int? _totalDoctorsCount;
  String? _todayFeeling;
  bool _isMoodExpanded = false;
  bool _isMoodSubmittedToday = false;
  bool _isLoading = true;
  bool _isOffline = false;
  String? _error;

  // Search suggestions
  bool _showSuggestions = false;
  bool _isSearchingSuggestions = false;
  List<Doctor> _doctorSuggestions = [];
  List<String> _specialitySuggestions = [];

  // Symptom inline detection in main search bar
  MatchResult? _symptomMatch;
  bool _isAiSuggestingSpecialty = false;
  StreamSubscription<User?>? _authSubscription;

  String get _greetingName {
    final displayName = AuthService.currentUser?.displayName ?? '';
    if (displayName.trim().isEmpty) return '';
    final firstName = displayName.trim().split(' ').first;
    return firstName.isNotEmpty ? firstName : '';
  }


  List<Doctor> get _displayedDoctors {
    final query = _searchController.text.trim().toLowerCase();
    List<Doctor> list = query.isEmpty
        ? List<Doctor>.from(_topDoctors)
        : _topDoctors.where((d) =>
            d.name.toLowerCase().contains(query) ||
            d.specialities.any((s) => s.toLowerCase().contains(query)) ||
            (d.chamber?.hospitalName?.toLowerCase().contains(query) ?? false)).toList();

    final ownId = AuthService.userRoles.doctorProfileId;
    if (ownId != null && ownId.isNotEmpty) {
      final existingIdx = list.indexWhere((d) => d.id == ownId);
      if (existingIdx > 0) {
        final d = list.removeAt(existingIdx);
        list.insert(0, d);
      } else if (existingIdx < 0 && _ownDoctor != null) {
        final matches = query.isEmpty ||
            _ownDoctor!.name.toLowerCase().contains(query) ||
            _ownDoctor!.specialities.any((s) => s.toLowerCase().contains(query));
        if (matches) {
          list.insert(0, _ownDoctor!);
        }
      }
    }
    return list;
  }

  IconData _getSpecialtyIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('cardio') || lower.contains('heart')) return Icons.favorite_border;
    if (lower.contains('derma') || lower.contains('skin')) return Icons.spa_outlined;
    if (lower.contains('pediatric') || lower.contains('child') || lower.contains('baby')) return Icons.child_care_outlined;
    if (lower.contains('neuro') || lower.contains('brain')) return Icons.psychology_outlined;
    if (lower.contains('ortho') || lower.contains('bone')) return Icons.accessibility_new_outlined;
    if (lower.contains('eye') || lower.contains('ophthalm')) return Icons.visibility_outlined;
    if (lower.contains('dent') || lower.contains('tooth')) return Icons.sentiment_satisfied_alt_outlined;
    if (lower.contains('ent') || lower.contains('ear') || lower.contains('throat')) return Icons.hearing_outlined;
    if (lower.contains('gyn') || lower.contains('women') || lower.contains('obs')) return Icons.pregnant_woman_outlined;
    if (lower.contains('medic') || lower.contains('general')) return Icons.medical_services_outlined;
    if (lower.contains('pulmon') || lower.contains('lung') || lower.contains('chest')) return Icons.air_outlined;
    return Icons.local_hospital_outlined;
  }

  String get _todayDateKey {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _moodEmoji(String? mood) {
    switch (mood) {
      case 'great':
        return '🌟';
      case 'good':
        return '😊';
      case 'okay':
        return '😐';
      case 'low':
        return '😔';
      case 'unwell':
        return '🤒';
      default:
        return '🙂';
    }
  }

  String _moodLabel(String? mood) {
    switch (mood) {
      case 'great':
        return 'Great';
      case 'good':
        return 'Good';
      case 'okay':
        return 'Okay';
      case 'low':
        return 'Low';
      case 'unwell':
        return 'Unwell';
      default:
        return '';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdateChecker.checkForUpdate(context);
    });
    _searchController.addListener(_onSearchInputChanged);
    _loadData();
    _authSubscription = AuthService.authStateChanges.listen((user) {
      if (mounted) {
        setState(() {});
        _loadData();
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _searchDebounce?.cancel();
    _searchController.removeListener(_onSearchInputChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _openHealthAssistant() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const HealthChatScreen()),
    ).then((_) => _loadData());
  }

  void _onSearchInputChanged() {
    final query = _searchController.text.trim();
    _searchDebounce?.cancel();

    if (query.isEmpty) {
      setState(() {
        _showSuggestions = false;
        _isSearchingSuggestions = false;
        _doctorSuggestions = [];
        _specialitySuggestions = [];
        _symptomMatch = null;
        _isAiSuggestingSpecialty = false;
      });
      return;
    }

    setState(() {
      _showSuggestions = true;
      _isSearchingSuggestions = true;
    });

    // Rule-based symptom match — runs synchronously, no Firestore
    final ruleMatch = SpecialtyMatcher.match(query);
    if (ruleMatch != null) {
      setState(() => _symptomMatch = ruleMatch);
    }

    _searchDebounce = Timer(const Duration(milliseconds: 350), () async {
      // 1. Doctor/specialty directory suggestions (existing logic)
      try {
        final specMatches = _specialities
            .map((s) => (s['speciality'] ?? '').toString())
            .where((name) => name.toLowerCase().contains(query.toLowerCase()))
            .take(3)
            .toList();

        final searchResult = await ApiService.fetchDoctors(
          search: query,
          limit: 5,
        );

        if (mounted && _searchController.text.trim() == query) {
          setState(() {
            _specialitySuggestions = specMatches;
            _doctorSuggestions = List<Doctor>.from(searchResult['doctors'] ?? []);
            _isSearchingSuggestions = false;
          });
        }
      } catch (_) {
        if (mounted) {
          final localDoctorMatches = _topDoctors
              .where((d) =>
                  d.name.toLowerCase().contains(query.toLowerCase()) ||
                  d.specialities
                      .any((s) => s.toLowerCase().contains(query.toLowerCase())))
              .take(5)
              .toList();
          setState(() {
            _specialitySuggestions = _specialities
                .map((s) => (s['speciality'] ?? '').toString())
                .where((name) => name.toLowerCase().contains(query.toLowerCase()))
                .take(3)
                .toList();
            _doctorSuggestions = localDoctorMatches;
            _isSearchingSuggestions = false;
          });
        }
      }

      // 2. If no rule match AND query looks like a symptom description,
      //    call Gemini AI for specialty suggestion
      if (mounted && _symptomMatch == null && (query.split(' ').length >= 2 || query.length >= 10)) {
        setState(() => _isAiSuggestingSpecialty = true);
        try {
          final aiResult = await GeminiService.evaluateSymptoms(query);
          if (mounted && _searchController.text.trim() == query && aiResult != null && !aiResult.isOffTopic) {
            final specialty = aiResult.recommendedSpecialty;
            if (specialty != null && specialty.isNotEmpty) {
              setState(() {
                _symptomMatch = MatchResult(
                  topSpecialty: specialty,
                  alternatives: [specialty],
                  isVague: false,
                );
              });
            }
          }
        } catch (_) {} finally {
          if (mounted) setState(() => _isAiSuggestingSpecialty = false);
        }
      } else {
        if (mounted) setState(() => _isAiSuggestingSpecialty = false);
      }
    });
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final localTodayMood = prefs.getString('mood_$_todayDateKey');
      if (localTodayMood != null) {
        _isMoodSubmittedToday = true;
        _todayFeeling = localTodayMood;
      }

      final specialitiesData = await ApiService.fetchSpecialities();
      final doctorsData = await ApiService.fetchDoctors(limit: 5);
      final todayStatus = await ApiService.fetchTodayFeeling();

      Doctor? ownDoc;
      final ownId = AuthService.userRoles.doctorProfileId;
      if (ownId != null && ownId.isNotEmpty) {
        try {
          ownDoc = await ApiService.fetchDoctorById(ownId);
        } catch (_) {}
      }

      final List<Doctor> doctors =
          List<Doctor>.from(doctorsData['doctors'] ?? []);
      final bool offlineFlag = doctorsData['isOffline'] == true;

      // Cache real data locally so cutting the backend keeps the app presentable
      if (doctors.isNotEmpty) {
        await prefs.setString('cached_top_doctors',
            jsonEncode(doctors.map((d) => d.toJson()).toList()));
      }
      if (specialitiesData.isNotEmpty) {
        await prefs.setString(
            'cached_specialities', jsonEncode(specialitiesData));
      }
      if (doctorsData['total'] != null) {
        await prefs.setInt('cached_total_doctors', doctorsData['total'] as int);
      }

      setState(() {
        _specialities = specialitiesData;
        _topDoctors = doctors;
        _ownDoctor = ownDoc;
        _totalDoctorsCount = doctorsData['total'] as int?;
        _isOffline = offlineFlag;
        if (todayStatus != null && todayStatus['feeling'] != null) {
          _todayFeeling = todayStatus['feeling'];
          _isMoodSubmittedToday = true;
          prefs.setString('mood_$_todayDateKey', _todayFeeling!);
        }
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      // Fallback: try loading cached doctor info so app is still presentable
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedDocsRaw = prefs.getString('cached_top_doctors');
        final cachedSpecsRaw = prefs.getString('cached_specialities');
        final cachedTotal = prefs.getInt('cached_total_doctors');

        if (cachedDocsRaw != null && cachedDocsRaw.isNotEmpty) {
          final List decoded = jsonDecode(cachedDocsRaw);
          final loadedDocs = decoded.map((j) => Doctor.fromJson(j)).toList();
          List<Map<String, dynamic>> loadedSpecs = [];
          if (cachedSpecsRaw != null) {
            final List decSpecs = jsonDecode(cachedSpecsRaw);
            loadedSpecs = decSpecs.cast<Map<String, dynamic>>();
          }

          setState(() {
            _topDoctors = loadedDocs;
            _specialities = loadedSpecs;
            _totalDoctorsCount = cachedTotal ?? loadedDocs.length;
            _isOffline = true;
            _isLoading = false;
            _error = null;
          });
          return;
        }
      } catch (_) {}

      setState(() {
        _error =
            'No Internet Connection\nPlease check your network connection and try again.';
        _isLoading = false;
      });
    }
  }

  void _submitSearch(String query) {
    setState(() {
      _showSuggestions = false;
    });
    _searchFocusNode.unfocus();
    if (query.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DoctorsScreen(initialQuery: query),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayedDoctors = _displayedDoctors;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Header: Full-width primary-color block with rounded bottom corners (radius 28)
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(AppConstants.radiusHeader),
                    bottomRight: Radius.circular(AppConstants.radiusHeader),
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppConstants.screenPadding,
                      12,
                      AppConstants.screenPadding,
                      14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Top row: avatar (circle, 44) + "Welcome" & username on left, notification bell on right
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ProfileScreen(),
                                  ),
                                );
                              },
                              child: const UserAvatar.me(radius: 22, ring: true),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Hello, ${_greetingName.isNotEmpty ? _greetingName : 'there'}',
                                    style: GoogleFonts.poppins(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            StreamBuilder<List<AppNotification>>(
                              stream: NotificationService.notificationsStream(
                                  AuthService.currentUser?.uid ?? 'guest'),
                              builder: (context, snapshot) {
                                final unreadCount = snapshot.data
                                        ?.where((n) => !n.isRead)
                                        .length ??
                                    0;
                                return Stack(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.notifications_none, color: Colors.white),
                                      tooltip: 'Notifications',
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => const NotificationsScreen(),
                                          ),
                                        );
                                      },
                                    ),
                                    if (unreadCount > 0)
                                      Positioned(
                                        right: 8,
                                        top: 8,
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: const BoxDecoration(
                                            color: AppColors.error,
                                            shape: BoxShape.circle,
                                          ),
                                          constraints: const BoxConstraints(
                                            minWidth: 16,
                                            minHeight: 16,
                                          ),
                                          child: Text(
                                            unreadCount > 9 ? '9+' : '$unreadCount',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Below: White rounded search bar (radius 14, height 48, hint "Search doctor", search icon on right)
                        Container(
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(AppConstants.radiusSearch),
                            boxShadow: AppConstants.softShadow,
                          ),
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            onChanged: (_) {
                              setState(() {});
                              _onSearchInputChanged();
                            },
                            onSubmitted: _submitSearch,
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AppColors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Search doctor',
                              hintStyle: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: AppColors.textSecondary,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.primary, size: 20),
                                    tooltip: 'Ask AI Assistant',
                                    onPressed: _openHealthAssistant,
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.search, color: Theme.of(context).colorScheme.primary),
                                    onPressed: () => _submitSearch(_searchController.text),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Content body
              Padding(
                padding: const EdgeInsets.all(AppConstants.screenPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Dropdown matching doctor names / specialties / symptoms
                    _buildSearchSuggestionsDropdown(colorScheme),
                    if (_showSuggestions && _searchController.text.trim().isNotEmpty)
                      const SizedBox(height: AppConstants.sectionGap),

                    // Doctors Near Me Card (white card, location icon in soft red circle, chevron)
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppConstants.radiusCard),
                        boxShadow: AppConstants.softShadow,
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(AppConstants.radiusCard),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const NearbyDoctorsScreen(),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                              vertical: 14.0,
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: AppColors.locationRed.withValues(alpha: 0.15),
                                  child: const Icon(
                                    Icons.location_on_outlined,
                                    color: AppColors.locationRed,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Doctors Near Me',
                                        style: AppTheme.cardTitle,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Find chambers and listed doctors close to your location',
                                        style: AppTheme.caption,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right, color: AppColors.textSecondary),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: AppConstants.sectionGap),

                    if (_isLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                          child: Card(
                            color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusCard)),
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                children: [
                                  Icon(Icons.wifi_off_rounded, size: 40, color: Theme.of(context).colorScheme.error),
                                  const SizedBox(height: 10),
                                  Text(
                                    'No Internet Connection',
                                    style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.error),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Please check your network connection and try again.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                  ),
                                  const SizedBox(height: 12),
                                  FilledButton.tonalIcon(
                                    onPressed: _loadData,
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('Retry'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    else ...[
                      if (_isOffline)
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.amber.shade300),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.cloud_off_rounded, size: 20, color: Colors.amber.shade900),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Offline mode • Displaying saved doctor directory',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // "Categories" row: title left, "Show All" right in primary color
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Categories', style: AppTheme.sectionTitle),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const DoctorsScreen(),
                                ),
                              );
                            },
                            child: Text(
                              'Show All',
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 3-column grid of white rounded tiles (radius 16), outlined primary-color icon (32) above 12px label
                      _buildCategoriesGrid(),

                      const SizedBox(height: AppConstants.sectionGap),

                      // "Top Doctors" row with "6,000+ listed doctors" subtitle and "See All"
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Top Doctors', style: AppTheme.sectionTitle),
                              const SizedBox(height: 2),
                              Text(
                                _totalDoctorsCount != null && _totalDoctorsCount! >= 1000
                                    ? '6,000+ listed doctors'
                                    : '6,000+ listed doctors',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const DoctorsScreen(),
                                ),
                              );
                            },
                            child: Text(
                              'See All',
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Doctor cards
                      if (displayedDoctors.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24.0),
                          child: Center(
                            child: Text(
                              'No matching doctors found.',
                              style: AppTheme.body,
                            ),
                          ),
                        )
                      else
                        ...displayedDoctors.map((doc) => _DoctorListCard(doctor: doc, isPinnedOwn: AuthService.userRoles.doctorProfileId == doc.id)),
                    ],

                    const SizedBox(height: AppConstants.sectionGap),

                    // Daily feeling / mood widget
                    _buildFeelingSection(context, colorScheme),

                    // Reserve bottom padding so content scrolls above floating nav
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Display label for a category tile: "MEDICINE SPECIALISTS" -> "Medicine
  /// Specialists" (wraps to two lines instead of truncating).
  static String _categoryLabel(String raw) {
    if (raw.toUpperCase().contains('(ENT)')) return 'ENT Specialists';
    return raw
        .toLowerCase()
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  Widget _buildCategoriesGrid() {
    final List<String> rawSpecs = _specialities
        .map((s) => (s['speciality'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .take(5)
        .toList();
    final List<String> categories = rawSpecs.isNotEmpty
        ? [...rawSpecs, if (!rawSpecs.any((s) => s.toLowerCase().contains('ent'))) 'OTOLARYNGOLOGISTS (ENT)']
            .take(6)
            .toList()
        : const ['General Medicine', 'Cardiology', 'Pediatrics', 'Dermatology', 'ENT', 'Orthopedics'];

    return GridView.builder(
      shrinkWrap: true,
      // Without this the grid inherits the status-bar inset as top padding.
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: categories.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.0,
      ),
      itemBuilder: (context, index) {
        final cat = categories[index];
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppConstants.radiusCard),
            boxShadow: AppConstants.softShadow,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppConstants.radiusCard),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DoctorsScreen(initialQuery: cat),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _getSpecialtyIcon(cat),
                      size: 32,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _categoryLabel(cat),
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchSuggestionsDropdown(ColorScheme colorScheme) {
    if (!_showSuggestions || _searchController.text.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        // Transparent Material so ListTile ink shows above the white card.
        child: Material(
          color: Colors.transparent,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Symptom match banner — rule-based or AI suggestion
            if (_symptomMatch != null) ...[
              InkWell(
                onTap: () {
                  final specialty = _symptomMatch!.topSpecialty!;
                  setState(() {
                    _showSuggestions = false;
                    _symptomMatch = null;
                    _searchController.clear();
                  });
                  _searchFocusNode.unfocus();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DoctorsScreen(initialQuery: specialty),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.35),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 16, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            style: const TextStyle(fontSize: 13),
                            children: [
                              const TextSpan(text: 'Sounds like you need a '),
                              TextSpan(
                                text: _symptomMatch!.topSpecialty,
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const TextSpan(text: ' · Tap to find doctors →'),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
            ] else if (_isAiSuggestingSpecialty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Checking symptoms with AI…',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
            if (_isSearchingSuggestions)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_specialitySuggestions.isEmpty &&
                _doctorSuggestions.isEmpty &&
                _symptomMatch == null)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.search_off, size: 18, color: Colors.grey[400]),
                    const SizedBox(width: 8),
                    Text(
                      'No matching doctors or specialties',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ],
                ),
              )
            else if (!_isSearchingSuggestions) ...[
              for (final spec in _specialitySuggestions)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.medical_services_outlined,
                      color: colorScheme.primary, size: 20),
                  title: Text(
                    spec,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  trailing: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color:
                          colorScheme.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Specialty',
                      style: TextStyle(
                          fontSize: 10,
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  onTap: () {
                    setState(() {
                      _showSuggestions = false;
                      _searchController.clear();
                    });
                    _searchFocusNode.unfocus();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DoctorsScreen(initialQuery: spec),
                      ),
                    );
                  },
                ),
              for (final doc in _doctorSuggestions)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: colorScheme.primaryContainer,
                    child: Text(
                      doc.name.isNotEmpty ? doc.name[0].toUpperCase() : '?',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onPrimaryContainer),
                    ),
                  ),
                  title: Text(
                    doc.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    doc.specialities.join(', '),
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      size: 18, color: Colors.grey),
                  onTap: () {
                    setState(() {
                      _showSuggestions = false;
                      _searchController.clear();
                    });
                    _searchFocusNode.unfocus();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DoctorDetailScreen(doctorId: doc.id),
                      ),
                    );
                  },
                ),
            ],
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeelingSection(BuildContext context, ColorScheme colorScheme) {
    if (_isMoodSubmittedToday && !_isMoodExpanded) {
      // Today's mood is logged, but user can tap the card or "Change" anytime to update it!
      return Card(
        elevation: 0.6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            setState(() {
              _isMoodExpanded = true;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Text(_moodEmoji(_todayFeeling),
                          style: const TextStyle(fontSize: 22)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "Today's feeling: ${_moodLabel(_todayFeeling)}",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13.5),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Tap to change',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('Change', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() {
                      _isMoodExpanded = true;
                    });
                  },
                ),
                const SizedBox(width: 4),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const HealthCalendarScreen()),
                    );
                  },
                  child: const Text('Calendar', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_isMoodExpanded) {
      // Single line by default
      return Card(
        elevation: 0.8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            setState(() {
              _isMoodExpanded = true;
            });
          },
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.sentiment_satisfied_alt_outlined,
                        color: colorScheme.primary, size: 20),
                    const SizedBox(width: 10),
                    const Text(
                      'How are you feeling today? 🙂',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ],
                ),
                Icon(Icons.expand_more, color: Colors.grey[600], size: 20),
              ],
            ),
          ),
        ),
      );
    }

    // Expanded view with emoji picker
    return Card(
      elevation: 0.8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.calendar_month_outlined,
                          color: colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'How are you feeling today?',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const HealthCalendarScreen()),
                        );
                      },
                      child: const Text('Calendar',
                          style: TextStyle(fontSize: 12)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.expand_less, size: 18),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 28, height: 28),
                      onPressed: () {
                        setState(() {
                          _isMoodExpanded = false;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F8E9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.spa_outlined, color: Color(0xFF33691E), size: 16),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Be grateful for your health today • Keep your daily wellness streak',
                      style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF33691E),
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _moodButton('great', '🌟', 'Great', colorScheme),
                _moodButton('good', '😊', 'Good', colorScheme),
                _moodButton('okay', '😐', 'Okay', colorScheme),
                _moodButton('low', '😔', 'Low', colorScheme),
                _moodButton('unwell', '🤒', 'Unwell', colorScheme),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _moodButton(
      String key, String emoji, String label, ColorScheme colorScheme) {
    final isSelected = _todayFeeling == key;
    Color? borderColor = Colors.transparent;
    Color? bgColor = Colors.transparent;
    Color? textColor = Colors.grey[700];

    if (isSelected) {
      if (key == 'good' || key == 'great') {
        borderColor = const Color(0xFF2E7D32);
        bgColor = const Color(0xFFE8F5E9);
        textColor = const Color(0xFF2E7D32);
      } else if (key == 'okay') {
        borderColor = const Color(0xFFF9A825);
        bgColor = const Color(0xFFFFFDE7);
        textColor = const Color(0xFFF57F17);
      } else if (key == 'low') {
        borderColor = const Color(0xFF7E57C2);
        bgColor = const Color(0xFFEDE7F6);
        textColor = const Color(0xFF5E35B1);
      } else if (key == 'unwell') {
        borderColor = const Color(0xFFC62828);
        bgColor = const Color(0xFFFFEBEE);
        textColor = const Color(0xFFC62828);
      }
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _onFeelingSelected(key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: borderColor,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onFeelingSelected(String key) {
    setState(() {
      _todayFeeling = key;
      _isMoodSubmittedToday = true;
      _isMoodExpanded = false;
    });

    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('mood_$_todayDateKey', key);
    });

    ApiService.logFeeling(feeling: key);

    if (key == 'good' || key == 'great') {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle, color: Color(0xFF81C784), size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text('Today marked green on your Health Calendar! 🟢'),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Calendar',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HealthCalendarScreen()),
              );
            },
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    } else if (key == 'okay') {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.circle, color: Color(0xFFFBC02D), size: 14),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Today marked yellow on your Health Calendar! 🟡 Steady and balanced.'),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Calendar',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HealthCalendarScreen()),
              );
            },
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    } else if (key == 'low') {
      _showPsychiatristPrompt();
    } else if (key == 'unwell') {
      _showGeneralDoctorPrompt();
    }
  }

  void _showPsychiatristPrompt() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: Color(0xFFEDE7F6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.psychology_outlined,
                        color: Color(0xFF5E35B1), size: 28),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'Feeling low or overwhelmed?',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Mental health is just as important as physical health. Would you like to speak to a licensed Psychiatrist or specialist?',
                style: TextStyle(
                    color: Colors.grey[700], fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Marked on your Health Calendar. Be kind to yourself today.'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
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
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _showGeneralDoctorPrompt() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFEBEE),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.local_hospital_outlined,
                        color: Color(0xFFC62828), size: 28),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'Feeling unwell today?',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'We noticed you are feeling unwell. Would you like to consult a General Physician (GD) or Medicine doctor?',
                style: TextStyle(
                    color: Colors.grey[700], fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Marked on your Health Calendar. Rest well and stay hydrated!'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                const DoctorsScreen(initialQuery: 'Medicine'),
                          ),
                        );
                      },
                      icon:
                          const Icon(Icons.medical_services_outlined, size: 18),
                      label: const Text('See General Doctor'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF3B6FA0),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DoctorListCard extends StatelessWidget {
  final Doctor doctor;
  final bool isPinnedOwn;

  const _DoctorListCard({required this.doctor, this.isPinnedOwn = false});


  @override
  Widget build(BuildContext context) {
    final spec = doctor.specialities.isNotEmpty ? doctor.specialities.first : 'Specialist';
    final hospital = doctor.chamber?.hospitalName;
    final specHospital = (hospital != null && hospital.trim().isNotEmpty)
        ? '$spec | $hospital'
        : spec;

    final hasReviews = doctor.ratingCount > 0;
    final ratingValue = doctor.bayesianRating?.toStringAsFixed(1) ?? 'N/A';
    final ratingText = hasReviews
        ? '$ratingValue (${doctor.ratingCount} Reviews)'
        : 'No reviews yet';

    return Container(
      margin: const EdgeInsets.only(bottom: AppConstants.cardGap),
      decoration: BoxDecoration(
        color: isPinnedOwn
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(AppConstants.radiusCard),
        border: isPinnedOwn
            ? Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4))
            : null,
        boxShadow: AppConstants.softShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppConstants.radiusCard),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DoctorDetailScreen(doctorId: doctor.id),
              ),
            );
          },
          child: Padding(padding: const EdgeInsets.all(14.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left circular avatar 56
                // Claimed doctors show their account photo; never the
                // BMDC certificate upload.
                UserAvatar(
                  uid: doctor.claimedByUid,
                  name: doctor.name,
                  radius: 28,
                ),
                const SizedBox(width: 14),
                // Details column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              doctor.name,
                              style: AppTheme.cardTitle.copyWith(
                                color: const Color(0xFF0F172A),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isPinnedOwn) ...[
                            Container(
                              margin: const EdgeInsets.only(left: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Your profile',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle, size: 12, color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 2),
                                const Text(
                                  'Claimed',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ],
                            ),
                          ] else if (doctor.claimedByUid != null && doctor.claimedByUid!.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.check, size: 10, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 2),
                                  const Text(
                                    'Claimed',
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (doctor.verificationStatus == 'checked_found' || doctor.verificationStatus == 'verified') ...[
                            const SizedBox(width: 4),
                            Icon(Icons.verified, color: Theme.of(context).colorScheme.primary, size: 16),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        specHospital,
                        style: AppTheme.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${doctor.experienceYears.toStringAsFixed(0)} years of experience',
                        style: AppTheme.caption,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.star,
                            size: 16,
                            color: hasReviews ? AppColors.star : AppColors.textTertiary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            ratingText,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: hasReviews ? FontWeight.w600 : FontWeight.w400,
                              color: hasReviews ? AppColors.textPrimary : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Green accessibility icon on right for accessible chambers
                if (doctor.hasAccessibleChamber) ...[
                  const SizedBox(width: 8),
                  const AccessibilityIcon(isAccessible: true),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
