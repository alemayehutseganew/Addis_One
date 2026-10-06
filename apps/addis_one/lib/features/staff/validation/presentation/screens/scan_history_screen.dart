import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/config/app_config.dart';
import '../../../../../core/models/scan_outcome.dart';
import '../../../../../core/network/api_failure.dart';

/// This officer's own recent scans.
///
/// Scoped to the caller by the server, deliberately: a network-wide feed of who
/// inspected whom and where is surveillance data with no operational use on a
/// handheld. Oversight belongs to the audit surface.
class ScanHistoryScreen extends ConsumerStatefulWidget {
  const ScanHistoryScreen({super.key});

  @override
  ConsumerState<ScanHistoryScreen> createState() => _ScanHistoryScreenState();
}

class _ScanHistoryScreenState extends ConsumerState<ScanHistoryScreen> {
  late Future<List<ScanHistoryEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<ScanHistoryEntry>> _load() {
    return ref
        .read(staffRepositoryProvider)
        .recentScans(take: AppConfig.historyPageSize);
  }

  void _reload() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My scans'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<ScanHistoryEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            final err = snapshot.error;
            return _Message(
              icon: err is ApiException && err.failure == ApiFailure.network
                  ? Icons.cloud_off
                  : Icons.error_outline,
              title: 'Could not load your scans',
              detail: err is ApiException
                  ? (err.message ?? 'Try again shortly.')
                  : 'Something went wrong. Try again shortly.',
              action: _reload,
            );
          }

          final rows = snapshot.data ?? const <ScanHistoryEntry>[];
          if (rows.isEmpty) {
            return const _Message(
              icon: Icons.history,
              title: 'No scans yet',
              detail: 'Tickets you validate will appear here.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _ScanTile(record: rows[i]),
            ),
          );
        },
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({required this.record});

  final ScanHistoryEntry record;

  @override
  Widget build(BuildContext context) {
    final outcome = record.outcome;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: outcome.color,
        child: Icon(outcome.icon, color: Colors.white, size: 20),
      ),
      title: Text(
        outcome.headline,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          color: outcome.color,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (record.ticketReference != null)
            Text(record.ticketReference!,
                style: const TextStyle(fontSize: 12)),
          Text(
            DateFormat('d MMM yyyy, HH:mm:ss').format(record.validatedAt.toLocal()),
            style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
          ),
        ],
      ),
      isThreeLine: record.ticketReference != null,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: AppColors.inkMuted),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppColors.inkMuted),
            ),
            if (action != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(onPressed: action, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
