import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../core/config/app_config.dart';
import '../../domain/staff_auth_state.dart';
import '../widgets/code_step.dart';
import '../widgets/phone_step.dart';
import '../widgets/sign_in_chrome.dart';

/// Staff sign-in: phone number, then verification code.
///
/// One screen with two steps rather than two routes, because an officer
/// correcting a typo should not trigger a navigation animation on the way back.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _phoneFocus = FocusNode();
  final _codeFocus = FocusNode();

  /// Whether the server currently offers the bypass route.
  ///
  /// Null until answered, so the control stays hidden rather than flashing in
  /// and then disappearing — a button that appears and vanishes reads as a bug.
  bool? _devAvailable;

  @override
  void initState() {
    super.initState();
    // The remembered phone is adopted in build() from the controller's state,
    // which bootstrap() has already populated by the time this screen mounts.
    // Bootstrap itself is started by _Root, not here — see app.dart.
    _phoneCtrl.text = ref.read(staffAuthControllerProvider.notifier).rememberedPhone;

    // Only asked when the build opts in, so a release build spends no round
    // trip discovering a control it will not show.
    if (AppConfig.enableDevSignIn) {
      _probeDevSignIn();
    }

    // A session can already exist by the time this screen mounts: bootstrap()
    // runs from launch and may finish while the role picker is still on
    // screen. The ref.listen in build() only sees transitions, so without this
    // check an officer holding a valid session would face a sign-in form with
    // nowhere to go.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(staffAuthControllerProvider).stage ==
          StaffAuthStage.signedIn) {
        context.go(Routes.staffDuty);
      }
    });
  }

  Future<void> _probeDevSignIn() async {
    final available =
        await ref.read(staffRepositoryProvider).devSignInAvailable();
    if (!mounted) return;
    setState(() => _devAvailable = available);
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _phoneFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(staffAuthControllerProvider);
    final busy = auth.stage == StaffAuthStage.submitting;

    // The controller only records the signed-in stage — moving on is this
    // screen's job. Without this, a successful sign-in (code or the dev
    // shortcut) stores a valid session behind a form that never navigates
    // anywhere, which is exactly how an officer ends up tapping the shortcut
    // repeatedly against a server that is issuing sessions happily.
    ref.listen(staffAuthControllerProvider, (previous, next) {
      if (next.stage == StaffAuthStage.signedIn &&
          previous?.stage != StaffAuthStage.signedIn) {
        context.go(Routes.staffDuty);
      }
    });

    // The remembered number is adopted once, after bootstrap has read it.
    if (auth.phone.isNotEmpty && _phoneCtrl.text.isEmpty) {
      _phoneCtrl.text = auth.phone;
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SignInHeader(),
                  const SizedBox(height: 28),
                  if (auth.error != null) ...[
                    SignInErrorBanner(message: auth.error!),
                    const SizedBox(height: 16),
                  ],
                  if (auth.stage == StaffAuthStage.awaitingCode)
                    CodeStep(
                      phone: auth.phone,
                      controller: _codeCtrl,
                      focusNode: _codeFocus,
                      busy: busy,
                      onSubmit: () => ref
                          .read(staffAuthControllerProvider.notifier)
                          .verifyCode(_codeCtrl.text.trim()),
                      onBack: () {
                        ref
                            .read(staffAuthControllerProvider.notifier)
                            .backToPhone();
                        _codeCtrl.clear();
                      },
                    )
                  else
                    PhoneStep(
                      controller: _phoneCtrl,
                      focusNode: _phoneFocus,
                      busy: busy,
                      onSubmit: () => ref
                          .read(staffAuthControllerProvider.notifier)
                          .requestCode(_phoneCtrl.text.trim()),
                    ),
                  if (_devAvailable == true) ...[
                    const SizedBox(height: 20),
                    DevSignInControl(
                      busy: busy,
                      enabled: auth.stage != StaffAuthStage.awaitingCode,
                      onPressed: () => ref
                          .read(staffAuthControllerProvider.notifier)
                          .devSignIn(_phoneCtrl.text.trim()),
                    ),
                  ],
                  const SizedBox(height: 24),
                  BuildStamp(
                    buildFlavour: AppConfig.buildFlavour,
                    baseUrl: AppConfig.apiBaseUrl,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
