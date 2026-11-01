import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/doctor.dart';
import '../services/api_service.dart';
import '../services/location_search_service.dart';
import 'doctor_detail_screen.dart';
import '../widgets/chamber_accessibility.dart';

class NearbyDoctorsScreen extends StatefulWidget {
  final String? initialSpeciality;

  const NearbyDoctorsScreen({super.key, this.initialSpeciality});

  @override
  State<NearbyDoctorsScreen> createState() => _NearbyDoctorsScreenState();
}

class _NearbyDoctorsScreenState extends State<NearbyDoctorsScreen> {
  final TextEditingController _addressController = TextEditingController();
  Timer? _suggestionDebounce;

  static const List<Map<String, dynamic>> availableDoctorLocations = [
    {'name': 'Mirpur', 'label': 'Mirpur, Dhaka', 'lat': 23.8223, 'lng': 90.3654, 'filter': 'Mirpur'},
    {'name': 'Dhanmondi', 'label': 'Dhanmondi, Dhaka', 'lat': 23.7465, 'lng': 90.3760, 'filter': 'Dhanmondi'},
    {'name': 'Uttara', 'label': 'Uttara, Dhaka', 'lat': 23.8759, 'lng': 90.3795, 'filter': 'Uttara'},
    {'name': 'Kalyanpur', 'label': 'Kalyanpur, Dhaka', 'lat': 23.7788, 'lng': 90.3582, 'filter': 'Kallyanpur'},
    {'name': 'Banasree', 'label': 'Banasree, Dhaka', 'lat': 23.7632, 'lng': 90.4379, 'filter': 'Banasree'},
    {'name': 'Motijheel', 'label': 'Motijheel, Dhaka', 'lat': 23.7333, 'lng': 90.4176, 'filter': 'Motijheel'},
    {'name': 'Mohammadpur', 'label': 'Mohammadpur, Dhaka', 'lat': 23.7679, 'lng': 90.3585, 'filter': 'Mohammadpur'},
  ];

  List<Doctor> _doctors = [];
  List<Map<String, dynamic>> _suggestions = [];
  bool _isLoading = false;
  bool _isSearchingSuggestions = false;
  String? _suggestionError;
  String? _error;
  String? _locationLabel;
  String? _selectedAreaFilter;
  bool _showManualInput = false;
  double? _lat;
  double? _lng;
  bool _accessibleOnly = false;

  @override
  void initState() {
    super.initState();
    _loadSavedArea();
    unawaited(_prepareLocationSearch());
  }

