import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/theme.dart';
import '../../data/scan_submitter.dart';
import '../widgets/officer_chrome.dart';
import '../widgets/scanner_view.dart';
import '../widgets/verdict_card.dart';
import 'scan_history_screen.dart';

/// The primary screen: scan, and see the verdict.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  ScanSubmission? _last;
  int _sessionScans = 0;

  @override
  void initState() {
    super.initState();
    // Best effort. A failure only leaves the badge at zero, which is the safe
    // direction: the officer sees no pending work rather than a wrong count.
    _refreshPending();
  }

  Future<void> _refreshPending() async {
    try {
      final count = await ref.read(scanSubmitterProvider).pendingCount;
      ref.read(pendingScanCountProvider.notifier).state = count;
    } catch (_) {
      // Non-fatal; see above.
    }
  }

  /// Attempts to deliver parked scans, e.g. when the officer taps the badge.
  Future<void> _syncPending() async {
    try {
      final submitter = ref.read(scanSubmitterProvider);
      final result = await submitter.drainPending();
      ref.read(pendingScanCountProvider.notifier).state =
          await submitter.pendingCount;

      if (!mounted || result.isEmpty) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            result.delivered > 0
                ? '${result.delivered} queued scan(s) validated'
                : 'Some queued scans could not be sent',
          ),
        ));
    } catch (_) {
      // A failed sync leaves the durable queue unchanged, so nothing is lost.
    }
  }

  void _onResult(ScanSubmission submission) {
    setState(() {
      _last = submission;
      _sessionScans++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(staffAuthControllerProvider);
    final pending = ref.watch(pendingScanCountProvider);
    final session = auth.session;

    // A role without scan rights gets an explanation rather than a camera, so
    // the officer is told why before aiming a lens at anyone.
    if (session != null && !session.canValidate) {
      return Scaffold(
        appBar: AppBar(title: const Text('Validate ticket')),
        body: NoScanRightsNotice(role: session.role),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Validate ticket'),
        actions: [
          if (pending > 0)
            IconButton(
              tooltip: '$pending scan(s) waiting for a connection',
              onPressed: _syncPending,
              icon: Badge(
                label: Text('$pending'),
                backgroundColor: AppColors.verdictUnknown,
                child: const Icon(Icons.cloud_upload_outlined),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'history') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ScanHistoryScreen(),
                  ),
                );
              } else if (value == 'signout') {
                ref.read(staffAuthControllerProvider.notifier).signOut();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'history', child: Text('My scans')),
              PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (session != null)
            OfficerBar(
              displayName: session.displayName,
              role: session.role,
            ),
          Expanded(
            child: Stack(
              children: [
                ScannerView(onResult: _onResult),
                if (_last != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: VerdictCard(
                      result: _last!.result,
                      isDeferred: _last!.isDeferred,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            child: Text(
              '$_sessionScans scanned this session · point the camera at the '
              'ticket QR',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
            ),
          ),
        ],
      ),
    );
  }
}
