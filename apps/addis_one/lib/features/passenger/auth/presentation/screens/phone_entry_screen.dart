import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/config/app_config.dart';
import '../../../../../core/localization.dart';
import '../../domain/auth_state.dart';

/// Phone entry.
///
/// Validation happens in the controller, not here, so the rules are the same
/// ones the tests cover and cannot drift from the widget's own idea of valid.
class PhoneEntryScreen extends ConsumerStatefulWidget {
  const PhoneEntryScreen({super.key});

  @override
  ConsumerState<PhoneEntryScreen> createState() => _PhoneEntryScreenState();
}

class _PhoneEntryScreenState extends ConsumerState<PhoneEntryScreen> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _error;

  /// Whether the shortcut is shown.
  ///
  /// Starts false and is only ever set true by a successful probe, so the
  /// control cannot flash on screen before the server has confirmed the route
  /// exists.
  bool _devSignInOffered = false;

  @override
  void initState() {
    super.initState();
    // Probed from initState rather than from the build method: build runs on
    // every keystroke, and a round trip per keystroke is not a thing to ship.
    // Guarded by the build flag so a release build makes no request at all.
    if (AppConfig.enableDevSignIn) {
      ref
          .read(passengerAuthControllerProvider)
          .devSignInAvailable()
          .then((available) {
            if (mounted && available) {
              setState(() => _devSignInOffered = true);
            }
          });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(s.signIn)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.phoneNumber, style: theme.textTheme.headlineSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '09XX XXX XXX',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.inkMuted),
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  controller: _controller,
                  keyboardType: TextInputType.phone,
                  autofocus: true,
                  style: theme.textTheme.titleLarge,
                  decoration: InputDecoration(
                    hintText: s.phoneHint,
                    prefixIcon: const Icon(Icons.phone_rounded),
                    errorText: _error,
                  ),
                  validator: (value) {
                    final normalized =
                        EthiopianPhone.normalize(value ?? '');
                    return normalized == null ? s.invalidPhone : null;
                  },
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: _submit,
                  child: Text(s.continueLabel),
                ),
                if (_devSignInOffered) ...[
                  const SizedBox(height: AppSpacing.md),
                  TextButton(
                    onPressed: _devSignIn,
                    child: const Text('Sign in without a code'),
                  ),
                  Text(
                    'Development shortcut. Skips verification — not for a real '
                    'deployment.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.inkMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Signs in without an OTP, for field testing.
  ///
  /// Offered only when the build asked for it *and* the server confirmed the
  /// route is registered. Both checks are needed: the build flag stops a release
  /// build spending a round trip, and the server probe stops a development build
  /// offering a button that would 404.
  Future<void> _devSignIn() async {
    final controller = ref.read(passengerAuthControllerProvider);
    final session = await controller.devSignIn(_controller.text);
    if (!mounted) return;

    if (session == null) {
      final state = controller.state;
      setState(() {
        _error = state is PassengerAuthFailure ? state.message : null;
      });
      return;
    }
    context.go(Routes.passengerHome);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final controller = ref.read(passengerAuthControllerProvider);
    final ok = await controller.submitPhone(_controller.text);
    if (!mounted) return;

    if (ok) {
      await controller.requestOtp();
      if (mounted) context.push(Routes.passengerOtp);
    } else {
      final state = controller.state;
      setState(() {
        _error = state is PassengerAuthFailure ? state.message : null;
      });
    }
  }
}
