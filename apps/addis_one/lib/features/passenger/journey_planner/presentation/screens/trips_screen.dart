import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/widgets/empty_state.dart';
import '../../domain/transport_repository.dart';

/// Trip history — every journey planned, newest first.
///
/// Deliberately not the same list as Tickets. Most searches never become a
/// purchase, and hiding them would make the app look like it forgot the trip
/// the passenger just planned.
class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key});

  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen> {
  late Future<TripsResult> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = ref.read(transportRepositoryProvider).myTrips();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(s.trips)),
      body: FutureBuilder<TripsResult>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.cloud_off_outlined,
              message: s.errorNetwork,
              actionLabel: 'Retry',
              onAction: () => setState(_load),
            );
          }

          final result = snapshot.data!;
          if (!result.signedIn) {
            return EmptyState(
              icon: Icons.person_outline_rounded,
              message: s.signInToSeeTrips,
              actionLabel: s.signIn,
              onAction: () => context.pushNamed(Routes.passengerSignInName),
            );
          }
          if (result.trips.isEmpty) {
            return EmptyState(icon: Icons.route_outlined, message: s.noTripsYet);
          }

          return RefreshIndicator(
            onRefresh: () async => setState(_load),
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: result.trips.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, i) => _TripCard(trip: result.trips[i]),
            ),
          );
        },
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip});

  final PastTrip trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${trip.originLabel} → ${trip.destinationLabel}',
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  trip.totalFare.display,
                  style:
                      theme.textTheme.titleMedium?.copyWith(color: AppColors.green),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${trip.durationLabel} · ${trip.transferCount} transfers',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(
                  trip.wasTravelled
                      ? Icons.confirmation_number_outlined
                      : Icons.bookmark_border,
                  size: 16,
                  color: trip.wasTravelled ? AppColors.green : AppColors.inkMuted,
                ),
                const SizedBox(width: 6),
                // Separates a journey actually travelled from one only searched
                // for, so the list is not read as a record of rides never taken.
                Text(
                  trip.wasTravelled ? 'Ticketed' : 'Planned only',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: trip.wasTravelled ? AppColors.green : AppColors.inkMuted,
                  ),
                ),
                const Spacer(),
                Text(
                  _when(trip.departureTime),
                  style:
                      theme.textTheme.labelSmall?.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _when(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return sameDay ? 'Today $hh:$mm' : '${t.day}/${t.month} $hh:$mm';
  }
}
