import 'consultation_management_screen.dart';
import 'bmdc_verification_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_constants.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/firestore_service.dart';
import '../widgets/app_role_and_nav.dart';

class AdminConsoleScreen extends StatefulWidget {
  final ValueChanged<UserRole>? onRoleChanged;

  const AdminConsoleScreen({super.key, this.onRoleChanged});

  @override
  State<AdminConsoleScreen> createState() => _AdminConsoleScreenState();
}

class _AdminConsoleScreenState extends State<AdminConsoleScreen> {
  Future<void> _loadTestAppointments() async {
    setState(() => _loadingTestAppointments = true);
    try {
      final list = await DataService.fetchTestAppointments();
      if (mounted) setState(() => _testAppointments = list);
    } catch (_) {} finally {
      if (mounted) setState(() => _loadingTestAppointments = false);
    }
  }

  Future<void> _confirmDeleteTestAppointment(String apptId, String patientName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Test Appointment?'),
        content: Text('Permanently delete test appointment for $patientName (ID: $apptId)?'),
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
    if (confirmed == true) {
      try {
        await DataService.deleteAppointment(apptId);
        _loadTestAppointments();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Test appointment deleted.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting test appointment: $e')),
          );
        }
      }
    }
  }


  bool _loading = false;
  String _serverStatus = 'Checking...';
  int? _latencyMs;
  String? _lastActionMessage;
  List<Map<String, dynamic>> _doctorApplications = [];
  List<Map<String, dynamic>> _moderators = [];
  final TextEditingController _manualUidController = TextEditingController();
  bool _isUploadingBundled = false;
  int _bundledUploadCursor = 0;
  int _bundledDoctorTotal = 0;
  double _bundledUploadProgress = 0.0;
  String _bundledUploadStatus = '';
  final TextEditingController _moderatorUidController = TextEditingController();
  bool _manualGrantVerified = false;
  String _verificationFilter = 'all';
  String _claimStatusFilter = 'all';
  List<Map<String, dynamic>> _verificationDoctors = [];
  bool _loadingVerificationDoctors = false;
  List<Map<String, dynamic>> _testAppointments = [];
  bool _loadingTestAppointments = false;

  @override
  void initState() {
    super.initState();
    _refreshBackendStats();
    _loadDoctorApplications();
    _loadModerators();
    _loadVerificationDoctors();
    _loadBundledUploadStatus();
    if (kDebugMode) _loadTestAppointments();
  }

  @override
  void dispose() {
    _manualUidController.dispose();
    _moderatorUidController.dispose();
    super.dispose();
  }


  Future<void> _loadBundledUploadStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cur = prefs.getInt('admin_bundled_doctors_upload_cursor') ?? 0;
      final total = await FirestoreService.bundledDoctorCount();
      if (mounted) {
        setState(() {
          _bundledUploadCursor = cur;
          _bundledDoctorTotal = total;
          _bundledUploadProgress = total > 0 ? (cur / total).clamp(0.0, 1.0) : 0.0;
        });
      }
    } catch (_) {}
  }

  Future<void> _startBundledUpload({bool restart = false}) async {
    setState(() {
      _isUploadingBundled = true;
      _bundledUploadStatus = 'Starting bundled doctors upload...';
    });

    try {
      await FirestoreService.uploadBundledDoctorsToFirestore(
        restartFromBeginning: restart,
        onProgress: (processed, total, status) {
          if (mounted) {
            setState(() {
              _bundledUploadCursor = processed;
              _bundledUploadProgress = total > 0 ? (processed / total).clamp(0.0, 1.0) : 0.0;
              _bundledUploadStatus = status;
            });
          }
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Doctor catalog successfully synced to Firestore!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed or paused: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingBundled = false;
        });
      }
    }
  }

  void _showAssignDoctorToEmailDialog() {
    final doctorIdController = TextEditingController(text: 'doctor_nuzhat_saima');
    final emailController = TextEditingController(text: 'nuzhatsaima.16@gmail.com');
    bool assigning = false;
    String? errorMsg;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              title: const Text('Assign Doctor to Email'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Look up an existing registered user by email and assign a doctor profile to them.',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: doctorIdController,
                      decoration: const InputDecoration(
                        labelText: 'Doctor Document ID',
                        hintText: 'e.g. doctor_nuzhat_saima',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'User Email',
                        hintText: 'e.g. nuzhatsaima.16@gmail.com',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    if (errorMsg != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        errorMsg!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: assigning ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: assigning
                      ? null
                      : () async {
                          final docId = doctorIdController.text.trim();
                          final targetEmail = emailController.text.trim();
                          if (docId.isEmpty || targetEmail.isEmpty) {
                            setDialogState(() {
                              errorMsg = 'Doctor ID and Email are required.';
                            });
                            return;
                          }
                          setDialogState(() {
                            assigning = true;
                            errorMsg = null;
                          });
                          try {
                            final res = await DataService.assignDoctorToEmail(
                              doctorId: docId,
                              email: targetEmail,
                            );
                            if (!dialogCtx.mounted) return;
                            Navigator.of(dialogCtx).pop();
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Successfully linked $docId to ${res["email"]} (UID: ${res["uid"]})',
                                ),
                              ),
                            );
                            _loadDoctorApplications();
                          } catch (e) {
                            if (dialogCtx.mounted) {
                              setDialogState(() {
                                assigning = false;
                                errorMsg = e.toString().replaceFirst('StateError: ', '');
                              });
                            }
                          }
                        },
                  child: assigning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Assign Doctor'),
                ),
              ],
            );
          },
        );
      },
    );
  }
  Future<void> _loadDoctorApplications() async {
    try {
      final apps = await DataService.fetchDoctorApplications();
      if (mounted) {
        setState(() {
          _doctorApplications = apps;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadModerators() async {
    try {
      final mods = await DataService.fetchModerators();
      if (mounted) {
        setState(() {
          _moderators = mods;
        });
      }
    } catch (_) {}
  }

  Future<void> _approveDoctorApplication(String uid) async {
    setState(() => _loading = true);
    try {
      final doctorProfileId =
          await DataService.approveDoctorApplication(uid: uid);
      setState(() {
        _lastActionMessage =
            'Approved doctor application and linked directory profile $doctorProfileId.';
      });
      await _loadDoctorApplications();
      await _refreshBackendStats();
    } catch (e) {
      setState(() => _lastActionMessage = 'Error allocating doctor role: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rejectDoctorApplication(String uid) async {
    setState(() => _loading = true);
    try {
      await DataService.setDoctorRole(uid: uid, isDoctor: false);
      setState(() {
        _lastActionMessage =
            'Doctor application rejected/revoked for user $uid in database.';
      });
      await _loadDoctorApplications();
      await _refreshBackendStats();
    } catch (e) {
      setState(
          () => _lastActionMessage = 'Error rejecting doctor application: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reopenDoctorApplication(String uid) async {
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'doctorApplication': {
          'status': 'under_appeal',
          'appealedAt': FieldValue.serverTimestamp(),
        }
      }, SetOptions(merge: true));
      setState(() {
        _lastActionMessage =
            'Application for $uid reopened under appeal for review.';
      });
      await _loadDoctorApplications();
      await _refreshBackendStats();
    } catch (e) {
      setState(() => _lastActionMessage = 'Error reopening application: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showAddDoctorDialog({Map<String, dynamic>? applicant}) async {
    final applicantDoc = applicant?['doctorApplication'] as Map? ?? {};
    final initialName = (applicantDoc['name'] ?? applicant?['name'] ?? '').toString();
    final initialSpec = (applicantDoc['speciality'] ?? '').toString();
    final initialPhone = (applicantDoc['phone'] ?? applicant?['phone'] ?? '').toString();
    final initialBmdc = (applicantDoc['bmdcNumber'] ?? applicant?['bmdcRegNumber'] ?? '').toString();

    String? selectedApplicantUid = applicant?['uid']?.toString();

    final nameCtrl = TextEditingController(
      text: initialName.isNotEmpty ? (initialName.startsWith('Dr.') ? initialName : 'Dr. $initialName') : '',
    );
    final specCtrl = TextEditingController(
      text: initialSpec.isNotEmpty ? initialSpec : 'General Medicine',
    );
    final chamberCtrl = TextEditingController(text: 'Bup Medical');
    final degreeCtrl = TextEditingController(text: 'MBBS');
    final phoneCtrl = TextEditingController(text: initialPhone);
    final bmdcCtrl = TextEditingController(text: initialBmdc);

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            selectedApplicantUid != null
                ? 'Review & Create Doctor Profile'
                : 'Add Doctor to Directory',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (applicant == null && _doctorApplications.isNotEmpty) ...[
                  DropdownButtonFormField<String?>(
                    initialValue: selectedApplicantUid,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Link to Pending Applicant',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('None (Unclaimed Directory Profile)'),
                      ),
                      ..._doctorApplications.map((app) {
                        final docApp = app['doctorApplication'] as Map? ?? {};
                        final aName = (docApp['name'] ?? app['name'] ?? 'Applicant').toString();
                        final aPhone = (docApp['phone'] ?? app['phone'] ?? '').toString();
                        final aEmail = (app['email'] ?? '').toString();
                        final sub = aPhone.isNotEmpty ? aPhone : aEmail;
                        return DropdownMenuItem<String?>(
                          value: app['uid']?.toString(),
                          child: Text('$aName ($sub)', overflow: TextOverflow.ellipsis),
                        );
                      }),
                    ],
                    onChanged: (val) {
                      setDialogState(() {
                        selectedApplicantUid = val;
                        if (val != null) {
                          final match = _doctorApplications.firstWhere(
                            (a) => a['uid']?.toString() == val,
                            orElse: () => {},
                          );
                          if (match.isNotEmpty) {
                            final mApp = match['doctorApplication'] as Map? ?? {};
                            final mName = (mApp['name'] ?? match['name'] ?? '').toString();
                            final mPhone = (mApp['phone'] ?? match['phone'] ?? '').toString();
                            final mBmdc = (mApp['bmdcNumber'] ?? match['bmdcRegNumber'] ?? '').toString();
                            final mSpec = (mApp['speciality'] ?? '').toString();
                            if (mName.isNotEmpty) {
                              nameCtrl.text = mName.startsWith('Dr.') ? mName : 'Dr. $mName';
                            }
                            if (mPhone.isNotEmpty) phoneCtrl.text = mPhone;
                            if (mBmdc.isNotEmpty) bmdcCtrl.text = mBmdc;
                            if (mSpec.isNotEmpty) specCtrl.text = mSpec;
                          }
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                if (selectedApplicantUid != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.link, size: 16, color: Colors.green.shade800),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Will link directory profile to UID: $selectedApplicantUid',
                            style: TextStyle(fontSize: 11.5, color: Colors.green.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Doctor Name (e.g. Dr. Jane Doe)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: specCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Speciality (e.g. General Medicine)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: chamberCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Chamber / Hospital (e.g. Bup Medical)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: degreeCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Degree (e.g. MBBS)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone Number (e.g. +880 1...)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: bmdcCtrl,
                  decoration: const InputDecoration(
                    labelText: 'BMDC Reg Number (e.g. A-98765)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: Text(selectedApplicantUid != null ? 'Add & Link Doctor' : 'Add Doctor'),
            ),
          ],
        ),
      ),
    );

    if (result == true && mounted) {
      setState(() => _loading = true);
      try {
        final newId = await FirestoreService.addDoctor(
          name: nameCtrl.text.trim(),
          specialities: [
            specCtrl.text.trim().isNotEmpty
                ? specCtrl.text.trim()
                : 'General Medicine'
          ],
          designation: 'Specialist Consultant',
          education: [
            degreeCtrl.text.trim().isNotEmpty ? degreeCtrl.text.trim() : 'MBBS'
          ],
          bmdcRegNumber: bmdcCtrl.text.trim(),
          phone: phoneCtrl.text.trim(),
          applicantUid: selectedApplicantUid,
          chambers: [
            {
              'hospitalName': chamberCtrl.text.trim().isNotEmpty
                  ? chamberCtrl.text.trim()
                  : 'Bup Medical',
              'area': 'Mirpur',
              'location': 'Dhaka',
            }
          ],
        );
        setState(() {
          _lastActionMessage = selectedApplicantUid != null
              ? 'Added doctor "${nameCtrl.text.trim()}" (ID: $newId) and linked to applicant $selectedApplicantUid.'
              : 'Added doctor "${nameCtrl.text.trim()}" successfully (ID: $newId).';
        });
        await _loadDoctorApplications();
        await _refreshBackendStats();
      } catch (e) {
        setState(() => _lastActionMessage = 'Error adding doctor: $e');
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<void> _toggleModeratorRole(String uid, bool grant) async {
    final isAdmin = AuthService.userRoles.isAdmin;
    if (!isAdmin) {
      setState(() {
        _lastActionMessage =
            'Permission Denied: Only System Administrators can add or remove moderators. Moderators cannot remove other moderators.';
      });
      return;
    }

    setState(() => _loading = true);
    try {
      await DataService.setModeratorRole(uid: uid, isModerator: grant);
      setState(() {
        _lastActionMessage = grant
            ? 'Granted Moderator role to $uid in database.'
            : 'Revoked Moderator role from $uid in database.';
        _moderatorUidController.clear();
      });
      await _loadModerators();
      await _refreshBackendStats();
    } catch (e) {
      setState(() => _lastActionMessage = 'Error updating moderator role: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _manualToggleDoctorRole(bool grant) async {
    final uid = _manualUidController.text.trim();
    if (uid.isEmpty) {
      setState(() => _lastActionMessage = 'Please enter a valid user UID.');
      return;
    }
    setState(() => _loading = true);
    try {
      await DataService.setDoctorRole(
        uid: uid,
        isDoctor: grant,
        isBmdcVerified: grant && _manualGrantVerified,
      );
      setState(() {
        _lastActionMessage = grant
            ? 'Granted Doctor role${_manualGrantVerified ? ' (Verified)' : ''} to $uid via database.'
            : 'Revoked Doctor role from $uid via database.';
        _manualUidController.clear();
      });
      await _loadDoctorApplications();
      await _refreshBackendStats();
    } catch (e) {
      setState(() => _lastActionMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshBackendStats() async {
    setState(() => _loading = true);
    final stopwatch = Stopwatch()..start();

    try {
      await ApiService.fetchSpecialities();
      stopwatch.stop();


      if (mounted) {
        setState(() {
          _loading = false;
          _serverStatus = 'Online (Cloud Firestore)';
          _latencyMs = stopwatch.elapsedMilliseconds;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _serverStatus = 'Offline: $e';
          _latencyMs = null;
        });
      }
    }
  }

  Future<void> _clearAllAppointments() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Appointments?'),
        content: const Text(
          'This will delete all seeded and live appointments from the database.\n\nYou can re-seed them anytime from this console.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);
    try {
      await ApiService.clearAllAppointments();
      setState(() {
        _lastActionMessage = 'All appointments deleted successfully.';
      });
    } catch (e) {
      setState(() => _lastActionMessage = 'Clear error: $e');
    }
    await _refreshBackendStats();
  }

  Future<void> _loadVerificationDoctors() async {
    setState(() => _loadingVerificationDoctors = true);
    try {
      final docs = await FirestoreService.fetchDoctorsForVerification(
        statusFilter: _verificationFilter == 'all' ? null : _verificationFilter,
      );
      if (mounted) {
        setState(() {
          _verificationDoctors = docs;
        });
      }
    } catch (e) {
      debugPrint('Error loading verification doctors: $e');
    } finally {
      if (mounted) setState(() => _loadingVerificationDoctors = false);
    }
  }

  Future<void> _approveClaim(Map<String, dynamic> claim) async {
    final adminUid = AuthService.currentUser?.uid ?? 'admin';
    final requestId = claim['id'] as String;
    final doctorId = claim['doctorId'] as String? ?? '';
    final applicantUid = claim['applicantUid'] as String? ?? '';
    final bmdcNumber = claim['bmdcNumber'] as String? ?? '';

    setState(() => _loading = true);
    try {
      await FirestoreService.approveClaimRequest(
        requestId: requestId,
        doctorId: doctorId,
        applicantUid: applicantUid,
        bmdcNumber: bmdcNumber,
        adminUid: adminUid,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Claim approved! Doctor profile and role linked.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error approving claim: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rejectClaim(Map<String, dynamic> claim) async {
    final reasonController = TextEditingController();
    final shouldReject = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Claim Request'),
        content: TextField(
          controller: reasonController,
          decoration: const InputDecoration(
            labelText: 'Reason for rejection',
            hintText: 'e.g. BMDC number does not match record',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (shouldReject != true) return;

    final adminUid = AuthService.currentUser?.uid ?? 'admin';
    final requestId = claim['id'] as String;
    final doctorId = claim['doctorId'] as String? ?? '';
    final applicantUid = claim['applicantUid'] as String? ?? '';

    setState(() => _loading = true);
    try {
      await FirestoreService.rejectClaimRequest(
        requestId: requestId,
        doctorId: doctorId,
        applicantUid: applicantUid,
        reason: reasonController.text.trim().isEmpty ? 'Verification failed' : reasonController.text.trim(),
        adminUid: adminUid,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Claim request rejected.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error rejecting claim: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings_outlined),
            SizedBox(width: 8),
            Text('Admin Console'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshBackendStats,
            tooltip: 'Refresh Dashboard',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshBackendStats,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Live backend status: connection plus the numbers an admin acts on.
            Builder(builder: (context) {
              final colors = Theme.of(context).colorScheme;
              final online = _serverStatus.contains('Online');
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: online ? AppColors.success : AppColors.error,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            online ? 'Live · Cloud Firestore' : 'Backend unreachable',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                          ),
                        ),
                        Text(
                          _latencyMs != null ? '$_latencyMs ms' : '—',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        _metric('Pending applications', '${_doctorApplications.length}', colors.primary),
                        const SizedBox(width: 10),
                        _metric('Moderators', '${_moderators.length}', colors.primary),
                      ],
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 16),

            if (_lastActionMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_lastActionMessage!,
                          style: const TextStyle(
                              fontSize: 12.5, color: Colors.blue)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],


            // 1. Verification Section
            _sectionTitle('VERIFICATION'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Doctor roles are allocated strictly via the database. Users who apply for a doctor account remain pending until approved here.',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Pending Applications (${_doctorApplications.length})',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: 'Refresh applications',
                          onPressed: _loading ? null : _loadDoctorApplications,
                        ),
                      ],
                    ),
                    const Divider(height: 1),
                    if (_doctorApplications.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text(
                            'No pending doctor applications.',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                      )
                    else
                      ..._doctorApplications.map((app) {
                        final uid = app['uid'] ?? '';
                        final docApp =
                            app['doctorApplication'] as Map<String, dynamic>? ??
                                {};
                        final name = app['name']?.toString().isNotEmpty == true
                            ? app['name']
                            : (docApp['name'] ?? 'Doctor Applicant');
                        final email = app['email'] ?? docApp['email'] ?? '';
                        final phone = app['phone'] ?? docApp['phone'] ?? '';
                        final nid = docApp['nid'] ?? app['nid'] ?? '';
                        final bmdcNumber =
                            docApp['bmdcNumber'] ?? app['bmdcRegNumber'] ?? '';
                        final hasDocs =
                            docApp['hasProvidedVerificationDocs'] == true ||
                                (nid.toString().isNotEmpty ||
                                    bmdcNumber.toString().isNotEmpty);

                        return Container(
                          margin: const EdgeInsets.only(top: 8, bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue.shade100),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text('$name',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14)),
                                  ),
                                  if (hasDocs)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.verified,
                                              size: 12,
                                              color: Colors.green.shade800),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Docs Provided',
                                            style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.green.shade800),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text('UID: $uid',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.black54)),
                              if (phone.isNotEmpty)
                                Text(
                                    'Doctor Phone (Required for Login): $phone',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87)),
                              if (email.isNotEmpty)
                                Text('Email: $email',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.black54)),
                              if (nid.isNotEmpty)
                                Text('NID: $nid',
                                    style: const TextStyle(
                                        fontSize: 11.5, color: Colors.indigo)),
                              if (bmdcNumber.isNotEmpty)
                                Text('BMDC Reg No: $bmdcNumber',
                                    style: const TextStyle(
                                        fontSize: 11.5, color: Colors.teal)),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: AppColors.success),
                                    onPressed: _loading
                                        ? null
                                        : () => _approveDoctorApplication(uid),
                                    child: const Text('Approve Application'),
                                  ),
                                  FilledButton.tonal(
                                    onPressed: _loading
                                        ? null
                                        : () => _showAddDoctorDialog(applicant: app),
                                    child: const Text('Review & Create Profile'),
                                  ),
                                  FilledButton.tonal(
                                    onPressed: _loading
                                        ? null
                                        : () => _reopenDoctorApplication(uid),
                                    child: const Text('Appeal / Reopen'),
                                  ),
                                  OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red),
                                    onPressed: _loading
                                        ? null
                                        : () => _rejectDoctorApplication(uid),
                                    child: const Text('Reject'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                    const SizedBox(height: 12),
                    const Divider(),
                    const SizedBox(height: 8),
                    const Text(
                      'Manual Doctor Role Assignment (by UID):',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 12.5),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Checkbox(
                          value: _manualGrantVerified,
                          onChanged: (val) {
                            setState(() => _manualGrantVerified = val ?? false);
                          },
                        ),
                        const Text('Include BMDC & NID Verified Status',
                            style: TextStyle(fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _manualUidController,
                            decoration: const InputDecoration(
                              hintText: 'Enter user UID',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _loading
                              ? null
                              : () => _manualToggleDoctorRole(true),
                          child: const Text('Grant'),
                        ),
                        const SizedBox(width: 4),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red),
                          onPressed: _loading
                              ? null
                              : () => _manualToggleDoctorRole(false),
                          child: const Text('Revoke'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Manage verification and BMDC registration status for listed doctors.',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final status in ['all', 'unverified', 'pending', 'verified', 'rejected'])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(
                                  status.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: _verificationFilter == status ? Colors.white : Colors.black87,
                                  ),
                                ),
                                selected: _verificationFilter == status,
                                selectedColor: Theme.of(context).colorScheme.primary,
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() => _verificationFilter = status);
                                    _loadVerificationDoctors();
                                  }
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Doctors (${_verificationDoctors.length})',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: 'Reload doctors',
                          onPressed: _loadingVerificationDoctors ? null : _loadVerificationDoctors,
                        ),
                      ],
                    ),
                    const Divider(height: 1),
                    if (_loadingVerificationDoctors)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_verificationDoctors.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Text(
                            'No doctors found with status "$_verificationFilter".',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                      )
                    else
                      ..._verificationDoctors.take(15).map((doc) {
                        final docId = (doc['id'] ?? doc['_id'] ?? '').toString();
                        final name = (doc['name'] ?? 'Doctor').toString();
                        final bmdc = (doc['bmdcNumber'] ?? doc['bmdcRegNumber'] ?? 'Not Provided').toString();
                        final status = (doc['verificationStatus'] ?? 'unverified').toString().toLowerCase();
                        final specs = (doc['specialities'] as List? ?? ['General Medicine']).join(', ');

                        Color badgeColor = Colors.grey;
                        IconData badgeIcon = Icons.help_outline;
                        if (status == 'verified') {
                          badgeColor = Colors.green;
                          badgeIcon = Icons.verified;
                        } else if (status == 'pending') {
                          badgeColor = Colors.orange;
                          badgeIcon = Icons.hourglass_top;
                        } else if (status == 'rejected') {
                          badgeColor = Colors.red;
                          badgeIcon = Icons.cancel;
                        }

                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: badgeColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: badgeColor),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(badgeIcon, color: badgeColor, size: 13),
                                        const SizedBox(width: 4),
                                        Text(
                                          status.toUpperCase(),
                                          style: TextStyle(
                                            color: badgeColor,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text('Speciality: $specs', style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
                              Text('BMDC Reg: $bmdc', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.open_in_browser, size: 13),
                                    label: const Text('Verify on BMDC', style: TextStyle(fontSize: 11)),
                                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                                    onPressed: () async {
                                      final res = await Navigator.push<bool>(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => BmdcVerificationScreen(
                                            doctorId: docId,
                                            doctorName: (doc['name'] ?? 'Doctor').toString(),
                                            bmdcNumber: bmdc,
                                            currentStatus: status,
                                          ),
                                        ),
                                      );
                                      if (res == true) {
                                        _loadVerificationDoctors();
                                      }
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (doc['hidden'] == true || doc['isHidden'] == true || doc['isDeleted'] == true) ...[
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.red.shade50,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: Colors.red.shade200),
                                      ),
                                      child: Text(
                                        doc['isDeleted'] == true ? 'DELETED' : 'HIDDEN',
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.red.shade800),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    FilledButton.tonal(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.teal.shade50,
                                        foregroundColor: Colors.teal.shade800,
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      onPressed: _loading ? null : () => _restoreDoctor(docId, name),
                                      child: const Text('Restore to Discovery', style: TextStyle(fontSize: 11)),
                                    ),
                                  ] else ...[
                                    // Destructive actions live behind a menu so they
                                    // can't be hit by accident.
                                    PopupMenuButton<String>(
                                      tooltip: 'More actions',
                                      enabled: !_loading,
                                      onSelected: (v) => v == 'hide'
                                          ? _showSoftHideDialog(docId, name)
                                          : _showHardDeleteDialog(docId, name),
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'hide',
                                          child: ListTile(
                                            leading: Icon(Icons.visibility_off_outlined),
                                            title: Text('Hide from discovery'),
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: ListTile(
                                            leading: Icon(Icons.delete_forever, color: AppColors.error),
                                            title: Text('Delete permanently',
                                                style: TextStyle(color: AppColors.error)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 20),

            // 2. Claims Section
            _sectionTitle('CLAIMS'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.link, color: Colors.indigo),
                title: const Text('Assign Doctor Profile to Email', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                subtitle: const Text('Link a doctor profile directly to a registered user account by email (e.g. Dr. Nuzhat Saima).', style: TextStyle(fontSize: 12)),
                trailing: FilledButton.tonal(
                  onPressed: _showAssignDoctorToEmailDialog,
                  child: const Text('Assign'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Physicians who submit BMDC documentation to claim their directory profile.',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final s in ['all', 'pending', 'approved', 'rejected'])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(
                                  s.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: _claimStatusFilter == s ? Colors.white : Colors.black87,
                                  ),
                                ),
                                selected: _claimStatusFilter == s,
                                selectedColor: Colors.deepPurple.shade600,
                                onSelected: (sel) {
                                  if (sel) setState(() => _claimStatusFilter = s);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    StreamBuilder<List<Map<String, dynamic>>>(
                      stream: FirestoreService.streamClaimRequests(
                        statusFilter: _claimStatusFilter == 'all' ? null : _claimStatusFilter,
                      ),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final claims = snapshot.data ?? [];
                        if (claims.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Center(
                              child: Text(
                                'No claim requests with status "$_claimStatusFilter".',
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ),
                          );
                        }
                        return Column(
                          children: claims.map((claim) {
                            final docName = (claim['doctorName'] ?? 'Doctor Profile').toString();
                            final applicantName = (claim['applicantName'] ?? 'Applicant').toString();
                            final applicantEmail = (claim['applicantEmail'] ?? '').toString();
                            final bmdc = (claim['bmdcNumber'] ?? 'None').toString();
                            final status = (claim['status'] ?? 'pending').toString().toLowerCase();

                            Color stColor = Colors.orange;
                            if (status == 'approved') stColor = Colors.green;
                            if (status == 'rejected') stColor = Colors.red;

                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.deepPurple.shade50.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.deepPurple.shade100),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          docName,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: stColor.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: stColor),
                                        ),
                                        child: Text(
                                          status.toUpperCase(),
                                          style: TextStyle(color: stColor, fontWeight: FontWeight.bold, fontSize: 10),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text('Claimed By: $applicantName ($applicantEmail)',
                                      style: const TextStyle(fontSize: 11.5, color: Colors.black87)),
                                  Text('BMDC Reg Number: $bmdc',
                                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                                  if (claim['rejectionReason'] != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        'Rejection reason: ${claim['rejectionReason']}',
                                        style: const TextStyle(fontSize: 11, color: Colors.red),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  if (status == 'pending')
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        OutlinedButton.icon(
                                          icon: const Icon(Icons.open_in_browser, size: 13),
                                          label: const Text('BMDC Check', style: TextStyle(fontSize: 11)),
                                          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                                          onPressed: () async {
                                            await Navigator.push<bool>(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => BmdcVerificationScreen(
                                                  doctorId: (claim['doctorId'] ?? '').toString(),
                                                  doctorName: (claim['doctorName'] ?? 'Doctor').toString(),
                                                  bmdcNumber: bmdc,
                                                  currentStatus: 'pending',
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        const SizedBox(width: 6),
                                        OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.red,
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          onPressed: _loading ? null : () => _rejectClaim(claim),
                                          child: const Text('Reject', style: TextStyle(fontSize: 11)),
                                        ),
                                        const SizedBox(width: 8),
                                        FilledButton(
                                          style: FilledButton.styleFrom(
                                            backgroundColor: AppColors.success,
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          onPressed: _loading ? null : () => _approveClaim(claim),
                                          child: const Text('Approve Claim', style: TextStyle(fontSize: 11)),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 20),

            // 3. Doctors Section
            _sectionTitle('DOCTORS'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Doctor Profiles Directory',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        FilledButton.icon(
                          icon: const Icon(Icons.person_add, size: 16),
                          label: const Text('Add Doctor'),
                          onPressed: _showAddDoctorDialog,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Admins can add verified doctors directly or manage profiles in the directory.',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.cloud_upload_outlined, color: Colors.teal),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Upload Bundled Doctors to Firestore',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                        if (_bundledDoctorTotal > 0 && _bundledUploadCursor >= _bundledDoctorTotal)
                          const Chip(
                            label: Text('Synced', style: TextStyle(fontSize: 11, color: Colors.teal)),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _bundledDoctorTotal > 0
                          ? 'Uploads $_bundledDoctorTotal bundled doctors to Firestore with stable IDs in batches of 500. Resumable and idempotent.'
                          : 'Uploads bundled doctors to Firestore with stable IDs in batches of 500. Resumable and idempotent.',
                      style: const TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    if (_isUploadingBundled) ...[
                      LinearProgressIndicator(value: _bundledUploadProgress),
                      const SizedBox(height: 8),
                      Text(
                        _bundledUploadStatus.isNotEmpty ? _bundledUploadStatus : 'Writing batches of 500...',
                        style: const TextStyle(fontSize: 12, color: Colors.teal, fontWeight: FontWeight.w600),
                      ),
                    ] else ...[
                      Text(
                        'Uploaded: $_bundledUploadCursor / $_bundledDoctorTotal doctors live in Firestore',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            icon: Icon(_bundledDoctorTotal > 0 && _bundledUploadCursor >= _bundledDoctorTotal ? Icons.sync : Icons.cloud_upload, size: 16),
                            label: Text(
                              _bundledUploadCursor == 0
                                  ? 'Start Upload (Batches of 500)'
                                  : _bundledUploadCursor < _bundledDoctorTotal
                                      ? 'Resume Upload ($_bundledUploadCursor/$_bundledDoctorTotal)'
                                      : 'Re-sync All to Firestore',
                            ),
                            onPressed: () => _startBundledUpload(restart: _bundledDoctorTotal > 0 && _bundledUploadCursor >= _bundledDoctorTotal),
                          ),
                          if (_bundledUploadCursor > 0 && _bundledUploadCursor < _bundledDoctorTotal)
                            OutlinedButton(
                              onPressed: () => _startBundledUpload(restart: true),
                              child: const Text('Restart from 0'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 20),

            // 4. Consultations Section
            _sectionTitle('CONSULTATIONS'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.payment, color: Colors.teal),
                title: const Text('Consultation Approvals & Chats'),
                subtitle: const Text('Verify patient bKash/Nagad TrxIDs and activate direct consultations'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ConsultationManagementScreen(isDoctor: false),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 20),

            // 5. Maintenance Section
            _sectionTitle('MAINTENANCE'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'System Administrators can appoint and remove moderators. Moderators can post YouTube videos, publish clinical tips, and answer community Q&A. Moderators cannot remove other moderators.',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    if (!AuthService.userRoles.isAdmin)
                      Container(
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.shade300),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.lock_outline,
                                size: 18, color: Colors.amber.shade900),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Restricted: You are viewing as a Moderator. Moderators cannot add or remove other moderators.',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.amber.shade900),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Active Moderators (${_moderators.length})',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: 'Refresh moderators',
                          onPressed: _loading ? null : _loadModerators,
                        ),
                      ],
                    ),
                    const Divider(height: 1),
                    if (_moderators.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text(
                            'No moderators appointed yet.',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                      )
                    else
                      ..._moderators.map((mod) {
                        final uid = mod['uid'] ?? '';
                        final name = mod['name'] ?? 'Moderator User';
                        final email = mod['email'] ?? '';
                        final isAdmin = AuthService.userRoles.isAdmin;

                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            backgroundColor: Colors.deepOrange,
                            child: Icon(Icons.security,
                                color: Colors.white, size: 18),
                          ),
                          title: Text('$name',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13.5)),
                          subtitle: Text(
                              'UID: $uid${email.isNotEmpty ? ' • $email' : ''}',
                              style: const TextStyle(fontSize: 11)),
                          trailing: isAdmin
                              ? OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red),
                                  onPressed: _loading
                                      ? null
                                      : () => _toggleModeratorRole(uid, false),
                                  child: const Text('Revoke'),
                                )
                              : null,
                        );
                      }),
                    if (AuthService.userRoles.isAdmin) ...[
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 8),
                      const Text(
                        'Appoint New Moderator (by UID):',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12.5),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _moderatorUidController,
                              decoration: const InputDecoration(
                                hintText: 'Enter user UID to make moderator',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: Colors.deepOrange),
                            onPressed: _loading
                                ? null
                                : () {
                                    final uid =
                                        _moderatorUidController.text.trim();
                                    if (uid.isNotEmpty) {
                                      _toggleModeratorRole(uid, true);
                                    }
                                  },
                            child: const Text('Appoint'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 12),
            if (kDebugMode) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Test Appointments Cleanup (Manual)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                          ),
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: 'Refresh test appointments',
                            onPressed: _loadingTestAppointments ? null : _loadTestAppointments,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Individually delete test appointments with missing or legacy status (e.g. waiting, pending). No automatic deletion.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const Divider(height: 16),
                      if (_loadingTestAppointments)
                        const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
                      else if (_testAppointments.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('No legacy or test appointments found.', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        )
                      else
                        ..._testAppointments.map((appt) {
                          final id = (appt['id'] ?? '').toString();
                          final patName = (appt['patientName'] ?? 'Unknown').toString();
                          final docName = (appt['doctorName'] ?? 'Specialist').toString();
                          final status = (appt['status'] ?? 'missing').toString();
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('$patName • Dr. $docName', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            subtitle: Text('Status: $status • ID: $id', style: const TextStyle(fontSize: 11)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                              tooltip: 'Delete this appointment',
                              onPressed: () => _confirmDeleteTestAppointment(id, patName),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent),
                      title: const Text('Clear All Appointments'),
                      subtitle: const Text('Deletes all seeded and live patient appointments from Firestore'),
                      trailing: FilledButton.tonal(
                        style: FilledButton.styleFrom(backgroundColor: Colors.red.shade50),
                        onPressed: _loading ? null : _clearAllAppointments,
                        child: const Text('Purge', style: TextStyle(color: Colors.red)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Role Impersonation & Testing
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.medical_services_outlined, color: Colors.blue),
                      title: const Text('Switch to Doctor Portal'),
                      subtitle: const Text('Active chamber management and live patient queue view'),
                      onTap: () {
                        widget.onRoleChanged?.call(UserRole.doctor);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Switched to Doctor portal view')),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.desktop_windows_outlined, color: Colors.indigo),
                      title: const Text('Switch to Operator Desk'),
                      subtitle: const Text('Reception queue desk for patient check-ins and tickets'),
                      onTap: () {
                        widget.onRoleChanged?.call(UserRole.operator);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Switched to Operator Desk view')),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.person_outline, color: Colors.teal),
                      title: const Text('Switch to Guest Patient Mode'),
                      subtitle: const Text('Clean guest view without doctor/operator tabs'),
                      onTap: () async {
                        await AuthService.setGuestMode(true);
                        widget.onRoleChanged?.call(UserRole.patient);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Switched to Guest Patient view')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Database Utilities
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_outlined, color: Colors.grey),
                      title: const Text('Reset All Local App Storage'),
                      subtitle: const Text('Clears SharedPreferences roles, guest mode, and mood keys'),
                      onTap: () async {
                        await AuthService.signOut();
                        await AuthService.setGuestMode(true);
                        widget.onRoleChanged?.call(UserRole.patient);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('All local app storage reset to clean state.')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 20)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
          color: Colors.grey.shade600,
        ),
      ),
    );
  }

  Future<void> _showSoftHideDialog(String docId, String docName) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Soft Hide Dr. $docName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This doctor will be immediately removed from discovery for patients, but their record remains preserved in Firestore for admin review.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                labelText: 'Reason for hiding',
                hintText: 'e.g. License check issue, requested removal',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade800),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hide Doctor'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final uid = AuthService.currentUser?.uid ?? 'admin';
      final reason = reasonController.text.trim().isNotEmpty
          ? reasonController.text.trim()
          : 'Hidden by administrator';
      await FirestoreService.softHideDoctor(
        doctorId: docId,
        reason: reason,
        adminUid: uid,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Dr. $docName is now hidden from discovery.')),
        );
        _loadVerificationDoctors();
      }
    }
  }

  Future<void> _restoreDoctor(String docId, String docName) async {
    await FirestoreService.restoreDoctor(docId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Dr. $docName has been restored to discovery.')),
      );
      _loadVerificationDoctors();
    }
  }

  Future<void> _showHardDeleteDialog(String docId, String docName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hard Delete Dr. $docName?'),
        content: const Text(
          'Warning: This permanently removes the doctor from discovery and writes a persistent tombstone so they never reappear, even from the bundled APK dataset.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await FirestoreService.hardDeleteDoctor(doctorId: docId, isBundled: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Dr. $docName was permanently deleted.')),
        );
        _loadVerificationDoctors();
      }
    }
  }

}
