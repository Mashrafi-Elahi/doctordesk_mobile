import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/doctor.dart';
import '../services/auth_service.dart';
import '../services/consultation_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_constants.dart';

class ConsultationBookingScreen extends StatefulWidget {
  final Doctor doctor;

  const ConsultationBookingScreen({super.key, required this.doctor});

  @override
  State<ConsultationBookingScreen> createState() => _ConsultationBookingScreenState();
}

class _ConsultationBookingScreenState extends State<ConsultationBookingScreen> {
  String _selectedMethod = 'bkash'; // 'bkash' | 'nagad'
  final TextEditingController _trxController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  bool _isSubmitting = false;

  final String _bkashNumber = '01711-223344';
  final String _nagadNumber = '01811-556677';

  @override
  void dispose() {
    _trxController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $text to clipboard!')),
    );
  }

  Future<void> _submitPayment() async {
    final patient = AuthService.currentUser;
    if (patient == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in first to book a consultation.')),
      );
      return;
    }

    final trxId = _trxController.text.trim();
    final phone = _phoneController.text.trim();

    if (phone.isEmpty || phone.length < 11) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid 11-digit mobile number.')),
      );
      return;
    }

    if (trxId.isEmpty || trxId.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid Transaction ID (at least 6 characters).')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final docUid = widget.doctor.claimedByUid ?? '';
      await ConsultationService.createConsultationRequest(
        patientUid: patient.uid,
        patientName: patient.displayName ?? 'Patient',
        doctorId: widget.doctor.id,
        doctorUid: docUid,
        doctorName: widget.doctor.name,
        amount: widget.doctor.consultFee,
        paymentMethod: _selectedMethod,
        trxId: trxId,
        senderPhone: phone,
      );

      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline, color: Colors.green, size: 52),
          title: Text(
            'Payment Submitted for Review',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          content: Text(
            'Your payment of ৳${widget.doctor.consultFee.toStringAsFixed(0)} (TrxID: $trxId) has been sent to Dr. ${widget.doctor.name} for verification.\n\nOnce approved, direct chat will unlock automatically and you will receive an in-app notification.',
            style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 45)),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.pop(context, true);
              },
              child: const Text('OK, Got It'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Submission error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fee = widget.doctor.consultFee;
    final availability = widget.doctor.consultAvailability ?? 'Evening 7:00 PM - 10:00 PM';
    final activeNumber = _selectedMethod == 'bkash' ? _bkashNumber : _nagadNumber;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Online Consultation Booking',
          style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Medical Disclaimer Banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.amber.shade50,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Not for emergency medical conditions. In an emergency, please visit the nearest hospital or call 999 immediately.',
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        color: Colors.amber.shade900,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Doctor Summary Card
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.grey.shade200),
                    ),
                    color: AppColors.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const CircleAvatar(
                            radius: 26,
                            backgroundColor: Color(0xFFE0F2FE),
                            child: Icon(Icons.person, color: Color(0xFF0284C7), size: 30),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.doctor.name,
                                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16),
                                ),
                                if (widget.doctor.specialities.isNotEmpty)
                                  Text(
                                    widget.doctor.specialities.join(', '),
                                    style: GoogleFonts.poppins(fontSize: 12.5, color: Colors.grey.shade600),
                                  ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.schedule, size: 14, color: Colors.teal),
                                    const SizedBox(width: 4),
                                    Text(
                                      availability,
                                      style: GoogleFonts.poppins(fontSize: 11.5, color: Colors.teal.shade800),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '৳${fee.toStringAsFixed(0)}',
                              style: GoogleFonts.poppins(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                  Text(
                    'Select Payment Method',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _selectedMethod = 'bkash'),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _selectedMethod == 'bkash' ? const Color(0xFFD82E6B) : Colors.grey.shade300,
                                width: _selectedMethod == 'bkash' ? 2 : 1,
                              ),
                              color: _selectedMethod == 'bkash' ? const Color(0xFFD82E6B).withValues(alpha: 0.08) : Colors.white,
                            ),
                            child: Column(
                              children: [
                                const Icon(Icons.phone_android, color: Color(0xFFD82E6B), size: 28),
                                const SizedBox(height: 4),
                                Text(
                                  'bKash',
                                  style: GoogleFonts.poppins(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: const Color(0xFFD82E6B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _selectedMethod = 'nagad'),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _selectedMethod == 'nagad' ? const Color(0xFFF7931E) : Colors.grey.shade300,
                                width: _selectedMethod == 'nagad' ? 2 : 1,
                              ),
                              color: _selectedMethod == 'nagad' ? const Color(0xFFF7931E).withValues(alpha: 0.08) : Colors.white,
                            ),
                            child: Column(
                              children: [
                                const Icon(Icons.account_balance_wallet, color: Color(0xFFF7931E), size: 28),
                                const SizedBox(height: 4),
                                Text(
                                  'Nagad',
                                  style: GoogleFonts.poppins(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: const Color(0xFFF7931E),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),
                  // Payment Instructions Box
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Payment Instructions (${_selectedMethod.toUpperCase()}):',
                          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blue.shade900),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '1. Send ৳${fee.toStringAsFixed(0)} (Send Money) to the official doctor desk number below:',
                          style: GoogleFonts.poppins(fontSize: 12, color: Colors.blue.shade900),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.blue.shade200),
                              ),
                              child: Text(
                                activeNumber,
                                style: GoogleFonts.robotoMono(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                              icon: const Icon(Icons.copy, size: 14),
                              label: const Text('Copy', style: TextStyle(fontSize: 12)),
                              onPressed: () => _copyToClipboard(activeNumber),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '2. Copy the Transaction ID from the SMS and paste it below.',
                          style: GoogleFonts.poppins(fontSize: 12, color: Colors.blue.shade900),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                  // Sender Phone Input
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Your Sender Mobile Number',
                      hintText: 'e.g. 01712345678',
                      prefixIcon: const Icon(Icons.phone),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),

                  const SizedBox(height: 14),
                  // TrxID Input
                  TextField(
                    controller: _trxController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: 'Transaction ID (TrxID)',
                      hintText: 'e.g. 9K38LA87XQ',
                      prefixIcon: const Icon(Icons.receipt_long),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),

                  const SizedBox(height: 28),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open),
                    label: Text(
                      _isSubmitting ? 'Submitting...' : 'Submit Payment & Unlock Chat',
                      style: AppTheme.buttonText,
                    ),
                    onPressed: _isSubmitting ? null : _submitPayment,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
