import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/firestore_service.dart';

/// One entry point for doctors joining DoctorDesk:
/// - with a Profile ID (copied from their listed profile) it sends a claim
///   request to the admin, after checking the profile exists and is unclaimed;
/// - without one it sends a "get me listed" application.
/// Nothing is granted on the device; an admin approves either request.
/// Returns true when a request was sent.
Future<bool> showDoctorClaimDialog(BuildContext context, {String? profileId}) async {
  final user = AuthService.currentUser;
  if (user == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sign in first to apply as a doctor.')),
    );
    return false;
  }
  final idController = TextEditingController(text: profileId ?? '');
  final phoneController = TextEditingController(text: user.phoneNumber ?? '');
  final bmdcController = TextEditingController();
  String? error;
  bool busy = false;

  final sent = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        Future<void> submit() async {
          final id = idController.text.trim();
          final phone = phoneController.text.trim();
          final bmdc = bmdcController.text.trim();
          if (phone.isEmpty) {
            setState(() => error = 'Phone number is required.');
            return;
          }
          setState(() {
            busy = true;
            error = null;
          });
          try {
            if (id.isEmpty) {
              await DataService.applyForDoctorRole(
                uid: user.uid,
                phone: phone,
                bmdcNumber: bmdc,
                name: user.displayName,
              );
              if (dialogContext.mounted) Navigator.pop(dialogContext, 'listed');
              return;
            }
            final found = await FirestoreService.resolveDoctorForClaim(id);
            if (found == null) {
              setState(() => error = 'No doctor has this Profile ID. Copy it from your profile page.');
            } else if (found.status == 'claimed') {
              setState(() => error = 'This profile is already claimed.');
            } else {
              if (bmdc.isEmpty) {
                setState(() => error = 'BMDC number is required to claim a profile.');
              } else {
                await FirestoreService.claimDoctor(found.id, bmdcRegNumber: bmdc, claimedByUid: user.uid);
                if (dialogContext.mounted) Navigator.pop(dialogContext, 'claim');
                return;
              }
            }
          } catch (e) {
            setState(() => error = 'Could not send: $e');
          }
          setState(() => busy = false);
        }

        return AlertDialog(
          title: const Text('Join as a doctor'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Already listed? Paste your Profile ID (copy it from your doctor page) to claim it. '
                  'Not listed? Leave it empty and the admin will list you.',
                  style: TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: idController,
                  decoration: const InputDecoration(
                    labelText: 'Profile ID (optional)',
                    hintText: 'e.g. doc_1234',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bmdcController,
                  decoration: const InputDecoration(
                    labelText: 'BMDC registration number',
                    hintText: 'e.g. A-12345',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(busy ? 'Sending…' : 'Send to admin'),
            ),
          ],
        );
      },
    ),
  );

  if (sent != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent == 'claim'
          ? 'Claim request sent. The admin will verify your BMDC and link the profile.'
          : 'Application sent. The admin will review it and list you.'),
    ));
  }
  return sent != null;
}
