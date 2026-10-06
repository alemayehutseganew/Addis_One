import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';

/// Red inline banner for a failed sign-in step.
///
/// Treated as a warning rather than a modal dialog: an officer mid-shift needs
/// to read the cause and correct one field, not dismiss a dialog to get back to
/// the form.
class SignInErrorBanner extends StatelessWidget {
  const SignInErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.verdictRefuse.withValues(alpha: 0.08),
        border: const Border(
          left: BorderSide(color: AppColors.verdictRefuse, width: 4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.verdictRefuse, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 14, color: AppColors.verdictRefuse),
            ),
          ),
        ],
      ),
    );
  }
}

/// Names the build and its target on screen.
///
/// A field handset is the app most likely to be pointed at the wrong
/// environment by accident — devices are swapped between testers without
/// ceremony — and the base URL is a compile-time constant and therefore
/// invisible at runtime. An officer reporting "the scanner is broken" is far
/// easier to help when this line is on a screenshot.
class BuildStamp extends StatelessWidget {
  const BuildStamp({super.key, required this.buildFlavour, required this.baseUrl});

  final String buildFlavour;
  final String baseUrl;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$buildFlavour build · ${baseUrl.replaceFirst(RegExp(r'^https?://'), '')}',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 11, color: AppColors.inkMuted),
    );
  }
}

/// App identity block shown above the sign-in form.
class SignInHeader extends StatelessWidget {
  const SignInHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: StaffColors.green,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.fact_check, size: 40, color: Colors.white),
        ),
        const SizedBox(height: 16),
        const Text(
          'Addis One',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          'Staff Inspector',
          style: TextStyle(
            fontSize: 16,
            color: AppColors.inkMuted,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
