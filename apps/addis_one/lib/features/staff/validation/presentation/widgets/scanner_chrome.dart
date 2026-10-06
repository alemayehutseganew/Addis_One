import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';

/// Framing guide drawn over the camera preview.
///
/// Purely visual: the camera does not restrict detection to this box, and
/// pretending otherwise would silently drop valid tickets scanned slightly
/// off-centre at a moving door.
class ScannerReticle extends StatelessWidget {
  const ScannerReticle({super.key});

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: Center(
        child: SizedBox(
          width: 230,
          height: 230,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.fromBorderSide(
                BorderSide(color: Colors.white70, width: 3),
              ),
              borderRadius: BorderRadius.all(Radius.circular(18)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the camera cannot start or has no usable permission.
///
/// Manual entry is offered here rather than being buried. A scratched ticket, a
/// broken camera, or a device issued without one must not leave an inspector
/// unable to work the door.
class CameraUnavailable extends StatelessWidget {
  const CameraUnavailable({super.key, required this.onManualEntry});

  final VoidCallback onManualEntry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.ink,
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography, size: 56, color: Colors.white54),
          const SizedBox(height: 14),
          const Text(
            'Camera unavailable',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'You can still validate by entering the ticket code by hand.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onManualEntry,
            icon: const Icon(Icons.keyboard),
            label: const Text('Enter code manually'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white54),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }
}
