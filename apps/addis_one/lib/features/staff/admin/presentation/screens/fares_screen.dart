import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/reference.dart';
import '../../../../../core/network/api_failure.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// Fare rules, and the two distinct rights over them.
///
/// Authoring and approval are separate capabilities and can be separate screens,
/// because the backend treats them as separate rights: an operator may draft but
/// not approve, an auditor may approve but not draft. Combining them behind one
/// "manage fares" button would hide that distinction from the person using it.
///
/// Self-approval is refused by the server even for a role holding both rights —
/// the draft's own author may not activate it. This screen does not try to
/// second-guess that, and simply reports the refusal if it happens.
class FaresScreen extends ConsumerStatefulWidget {
  const FaresScreen({
    super.key,
    this.authoring = false,
    this.approving = false,
  });

  /// Show the drafting action.
  final bool authoring;

  /// Show the activation action.
  final bool approving;

  @override
  ConsumerState<FaresScreen> createState() => _FaresScreenState();
}

class _FaresScreenState extends ConsumerState<FaresScreen> {
  late Future<List<FareRule>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = ref.read(staffRepositoryProvider).fareRules();
  }

  void _reload() =>
      setState(() => _future = ref.read(staffRepositoryProvider).fareRules());

  Future<void> _activate(FareRule rule) async {
    if (rule.id.isEmpty) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(staffRepositoryProvider).activateFareRule(rule.id);
      messenger.showSnackBar(const SnackBar(content: Text('Fare activated')));
      _reload();
    } on ApiException catch (e) {
      // The self-approval refusal arrives here, and its message is the whole
      // point of showing it rather than a generic failure.
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? 'Activation was refused.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Collects a new fare version and sends it as a draft.
  ///
  /// Drafting only. Activation is a separate right and a separate call, and the
  /// server separately refuses to let an author approve their own draft — so this
  /// form deliberately offers no "and make it live" checkbox.
  Future<void> _openDraft() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _DraftFareForm(),
    );
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(staffRepositoryProvider).reviseFareRule(result);
      messenger.showSnackBar(
        const SnackBar(content: Text('Draft recorded — awaiting sign-off')),
      );
      _reload();
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? 'The draft was refused.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.approving && !widget.authoring
        ? 'Sign off fares'
        : widget.authoring && !widget.approving
            ? 'Draft a fare'
            : 'Fare rules';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.authoring)
            IconButton(
              tooltip: 'Draft a new version',
              onPressed: _openDraft,
              icon: const Icon(Icons.add),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<FareRule>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }

          final rows = snapshot.data ?? const <FareRule>[];
          if (rows.isEmpty) {
            return const EmptyPane(
              title: 'No fare rules',
              detail: 'Nothing has been configured yet.',
            );
          }

          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => _FareTile(
              rule: rows[i],
              approving: widget.approving,
              busy: _busy,
              onActivate: _activate,
            ),
          );
        },
      ),
    );
  }
}

class _FareTile extends StatelessWidget {
  const _FareTile({
    required this.rule,
    required this.approving,
    required this.busy,
    required this.onActivate,
  });

  final FareRule rule;
  final bool approving;
  final bool busy;
  final Future<void> Function(FareRule rule) onActivate;

  @override
  Widget build(BuildContext context) {
    final base = Json.birr(rule.baseFareFils);
    final perKm = Json.birr(rule.perKmFils);
    final zones = rule.zonesLabel;
    // The date part only: `effectiveFrom` is a date, and rendering the time of
    // day it was stamped at would imply a precision the rule does not have.
    final from = rule.effectiveFrom?.toIso8601String().split('T').first;

    // Assembled by appending rather than with collection-element guards. The
    // guards read fine until one of them has to compose two optional values, at
    // which point the nesting is worse than the four lines below.
    final parts = <String>[
      if (rule.version != null) 'v${rule.version}',
      if (base != null) 'base ETB $base',
      if (perKm != null) '+ ETB $perKm/km',
    ];
    if (zones != null) parts.add(zones);
    if (from != null) parts.add('from $from');

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: ListTile(
        title: Text(rule.ruleKey.isEmpty ? '(unnamed rule)' : rule.ruleKey),
        subtitle: Text(parts.join(' · ')),
        // Only drafts offer activation, and only where the server said this
        // officer may approve. Both conditions are needed: the right without a
        // draft has nothing to act on, and a draft without the right would only
        // produce a 403.
        trailing: approving && rule.isDraft && !rule.isLive
            ? (busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : FilledButton.tonal(
                    onPressed: rule.id.isEmpty
                        ? null
                        : () => onActivate(rule),
                    child: const Text('Activate'),
                  ))
            : rule.isLive
                ? const Chip(label: Text('Live'))
                : (rule.status.isEmpty ? null : Chip(label: Text(rule.status))),
      ),
    );
  }
}

/// The draft form.
///
/// Pops the payload it built rather than sending anything itself, so the caller
/// keeps one code path for reporting success and failure — a sheet that sent its
/// own request would have to duplicate that error handling for no benefit.
class _DraftFareForm extends StatefulWidget {
  const _DraftFareForm();

