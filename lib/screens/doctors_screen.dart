import 'package:flutter/material.dart';
import 'dart:async';
import '../models/doctor.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'doctor_detail_screen.dart';
import '../widgets/user_avatar.dart';
import '../widgets/chamber_accessibility.dart';

class DoctorsScreen extends StatefulWidget {
  final String? initialQuery;

  const DoctorsScreen({super.key, this.initialQuery});

  @override
  State<DoctorsScreen> createState() => _DoctorsScreenState();
}

class _DoctorsScreenState extends State<DoctorsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _debounce;

  List<Doctor> _doctors = [];
  List<String> _specialities = ['All'];
  String _selectedSpeciality = 'All';
  bool _accessibleOnly = false;

  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isOffline = false;
  String? _error;

  int _currentPage = 1;
  int _totalPages = 1;
  final int _limit = 20;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null) {
      _searchController.text = widget.initialQuery!;
    }
    _fetchSpecialities();
    _fetchDoctors();

    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _currentPage = 1;
      _fetchDoctors();
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _currentPage < _totalPages) {
        _currentPage++;
        _fetchDoctors(loadMore: true);
      }
    }
  }

  Future<void> _fetchSpecialities() async {
    try {
      final specs = await ApiService.fetchSpecialities();
      final matchingSpeciality = widget.initialQuery == null
          ? null
          : specs
              .map((spec) => spec['speciality']?.toString() ?? '')
              .cast<String?>()
              .firstWhere(
                (spec) =>
                    spec != null &&
                    spec.toLowerCase() == widget.initialQuery!.toLowerCase(),
                orElse: () => null,
              );
      if (!mounted) return;
      setState(() {
        _specialities = ['All', ...specs.map((s) => s['speciality'] as String)];
        if (matchingSpeciality != null) {
          _selectedSpeciality = matchingSpeciality;
          _searchController.clear();
        }
      });
      if (matchingSpeciality != null) {
        _currentPage = 1;
        _fetchDoctors();
      }
    } catch (e) {
      // Handle silently for now
    }
  }

  Future<void> _fetchDoctors({bool loadMore = false}) async {
    if (loadMore) {
      setState(() {
        _isLoadingMore = true;
      });
    } else {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final data = await ApiService.fetchDoctors(
        page: _currentPage,
        limit: _limit,
        search: _searchController.text,
        speciality: _selectedSpeciality == 'All' ? null : _selectedSpeciality,
      );

      final isOff = data['isOffline'] == true;
      setState(() {
        if (loadMore) {
          _doctors.addAll(List<Doctor>.from(data['doctors']));
        } else {
          _doctors = List<Doctor>.from(data['doctors']);
        }
        _totalPages = (data['totalPages'] as int?) ?? 1;
        _isOffline = isOff;
        _isLoading = false;
        _isLoadingMore = false;
      });
    } catch (e) {
      setState(() {
        _error =
            'No Internet Connection\nPlease check your network connection and try again.';
        _isLoading = false;
        _isLoadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find Doctors'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search by name or keyword...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    avatar: const Icon(Icons.accessible, size: 16, color: Color(0xFF2E7D32)),
                    label: const Text('Accessible only'),
                    selected: _accessibleOnly,
                    onSelected: (selected) {
                      setState(() {
                        _accessibleOnly = selected;
                      });
                    },
                  ),
                ),
                ..._specialities.map((spec) {
                  final isSelected = _selectedSpeciality == spec;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: ChoiceChip(
                      label: Text(spec),
                      selected: isSelected,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedSpeciality = spec;
                            _currentPage = 1;
                          });
                          _fetchDoctors();
                        }
                      },
                    ),
                  );
                }),
              ],
            ),
          ),
          Expanded(
            child: _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_off_rounded,
                  size: 52, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 14),
              Text(
                'No Internet Connection',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Please check your network connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () {
                  _currentPage = 1;
                  _fetchDoctors();
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final displayDoctors = _accessibleOnly
        ? _doctors.where((d) => d.hasAccessibleChamber).toList()
        : _doctors;

    if (displayDoctors.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _accessibleOnly ? 'No accessible doctors found' : 'No doctors found',
              style: TextStyle(color: Colors.grey[600], fontSize: 18),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_isOffline)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded,
                    size: 18, color: Colors.amber.shade900),
                const SizedBox(width: 8),
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
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16.0),
            itemCount: displayDoctors.length + (_isLoadingMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == displayDoctors.length) {
                return const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final doctor = displayDoctors[index];
              final ownId = AuthService.userRoles.doctorProfileId;
              final isPinnedOwn = ownId != null && ownId.isNotEmpty && ownId == doctor.id;
              return _DoctorListCard(doctor: doctor, isPinnedOwn: isPinnedOwn);
            },
          ),
        ),
      ],
    );
  }
}

class _DoctorListCard extends StatelessWidget {
  final Doctor doctor;
  final bool isPinnedOwn;

  const _DoctorListCard({required this.doctor, this.isPinnedOwn = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      color: isPinnedOwn ? colorScheme.primary.withValues(alpha: 0.10) : null,
      shape: isPinnedOwn
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.4), width: 1.5),
            )
          : null,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => DoctorDetailScreen(doctorId: doctor.id)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(
                uid: doctor.claimedByUid,
                name: doctor.name,
                radius: 30,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            doctor.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: Color(0xFF0F172A)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isPinnedOwn) ...[
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Your profile',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle, size: 12, color: Colors.blue),
                              SizedBox(width: 2),
                              Text(
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
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check, size: 10, color: Colors.blue),
                                SizedBox(width: 2),
                                Text(
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
                        if (doctor.verificationStatus == 'checked_found' || doctor.verificationStatus == 'verified')
                          const Padding(
                            padding: EdgeInsets.only(left: 4.0),
                            child: Icon(Icons.verified,
                                color: Colors.blue, size: 16),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      doctor.specialities.join(', '),
                      style: TextStyle(color: Colors.grey[700], fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${doctor.experienceYears.toStringAsFixed(0)} years experience',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                    if (doctor.chamber?.hospitalName != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.local_hospital_outlined,
                              size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              doctor.chamber!.hospitalName!,
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (doctor.hasAccessibleChamber) ...[
                            const SizedBox(width: 6),
                            const AccessibilityIcon(isAccessible: true),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.star,
                            size: 16,
                            color: doctor.ratingCount > 0
                                ? Colors.amber
                                : Colors.grey[400]),
                        const SizedBox(width: 4),
                        Text(
                          doctor.ratingCount > 0
                              ? (doctor.bayesianRating?.toStringAsFixed(1) ??
                                  'N/A')
                              : 'Not rated yet',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: doctor.ratingCount > 0
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: doctor.ratingCount > 0
                                ? Colors.black87
                                : Colors.grey[500],
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