  Future<void> _prepareLocationSearch() async {
    try {
      await LocationSearchService.initialize();
      final query = _addressController.text.trim();
      if (mounted && query.length >= 2) {
        final local = await LocationSearchService.localSuggestions(query);
        setState(() {
          _suggestions = _mergeResolvedSuggestions(local, const []);
        });
      }
    } catch (error, stackTrace) {
      debugPrint('Location suggestion preload failed: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _suggestionError =
              "Couldn't load suggestions. Check your connection and try again.";
        });
      }
    }
  }

  /// The first-time check-in already asks the user to pick a Dhaka area.
  /// Reuse it here instead of making an emulator GPS fix a hard requirement.
  Future<void> _loadSavedArea() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble('user_location_lat');
    final lng = prefs.getDouble('user_location_lng');
    final area = prefs.getString('user_location_area');

    if (!mounted) return;
    if (lat != null && lng != null) {
      String? matchedFilter;
      if (area != null) {
        for (final loc in availableDoctorLocations) {
          if (area.toLowerCase().contains((loc['name'] as String).toLowerCase())) {
            matchedFilter = loc['filter'] as String;
            break;
          }
        }
      }
      setState(() {
        _lat = lat;
        _lng = lng;
        _locationLabel =
            area == null || area.isEmpty ? 'Saved area' : '$area, Dhaka';
        _selectedAreaFilter = matchedFilter;
      });
      await _searchNearby();
      return;
    }

    // Default to Mirpur if no location is saved yet
    final defaultLoc = availableDoctorLocations.first;
    _selectAvailableLocation(defaultLoc);
  }

  Future<void> _selectAvailableLocation(Map<String, dynamic> loc) async {
    setState(() {
      _lat = loc['lat'] as double;
      _lng = loc['lng'] as double;
      _locationLabel = loc['label'] as String;
      _selectedAreaFilter = loc['filter'] as String;
      _showManualInput = false;
      _addressController.clear();
      _suggestions = [];
    });
    await _persistLocation(label: _locationLabel!, lat: _lat!, lng: _lng!);
    await _searchNearby();
  }

  Future<void> _requestLocationAndSearch() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _isLoading = false;
          _showManualInput = true;
          _error =
              'Location services are disabled. Please enter your address manually.';
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _isLoading = false;
          _showManualInput = true;
          _error =
              'Location permission is permanently denied. Choose an area below or enable it in Android settings.';
        });
        return;
      }
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _isLoading = false;
            _showManualInput = true;
            _error =
                'Location permission denied. Please enter your address manually.';
          });
          return;
        }
      }

      // Emulators frequently have a permission grant but no fresh GPS fix.
      // Reuse the last Android location while waiting for a new one so a
      // granted permission can still produce a useful nearby search.
      Position? lastKnownPosition = await Geolocator.getLastKnownPosition();
      Position position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 20),
          ),
        );
      } catch (_) {
        if (lastKnownPosition == null) rethrow;
        position = lastKnownPosition;
      }

      if (position.latitude == 0 && position.longitude == 0) {
        throw StateError('Device returned an invalid location.');
      }

      _lat = position.latitude;
      _lng = position.longitude;
      _locationLabel = 'Your current location';
      _showManualInput = false;
      await _persistLocation(
        label: _locationLabel!,
        lat: _lat!,
        lng: _lng!,
      );
      await _searchNearby();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _showManualInput = true;
        _error = 'Unable to get location. Please enter your address manually.';
      });
    }
  }

  Future<void> _searchNearby() async {
    if (_lat == null || _lng == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final doctors = await ApiService.fetchNearbyDoctors(
        lat: _lat!,
        lng: _lng!,
        radiusKm: 6,
        speciality: widget.initialSpeciality,
        areaFilter: _selectedAreaFilter,
      );

      setState(() {
        _doctors = doctors;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _searchAddress(String query) async {
    if (query.trim().length < 2) return;

    setState(() {
      _isSearchingSuggestions = true;
      _suggestionError = null;
    });

    final localFuture = LocationSearchService.localSuggestions(query);
    final photonFuture = LocationSearchService.photonSuggestions(query);
    List<Map<String, dynamic>> photonResults = const [];
    List<Map<String, dynamic>> localResults = const [];
    Object? suggestionError;
    try {
      localResults = await localFuture;
    } catch (error, stackTrace) {
      debugPrint('Local location suggestions failed: $error\\n$stackTrace');
      suggestionError = error;
    }
    try {
      photonResults = await photonFuture;
    } catch (error, stackTrace) {
      debugPrint('Photon location suggestions failed: $error\\n$stackTrace');
      suggestionError ??= error;
    }

    var results = _mergeResolvedSuggestions(localResults, photonResults);
    if (results.isEmpty && LocationSearchService.looksLikeExactAddress(query)) {
      try {
        results = _mergeResolvedSuggestions(
          localResults,
          await LocationSearchService.nominatimExactAddress(query),
        );
      } catch (error, stackTrace) {
        debugPrint(
            'Nominatim exact-address fallback failed: $error\\n$stackTrace');
        suggestionError ??= error;
      }
    }
    if (!mounted || _addressController.text.trim() != query.trim()) return;
    setState(() {
      _suggestions = results;
      _isSearchingSuggestions = false;
      _suggestionError = suggestionError == null
          ? null
          : "Couldn't load suggestions. Check your connection and try again.";
    });
  }

  List<Map<String, dynamic>> _mergeResolvedSuggestions(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
  ) {
    final results = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final result in [...local, ...remote]) {
      final key = (result['name'] ?? result['displayName'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (key.isNotEmpty && seen.add(key)) results.add(result);
    }
    return results;
  }

  Future<void> _applyLocalSuggestions(String query) async {
    try {
      final local = await LocationSearchService.localSuggestions(query);
      if (!mounted || _addressController.text.trim() != query.trim()) return;
      setState(() {
        _suggestions = _mergeResolvedSuggestions(local, const []);
      });
    } catch (error, stackTrace) {
      debugPrint('Local location suggestions failed: $error\\n$stackTrace');
      if (mounted) {
        setState(() {
          _suggestionError =
              "Couldn't load suggestions. Check your connection and try again.";
        });
      }
    }
  }

  Future<void> _selectSuggestion(Map<String, dynamic> suggestion) async {
    final lat = suggestion['lat'] as num?;
    final lng = suggestion['lng'] as num?;
    if (lat == null || lng == null) return;
    final label = (suggestion['displayName'] ?? 'Selected area').toString();

    String? matchedFilter;
    for (final loc in availableDoctorLocations) {
      if (label.toLowerCase().contains((loc['name'] as String).toLowerCase())) {
        matchedFilter = loc['filter'] as String;
        break;
      }
    }

    setState(() {
      _lat = lat.toDouble();
      _lng = lng.toDouble();
      _locationLabel = label;
      _selectedAreaFilter = matchedFilter;
      _suggestions = [];
      _addressController.clear();
      _showManualInput = false;
    });
    await _persistLocation(label: label, lat: _lat!, lng: _lng!);
    await _searchNearby();
  }

  Future<void> _persistLocation({
    required String label,
    required double lat,
    required double lng,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_location_area', label);
    await prefs.setDouble('user_location_lat', lat);
    await prefs.setDouble('user_location_lng', lng);
  }

  void _onAddressChanged(String value) {
    _suggestionDebounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _suggestions = [];
        _isSearchingSuggestions = false;
        _suggestionError = null;
      });
      return;
    }

    // Local Dhaka/chamber matches appear while Photon is still debouncing.
    setState(() {
      _suggestionError = null;
      _isSearchingSuggestions = true;
    });
    unawaited(_applyLocalSuggestions(query));
    _suggestionDebounce = Timer(const Duration(milliseconds: 300), () {
      _searchAddress(query);
    });
  }

  String? _formatDistance(double? km) {
    if (km == null) return null;
    // Bundled chambers are geocoded to area centres, so a chamber in the
    // searched area lands exactly on it; "0 m away" would be misleading.
    if (km < 0.05) return 'In your area';
    if (km < 1.0) {
      return '${(km * 1000).round()} m away';
    }
    return '${km.toStringAsFixed(1)} km away';
  }

  Future<void> _showLocationPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Change location', style: TextStyle(fontWeight: FontWeight.w700))),
            ...availableDoctorLocations.map(
              (location) => ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(location['label'] as String),
                onTap: () async {
                  Navigator.pop(context);
                  await _selectAvailableLocation(location);
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.my_location_outlined),
              title: const Text('Use device location'),
              onTap: () async {
                Navigator.pop(context);
                await _requestLocationAndSearch();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Doctors Near Me'),
      ),
      body: Column(
        children: [
          // One persisted location row; locations are selected from Change.
          Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: colorScheme.primaryContainer.withValues(alpha: 0.3),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _locationLabel ?? 'Mirpur, Dhaka',
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _showLocationPicker,
                    child: const Text('Change', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),

          // Filter row
          if (_doctors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  FilterChip(
                    avatar: const Icon(Icons.accessible, size: 16, color: Color(0xFF2E7D32)),
                    label: const Text('Accessible only'),
                    selected: _accessibleOnly,
                    onSelected: (val) {
                      setState(() {
                        _accessibleOnly = val;
                      });
                    },
                  ),
                ],
              ),
            ),

          // Manual address input
          if (_showManualInput || _error != null && _doctors.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null && _doctors.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
                    ),
                  TextField(
                    controller: _addressController,
                    decoration: InputDecoration(
                      hintText: 'Enter area or address...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _isSearchingSuggestions
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                    ),
                    onChanged: _onAddressChanged,
                    onSubmitted: _searchAddress,
                    textInputAction: TextInputAction.search,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: availableDoctorLocations.map((location) {
                      return ActionChip(
                        avatar:
                            const Icon(Icons.location_on_outlined, size: 16),
                        label: Text(location['name'] as String),
                        onPressed: () => _selectAvailableLocation(location),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _isLoading ? null : _requestLocationAndSearch,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('Use device location'),
                  ),
                  // Suggestions
                  if (_suggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: Column(
                        children: _suggestions.map((suggestion) {
                          return ListTile(
                            dense: true,
                            leading: Icon(Icons.place_outlined,
                                color: colorScheme.primary, size: 20),
                            title: Text(
                              suggestion['displayName'] ?? '',
                              style: const TextStyle(fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectSuggestion(suggestion),
                          );
                        }).toList(),
                        ),
                      ),
                    ),
                  if (_suggestionError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _suggestionError!,
                        style:
                            TextStyle(color: Colors.red.shade700, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),

          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _doctors.isEmpty && !_showManualInput
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.location_off_outlined,
                                  size: 48, color: Colors.grey[400]),
                              const SizedBox(height: 16),
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style:
                                      TextStyle(color: Colors.grey[600])),
                              const SizedBox(height: 16),
                              FilledButton.tonal(
                                onPressed: _requestLocationAndSearch,
                                child: const Text('Try Again'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _doctors.isEmpty && !_showManualInput && _lat != null
                        ? Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.location_city_outlined,
                                      size: 56, color: Colors.grey.shade400),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No doctors found in ${_locationLabel ?? "this area"}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'We do not have listed doctor chambers in this specific area yet.\nPlease select one of the available locations:',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                                  ),
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.center,
                                    children: availableDoctorLocations.map((loc) {
                                      return ActionChip(
                                        avatar: const Icon(Icons.place, size: 14),
                                        label: Text(loc['name'] as String),
                                        onPressed: () => _selectAvailableLocation(loc),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : _doctors.isNotEmpty
                            ? _buildDoctorList()
                            : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _suggestionDebounce?.cancel();
    _addressController.dispose();
    super.dispose();
  }

  Widget _buildDoctorList() {
    final displayDoctors = _accessibleOnly
        ? _doctors.where((d) => d.hasAccessibleChamber).toList()
        : _doctors;

    if (displayDoctors.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_off, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'No accessible doctors found nearby',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'Try turning off the accessible filter or searching another area.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: displayDoctors.length,
      itemBuilder: (context, index) {
        final doctor = displayDoctors[index];
        return _NearbyDoctorCard(
          doctor: doctor,
          distance: (doctor.chamber?.lat != null && doctor.chamber?.lng != null) ||
                  doctor.chambers.any((chamber) => chamber.lat != null && chamber.lng != null)
              ? _formatDistance(doctor.distance)
              : null,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DoctorDetailScreen(doctorId: doctor.id),
              ),
            );
          },
        );
      },
    );
  }
}

class _NearbyDoctorCard extends StatelessWidget {
  final Doctor doctor;
  final String? distance;
  final VoidCallback onTap;

  const _NearbyDoctorCard({
    required this.doctor,
    required this.distance,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final initial = doctor.name.isNotEmpty ? doctor.name[0].toUpperCase() : '?';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: colorScheme.primaryContainer,
                child: Text(
                  initial,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doctor.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      doctor.specialities.isNotEmpty
                          ? doctor.specialities.join(', ')
                          : 'General',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                    if (distance != null && distance!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.near_me_outlined,
                              size: 14, color: colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            distance!,
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (doctor.hasAccessibleChamber) ...[
                            const SizedBox(width: 8),
                            const AccessibilityIcon(
                              isAccessible: true,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}
