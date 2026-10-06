import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/reference.dart';
import '../../../../../core/network/api_failure.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// The passenger complaint queue.
///
/// Filing is a passenger action and is not here; this is the staff side — reading
/// the queue and moving a complaint along. Which status is legal from which is a
/// server rule, so the buttons below offer the whole vocabulary and the server
/// decides. Offering only "the sensible next one" would need a client-side copy
/// of the workflow, which is exactly the kind of second implementation that ends
/// up disagreeing with the real one.
class ComplaintsScreen extends ConsumerStatefulWidget {
  const ComplaintsScreen({super.key});

  @override
  ConsumerState<ComplaintsScreen> createState() => _ComplaintsScreenState();
}

class _ComplaintsScreenState extends ConsumerState<ComplaintsScreen> {
  late Future<List<Complaint>> _future;
  String? _statusFilter;

  /// The server's vocabulary, as far as this build knows it.
  static const _statuses = [
    'OPEN',
    'IN_PROGRESS',
    'RESOLVED',
    'REJECTED',
    'CLOSED',
  ];

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() =>
      ref.read(staffRepositoryProvider).complaints(status: _statusFilter);

  void _reload() => setState(() => _future = _load());

  void _filter(String? status) {
    setState(() {
      _statusFilter = status;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complaints'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: _statusFilter == null,
                    onSelected: (_) => _filter(null),
                  ),
                ),
                for (final s in _statuses)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_pretty(s)),
                      selected: _statusFilter == s,
                      onSelected: (_) => _filter(s),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Complaint>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return MessagePane.forError(
                    snapshot.error!,
                    onRetry: _reload,
                  );
                }

                final rows = snapshot.data ?? const <Complaint>[];
                if (rows.isEmpty) {
                  return const EmptyPane(
                    title: 'Nothing in the queue',
                    detail: 'No complaints match this filter.',
                  );
                }

                return ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _ComplaintTile(
                    complaint: rows[i],
                    statuses: _statuses,
                    onChanged: _reload,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _pretty(String status) =>
      status
          .toLowerCase()
          .split('_')
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
}

class _ComplaintTile extends ConsumerStatefulWidget {
  const _ComplaintTile({
    required this.complaint,
    required this.statuses,
    required this.onChanged,
  });

  final Complaint complaint;
  final List<String> statuses;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ComplaintTile> createState() => _ComplaintTileState();
}

class _ComplaintTileState extends ConsumerState<_ComplaintTile> {
  bool _busy = false;

  String get _reference => widget.complaint.reference;

  Future<void> _advance(String status) async {
    if (_reference.isEmpty) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(staffRepositoryProvider).advanceComplaint(
            reference: _reference,
            status: status,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Marked ${status.toLowerCase()}')),
      );
      widget.onChanged();
    } on ApiException catch (e) {
      // The server rejects an illegal transition, and its message is the useful
      // part: it is the only thing that knows which moves are currently legal.
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? 'That move was refused.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.complaint;
    final current = c.status;

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
                Text(
                  _reference.isEmpty ? 'Complaint' : _reference,
                  style: theme.textTheme.titleSmall,
                ),
                if (current.isNotEmpty)
                  Chip(
                    label: Text(current),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (c.category.isNotEmpty)
              Text(
                c.category,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            const SizedBox(height: 6),
            // Bounded: the server allows 2000 characters, and this screen is not
            // the place to read them all. The full text stays on the record.
            Text(
              c.description,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final s in widget.statuses)
                  if (s != current)
                    OutlinedButton(
                      onPressed: _busy ? null : () => _advance(s),
                      child: Text(s.replaceAll('_', ' ')),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
