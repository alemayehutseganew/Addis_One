import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';

/// Identifies the officer holding the device and the role that permits scanning.
///
/// Worth the vertical space: a handset left on a desk must not reach the next
/// officer without it being obvious whose session is live, and a scan recorded
/// against the wrong person is an audit problem that is hard to unpick later.
class OfficerBar extends StatelessWidget {
  const OfficerBar({
    super.key,
    required this.displayName,
    required this.role,
  });

  final String displayName;
  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: StaffColors.greenDark,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.badge, color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$displayName · $role',
              style: const TextStyle(color: Colors.white, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Explains, in the officer's own terms, that their role cannot scan.
///
/// Shown instead of the camera rather than after a 403, because an officer who
/// does not know why they cannot scan will keep trying.
class NoScanRightsNotice extends StatelessWidget {
  const NoScanRightsNotice({super.key, required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.no_accounts, size: 64, color: AppColors.inkMuted),
            const SizedBox(height: 16),
            const Text(
              'Your role cannot scan',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'You are signed in as $role. Ticket validation is reserved for '
              'inspectors, conductors, ticket officers, supervisors and '
              'administrators.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppColors.inkMuted),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
