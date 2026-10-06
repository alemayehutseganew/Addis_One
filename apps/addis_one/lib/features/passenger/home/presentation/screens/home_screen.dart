import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/config/app_config.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/journey.dart';
import '../../../../../core/models/journey_plan.dart';
import '../../../location/domain/location_lookup_controller.dart';
import '../../../location/domain/location_service.dart';

/// Home screen.
///
/// Layout follows the brief: destination prompt first, primary action, then
/// mode shortcuts. The order is deliberate ——— on a phone held one-handed on a
/// moving bus, the most-used controls sit in the thumb zone at the bottom.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.onLocaleSelected});

  final ValueChanged<AppLocale> onLocaleSelected;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final signedIn = ref.watch(isPassengerSignedInProvider);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _Header(s: s, signedIn: signedIn),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.md,
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: AppSpacing.md),
                  _TripStartCard(s: s),
                  const SizedBox(height: AppSpacing.lg),
                  _ModeGrid(s: s),
                  const SizedBox(height: AppSpacing.lg),
                  _NearbyTransport(s: s),
                ]),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomNav(
        s: s,
        // Not tracked locally: the tab reflects where the user actually is, so
        // a highlighted destination always matches the content above it. Holding
        // an index in state lets the bar show "Profile" over the home screen.
        index: _currentTab(context),
        onChanged: (index) => _onTab(context, index),
      ),
    );
  }

  /// The tab that matches the current route, so the highlight never disagrees
  /// with the content above it.
  int _currentTab(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    for (var i = 0; i < _tabRoutes.length; i++) {
      final route = _tabRoutes[i];
      if (route != null && path.endsWith(route)) return i;
    }
    return 0;
  }

  /// Destination route per tab index; null means "home", which pops.
  static const _tabRoutes = <String?>[
    null,
    Routes.ticketsName,
    Routes.tripsName,
    Routes.profileName,
  ];

  void _onTab(BuildContext context, int index) {
    // Every destination now has a screen, so none of these are placeholders. A
    // tab that highlights and then does nothing is worse than no tab at all.
    const routes = <String?>[
      null, // Home: pop back rather than pushing a second home screen
      Routes.ticketsName,
      Routes.tripsName,
      Routes.profileName,
    ];

    final route = routes[index];
    if (route == null) {
      if (context.canPop()) context.pop();
      return;
    }

    // Already on this tab: popping avoids stacking duplicates every time the
    // passenger taps the same destination.
    if (GoRouterState.of(context).uri.path.endsWith(route)) {
      if (context.canPop()) context.pop();
      return;
    }
    _navigate(context, route);
  }

  /// Called by the header language toggle.
  void _setLocaleFromToggle(AppLocale locale) {
    widget.onLocaleSelected(locale);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.s, required this.signedIn});

  final AppStrings s;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.greenLight,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.directions_transit_rounded,
                  color: AppColors.green,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  s.appName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              // Sign-in lives in the header so the auth flow is reachable
              // rather than stranded behind a tab with no content yet.
              IconButton(
                onPressed: () => _openSignIn(context),
                icon: Icon(
                  signedIn ? Icons.person_rounded : Icons.login_rounded,
                  color: AppColors.green,
                ),
                tooltip: signedIn ? 'Account' : s.signIn,
              ),
              const _LanguageToggle(),
            ],
          ),
          const _ConnectionBanner(),
        ],
      ),
    );
  }
}


/// The primary call to action: where am I going?
/// How the passenger starts a trip: by planning where to go, or by boarding a
/// vehicle whose code they already have.
enum _TripStartMode { plan, vehicleCode }

/// Single card for both ways of starting a trip.
///
/// Planning a journey and boarding a known vehicle were two separate cards
/// stacked down the screen. They answer the same question — "how do I start
/// this trip?" — so they now share one card and one primary action, switched
/// with [_TripStartMode]. A passenger holding a phone one-handed on a moving
/// bus should not have to work out which of two similar cards is theirs.
///
/// Planning stays the default: it is the broader action, and boarding is a
/// single tap away. The vehicle-code branch keeps the origin fields out of the
/// way, because someone standing at a vehicle is not choosing a route — they
/// are paying to get on the bus in front of them.
class _TripStartCard extends StatefulWidget {
  const _TripStartCard({required this.s});

  final AppStrings s;

  @override
  State<_TripStartCard> createState() => _TripStartCardState();
}

