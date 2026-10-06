import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';
import '../../../../../core/models/scan_outcome.dart';

/// The verdict card shown after a scan.
///
/// Sized to be read at arm's length in a moving vehicle: the headline is
/// [headline] in large type, and the meaning is carried by an icon and a word as
/// well as by colour — a hue alone would be unreadable in glare and invisible to
/// a colour-blind officer.
class VerdictCard extends StatelessWidget {
  const VerdictCard({
    super.key,
    required this.result,
    required this.isDeferred,
  });

  final ScanResult result;

  /// True when the server was unreachable and the ticket was parked locally.
  final bool isDeferred;

  @override
  Widget build(BuildContext context) {
    final outcome = result.outcome;
    final color = isDeferred ? AppColors.verdictUnknown : outcome.color;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(outcome.icon, size: 64, color: Colors.white),
          const SizedBox(height: 10),
          Text(
            outcome.headline,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            result.reason,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35),
          ),
          if (result.ticketReference != null) ...[
            const SizedBox(height: 14),
            _MetaRow(label: 'Ticket', value: result.ticketReference!),
          ],
          _MetaRow(label: 'Validation ref', value: result.validationReference),
          if (result.isUnrecorded)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'This attempt could not be written to the audit trail. Report '
                'it to your supervisor.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
