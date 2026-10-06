import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/reference.dart';
import '../../../../../core/network/api_failure.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// Selling a ticket for cash, on a passenger's behalf.
///
/// An agent taking cash is the revenue-integrity edge of this app, so two things
/// are deliberately absent: any way to name a price, and any way to file the sale
/// against a drawer other than the officer's own. Both come from the server —
/// the fare is re-derived and the shift is taken from the caller's identity — so
/// this screen only collects the two identifiers the server cannot guess.
///
/// The idempotency key is generated once per sale and held for the life of the
/// form. Retapping "Take payment" after a dropped response must replay the same
/// key, or the passenger is charged twice for one fare.
class CashSaleScreen extends ConsumerStatefulWidget {
  const CashSaleScreen({super.key});

  @override
  ConsumerState<CashSaleScreen> createState() => _CashSaleScreenState();
}

class _CashSaleScreenState extends ConsumerState<CashSaleScreen> {
  final _passenger = TextEditingController();
  final _amount = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Stops the officer picks from. Loaded once per visit; the network does not
  /// change under a sale.
  late Future<List<Stop>> _stops;
  String? _originId;
  String? _destinationId;

  /// Held for the life of one sale. Regenerated only after a completed sale —
  /// see the note on [_newKey].
  late String _key;

  @override
  void initState() {
    super.initState();
    _key = _newKey();
    _stops = ref.read(staffRepositoryProvider).stops();
  }

  @override
  void dispose() {
    _passenger.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// A random idempotency key.
  ///
  /// `Random.secure` because this key is the only thing standing between a
  /// retried sale and a double charge. A timestamp would collide across two
  /// handhelds sold to in the same second; a UUID package would be a dependency
  /// for one call.
  static String _newKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Birr to fils, rejecting anything the server would reject.
  static int? _toFils(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('.');
    if (parts.length > 2) return null;
    final birr = int.tryParse(parts.first);
    if (birr == null || birr < 0) return null;
    var fraction = 0;
    if (parts.length == 2) {
      if (parts[1].length > 2 || int.tryParse(parts[1]) == null) return null;
      fraction = int.parse(parts[1].padRight(2, '0'));
    }
    return birr * 100 + fraction;
  }

  Future<void> _sell() async {
    final fils = _toFils(_amount.text);
    final passenger = _passenger.text.trim();
    final origin = _originId;
    final destination = _destinationId;

    if (passenger.isEmpty) {
      setState(() => _error = 'Enter the passenger phone number.');
      return;
    }
    if (origin == null || destination == null) {
      setState(() => _error = 'Choose where the passenger boards and alights.');
      return;
    }
    if (origin == destination) {
      setState(() => _error = 'Boarding and alighting stops must differ.');
      return;
    }
    if (fils == null || fils < 1) {
      setState(() => _error = 'Enter the fare in birr, such as 44.00');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ref.read(staffRepositoryProvider).sell(
            passengerPhone: passenger,
            originStopId: origin,
            destinationStopId: destination,
            amountFils: fils,
            idempotencyKey: _key,
          );
      // `ticket: null` means the payment has not confirmed yet. The officer must
      // not be handed a ticket reference in that case, so the message says so
      // rather than implying the sale has finished.
      final issued = res['ticket'] != null;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            issued ? 'Ticket issued' : 'Payment pending — check back shortly',
          ),
        ),
      );
      if (issued) {
        setState(() {
          _passenger.clear();
          _amount.clear();
          _originId = null;
          _destinationId = null;
          // A new key per completed sale: reusing it would replay the old sale.
          _key = _newKey();
        });
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message ?? 'The sale was refused.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Cash sale')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'The fare is re-derived by the server from the journey. '
            'The amount below is only checked against it, never trusted.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passenger,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Passenger phone',
              helperText: 'The number they signed up with',
            ),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<Stop>>(
            future: _stops,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Text(
                  'Stops could not be loaded.',
                  style: TextStyle(color: theme.colorScheme.error),
                );
              }
              final stops = snapshot.data ?? const <Stop>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _originId,
                    decoration: const InputDecoration(labelText: 'Boards at'),
                    items: [
                      for (final s in stops)
                        DropdownMenuItem(
                          value: s.id,
                          child: Text('${s.name} (${s.code})'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _originId = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _destinationId,
                    decoration:
                        const InputDecoration(labelText: 'Alights at'),
                    items: [
                      for (final s in stops)
                        DropdownMenuItem(
                          value: s.id,
                          child: Text('${s.name} (${s.code})'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _destinationId = v),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Fare (ETB)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _sell,
            child: Text(_busy ? 'Recording…' : 'Take payment'),
          ),
        ],
      ),
    );
  }
}

/// Handhelds this officer may enrol.
///
/// Enrolment links a device to a staff record so a lost or swapped handset can
/// be traced. The device id comes from the server rather than anything read off
/// the handset, so this screen cannot invent a device by supplying a string.
class DeviceScreen extends ConsumerStatefulWidget {
  const DeviceScreen({super.key});

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
  late Future<List<StaffDevice>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(staffRepositoryProvider).devices();
  }

  void _reload() =>
      setState(() => _future = ref.read(staffRepositoryProvider).devices());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('This handheld'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<StaffDevice>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }
          final rows = snapshot.data ?? const <StaffDevice>[];
          if (rows.isEmpty) {
            return const EmptyPane(
              title: 'No devices on record',
              detail: 'Nothing is enrolled against your account.',
            );
          }
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => _DeviceTile(
              row: rows[i],
              onChanged: _reload,
            ),
          );
        },
      ),
    );
  }
}

class _DeviceTile extends ConsumerStatefulWidget {
  const _DeviceTile({required this.row, required this.onChanged});

  final StaffDevice row;
  final VoidCallback onChanged;

  @override
  ConsumerState<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends ConsumerState<_DeviceTile> {
  bool _busy = false;

  Future<void> _enroll() async {
    if (widget.row.id.isEmpty) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(staffRepositoryProvider).enrollDevice(widget.row.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('Device enrolled')),
      );
      widget.onChanged();
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? 'Enrolment was refused.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final name = row.deviceCode.isNotEmpty
        ? row.deviceCode
        : (row.deviceId.isEmpty ? 'Device' : row.deviceId);

    return ListTile(
      title: Text(name),
      subtitle: Text(
        [
          if (row.platform.isNotEmpty) row.platform,
          if (row.appVersion != null) 'v${row.appVersion}',
          row.isEnrolled ? 'enrolled' : 'not enrolled',
        ].join(' · '),
      ),
      trailing: row.isEnrolled || _busy || row.id.isEmpty
          ? null
          : TextButton(onPressed: _enroll, child: const Text('Enrol')),
    );
  }
}