  @override
  State<_DraftFareForm> createState() => _DraftFareFormState();
}

class _DraftFareFormState extends State<_DraftFareForm> {
  final _key = TextEditingController();
  final _mode = TextEditingController(text: 'BUS');
  final _base = TextEditingController();
  final _perKm = TextEditingController();
  final _minimum = TextEditingController();
  final _origin = TextEditingController();
  final _destination = TextEditingController();
  final _reason = TextEditingController();
  DateTime _effectiveFrom = DateTime.now();
  String? _error;

  /// Modes the fare engine prices.
  static const _modes = ['BUS', 'TAXI', 'TRAIN'];

  @override
  void dispose() {
    _key.dispose();
    _mode.dispose();
    _base.dispose();
    _perKm.dispose();
    _minimum.dispose();
    _origin.dispose();
    _destination.dispose();
    _reason.dispose();
    super.dispose();
  }

  /// Birr to fils.
  ///
  /// Integer arithmetic throughout, because the server takes an integer fils
  /// figure and rejects a float. Parsing as a double and multiplying would put
  /// 12.50 * 100 at 1249.9999999999998 and produce a rejection nobody can
  /// diagnose from the message.
  static int? _toFils(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('.');
    if (parts.length > 2 || parts.first.isEmpty) return null;
    final birr = int.tryParse(parts.first);
    if (birr == null || birr < 0) return null;
    var fraction = 0;
    if (parts.length == 2) {
      if (parts[1].length > 2 || int.tryParse(parts[1]) == null) return null;
      fraction = int.parse(parts[1].padRight(2, '0'));
    }
    return birr * 100 + fraction;
  }

  /// An optional amount, or null when the field is blank.
  ///
  /// Blank and zero are different: a rule may legitimately carry no per-km
  /// component, but a per-km of zero fils would be a real (and probably wrong)
  /// assertion, so only an empty field means "not supplied".
  static int? _optionalFils(String raw) {
    if (raw.trim().isEmpty) return null;
    return _toFils(raw);
  }

  void _submit() {
    final ruleKey = _key.text.trim();
    final base = _toFils(_base.text);
    final perKm = _optionalFils(_perKm.text);
    final minimum = _optionalFils(_minimum.text);
    final reason = _reason.text.trim();

    if (ruleKey.isEmpty) {
      setState(() => _error = 'Enter the rule key, such as Z1_Z2_ADULT.');
      return;
    }
    if (base == null || base < 1) {
      setState(() => _error = 'Enter the base fare in birr, such as 15.00.');
      return;
    }
    // A malformed optional field must be reported, not silently dropped: sending
    // "12.5.5" as absent would quietly draft a rule the author did not intend.
    if (_perKm.text.trim().isNotEmpty && perKm == null) {
      setState(() => _error = 'The per-kilometre amount is not a valid figure.');
      return;
    }
    if (_minimum.text.trim().isNotEmpty && minimum == null) {
      setState(() => _error = 'The minimum fare is not a valid figure.');
      return;
    }
    if (reason.isEmpty) {
      // Mandatory, and not a formality: this is the line an auditor reads to
      // understand why the price of a journey changed.
      setState(() => _error = 'Record why this fare is changing.');
      return;
    }

    Navigator.of(context).pop({
      'ruleKey': ruleKey,
      'mode': _mode.text.trim(),
      'baseFareFils': base,
      'perKmFils': ?perKm,
      'minimumFareFils': ?minimum,
      'originZone': _blankToNull(_origin.text),
      'destinationZone': _blankToNull(_destination.text),
      // ISO-8601 date only. Sending a full timestamp makes the server's parse of
      // "when does this start" depend on a time of day nobody chose.
      'effectiveFrom': _effectiveFrom.toIso8601String().split('T').first,
      'changeReason': reason,
    });
  }

  static String? _blankToNull(String raw) {
    final t = raw.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveFrom,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _effectiveFrom = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Draft a fare version', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'This records a draft. Making it live is a separate action taken by '
            'someone with the approval right.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _key,
            decoration: const InputDecoration(labelText: 'Rule key'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _mode.text,
            decoration: const InputDecoration(labelText: 'Mode'),
            items: [
              for (final m in _modes)
                DropdownMenuItem(value: m, child: Text(m)),
            ],
            onChanged: (v) => setState(() => _mode.text = v ?? 'BUS'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _base,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Base fare (ETB)'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _perKm,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Per km (ETB)'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _minimum,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Minimum (ETB)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _origin,
                  decoration: const InputDecoration(labelText: 'From zone'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _destination,
                  decoration:
                      const InputDecoration(labelText: 'To zone'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // A tappable field rather than a date picker inline: the sheet is
          // already tall, and showDatePicker needs no explanation here.
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.event),
            label: Text(
              'Effective from '
              '${_effectiveFrom.toIso8601String().split('T').first}',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Why is this changing?',
              helperText: 'Recorded on the audit trail',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 18),
          FilledButton(onPressed: _submit, child: const Text('Record draft')),
        ],
      ),
    );
  }
}