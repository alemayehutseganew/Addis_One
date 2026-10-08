import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
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

  /// Whether the temporary username/password form is shown (until SMS live).
  ///
  /// Null until answered, same no-flash rule as [_devAvailable]. Probed
  /// unconditionally: this form is MEANT for field-test builds.
  bool? _testLoginAvailable;
  final _testUserCtrl = TextEditingController();
  final _testPassCtrl = TextEditingController();
  bool _testObscured = true;

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
    // The test login IS meant for field builds, so this probe is
    // unconditional — but still fails closed when the server 404s.
    _probeTestLogin();

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

  Future<void> _probeTestLogin() async {
    final available =
        await ref.read(staffRepositoryProvider).passwordLoginAvailable();
    if (!mounted) return;
    setState(() => _testLoginAvailable = available);
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _testUserCtrl.dispose();
    _testPassCtrl.dispose();
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
                  if (_testLoginAvailable == true) ...[
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 12),
                    const Text(
                      'Test sign-in (no SMS needed)',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _testUserCtrl,
                      enabled: !busy,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        hintText: 'staff',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _testPassCtrl,
                      enabled: !busy,
                      obscureText: _testObscured,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => ref
                          .read(staffAuthControllerProvider.notifier)
                          .passwordLogin(
                            _testUserCtrl.text,
                            _testPassCtrl.text,
                          ),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _testObscured
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(
                            () => _testObscured = !_testObscured,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => ref
                              .read(staffAuthControllerProvider.notifier)
                              .passwordLogin(
                                _testUserCtrl.text,
                                _testPassCtrl.text,
                              ),
                      icon: const Icon(Icons.key_outlined, size: 20),
                      label: Text(busy ? 'Signing in…' : 'Sign in as staff/test123'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: StaffColors.green,
                        side: const BorderSide(color: StaffColors.green),
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Temporary until SMS delivery is approved.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.verdictUnknown),
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
