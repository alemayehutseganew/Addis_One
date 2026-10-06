import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/journey.dart';
import '../../../../../core/models/journey_plan.dart';
import 'purchase_flow_screen.dart';

/// Journey results.
///
/// Each option shows fare, duration and transfer count at a glance. The fare is
/// rendered exactly as the server returned it ——— this screen never computes a
/// fare, because a client-side calculation that disagrees with the backend
/// produces a quote the passenger agreed to that the system cannot honour.
class JourneyResultsScreen extends StatelessWidget {
  const JourneyResultsScreen({
    super.key,
    required this.plan,
    required this.origin,
    required this.destination,
  });

  final JourneyPlan plan;

  /// Kept so checkout can re-plan the same trip after sign-in.
  final Place origin;
  final Place destination;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    if (plan.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(s.results)),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.route_outlined,
                size: 48,
                color: AppColors.inkMuted,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(s.noRoutes, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(s.results)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _HighlightRow(plan: plan),
          const SizedBox(height: AppSpacing.md),
          for (final journey in plan.journeys)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _JourneyCard(
                journey: journey,
                s: s,
                origin: origin,
                destination: destination,
              ),
            ),
        ],
      ),
    );
  }
}

/// Quick-pick row: cheapest / fastest / simplest.
///
/// Offering the three obvious trade-offs saves a passenger comparing four
/// numbers on a small screen. All three derive from the same server response.
class _HighlightRow extends StatelessWidget {
  const _HighlightRow({required this.plan});

  final JourneyPlan plan;

  @override
  Widget build(BuildContext context) {
    final options = <(String, PlannedJourney?)>[
      ('Cheapest', plan.cheapest),
      ('Fastest', plan.fastest),
      ('Simplest', plan.simplest),
    ];

    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.greenLight,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    options[i].$1,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    options[i].$2?.totalFare.plain ?? '———',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          if (i != options.length - 1) const SizedBox(width: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({
    required this.journey,
    required this.s,
    required this.origin,
    required this.destination,
  });

  final PlannedJourney journey;
  final AppStrings s;

  /// Passed down so checkout can re-plan the same trip after sign-in; the card
  /// has no access to the screen's own fields.
  final Place origin;
  final Place destination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(journey.durationLabel,
                            style: theme.textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(
                          '${journey.transferCount} ${s.transfers} · '
                          '${(journey.walkingMeters / 1000).toStringAsFixed(1)} km',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    journey.totalFare.display,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(color: AppColors.green),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _LegStrip(legs: journey.legs),
              const SizedBox(height: AppSpacing.md),
              FilledButton(onPressed: () => _open(context), child: Text(s.confirm)),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    // Checkout rather than a read-only detail page: tapping a fare means
    // "I want to travel this", and making the passenger hunt for a separate
    // Buy button is where a dropped purchase comes from.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PurchaseFlowScreen(
          journey: journey,
          origin: origin,
          destination: destination,
        ),
      ),
    );
  }
}

/// Horizontal leg indicator: walk → bus → walk.
class _LegStrip extends StatelessWidget {
  const _LegStrip({required this.legs});

  final List<JourneyLeg> legs;

  static const _colors = {
    TransportMode.bus: AppColors.modeBus,
    TransportMode.taxi: AppColors.modeTaxi,
    TransportMode.train: AppColors.modeTrain,
    TransportMode.walk: AppColors.modeWalk,
  };

  static IconData iconFor(TransportMode mode) {
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

  static Color colorFor(TransportMode mode) =>
      _colors[mode] ?? AppColors.modeWalk;

  @override
  Widget build(BuildContext context) {
    if (legs.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: legs.length,
        separatorBuilder: (_, _) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Icon(
            Icons.arrow_right_alt_rounded,
            size: 18,
            color: AppColors.inkMuted,
          ),
        ),
        itemBuilder: (context, index) {
          final leg = legs[index];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconFor(leg.mode), color: colorFor(leg.mode), size: 20),
              const SizedBox(height: 4),
              Text(leg.durationLabel, style: Theme.of(context).textTheme.labelSmall),
            ],
          );
        },
      ),
    );
  }
}

