import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/staff_session.dart';
import '../../../admin/presentation/screens/fares_screen.dart';
import '../../../admin/presentation/screens/network_data_screen.dart';
import '../../../admin/presentation/screens/roster_screen.dart';
import '../../../complaints/presentation/screens/complaints_screen.dart';
import '../../../driver/presentation/screens/trips_screen.dart';
import '../../../reports/presentation/screens/reports_screen.dart';
import '../../../shifts/presentation/screens/cash_sale_screen.dart';
import '../../../shifts/presentation/screens/shift_screen.dart';
import '../../../shifts/presentation/screens/variances_screen.dart';
import '../../../validation/presentation/screens/scan_history_screen.dart';
import '../../../validation/presentation/screens/scan_screen.dart';

/// One destination the server said this officer may reach.
class _Duty {
  const _Duty({
    required this.granted,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
    this.emphasise = false,
  });

  /// Reads the flag out of the capability set.
  final bool Function(StaffCapabilities caps) granted;

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  /// Marks the action an officer most likely came to do.
  ///
  /// Purely visual. There is no rule that the app's primary action must be the
  /// scanner — a driver opening the app wants their trip list, and a finance
  /// officer wants revenue — so each role gets its own lead tile.
  final bool emphasise;
}

/// The officer's home screen.
///
/// Replaces the scanner being the app's only destination. One binary serves
/// eleven roles, and a driver opening the handheld wants a trip list while an
/// inspector wants a scanner; showing both to both would mean a menu of buttons
/// that mostly answer 403.
///
/// Every tile below is driven by [StaffCapabilities], which the server derives
/// from the same role lists that guard the routes. That is the whole reason this
/// screen exists instead of a client-side role table — see the `canValidate`
/// regression in `StaffSession`, where a duplicated list offered a scan the
/// server refused.
///
/// The server still enforces everything. Hiding a tile is a courtesy; a tampered
/// build gains nothing but a 403.
class StaffDutyScreen extends ConsumerWidget {
  const StaffDutyScreen({super.key});

