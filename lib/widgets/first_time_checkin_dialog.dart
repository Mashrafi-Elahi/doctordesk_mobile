import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import '../services/device_location.dart';
import '../services/api_service.dart';
import '../services/dhaka_locations.dart';

/// Shows a first-time check-in dialog prompting the user for:
/// 1. Location / Area
/// 2. Current Mood
Future<void> showFirstTimeCheckinDialog(
  BuildContext context, {
  bool force = false,
  VoidCallback? onComplete,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final alreadyDone =
      prefs.getBool('has_completed_first_time_checkin') ?? false;
  if (alreadyDone && !force) {
    onComplete?.call();
    return;
  }

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _FirstTimeCheckinContent(
      onComplete: onComplete,
    ),
  );
}

class _FirstTimeCheckinContent extends StatefulWidget {
  final VoidCallback? onComplete;

  const _FirstTimeCheckinContent({this.onComplete});

  @override
  State<_FirstTimeCheckinContent> createState() =>
      _FirstTimeCheckinContentState();
}

class _FirstTimeCheckinContentState extends State<_FirstTimeCheckinContent> {
  String? _selectedArea = 'Dhanmondi';
  double? _selectedLat = 23.7465;
  double? _selectedLng = 90.3760;
  String? _selectedMood = 'good';
  bool _detectingGps = false;
  String? _gpsMessage;

  final List<Map<String, dynamic>> _areas = DhakaLocations.all
      .map((location) => {
            'name': location.name,
            'lat': location.lat,
            'lng': location.lng,
          })
      .toList();

  final List<Map<String, String>> _moods = [
    {'key': 'great', 'emoji': '🌟', 'label': 'Great'},
    {'key': 'good', 'emoji': '😊', 'label': 'Good'},
    {'key': 'okay', 'emoji': '😐', 'label': 'Okay'},
    {'key': 'low', 'emoji': '😔', 'label': 'Low'},
    {'key': 'unwell', 'emoji': '🤒', 'label': 'Unwell'},
  ];

  Future<void> _detectGpsLocation() async {
    setState(() {
      _detectingGps = true;
      _gpsMessage = null;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _detectingGps = false;
          _gpsMessage = 'Location services are disabled.';
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _detectingGps = false;
            _gpsMessage = 'Location permission was denied.';
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _detectingGps = false;
          _gpsMessage = 'Location permission is permanently denied.';
        });
        return;
      }

      final pos = await DeviceLocation.current();

      setState(() {
        _selectedArea = 'Your current location';
        _selectedLat = pos.latitude;
        _selectedLng = pos.longitude;
        _detectingGps = false;
        _gpsMessage = 'Location detected successfully!';
      });
    } catch (e) {
      setState(() {
        _detectingGps = false;
        _gpsMessage = e is DeviceLocationException ? e.message : 'Could not detect GPS location.';
      });
    }
  }

  Future<void> _saveAndFinish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_completed_first_time_checkin', true);

    if (_selectedArea != null) {
      await prefs.setString('user_location_area', _selectedArea!);
      if (_selectedLat != null && _selectedLng != null) {
        await prefs.setDouble('user_location_lat', _selectedLat!);
        await prefs.setDouble('user_location_lng', _selectedLng!);
      }
    }

    if (_selectedMood != null) {
      final now = DateTime.now();
      final dateKey = '${now.year}-${now.month}-${now.day}';
      await prefs.setString('mood_$dateKey', _selectedMood!);
      ApiService.logFeeling(feeling: _selectedMood!);
    }

    if (mounted) Navigator.pop(context);
    widget.onComplete?.call();
  }

  Future<void> _skip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_completed_first_time_checkin', true);
    if (mounted) Navigator.pop(context);
    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.health_and_safety_outlined,
                          color: colorScheme.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Welcome Check-in',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Personalize your care experience by picking your area and checking in on your mood today.',
                style: TextStyle(
                    color: Colors.grey[600], fontSize: 13, height: 1.3),
              ),
              const SizedBox(height: 16),

              // Section 1: Location
              const Text(
                '1. Select Your Area',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _areas.map((a) {
                  final isSelected = _selectedArea == a['name'];
                  return ChoiceChip(
                    label: Text(a['name'] as String),
                    selected: isSelected,
                    onSelected: (sel) {
                      if (sel) {
                        setState(() {
                          _selectedArea = a['name'] as String;
                          _selectedLat = a['lat'] as double;
                          _selectedLng = a['lng'] as double;
                          _gpsMessage = null;
                        });
                      }
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: _detectingGps
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location, size: 16),
                label: Text(_detectingGps
                    ? 'Detecting GPS...'
                    : 'Use Current GPS Location'),
                onPressed: _detectingGps ? null : _detectGpsLocation,
              ),
              if (_gpsMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  _gpsMessage!,
                  style: TextStyle(
                    fontSize: 11,
                    color: _gpsMessage!.contains('successfully')
                        ? Colors.green
                        : Colors.red,
                  ),
                ),
              ],
              const SizedBox(height: 18),

              // Section 2: Mood
              const Text(
                '2. How Are You Feeling Today?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: _moods.map((m) {
                  final isSelected = _selectedMood == m['key'];
                  return GestureDetector(
                    onTap: () => setState(() => _selectedMood = m['key']),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colorScheme.primaryContainer
                                .withValues(alpha: 0.6)
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? colorScheme.primary
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(m['emoji']!,
                              style: const TextStyle(fontSize: 24)),
                          const SizedBox(height: 4),
                          Text(
                            m['label']!,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? colorScheme.primary
                                  : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 22),

              // Action Buttons
              FilledButton(
                onPressed: _saveAndFinish,
                child: const Text('Save & Get Started'),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: _skip,
                child: Text(
                  'Skip for now',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
