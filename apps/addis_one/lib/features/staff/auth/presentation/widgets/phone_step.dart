import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';

/// Development-only sign-in bypass.
///
/// Rendered solely because the server confirmed the route exists, so a
/// production build never shows a control whose every press would 404.
class DevSignInControl extends StatelessWidget {
  const DevSignInControl({
    super.key,
    required this.busy,
    required this.enabled,
    required this.onPressed,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: (busy || !enabled) ? null : onPressed,
          icon: const Icon(Icons.developer_mode, size: 20),
          label: Text(busy ? 'Signing in…' : 'Sign in without a code'),
          style: OutlinedButton.styleFrom(
            foregroundColor: StaffColors.green,
            side: const BorderSide(color: StaffColors.green),
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Development shortcut. Skips verification — not for a real deployment.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.verdictUnknown),
        ),
      ],
    );
  }
}

/// Number entry, the first of the two sign-in steps.
class PhoneStep extends StatelessWidget {
  const PhoneStep({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: !busy,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          style: const TextStyle(fontSize: 20, letterSpacing: 0.5),
          decoration: const InputDecoration(
            labelText: 'Staff mobile number',
            hintText: '+251911000007',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy ? null : onSubmit,
          child: Text(busy ? 'Working…' : 'Send verification code'),
        ),
        const SizedBox(height: 12),
        const Text(
          'A six-digit code is sent to your mobile. In development it is also '
          'written to the server log.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
        ),
      ],
    );
  }
}