class _TripStartCardState extends State<_TripStartCard> {
  _TripStartMode _mode = _TripStartMode.plan;

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.whereTo, style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                _TripStartSwitch(
                  mode: _mode,
                  onChanged: (mode) => setState(() => _mode = mode),
                ),
                const SizedBox(height: AppSpacing.md),
                if (_mode == _TripStartMode.plan) ..._planBranch(context, s)
                else ..._vehicleBranch(context, s),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Acquires a real fix and resolves it to the nearest stop, then opens the
  /// planner with that origin already filled in. Tapping the destination row
  /// still just opens the planner.
  List<Widget> _planBranch(BuildContext context, AppStrings s) {
    return [
      _CurrentLocationField(
        icon: Icons.my_location_rounded,
        iconColor: AppColors.green,
      ),
      const SizedBox(height: AppSpacing.sm),
      _LocationField(
        icon: Icons.search_rounded,
        iconColor: AppColors.inkMuted,
        label: s.searchDestination,
        // Tapping either location field opens the planner, which is where
        // origin and destination are chosen. A tappable-looking row that only
        // shows a snackbar is worse than no affordance.
        onTap: () => _openPlanner(context),
      ),
      const SizedBox(height: AppSpacing.md),
      FilledButton.icon(
        onPressed: () => _openPlanner(context),
        icon: const Icon(Icons.route_rounded),
        label: Text(s.planJourney),
      ),
    ];
  }

  /// The boarding branch of the vehicle-code flow (steps 1–16).
  ///
  /// The code itself is typed on the dedicated vehicle-code screen rather than
  /// here: that screen owns validation, the not-found terminal, and the retry,
  /// and duplicating the input in two places invites the two to disagree about
  /// what a valid code looks like.
  List<Widget> _vehicleBranch(BuildContext context, AppStrings s) {
    final theme = Theme.of(context);

    return [
      _LocationField(
        icon: Icons.directions_bus_filled_outlined,
        iconColor: AppColors.yellowDark,
        label: s.vehicleCodeTitle,
        onTap: () => _openVehicleCode(context),
      ),
      const SizedBox(height: AppSpacing.sm),
      Text(
        s.vehicleCodeHelp,
        style: theme.textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
      ),
      const SizedBox(height: AppSpacing.md),
      FilledButton.icon(
        onPressed: () => _openVehicleCode(context),
        icon: const Icon(Icons.login_rounded),
        label: Text(s.searchVehicle),
      ),
    ];
  }
}

/// The origin row: acquires a position and names the stop it resolved to.
///
/// Shows the resolved stop name and its distance rather than silently jumping
/// to it, so the passenger can check the app picked the stop they are actually
/// standing at. An origin they cannot verify is an origin they will not trust.
class _CurrentLocationField extends ConsumerWidget {
  const _CurrentLocationField({
    required this.icon,
    required this.iconColor,
  });

  final IconData icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStringsScope.of(context);
    final lookup = ref.watch(locationLookupProvider);

    final label = switch (lookup) {
      LocationResting() => s.currentLocation,
      LocationPending() => s.locatingYou,
      LocationFound(:final stop) =>
        '${stop.place.displayName(isAmharic: s.isAmharic)} · '
            '${stop.displayDistance}',
      LocationDeclined(:final reason) => _describeFailure(context, reason),
      LocationUnavailable(:final reason) => _describeFailure(context, reason),
    };

    return _LocationField(
      icon: icon,
      iconColor: iconColor,
      label: label,
      // Disabled while a request is in flight so the field cannot be spammed
      // into duplicate permission prompts.
      onTap: lookup.isPending
          ? null
          : () => _useCurrentLocation(context, ref),
    );
  }

  /// Each failure gets the wording that describes it. The recovery differs —
  /// re-requesting permission, sending the passenger to settings, or simply
  /// retrying — so the reasons are kept distinct all the way to the UI instead
  /// of collapsing into one generic "unavailable".
  static String _describeFailure(
    BuildContext context,
    LocationFailureReason reason,
  ) {
    final s = AppStringsScope.of(context);
    return switch (reason) {
      LocationFailureReason.serviceDisabled => s.locationOff,
      LocationFailureReason.permissionDenied => s.locationPermissionDenied,
      LocationFailureReason.permissionDeniedForever =>
        s.locationPermissionForever,
      LocationFailureReason.timeout => s.locationNoFix,
      // A fix did arrive here; it was just too coarse to name a stop. Reporting
      // "could not get a fix" would send the passenger to check a GPS that had
      // worked perfectly.
      LocationFailureReason.tooInaccurate => s.locationTooInaccurate,
      LocationFailureReason.outsideServiceArea => s.locationOutsideServiceArea,
      // GPS and search both fine; the request itself failed.
      LocationFailureReason.lookupFailed => s.locationLookupFailed,
      LocationFailureReason.unknown => s.locationNoFix,
    };
  }

  Future<void> _useCurrentLocation(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final lookup = ref.read(locationLookupProvider);

    // Already resolved from a previous tap: go straight to the planner rather
    // than re-acquiring a fix the passenger did not ask to refresh.
    if (lookup is LocationFound) {
      _openPlanner(context, origin: lookup.stop.place);
      return;
    }

    await ref.read(locationLookupProvider.notifier).locate();
    if (!context.mounted) return;

    final result = ref.read(locationLookupProvider);
    if (result is LocationFound) {
      _openPlanner(context, origin: result.stop.place);
    }
  }
}

