import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/ticket.dart';
import 'ticket_qr_screen.dart';

/// The signed-in passenger's tickets, read from `GET /tickets/mine`.
///
/// Tapping a ticket opens the same QR screen the purchase flow produces, so a
/// passenger can re-show a ticket after a payment — important when boarding
/// without phone signal, which is common on Addis routes.
class TicketsListScreen extends ConsumerStatefulWidget {
  const TicketsListScreen({super.key});

  @override
  ConsumerState<TicketsListScreen> createState() => _TicketsListScreenState();
}

class _TicketsListScreenState extends ConsumerState<TicketsListScreen> {
  late Future<List<IssuedTicket>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = ref.read(transportRepositoryProvider).myTickets();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(s.myTickets)),
      body: FutureBuilder<List<IssuedTicket>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorState(
              message: s.errorNetwork,
              onRetry: () => setState(_load),
            );
          }

          final tickets = snapshot.data ?? const <IssuedTicket>[];
          if (tickets.isEmpty) {
            return Center(child: Text(s.noTicketsYet));
          }

          return RefreshIndicator(
            onRefresh: () async => setState(_load),
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: tickets.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) =>
                  _TicketCard(ticket: tickets[index]),
            ),
          );
        },
      ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.ticket});

  final IssuedTicket ticket;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final boardable = ticket.isBoardableAt(DateTime.now());

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TicketQrScreen(ticket: ticket),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(
                Icons.confirmation_number_outlined,
                color: boardable ? AppColors.green : AppColors.inkMuted,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ticket.reference, style: theme.textTheme.titleMedium),
                    Text(
                      // Relative time is more useful here than a wall clock: a
                      // passenger needs "how long do I have", not the time.
                      _expiryLabel(ticket),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.inkMuted),
                    ),
                    if (ticket.isSimulatedPayment)
                      Text(
                        'Test payment — no real money moved',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: AppColors.yellowDark),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.inkMuted),
            ],
          ),
        ),
      ),
    );
  }

  String _expiryLabel(IssuedTicket ticket) {
    if (ticket.isExpiredAt(DateTime.now())) return 'Expired';
    final left = ticket.expiresAt.difference(DateTime.now());
    if (left.inHours >= 1) return 'Valid for ${left.inHours} h ${left.inMinutes % 60} min';
    return 'Valid for ${left.inMinutes} min';
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined,
              size: 40, color: AppColors.inkMuted),
          const SizedBox(height: AppSpacing.md),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
