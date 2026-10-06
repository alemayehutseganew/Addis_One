import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../domain/auth_state.dart';

/// OTP entry.
///
/// Attempts remaining is shown explicitly. A passenger who mistypes a code
/// three times should understand *why* the screen is refusing them, rather than
/// experiencing a silent failure.
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(passengerAuthControllerProvider).state;

    final phone = switch (state) {
      PassengerAuthOtpSent(:final phoneE164) => phoneE164,
      PassengerAuthVerifying(:final phoneE164) => phoneE164,
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(s.enterOtp),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            ref.read(passengerAuthControllerProvider).backToPhone();
            Navigator.of(context).maybePop();
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (phone != null) ...[
                Text(
                  '${s.otpSentTo} ${EthiopianPhone.masked(phone)}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                autofocus: true,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: theme.textTheme.displaySmall,
                // Digits only: a code cannot contain letters, and filtering here
                // avoids a server round-trip on an impossible value.
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••••',
                  errorText: _error,
                ),
                onChanged: (value) {
                  if (value.length == 6 && !_busy) _verify();
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              if (state case final PassengerAuthOtpSent otpState) ...[
                Text(
                  '${otpState.attemptsRemaining} attempts left',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.inkMuted),
                ),
                const SizedBox(height: AppSpacing.md),
                TextButton(
                  onPressed: _busy ? null : _resend,
                  child: Text(s.resendCode),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: _busy ? null : _verify,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(s.verifyAndContinue),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _verify() async {
    final code = _controller.text.trim();
    if (code.length != 6) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final controller = ref.read(passengerAuthControllerProvider);
    final session = await controller.submitCode(code);

    if (!mounted) return;
    setState(() {
      _busy = false;
      final state = controller.state;
      _error = (session == null && state is PassengerAuthFailure) ? state.message : null;
    });

    if (session != null) {
      // GoRouter has no named-route equivalent of pushNamedAndRemoveUntil;
      // go() replaces the stack, which is what "signed in, start fresh" means.
      // Routes.passengerHome ('/passenger/home') rather than a bare '/home':
      // the merged router namespaces every route by role, and an unqualified
      // path falls through to the errorBuilder's "Route not found" page.
      context.go(Routes.passengerHome);
    }
  }

  Future<void> _resend() async {
    setState(() => _busy = true);
    await ref.read(passengerAuthControllerProvider).requestOtp(isResend: true);
    if (!mounted) return;
    setState(() => _busy = false);
  }
}
