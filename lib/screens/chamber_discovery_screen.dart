import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../theme/app_constants.dart';
import '../widgets/chamber_accessibility.dart';

/// Chamber Discovery Screen:
/// Lets users browse listed clinic & hospital chambers across doctors and apply
/// directly to become a Desk Operator. When the doctor agrees/approves, the user
/// is granted the Desk Operator role.
class ChamberDiscoveryScreen extends StatefulWidget {
  const ChamberDiscoveryScreen({super.key});

  @override
  State<ChamberDiscoveryScreen> createState() => _ChamberDiscoveryScreenState();
}

class _ChamberDiscoveryScreenState extends State<ChamberDiscoveryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _chambers = [];
  bool _isLoading = true;
  String _selectedArea = 'All';

  final List<String> _availableAreas = [
    'All',
    'Mirpur',
    'Dhanmondi',
    'Uttara',
    'Motijheel',
    'Banasree',
    'Mohammadpur',
    'Gulshan',
  ];

  @override
  void initState() {
    super.initState();
    _loadChambers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadChambers() async {
    setState(() => _isLoading = true);
    try {
      final list = await FirestoreService.fetchChambersDirectory(
        areaFilter: _selectedArea == 'All' ? null : _selectedArea,
      );
      if (mounted) {
        setState(() {
          _chambers = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showApplyDialog(Map<String, dynamic> chamber) {
    final user = AuthService.currentUser;
    if (user == null || AuthService.isGuest) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please log in with an account to apply as a Desk Operator.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final phoneCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.badge_outlined, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Apply as Desk Operator',
                    style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chamber['name'] ?? 'Chamber',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        Text(
                          'Doctor: ${chamber['doctorName']} (${chamber['doctorSpecialty']})',
                          style: const TextStyle(fontSize: 12, color: Colors.black87),
                        ),
                        Text(
                          'Location: ${chamber['area']}',
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'When Dr. ${chamber["doctorName"]} agrees and approves your application, you will automatically receive the Desk Operator portal.',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Contact Phone Number',
                      hintText: 'e.g. 017XXXXXXXX',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Experience / Availability Note',
                      hintText: 'e.g. Available daily 5pm-9pm to manage token queue',
                      border: OutlineInputBorder(),
                      isDense: true,
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
                onPressed: isSubmitting
                    ? null
                    : () async {
                        setDialogState(() => isSubmitting = true);
                        try {
                          await FirestoreService.applyForDeskOperator(
                            chamberId: chamber['id'],
                            chamberName: chamber['name'],
                            doctorId: chamber['doctorId'],
                            doctorName: chamber['doctorName'],
                            phone: phoneCtrl.text.trim(),
                            note: noteCtrl.text.trim(),
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'Application submitted to Dr. ${chamber["doctorName"]}! You will be notified once approved.'),
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 4),
                              ),
                            );
                          }
                        } catch (e) {
                          setDialogState(() => isSubmitting = false);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error applying: $e')),
                            );
                          }
                        }
                      },
                child: isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Submit Application'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = _chambers.where((c) {
      final name = (c['name'] ?? '').toString().toLowerCase();
      final doctor = (c['doctorName'] ?? '').toString().toLowerCase();
      final area = (c['area'] ?? '').toString().toLowerCase();
      return query.isEmpty ||
          name.contains(query) ||
          doctor.contains(query) ||
          area.contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Chambers & Desk Discovery',
          style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          // Search & Filter header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            color: Colors.white,
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search chambers, clinics, or doctors...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    fillColor: AppColors.background,
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.borderSubtle),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Location filter chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _availableAreas.map((area) {
                      final isSelected = _selectedArea == area;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(area, style: const TextStyle(fontSize: 12)),
                          selected: isSelected,
                          onSelected: (_) {
                            setState(() => _selectedArea = area);
                            _loadChambers();
                          },
                          selectedColor: Theme.of(context).colorScheme.primary,
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : AppColors.textPrimary,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.apartment_outlined, size: 56, color: Colors.grey.shade400),
                              const SizedBox(height: 12),
                              Text(
                                'No Chambers Found',
                                style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _selectedArea != 'All'
                                    ? 'No doctors have listed chambers in $_selectedArea yet.'
                                    : 'No chambers match your search.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final c = filtered[i];
                          final hasOperator = c['hasOperator'] == true;

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppConstants.radiusCard),
                            ),
                            elevation: 0.8,
                            child: Padding(
                              padding: const EdgeInsets.all(14.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.primaryContainer,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Icon(Icons.local_hospital_outlined,
                                            color: Theme.of(context).colorScheme.primary, size: 24),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              c['name'] ?? 'Chamber',
                                              style: GoogleFonts.poppins(
                                                fontSize: 15,
                                                fontWeight: FontWeight.bold,
                                                color: AppColors.textPrimary,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Row(
                                              children: [
                                                const Icon(Icons.location_on_outlined,
                                                    size: 13, color: Colors.grey),
                                                const SizedBox(width: 3),
                                                Text(
                                                  c['area'] ?? 'Dhaka',
                                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                                ),
                                                if (c['isAccessible'] == true) ...[
                                                  const SizedBox(width: 6),
                                                  const AccessibilityIcon(isAccessible: true, showLabel: false),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  const Divider(height: 1),
                                  const SizedBox(height: 8),

                                  // Doctor info
                                  Row(
                                    children: [
                                      const Icon(Icons.person_outline, size: 16, color: Colors.grey),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'Doctor: ${c["doctorName"]} • ${c["doctorSpecialty"]}',
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.black87,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(Icons.access_time, size: 16, color: Colors.grey),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Hours: ${c["visitingHours"]} • Fee: ৳${c["fee"]}',
                                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),

                                  // Status & Apply Action
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: hasOperator
                                              ? Colors.grey.shade100
                                              : Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: hasOperator
                                                ? Colors.grey.shade300
                                                : Colors.green.shade300,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              hasOperator ? Icons.check_circle_outline : Icons.group_add_outlined,
                                              size: 13,
                                              color: hasOperator ? Colors.grey : Colors.green.shade700,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              hasOperator
                                                  ? 'Operator: ${c["operatorName"] ?? "Assigned"}'
                                                  : 'Operator Vacancy',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: hasOperator ? Colors.grey.shade700 : Colors.green.shade800,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      FilledButton.tonal(
                                        style: FilledButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        ),
                                        onPressed: () => _showApplyDialog(c),
                                        child: Text(
                                          hasOperator ? 'Apply Alternate' : 'Apply as Operator',
                                          style: const TextStyle(fontSize: 11.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
