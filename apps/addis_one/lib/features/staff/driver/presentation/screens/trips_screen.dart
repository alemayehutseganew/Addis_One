import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/trip.dart';
import '../../../../../core/network/api_failure.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// The trips assigned to this officer, and the two actions they can take on one.
///
/// Rendering is deliberately thin. Trip state transitions belong to the server's
/// state machine, so this screen never decides for itself whether a trip may be
/// started or finished — it calls the route and shows what came back. A
/// client-side state machine would eventually disagree with the server at some
/// transition and tell a driver their trip is finished while it is still running.
class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key});

  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen> {
  late Future<List<Trip>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Trip>> _load() async {
    return ref.read(staffRepositoryProvider).myTrips();
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My trips'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<Trip>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }

          final trips = snapshot.data ?? const <Trip>[];
          if (trips.isEmpty) {
            return const EmptyPane(
              title: 'No trips assigned',
              detail: 'Trips posted to you will appear here.',
            );
          }

          return ListView.builder(
            itemCount: trips.length,
            itemBuilder: (context, i) => _TripTile(
              trip: trips[i],
              onChanged: _reload,
            ),
          );
        },
      ),
    );
  }
}

class _TripTile extends ConsumerStatefulWidget {
  const _TripTile({required this.trip, required this.onChanged});

  final Trip trip;
  final VoidCallback onChanged;

  @override
  ConsumerState<_TripTile> createState() => _TripTileState();
}

class _TripTileState extends ConsumerState<_TripTile> {
  bool _busy = false;

  Future<void> _act(Future<Map<String, dynamic>> Function() call) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await call();
      messenger.showSnackBar(const SnackBar(content: Text('Recorded')));
      widget.onChanged();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_reason(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Prefers the server's own wording over a Dart `toString()`.
  ///
  /// `ApiException.toString()` reads "ApiException(unauthorized, ...)", which an
  /// officer cannot act on. The message field is the sentence the server wrote
  /// for them.
  static String _reason(Object error) {
    if (error is ApiException) return error.message ?? 'Not permitted.';
    return 'Could not record that. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final theme = Theme.of(context);
    // Every button is gated on the server's own list of permitted next states,
    // so this screen cannot disagree with the state machine about what is legal.
    final canStart = trip.isActionable && trip.canStart;
    final canFinish = trip.isActionable && trip.canComplete;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(trip.label, style: theme.textTheme.titleSmall),
                ),
                if (trip.status.isNotEmpty)
                  Chip(
                    label: Text(trip.status),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (trip.vehiclePlate.isNotEmpty || trip.scheduledDeparture != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  [
                    if (trip.vehiclePlate.isNotEmpty) trip.vehiclePlate,
                    if (trip.scheduledDeparture != null)
                      _clock(trip.scheduledDeparture!),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            if (trip.isFinished)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'No further action.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (canStart || canFinish)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    if (canStart)
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _act(
                                  () => ref
                                      .read(staffRepositoryProvider)
                                      .startTrip(trip.id),
                                ),
                        child: const Text('Start trip'),
                      ),
                    if (canFinish)
                      FilledButton.tonal(
                        onPressed: _busy
                            ? null
                            : () => _act(
                                  () => ref
                                      .read(staffRepositoryProvider)
                                      .completeTrip(trip.id),
                                ),
                        child: const Text('Complete trip'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// `HH:mm` in the device's local zone.
  static String _clock(DateTime when) {
    final local = when.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}