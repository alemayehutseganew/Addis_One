import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/journey_plan.dart';
import '../../domain/transport_repository.dart';
import 'journey_results_screen.dart';

/// Origin/destination entry plus the plan action.
///
/// Stops come from `GET /stops`, never from a hardcoded list. An earlier
/// version bundled placeholder entries whose ids were invented strings
/// (`'stop-piazza'`); the planner endpoint validates ids as UUIDs, so every
/// request built from that list was rejected with a 400 before a single fare
/// was computed. A bundled list is only safe if it cannot reach the API.
class JourneySearchScreen extends ConsumerStatefulWidget {
  const JourneySearchScreen({super.key, this.initialOrigin});

  final Place? initialOrigin;

  @override
  ConsumerState<JourneySearchScreen> createState() => _JourneySearchScreenState();
}

class _JourneySearchScreenState extends ConsumerState<JourneySearchScreen> {
  Place? _origin;
  Place? _destination;
  bool _pickingDestination = false;
  bool _loading = false;
  bool _searching = false;
  String? _error;

  List<Place> _stops = const [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _origin = widget.initialOrigin;
    _pickingDestination = _origin == null;
    _loadStops();
  }

  @override
  void dispose() {
    // Cancelled so a pending debounce cannot call setState after dispose.
    _debounce?.cancel();
    super.dispose();
  }

  /// Fetches the real stop list. An empty query is a browse, which the backend
  /// treats as "return the busiest stops" rather than "match nothing".
  Future<void> _loadStops([String query = '']) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final stops = await ref.read(transportRepositoryProvider).searchPlaces(query);
      if (!mounted) return;
      setState(() => _stops = stops);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e.failure));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach the server');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Debounced so typing a stop name does not fire a request per keystroke.
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _loadStops(value));
  }

  String _describe(ApiFailure failure) => switch (failure) {
        ApiFailure.network => 'No connection to the server',
        ApiFailure.unauthorized => 'Please sign in again',
        ApiFailure.timeout => 'The server took too long to answer',
        _ => 'Could not load stops',
      };

  /// Assigns the tapped stop to whichever end is still empty.
  void _assign(Place place) {
    setState(() {
      if (_origin == null || _destination != null) {
        _origin = place;
        _destination = null;
        _pickingDestination = true;
      } else {
        _destination = place;
        _pickingDestination = false;
      }
    });
  }

  /// Switches which field the next stop tap fills.
  void _pick(bool isOrigin) {
    setState(() {
      _pickingDestination = !isOrigin;
      if (isOrigin) {
        _origin = null;
      } else {
        _destination = null;
      }
    });
  }

  Future<void> _plan() async {
    final origin = _origin;
    final destination = _destination;
    if (origin == null || destination == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repo = ref.read(transportRepositoryProvider);
      final plan = await repo.planJourney(
        JourneyPlanRequest(
          origin: origin,
          destination: destination,
          departureTime: DateTime.now(),
        ),
      );
      if (!mounted) return;
      if (plan.isEmpty) {
        setState(() => _error = 'No route between these two stops');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => JourneyResultsScreen(
            plan: plan,
            origin: origin,
            destination: destination,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e.failure));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not plan the journey');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);
    final canPlan = _origin != null && _destination != null && !_loading;

    return Scaffold(
      appBar: AppBar(title: Text(s.planJourney)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: [
                  _PlaceField(
                    icon: Icons.trip_origin_rounded,
                    color: AppColors.green,
                    label: s.from,
                    value: _origin,
                    active: !_pickingDestination,
                    onTap: () => _pick(true),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _PlaceField(
                    icon: Icons.place_rounded,
                    color: AppColors.red,
                    label: s.to,
                    value: _destination,
                    active: _pickingDestination,
                    onTap: () => _pick(false),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _error!,
                      style:
                          theme.textTheme.bodySmall?.copyWith(color: AppColors.red),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: canPlan ? _plan : null,
                    icon: _loading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.route_rounded),
                    label: Text(s.planJourney),
                  ),
                ],
              ),
            ),
            Expanded(child: _stopList(context, s)),
          ],
        ),
      ),
    );
  }

  /// The searchable stop list, with the search field pinned as the first row.
  Widget _stopList(BuildContext context, AppStrings s) {
    if (_searching && _stops.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_stops.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(
            _error == null ? 'No stops found' : 'Could not load stops',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _stops.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: TextField(
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: s.searchDestination,
                border: const OutlineInputBorder(),
              ),
            ),
          );
        }

        final place = _stops[index - 1];
        return ListTile(
          leading: const Icon(Icons.place_outlined),
          title: Text(place.name),
          // Amharic name where the bureau has supplied one — the primary
          // language for most of the ridership.
          subtitle: (place.nameAm == null || place.nameAm == place.name)
              ? Text(place.code)
              : Text('${place.nameAm} · ${place.code}'),
          onTap: () => _assign(place),
        );
      },
    );
  }
}

class _PlaceField extends StatelessWidget {
  const _PlaceField({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final Place? value;
  final VoidCallback onTap;

  /// True while this field is the one the next stop tap will fill.
  ///
  /// Highlighted so the passenger knows whether tapping a stop sets the origin
  /// or the destination — otherwise the two-field picker is a coin toss.
  final bool active;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          // The field being edited is outlined in its own colour, so the next
          // tap has an obvious destination.
          filled: active,
          fillColor: active ? color.withValues(alpha: 0.06) : null,
          prefixIcon: Icon(icon, color: color),
          suffixIcon: const Icon(Icons.expand_more_rounded),
        ),
        child: Text(
          value?.name ?? '———',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: value == null ? AppColors.inkMuted : AppColors.ink,
              ),
        ),
      ),
    );
  }
}