  /// Ordered most-used first, so the common case is one tap from the top.
  static final _duties = <_Duty>[
    _Duty(
      granted: (c) => c.canScan,
      icon: Icons.qr_code_scanner,
      title: 'Scan a ticket',
      subtitle: 'Check a ticket at the door',
      emphasise: true,
      builder: (_) => const ScanScreen(),
    ),
    _Duty(
      granted: (c) => c.canOperateTrips,
      icon: Icons.directions_bus,
      title: 'My trips',
      subtitle: "Today's work, start and finish",
      builder: (_) => const TripsScreen(),
    ),
    _Duty(
      granted: (c) => c.canManageShift,
      icon: Icons.point_of_sale,
      title: 'Shift',
      subtitle: 'Open a drawer, declare cash at close',
      builder: (_) => const ShiftScreen(),
    ),
    _Duty(
      granted: (c) => c.canManageShift,
      icon: Icons.payments,
      title: 'Cash sale',
      subtitle: 'Sell a ticket on a passenger\u2019s behalf',
      builder: (_) => const CashSaleScreen(),
    ),
    _Duty(
      granted: (c) => c.canManageShift,
      icon: Icons.smartphone,
      title: 'This handheld',
      subtitle: 'Devices enrolled to your account',
      builder: (_) => const DeviceScreen(),
    ),
    _Duty(
      granted: (c) => c.canScan,
      icon: Icons.history,
      title: 'My scans',
      subtitle: 'Your own recent validations',
      builder: (_) => const ScanHistoryScreen(),
    ),
    _Duty(
      granted: (c) => c.canHandleComplaints,
      icon: Icons.support_agent,
      title: 'Complaints',
      subtitle: 'Work the passenger queue',
      builder: (_) => const ComplaintsScreen(),
    ),
    _Duty(
      granted: (c) => c.canReconcile,
      icon: Icons.balance,
      title: 'Cash variances',
      subtitle: 'Who is short, and by how much',
      builder: (_) => const VariancesScreen(),
    ),
    _Duty(
      granted: (c) => c.canViewReports,
      icon: Icons.insights,
      title: 'Reports',
      subtitle: 'Operations and network performance',
      builder: (_) => const ReportsScreen(),
    ),
    _Duty(
      granted: (c) => c.canViewFinance,
      icon: Icons.payments,
      title: 'Revenue',
      subtitle: 'Money taken, by method and status',
      builder: (_) => const ReportsScreen(financeOnly: true),
    ),
    _Duty(
      granted: (c) => c.canViewDatabase,
      icon: Icons.storage,
      title: 'Database',
      subtitle: 'Sizes, counts and connection use',
      builder: (_) => const ReportsScreen(databaseOnly: true),
    ),
    _Duty(
      granted: (c) => c.canManageNetwork,
      icon: Icons.map_outlined,
      title: 'Stops, routes, vehicles',
      subtitle: 'Network reference data',
      builder: (_) => const NetworkDataScreen(),
    ),
    _Duty(
      granted: (c) => c.canAuthorFares,
      icon: Icons.price_change,
      title: 'Draft a fare',
      subtitle: 'Propose a new fare version',
      builder: (_) => const FaresScreen(authoring: true),
    ),
    _Duty(
      granted: (c) => c.canApproveFares,
      icon: Icons.verified,
      title: 'Sign off fares',
      subtitle: 'Activate a drafted fare version',
      builder: (_) => const FaresScreen(approving: true),
    ),
    _Duty(
      granted: (c) => c.canManageStaff,
      icon: Icons.badge,
      title: 'Staff roster',
      subtitle: 'Roles and employment status',
      builder: (_) => const RosterScreen(),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(staffAuthControllerProvider).session;

    // Unreachable while `app.dart` routes only signed-in states here, but handled
    // rather than asserted: an officer must never see a menu for a role this app
    // failed to learn.
    if (session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final available =
        _duties.where((d) => d.granted(session.capabilities)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Addis One · Staff'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(staffAuthControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _IdentityCard(session: session),
          const SizedBox(height: 18),
          if (available.isEmpty)
            // A real possibility rather than a theoretical one: an officer whose
            // role holds no capability would otherwise see a blank screen and no
            // explanation.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                'Your role has no duties assigned on this handheld. '
                'Contact your supervisor if that looks wrong.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          else
            ...available.map((d) => _DutyTile(duty: d)),
        ],
      ),
    );
  }
}

/// Who is signed in, and how much of the city they can see.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.session});

  final StaffSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.displayName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              session.role.isEmpty ? 'Role unknown' : _prettyRole(session.role),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            // Worth saying plainly: an operator-scoped officer looking at a short
            // list needs to know the rest exists before concluding it is empty.
            Text(
              session.capabilities.cityWide
                  ? 'City-wide access'
                  : 'Scoped to your operator',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `TRANSPORT_BUREAU_ADMIN` reads as `Transport Bureau Admin`.
  static String _prettyRole(String role) {
    return role
        .toLowerCase()
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}

/// A single destination.
///
/// The emphasised variant is a colour change and a bolder title, nothing more.
/// Tempting as it would be to also reorder the list so the lead action is first,
/// the order is fixed by how often each duty is used across all roles — and only
/// an inspector scans often enough to justify putting it above a driver's own
/// trip list.
class _DutyTile extends StatelessWidget {
  const _DutyTile({required this.duty});

  final _Duty duty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emphasised = duty.emphasise;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: emphasised ? theme.colorScheme.primaryContainer : null,
        child: ListTile(
          contentPadding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: emphasised ? 12 : 6,
          ),
          leading: Icon(duty.icon, size: emphasised ? 34 : 28),
          title: Text(
            duty.title,
            style: emphasised
                ? theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)
                : theme.textTheme.titleSmall,
          ),
          subtitle: Text(duty.subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: duty.builder),
          ),
        ),
      ),
    );
  }
}
