import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/app_role.dart';
import '../core/localization.dart';
import 'providers.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget.
///
/// Owns the theme, the active locale, the router, and the selected [AppRole].
///
/// ## Why the role lives here rather than in a provider
///
/// The role has to reach three places that are all created before the first
/// frame -- the router's redirect, the composition root's token storage, and the
/// initial location. Holding it as `State` on this widget means all three read
/// the same value in the same build, with no ordering question about which
/// provider has run. It is mirrored into [selectedRoleProvider] so the rest of
/// the tree can watch it, and that mirror is written in one place, right here.
///
/// The consequence worth stating: changing role tears down and rebuilds the
/// client stack. That is the point. A passenger token must not survive a switch
/// to staff.
class AddisOneApp extends ConsumerStatefulWidget {
  const AddisOneApp({super.key, this.initialLocale = AppLocale.am});

  /// Amharic by default -- the working language of the conductors and ticket
  /// officers who issue assisted (cash) tickets.
  final AppLocale initialLocale;

  @override
  ConsumerState<AddisOneApp> createState() => _AddisOneAppState();
}

class _AddisOneAppState extends ConsumerState<AddisOneApp> {
  late AppLocale _locale = widget.initialLocale;

  /// Null until someone picks a role on the picker.
  ///
  /// Held as state so a rebuild does not reset it; the provider mirror keeps the
  /// rest of the tree in step.
  AppRole? _role;

  /// Fires whenever [_role] changes, so go_router re-runs the redirect.
  ///
  /// A router constructed once cannot see a value that changed after it was
  /// built. `refreshListenable` is the supported way to close that gap, and
  /// without it the role guard would only be consulted on navigation events,
  /// leaving a deep link sitting on a screen the current role may not see.
  final ValueNotifier<AppRole?> _roleNotifier = ValueNotifier<AppRole?>(null);

  late final GoRouter _router = _buildRouter();

  @override
  void initState() {
    super.initState();
    // Published here rather than in build, because modifying a provider during
    /// build is not allowed in Riverpod. The callback closes over `this`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(changeRoleActionProvider.notifier).state = _changeRole;
      }
    });
  }

  void _setLocale(AppLocale locale) {
    if (locale == _locale) return;
    setState(() => _locale = locale);
  }

  /// Called by the role picker. See the class comment for why this replaces the
  /// client stack rather than merely navigating.
  void _selectRole(AppRole role) {
    setState(() => _role = role);
    _roleNotifier.value = role;
    ref.read(selectedRoleProvider.notifier).state = role;
    // `go`, not `push`: switching roles is a change of identity, not a step
    // forward. Leaving the previous half's screens on the back stack would let
    // Back return to a signed-out passenger home from inside the staff half.
    _router.go(signInFor(role));
  }

  /// Returns to the picker, ending whichever session was active.
  ///
  /// Signing out is handled by the two halves' own screens; this is only the
  /// escape hatch back to the fork. It clears the stored credential for the role
  /// being left, so picking the other one cannot inherit it.
  Future<void> _changeRole() async {
    final role = _role;
    if (role != null) {
      await ref.read(tokenStorageProvider).clearSession();
    }
    setState(() => _role = null);
    _roleNotifier.value = null;
    ref.read(selectedRoleProvider.notifier).state = null;
    _router.go(Routes.roleSelect);
  }

  GoRouter _buildRouter() {
    return buildRouter(
      onLocaleSelected: _setLocale,
      onRoleSelected: _selectRole,
      onChangeRole: _changeRole,
      // The redirect re-reads this on every navigation and whenever the notifier
      // fires, so the guard stays in step with the role held here rather than
      // with a value captured when the router was constructed.
      roleReader: () => _role,
      roleListenable: _roleNotifier,
    );
  }

  @override
  void dispose() {
    _roleNotifier.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = _locale == AppLocale.am ? AppStrings.am : AppStrings.en;

    return AppStringsScope(
      strings: strings,
      child: MaterialApp.router(
        title: strings.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        routerConfig: _router,
        locale: Locale(_locale.code),
        supportedLocales: const [Locale('am'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
      ),
    );
  }
}