class _LocationField extends StatelessWidget {
  const _LocationField({
    required this.icon,
    required this.iconColor,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.inkMuted),
          ],
        ),
      ),
    );
  }
}

/// Two-way switch between planning a trip and boarding a vehicle.
///
/// Hand-built rather than using [SegmentedButton] so the selection pill matches
/// the rounded, bordered look of the rest of the card. Amharic labels are wider
/// than their English equivalents, so each segment clips its own label instead
/// of letting a long word push the row wider than the screen.
class _TripStartSwitch extends StatelessWidget {
  const _TripStartSwitch({required this.mode, required this.onChanged});

  final _TripStartMode mode;
  final ValueChanged<_TripStartMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.greenLight,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          _segment(context, _TripStartMode.plan, s.planJourney),
          _segment(context, _TripStartMode.vehicleCode, s.vehicleCode),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    _TripStartMode value,
    String label,
  ) {
    final theme = Theme.of(context);
    final selected = value == mode;

    // The pill sits inset by the track's padding, so its corner radius is
    // reduced to match — otherwise the pill bulges past the track's curve at
    // the edges.
    final radius = AppRadius.sm - AppSpacing.xs;

    return Expanded(
      child: InkWell(
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: selected ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? AppColors.green : AppColors.inkMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Transport mode shortcuts.
class _ModeGrid extends StatelessWidget {
  const _ModeGrid({required this.s});
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final modes = <(TransportMode, String, Color)>[
      (TransportMode.bus, s.bus, AppColors.modeBus),
      (TransportMode.taxi, s.taxi, AppColors.modeTaxi),
      (TransportMode.train, s.train, AppColors.modeTrain),
    ];

    return Row(
      children: [
        for (var i = 0; i < modes.length; i++) ...[
          Expanded(
            child: _ModeCard(
              mode: modes[i].$1,
              label: modes[i].$2,
              color: modes[i].$3,
              onTap: () => _openPlanner(context),
            ),
          ),
          if (i != modes.length - 1) const SizedBox(width: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.mode,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final TransportMode mode;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(_iconFor(mode), color: color, size: 22),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(label, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(TransportMode mode) {
    switch (mode) {
      case TransportMode.bus:
        return Icons.directions_bus_rounded;
      case TransportMode.taxi:
        return Icons.local_taxi_rounded;
      case TransportMode.train:
        return Icons.train_rounded;
      case TransportMode.walk:
        return Icons.directions_walk_rounded;
    }
  }
}

/// Nearby departures.
///
/// ETA values carry a [DataFreshness] so the UI never presents a stale
/// estimate as live. A "2 min" claim computed from a 15-minute-old GPS fix is
/// worse than admitting uncertainty.
class _NearbyTransport extends StatelessWidget {
  const _NearbyTransport({required this.s});
  final AppStrings s;

  static const _sample = <(TransportMode, String, int, DataFreshness)>[
    (TransportMode.bus, 'Route 12 · Piazza', 5, DataFreshness.unknown),
    (TransportMode.bus, 'Route 3 · Bole', 11, DataFreshness.unknown),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Nearby', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            // No GPS feed is wired up, so the ETAs below are not predictions.
            // Saying so prevents a passenger from waiting for a bus on a number
            // the system never computed.
            Text(
              'No live data',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: AppColors.inkMuted),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < _sample.length; i++) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Card(
              child: ListTile(
                leading: Icon(
                  _ModeCard._iconFor(_sample[i].$1),
                  color: AppColors.modeBus,
                ),
                title: Text(_sample[i].$2),
                subtitle: _sample[i].$4.isUnreliable
                    ? Text(
                        _sample[i].$4 == DataFreshness.stale
                            ? 'Live position unavailable'
                            : 'Scheduled time',
                        style: const TextStyle(color: AppColors.inkMuted),
                      )
                    : null,
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${_sample[i].$3} ${s.minutes}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    _FreshnessDot(freshness: _sample[i].$4),
                  ],
                ),
                onTap: () => _openPlanner(context),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _FreshnessDot extends StatelessWidget {
  const _FreshnessDot({required this.freshness});
  final DataFreshness freshness;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (freshness) {
      DataFreshness.realTime => (AppColors.green, 'Live'),
      DataFreshness.estimated => (AppColors.yellowDark, 'Est.'),
      DataFreshness.scheduled => (AppColors.inkMuted, 'Sched.'),
      DataFreshness.stale => (AppColors.red, 'Stale'),
      DataFreshness.unknown => (AppColors.inkMuted, '—'),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.s,
    required this.index,
    required this.onChanged,
  });

  final AppStrings s;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onChanged,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
          label: s.home,
        ),
        NavigationDestination(
          icon: const Icon(Icons.confirmation_num_outlined),
          selectedIcon: const Icon(Icons.confirmation_num_rounded),
          label: s.tickets,
        ),
        NavigationDestination(
          icon: const Icon(Icons.route_outlined),
          selectedIcon: const Icon(Icons.route_rounded),
          label: s.trips,
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline_rounded),
          selectedIcon: const Icon(Icons.person_rounded),
          label: s.profile,
        ),
      ],
    );
  }
}

/// Opens the journey planner.
///
/// Wrapped rather than called inline so a routing failure surfaces as a message
/// to the passenger instead of an unhandled exception. A primary button that
/// throws leaves the user staring at a screen that did nothing, which is
/// indistinguishable from a broken app.
void _openPlanner(BuildContext context, {Place? origin}) {
  // [origin] preselects the starting stop. The current-location field has
  // already resolved a real stop, so the passenger should not be asked to pick
  // the origin they are standing at.
  _navigate(
    context,
    Routes.planJourneyName,
    extra: origin == null ? null : {'origin': origin},
  );
}

void _openSignIn(BuildContext context) {
  _navigate(context, Routes.passengerSignInName);
}

/// Opens the vehicle-code boarding flow.
///
/// Routed through [_navigate] for the same reason as [_openPlanner]: a routing
/// mistake surfaces as a message rather than an unhandled exception from a
/// button the passenger is tapping while standing at a bus.
void _openVehicleCode(BuildContext context) {
  _navigate(context, Routes.vehicleCodeName);
}

void _navigate(BuildContext context, String name, {Object? extra}) {
  try {
    context.pushNamed(name, extra: extra);
  } catch (error) {
    debugPrint('navigation to "$name" failed: $error');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('That screen is not available yet'),
          duration: Duration(seconds: 2),
        ),
      );
  }
}

/// Shows which data source this build is using.
///
/// A demo build and a live build must never be indistinguishable: otherwise a
/// screenshot of demo itineraries could be mistaken for a working production
/// app. The banner names the actual API URL so the two are always separable.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner();

  @override
  Widget build(BuildContext context) {
    final demo = AppConfig.useDemoData;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: demo ? AppColors.yellowLight : AppColors.greenLight,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: demo ? AppColors.yellow : AppColors.green,
          ),
        ),
        child: Row(
          children: [
            Icon(
              demo ? Icons.science_outlined : Icons.cloud_done_outlined,
              size: 14,
              color: demo ? AppColors.yellowDark : AppColors.green,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                demo
                    ? 'Demo data · ${AppConfig.apiBaseUrl}'
                    : 'Live · ${AppConfig.apiBaseUrl}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: demo ? AppColors.yellowDark : AppColors.green,
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact am/en switch.
///
/// Full language selection is its own onboarding screen; this is the
/// always-available escape hatch for a passenger who needs English mid-journey
/// and should not have to sign out to change it.
class _LanguageToggle extends StatelessWidget {
  const _LanguageToggle();

  @override
  Widget build(BuildContext context) {
    final current = AppStringsScope.of(context).locale;

    return PopupMenuButton<AppLocale>(
      tooltip: 'Language',
      initialValue: current,
      onSelected: (locale) => context
          .findAncestorStateOfType<_HomeScreenState>()
          ?._setLocaleFromToggle(locale),
      itemBuilder: (context) => AppLocale.values
          .map((l) => PopupMenuItem(value: l, child: Text(l.nativeLabel)))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text(
          current.nativeLabel,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    );
  }
}

