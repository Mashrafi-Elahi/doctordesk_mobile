import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_constants.dart';
import '../models/consultation.dart';
import '../widgets/state_views.dart';
import '../services/auth_service.dart';
import '../services/consultation_service.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';

class ConsultationManagementScreen extends StatefulWidget {
  final bool isDoctor;
  final String? doctorProfileId;

  const ConsultationManagementScreen({
    super.key,
    this.isDoctor = false,
    this.doctorProfileId,
  });

  @override
  State<ConsultationManagementScreen> createState() => _ConsultationManagementScreenState();
}

class _ConsultationManagementScreenState extends State<ConsultationManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Doctor Settings State
  bool _consultEnabled = true;
  final TextEditingController _feeController = TextEditingController(text: '500');
  final TextEditingController _availabilityController =
      TextEditingController(text: 'Evening 7:00 PM - 10:00 PM');
  bool _isSavingSettings = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: widget.isDoctor ? 3 : 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _feeController.dispose();
    _availabilityController.dispose();
    super.dispose();
  }

  Future<void> _approve(Consultation c) async {
    try {
      final docName = c.doctorName.isNotEmpty ? c.doctorName : 'Specialist Doctor';
      final patName = c.patientName.isNotEmpty ? c.patientName : 'Patient';
      final currentUid = AuthService.currentUser?.uid ?? '';
      final docUid = c.doctorUid.isNotEmpty ? c.doctorUid : currentUid;

      final chatId = await ConsultationService.approveConsultation(
        consultationId: c.id,
        doctorUid: docUid,
        patientUid: c.patientUid,
        doctorName: docName,
        patientName: patName,
        doctorId: c.doctorId,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Consultation verified and chat unlocked! 🎉')),
      );

      // Offer to open chat
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Consultation Activated'),
          content: Text('Payment verified successfully for $patName. Would you like to open the chat now?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open Chat')),
          ],
        ),
      );

      if (open == true && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              chatId: chatId,
              otherUserName: widget.isDoctor ? patName : docName,
              otherUserUid: widget.isDoctor ? c.patientUid : docUid,
              isDoctor: widget.isDoctor,
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error approving consultation: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _reject(Consultation c) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Decline Payment Verification'),
        content: TextField(
          controller: reasonCtrl,
          decoration: const InputDecoration(
            labelText: 'Reason for decline',
            hintText: 'e.g. TrxID not found or invalid amount',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Decline Request'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      try {
        await ConsultationService.rejectConsultation(
          consultationId: c.id,
          patientUid: c.patientUid,
          doctorName: c.doctorName,
          reason: reasonCtrl.text.trim().isEmpty ? 'Payment could not be verified' : reasonCtrl.text.trim(),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Consultation request declined and patient notified.')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error declining: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _saveSettings() async {
    final docId = widget.doctorProfileId;
    if (docId == null || docId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No linked doctor profile found.')),
      );
      return;
    }

    final fee = double.tryParse(_feeController.text.trim()) ?? 500.0;
    setState(() => _isSavingSettings = true);

    try {
      await ConsultationService.updateDoctorConsultSettings(
        doctorId: docId,
        consultEnabled: _consultEnabled,
        consultFee: fee,
        availability: _availabilityController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Consultation settings updated successfully!')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving settings: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = AuthService.currentUser?.uid ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isDoctor ? 'Doctor Telehealth Portal' : 'Consultation Approvals',
          style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: [
            const Tab(text: 'Pending (TrxID)'),
            const Tab(text: 'Active Chats'),
            if (widget.isDoctor) const Tab(text: 'Settings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Tab 1: Pending Approvals
          StreamBuilder<List<Consultation>>(
            stream: ConsultationService.streamPendingConsultations(
              doctorUid: widget.isDoctor ? currentUid : null,
            ),
            builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorStateView.fromError(snapshot.error,
                what: 'payment requests', onRetry: () => setState(() {}));
          }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final list = snapshot.data ?? [];
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_outline, size: 56, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        Text(
                          'No Pending Payment Requests',
                          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'New patient consultation payments will appear here for verification.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final c = list[index];
                  return Card(
                    elevation: 1,
                    margin: const EdgeInsets.only(bottom: 12),
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
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                c.patientName,
                                style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.amber.shade300),
                                ),
                                child: Text(
                                  '৳${c.amount.toStringAsFixed(0)} via ${c.paymentMethod.toUpperCase()}',
                                  style: GoogleFonts.poppins(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('Doctor: ${c.doctorName}', style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.receipt, size: 16, color: Colors.blueGrey),
                                const SizedBox(width: 6),
                                Text(
                                  'TrxID: ${c.trxId}',
                                  style: GoogleFonts.robotoMono(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppColors.success,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  icon: const Icon(Icons.check, size: 16),
                                  label: const Text('Verify & Activate Chat', style: TextStyle(fontSize: 12)),
                                  onPressed: () => _approve(c),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Decline payment',
                                icon: const Icon(Icons.close, color: Colors.red),
                                onPressed: () => _reject(c),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),

          // Tab 2: Active Consultations
          StreamBuilder<List<Consultation>>(
            stream: widget.isDoctor
                ? ConsultationService.streamDoctorConsultations(currentUid)
                : ConsultationService.streamPatientConsultations(currentUid),
            builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorStateView.fromError(snapshot.error,
                what: 'consultations', onRetry: () => setState(() {}));
          }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final activeList = (snapshot.data ?? []).where((c) => c.status == 'active').toList();
              if (activeList.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_outlined, size: 56, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        Text(
                          'No Active Consultations',
                          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Approved consultations and ongoing chats will appear here.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: activeList.length,
                itemBuilder: (context, index) {
                  final c = activeList[index];
                  final otherName = widget.isDoctor ? c.patientName : c.doctorName;
                  final otherUid = widget.isDoctor ? c.patientUid : c.doctorUid;

                  return Card(
                    elevation: 1,
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(14),
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                        child: Icon(widget.isDoctor ? Icons.person : Icons.medical_services, color: Theme.of(context).colorScheme.primary),
                      ),
                      title: Text(otherName, style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15)),
                      subtitle: Text('Status: Active Consultation · ৳${c.amount.toStringAsFixed(0)}', style: const TextStyle(fontSize: 12.5)),
                      trailing: FilledButton.tonalIcon(
                        icon: const Icon(Icons.chat, size: 16),
                        label: const Text('Open Chat', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          if (c.chatId != null && c.chatId!.isNotEmpty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  chatId: c.chatId!,
                                  otherUserName: otherName,
                                  otherUserUid: otherUid,
                                  isDoctor: widget.isDoctor,
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  );
                },
              );
            },
          ),

          // Tab 3: Consultation Settings (Doctor only)
          if (widget.isDoctor)
            SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Online Telehealth & Consultation Settings',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Control whether patients can request online consultations with you and set your fee.',
                    style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    title: const Text('Enable Online Consultations', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Allow patients to submit payment and chat with you directly'),
                    value: _consultEnabled,
                    activeThumbColor: Theme.of(context).colorScheme.primary,
                    onChanged: (val) => setState(() => _consultEnabled = val),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _feeController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Consultation Fee (BDT)',
                      prefixText: '৳ ',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _availabilityController,
                    decoration: InputDecoration(
                      labelText: 'Online Availability Hours',
                      hintText: 'e.g. Daily 7:00 PM - 10:00 PM',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: _isSavingSettings
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.save),
                    label: Text(_isSavingSettings ? 'Saving...' : 'Save Settings', style: AppTheme.buttonText),
                    onPressed: _isSavingSettings ? null : _saveSettings,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
