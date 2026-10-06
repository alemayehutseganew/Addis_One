import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/reference.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// Who is short, and by how much.
///
/// Narrower than holding a drawer on purpose: an officer who takes cash should
/// not thereby gain the power to audit everyone else's. The server enforces that
/// split, and `canReconcile` reflects it.
class VariancesScreen extends ConsumerStatefulWidget {
  const VariancesScreen({super.key});

  @override
  ConsumerState<VariancesScreen> createState() => _VariancesScreenState();
}

class _VariancesScreenState extends ConsumerState<VariancesScreen> {
  late Future<List<CashVariance>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CashVariance>> _load() =>
      ref.read(staffRepositoryProvider).variances();

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cash variances'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<CashVariance>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }

          final rows = snapshot.data ?? const <CashVariance>[];
          if (rows.isEmpty) {
            return const EmptyPane(
              title: 'No variances',
              detail: 'Every closed drawer balanced.',
            );
          }

          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => _VarianceTile(row: rows[i]),
          );
        },
      ),
    );
  }
}

class _VarianceTile extends StatelessWidget {
  const _VarianceTile({required this.row});

  final CashVariance row;

  @override
  Widget build(BuildContext context) {
    final name = row.staffDisplayName.isNotEmpty
        ? row.staffDisplayName
        : row.reference;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: ListTile(
        title: Text(name),
        subtitle: Text(
          [
            if (row.expectedCashFils != null)
              'expected ETB ${Json.birr(row.expectedCashFils)}',
            if (row.declaredCashFils != null)
              'declared ETB ${Json.birr(row.declaredCashFils)}',
          ].join(' · '),
        ),
        trailing: _Amount(variance: row),
      ),
    );
  }
}

/// A variance, with its sign carried by a word as well as a colour.
///
/// Same reasoning as the verdict colours on the scanner: an officer reads this at
/// arm's length, so a bare "-1200" in red is not enough — "short" and "over" have
/// opposite remedies and must not be separable by hue alone.
class _Amount extends StatelessWidget {
  const _Amount({required this.variance});

  final CashVariance variance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fils = variance.varianceFils;
    if (fils == null) {
      return Text('—', style: theme.textTheme.bodyMedium);
    }
    final balanced = variance.isBalanced;
    final color = balanced
        ? theme.colorScheme.outline
        : variance.isShort
            ? theme.colorScheme.error
            : Colors.teal.shade700;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          balanced ? 'Balanced' : 'ETB ${Json.birr(fils.abs())}',
          style: theme.textTheme.titleSmall?.copyWith(color: color),
        ),
        if (!balanced)
          Text(
            variance.isShort ? 'short' : 'over',
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
      ],
    );
  }
}