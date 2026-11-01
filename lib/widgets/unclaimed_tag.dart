import 'package:flutter/material.dart';

/// Marks a listed doctor who has no DoctorDesk account yet, so patients know
/// the profile is information only and cannot be booked here.
class UnclaimedTag extends StatelessWidget {
  const UnclaimedTag({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Unclaimed profile. Online booking is not available.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade400),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_busy_outlined, size: 12, color: Colors.grey.shade700),
            const SizedBox(width: 4),
            Text(
              'Unclaimed · not bookable yet',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
