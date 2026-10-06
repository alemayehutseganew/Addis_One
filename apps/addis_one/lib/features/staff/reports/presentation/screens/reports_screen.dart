import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// Reporting, in whichever flavour this officer's role allows.
///
/// One screen with three modes rather than three screens, because the three
/// report families differ only in which route they call. The capability decides
/// which mode the app offers, so a finance officer gets revenue and an auditor
/// gets fares, without this screen carrying any role table of its own.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({
    super.key,
    this.financeOnly = false,
    this.databaseOnly = false,
  });

  /// Revenue and fare reporting.
  final bool financeOnly;

  /// Database internals.
  final bool databaseOnly;

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  late Future<Map<String, dynamic>> _future;
  late String _title;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(staffRepositoryProvider);
    if (widget.databaseOnly) {
      _title = 'Database';
      _future = repo.databaseStats();
    } else if (widget.financeOnly) {
      _title = 'Revenue';
      _future = repo.revenue();
    } else {
      _title = 'Reports';
      _future = repo.overview();
    }
  }

  void _reload() {
    final repo = ref.read(staffRepositoryProvider);
    setState(() {
      if (widget.databaseOnly) {
        _future = repo.databaseStats();
      } else if (widget.financeOnly) {
        _future = repo.revenue();
      } else {
        _future = repo.overview();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }
          return _ReportView(data: snapshot.data ?? const {});
        },
      ),
    );
  }
}

/// Renders a report envelope as nested key/value rows.
///
/// Deliberately generic. These reports are shaped for the dashboard's panels and
/// their exact keys change as figures are added; hand-writing a widget per
/// metric would mean editing this screen every time a report grows a column. A
/// flat walk shows whatever the server sent, including fields this build has
/// never heard of — which is the honest behaviour when the server is newer than
/// the client.
///
/// Depth-bounded so a deeply nested envelope cannot spin this into an unbounded
/// tree on a handheld.
class _ReportView extends StatelessWidget {
  const _ReportView({required this.data, this.depth = 0});

  final Map<String, dynamic> data;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (data.isEmpty) {
      return const EmptyPane(title: 'Nothing to report');
    }

    final rows = <Widget>[];
    data.forEach((key, value) {
      final name = _pretty(key);
      if (value is Map) {
        if (depth < 2 && value.isNotEmpty) {
          rows.add(
            Padding(
              padding: EdgeInsets.only(top: depth == 0 ? 14 : 8, bottom: 2),
              child: Text(
                name,
                style: depth == 0
                    ? theme.textTheme.titleSmall
                    : theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
              ),
            ),
          );
          rows.add(
            Padding(
              padding: EdgeInsets.only(left: depth * 10.0),
              child: _ReportView(
                data: Map<String, dynamic>.from(value),
                depth: depth + 1,
              ),
            ),
          );
        }
        return;
      }
      if (value is List) {
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(name, style: theme.textTheme.bodyMedium)),
                Text(
                  value.isEmpty ? '0' : '${value.length}',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        );
        return;
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(name, style: theme.textTheme.bodyMedium)),
              const SizedBox(width: 12),
              Text(
                '${value ?? '—'}',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    });

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: rows,
    );
  }

  static String _pretty(String key) {
    final spaced = key.replaceAllMapped(
      RegExp('([a-z0-9])([A-Z])'),
      (m) => '${m[1]} ${m[2]}',
    );
    if (spaced.isEmpty) return spaced;
    return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }
}