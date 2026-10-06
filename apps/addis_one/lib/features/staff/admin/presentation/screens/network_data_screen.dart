// `Route` here is this app's network-route model. Flutter has a routing `Route`
// in navigator.dart, and an unprefixed import of both makes every use ambiguous —
// which is a confusing error to read when the clash is between two unrelated
// meanings of the same ordinary English word.
import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/reference.dart';
import '../../../../../core/network/api_failure.dart';
import '../../../auth/domain/staff_repository.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// Stops, routes and vehicles.
///
/// Read-and-toggle rather than full editing. The create and patch routes exist
/// and are reachable, but a stop form on a phone is a poor way to enter
/// coordinates and zone assignments, and getting them wrong puts a shelter in the
/// wrong part of the city. Activation is offered because it is a single, clearly
/// reversible switch; everything else belongs on a keyboard.
class NetworkDataScreen extends ConsumerStatefulWidget {
  const NetworkDataScreen({super.key});

  @override
  ConsumerState<NetworkDataScreen> createState() => _NetworkDataScreenState();
}

class _NetworkDataScreenState extends ConsumerState<NetworkDataScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Joins the present fields with a separator, skipping the absent ones.
  static String _join(List<String?> parts) =>
      parts.whereType<String>().where((p) => p.isNotEmpty).join(' · ');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reference data'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Stops'),
            Tab(text: 'Routes'),
            Tab(text: 'Vehicles'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ReferenceList<Stop>(
            title: 'Stops',
            load: (repo) => repo.adminStops(includeInactive: true),
            name: (row) => row.name,
            subtitle: (row) =>
                _join([row.code, row.zone ?? '', row.nameAm ?? '']),
            isActive: (row) => row.isActive,
            // Only stops get a toggle. Routes and vehicles have their own
            // activation routes on the server, and offering a stop-shaped control
            // on them would send the wrong verb to the wrong path.
            toggle: (repo, row) async {
              if (row.id.isEmpty) return false;
              final next = !row.isActive;
              await repo.setStopActive(stopId: row.id, isActive: next);
              return next;
            },
          ),
          _ReferenceList<Route>(
            title: 'Routes',
            load: (repo) => repo.adminRoutes(includeInactive: true),
            name: (row) => row.name.isEmpty ? row.code : row.name,
            subtitle: (row) =>
                _join([row.code, row.mode, row.distanceLabel ?? '']),
            isActive: (row) => row.isActive,
          ),
          _ReferenceList<Vehicle>(
            title: 'Vehicles',
            load: (repo) => repo.adminVehicles(includeInactive: true),
            name: (row) => row.label,
            subtitle: (row) => _join([
                  row.mode,
                  if (row.capacity != null) '${row.capacity} seats',
                  if (row.status.isNotEmpty) row.status,
                ]),
            isActive: (row) => row.isActive,
          ),
        ],
      ),
    );
  }
}

/// A list of reference records, each showing whether it is active.
///
/// Generic over the row type rather than over a map: the three tabs show
/// genuinely different records, and a single shape would either erase the
/// differences that matter (a stop's zone, a vehicle's capacity) or push them
/// into untyped lookups at every call site.
class _ReferenceList<T> extends ConsumerStatefulWidget {
  const _ReferenceList({
    required this.title,
    required this.load,
    required this.name,
    required this.subtitle,
    required this.isActive,
    this.toggle,
  });

  final String title;
  final Future<List<T>> Function(StaffRepository repo) load;
  final String Function(T row) name;
  final String Function(T row) subtitle;
  final bool Function(T row) isActive;

  /// Present only where the server has an activation route.
  final Future<bool> Function(StaffRepository repo, T row)? toggle;

  @override
  ConsumerState<_ReferenceList<T>> createState() => _ReferenceListState<T>();
}

class _ReferenceListState<T> extends ConsumerState<_ReferenceList<T>> {
  late Future<List<T>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load(ref.read(staffRepositoryProvider));
  }

  void _reload() =>
      setState(() => _future = widget.load(ref.read(staffRepositoryProvider)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<T>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }

          final rows = snapshot.data ?? const [];
          if (rows.isEmpty) {
            return const EmptyPane(title: 'Nothing recorded');
          }

          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => _ReferenceTile<T>(
              row: rows[i],
              name: widget.name(rows[i]),
              subtitle: widget.subtitle(rows[i]),
              active: widget.isActive(rows[i]),
              toggle: widget.toggle,
              onChanged: _reload,
            ),
          );
        },
      ),
    );
  }
}

class _ReferenceTile<T> extends ConsumerStatefulWidget {
  const _ReferenceTile({
    required this.row,
    required this.name,
    required this.subtitle,
    required this.active,
    required this.toggle,
    required this.onChanged,
  });

  final T row;
  final String name;
  final String subtitle;
  final bool active;
  final Future<bool> Function(StaffRepository repo, T row)? toggle;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ReferenceTile<T>> createState() =>
      _ReferenceTileState<T>();
}

class _ReferenceTileState<T> extends ConsumerState<_ReferenceTile<T>> {
  bool _busy = false;

  Future<void> _flip() async {
    final toggle = widget.toggle;
    if (toggle == null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await toggle(ref.read(staffRepositoryProvider), widget.row);
      widget.onChanged();
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? 'That change was refused.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final toggle = widget.toggle;

    return ListTile(
      title: Text(widget.name.isEmpty ? '(unnamed)' : widget.name),
      subtitle: widget.subtitle.isEmpty ? null : Text(widget.subtitle),
      // Status carried by shape and colour together; see StaffTheme on why hue
      // alone is not enough on a screen read in glare.
      leading: Icon(
        widget.active ? Icons.check_circle_outline : Icons.remove_circle_outline,
        color: widget.active
            ? Colors.teal
            : Theme.of(context).colorScheme.outline,
      ),
      trailing: toggle == null
          ? null
          : _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: _flip,
                  child: Text(widget.active ? 'Withdraw' : 'Reinstate'),
                ),
    );
  }
}