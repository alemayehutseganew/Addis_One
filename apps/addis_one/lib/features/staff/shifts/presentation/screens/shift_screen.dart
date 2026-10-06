import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/network/api_failure.dart';
import '../../../auth/domain/staff_repository.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// The officer's cash drawer.
///
/// Two states, because the server models it that way: either a shift is open or
/// it is not. The app never keeps its own notion of which — it asks
/// `/staff/shifts/mine` and renders the answer, so a drawer opened on another
/// handheld (or closed by a supervisor) is reflected immediately rather than
/// after this device's next failed action.
class ShiftScreen extends ConsumerStatefulWidget {
  const ShiftScreen({super.key});

  @override
  ConsumerState<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends ConsumerState<ShiftScreen> {
  late Future<Map<String, dynamic>?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>?> _load() =>
      ref.read(staffRepositoryProvider).myShift();

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shift'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }

          final shift = snapshot.data;
          return shift == null
              ? _OpenShiftForm(onOpened: _reload)
              : _OpenShiftView(shift: shift, onChanged: _reload);
        },
      ),
    );
  }
}

/// Opening a drawer: how much cash is in it.
class _OpenShiftForm extends ConsumerStatefulWidget {
  const _OpenShiftForm({required this.onOpened});

  final VoidCallback onOpened;

  @override
  ConsumerState<_OpenShiftForm> createState() => _OpenShiftFormState();
}

class _OpenShiftFormState extends ConsumerState<_OpenShiftForm> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Converts birr to fils.
  ///
  /// The server takes fils, a whole number. Hand-writing the conversion here
  /// rather than multiplying a parsed double avoids the classic float problem
  /// where `12.50 * 100` lands on `1249.9999` and the server rejects it as not an
  /// integer — an error the officer cannot see the cause of.
  static int? _toFils(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('.');
    if (parts.length > 2) return null;
    final birr = int.tryParse(parts.first);
    if (birr == null || birr < 0) return null;

    var fraction = 0;
    if (parts.length == 2) {
      final decimal = parts[1];
      if (decimal.length > 2 || int.tryParse(decimal) == null) return null;
      fraction = int.parse(decimal.padRight(2, '0'));
    }
    return birr * 100 + fraction;
  }

  Future<void> _open() async {
    final fils = _toFils(_controller.text);
    if (fils == null) {
      setState(() => _error = 'Enter an amount in birr, such as 250 or 250.50');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(staffRepositoryProvider)
          .openShift(openingCashFils: fils);
      messenger.showSnackBar(const SnackBar(content: Text('Drawer opened')));
      widget.onOpened();
    } on ApiException catch (e) {
      setState(() => _error = e.message ?? 'Could not open the drawer.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'No shift is open. Enter the cash you are starting the drawer with.',
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Opening cash (ETB)',
              helperText: 'Sent to the server in fils',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _open,
            child: Text(_busy ? 'Opening…' : 'Open shift'),
          ),
        ],
      ),
    );
  }
}

/// The open drawer: what went in, what came out, and the close-out action.
class _OpenShiftView extends ConsumerStatefulWidget {
  const _OpenShiftView({required this.shift, required this.onChanged});

  final Map<String, dynamic> shift;
  final VoidCallback onChanged;

  @override
  ConsumerState<_OpenShiftView> createState() => _OpenShiftViewState();
}

class _OpenShiftViewState extends ConsumerState<_OpenShiftView> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Birr, from a fils figure the server sent.
  static String _birr(Object? fils) {
    if (fils is! num) return '—';
    return (fils / 100).toStringAsFixed(2);
  }

  Future<void> _declare() async {
    final raw = _controller.text.trim();
    final parts = raw.split('.');
    final whole = parts.first.isEmpty ? 0 : int.tryParse(parts.first);
    if (whole == null || whole < 0) {
      setState(() => _error = 'Enter the cash in the drawer, in birr.');
      return;
    }
    var fraction = 0;
    if (parts.length > 1 && parts[1].isNotEmpty) {
      if (parts[1].length > 2 || int.tryParse(parts[1]) == null) {
        setState(() => _error = 'Use at most two decimal places.');
        return;
      }
      fraction = int.parse(parts[1].padRight(2, '0'));
    }

    final shiftId = (widget.shift['id'] ?? '') as String;
    if (shiftId.isEmpty) {
      setState(() => _error = 'This shift has no id and cannot be closed.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(staffRepositoryProvider).declareCash(
            shiftId: shiftId,
            declaredCashFils: whole * 100 + fraction,
          );
      messenger.showSnackBar(const SnackBar(content: Text('Shift closed')));
      widget.onChanged();
    } on ApiException catch (e) {
      setState(() => _error = e.message ?? 'Could not close the shift.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shift = widget.shift;
    final status = '${shift['status'] ?? ''}';
    final open = StaffRepository.isShiftOpen(shift);
    final expected = shift['expectedCashFils'];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                (shift['reference'] ?? 'Shift') as String,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (status.isNotEmpty) Chip(label: Text(status)),
          ],
        ),
        const SizedBox(height: 14),
        _Row(
          label: 'Opened with',
          value: 'ETB ${_birr(shift['openingCashFils'])}',
        ),
        _Row(
          label: 'Taken since',
          value: 'ETB ${_birr(shift['collectedFils'] ?? 0)}',
        ),
        if (expected != null)
          _Row(
            label: 'Expected now',
            // The server computes this. A client-side running total would be a
            // second implementation of the variance rule, and the one an officer
            // would be held to.
            value: 'ETB ${_birr(expected)}',
            emphasise: true,
          ),
        if (!open) ...[
          // A closed shift is the audit record and is kept on purpose; the
          // close-out form must not reappear over it. `RECONCILING` in particular
          // means the drawer was short and a supervisor owes it a decision, so
          // telling the officer plainly is more useful than an empty screen.
          const Divider(height: 28),
          Text(
            status == 'RECONCILING'
                ? 'This shift closed short and is awaiting a supervisor.'
                : 'This shift is closed. Its record is kept for audit.',
            style: theme.textTheme.bodyMedium,
          ),
          if (shift['varianceFils'] != null)
            _Row(
              label: 'Variance',
              value:
                  'ETB ${_birr((shift['varianceFils']! as num).abs())} '
                  '${(shift['varianceFils']! as num) < 0 ? 'short' : 'over'}',
            ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: widget.onChanged,
            child: const Text('Open a new shift'),
          ),
        ] else ...[
          const Divider(height: 28),
          Text('Close out', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Count the drawer and enter what is physically in it. '
            'Any difference from the expected figure is recorded as a variance.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Cash in drawer (ETB)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _busy ? null : _declare,
            child: Text(_busy ? 'Recording…' : 'Declare and close shift'),
          ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            value,
            style: emphasise
                ? theme.textTheme.titleSmall
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}