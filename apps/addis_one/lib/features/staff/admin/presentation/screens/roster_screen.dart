import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/models/reference.dart';
import '../../../../../core/network/api_failure.dart';
import '../../../common/presentation/widgets/message_pane.dart';

/// The staff roster, for changing a role or an employment state.
///
/// The most consequential screen in the app: a role change here grants or removes
/// another person's authority, effective on their very next request, because the
/// server re-reads the role live rather than trusting the token.
///
/// Because of that, every change confirms before sending. A mis-tap here takes
/// effect immediately for somebody else and is not something the person tapping
/// can undo.
class RosterScreen extends ConsumerStatefulWidget {
  const RosterScreen({super.key});

  @override
  ConsumerState<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends ConsumerState<RosterScreen> {
  late Future<List<StaffMember>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<StaffMember>> _load() =>
      ref.read(staffRepositoryProvider).staffRoster(includeInactive: true);

  void _reload() => setState(() => _future = _load());

  Future<void> _update(String id, Map<String, dynamic> input, String verb) async {
    if (id.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(staffRepositoryProvider)
          .updateStaff(staffId: id, input: input);
      messenger.showSnackBar(SnackBar(content: Text(verb)));
      _reload();
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? 'That change was refused.')),
      );
    }
  }

  Future<void> _confirmRole(StaffMember row) async {
    final id = row.id;
    final current = row.role;
    if (id.isEmpty || current.isEmpty) return;

    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _RolePicker(current: current),
    );
    if (chosen == null || chosen == current) return;

    final ok = await _confirm(
      title: 'Change role?',
      body: '$current → $chosen\n\nThis takes effect on their next request, '
          'on any device they are signed in to.',
      confirmLabel: 'Change role',
    );
    if (ok) await _update(id, {'role': chosen}, 'Role changed');
  }

  Future<void> _confirmTermination(StaffMember row) async {
    if (row.id.isEmpty) return;
    final ok = await _confirm(
      title: 'Terminate this officer?',
      body: 'They will be refused on their next request.',
      confirmLabel: 'Terminate',
    );
    if (ok) await _update(row.id, {'terminatedAt': 'now'}, 'Officer terminated');
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff roster'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<StaffMember>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessagePane.forError(snapshot.error!, onRetry: _reload);
          }

          final rows = snapshot.data ?? const <StaffMember>[];
          if (rows.isEmpty) {
            return const EmptyPane(title: 'No staff records');
          }

          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final row = rows[i];
              return ListTile(
                title: Text(row.label),
                subtitle: Text(
                  [
                    row.role,
                    if (row.employeeCode != null) '${row.employeeCode}',
                    if (!row.isWorking) 'inactive',
                  ].join(' · '),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (choice) {
                    if (choice == 'role') _confirmRole(row);
                    if (choice == 'terminate') _confirmTermination(row);
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'role', child: Text('Change role')),
                    if (!row.isTerminated)
                      const PopupMenuItem(
                        value: 'terminate',
                        child: Text('Terminate'),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// The roles the schema defines.
///
/// Hard-coded on purpose, and only here. The server re-reads the role from the
/// database on every request, so this list cannot grant anything; it exists so
/// the dialog offers the real vocabulary instead of a free-text field, where a
/// typo would be rejected by the database with an error no officer can act on.
class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.current});

  final String current;

  static const _roles = [
    'SUPER_ADMIN',
    'TRANSPORT_BUREAU_ADMIN',
    'OPERATOR_ADMIN',
    'FINANCE',
    'AUDITOR',
    'SUPERVISOR',
    'INSPECTOR',
    'TICKET_OFFICER',
    'AGENT',
    'CONDUCTOR',
    'DRIVER',
  ];

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text('Role (currently $current)'),
      children: [
        for (final role in _roles)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(role),
            child: Text(role.replaceAll('_', ' ')),
          ),
      ],
    );
  }
}
