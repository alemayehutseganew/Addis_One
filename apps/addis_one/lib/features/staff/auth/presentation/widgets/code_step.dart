import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../app/theme.dart';

/// Verification code entry, the second sign-in step.
class CodeStep extends StatelessWidget {
  const CodeStep({
    super.key,
    required this.phone,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSubmit,
    required this.onBack,
  });

  final String phone;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSubmit;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Code sent to $phone',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.inkMuted,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: !busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          // Digits only, and capped at six: the server's DTO rejects anything
          // else, and this keeps a pasted "code 123456 (expires 5m)" from
          // failing server-side for no visible reason.
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => onSubmit(),
          style: const TextStyle(
            fontSize: 32,
            letterSpacing: 10,
            fontWeight: FontWeight.w700,
          ),
          decoration: const InputDecoration(
            labelText: 'Verification code',
            hintText: '······',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : onSubmit,
          child: Text(busy ? 'Verifying…' : 'Sign in'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: busy ? null : onBack,
          child: const Text('Use a different number'),
        ),
      ],
    );
  }
}
