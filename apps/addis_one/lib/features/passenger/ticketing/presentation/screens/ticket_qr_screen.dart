import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/ticket.dart';
import '../../../vehicle_code/data/sms_gateway.dart';
import '../../../vehicle_code/data/ticket_share.dart';

/// Issued ticket — the QR an inspector scans.
///
/// A QR is rendered **only** when the backend has issued a signed credential.
/// With no credential nothing is shown: an empty or locally-generated code would
/// be a ticket that cannot be validated, and displaying it is worse than saying
/// the ticket is not ready.
class TicketQrScreen extends ConsumerStatefulWidget {
  const TicketQrScreen({super.key, required this.ticket});

  final IssuedTicket ticket;

  @override
  ConsumerState<TicketQrScreen> createState() => _TicketQrScreenState();
}

class _TicketQrScreenState extends ConsumerState<TicketQrScreen> {
  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final ticket = widget.ticket;
    final boardable = ticket.isBoardableAt(DateTime.now());

    return Scaffold(
      appBar: AppBar(title: Text(s.myTickets)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (ticket.hasQr)
              _QrPanel(ticket: ticket, boardable: boardable)
            else
              _NoCredentialPanel(ticket: ticket),
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  children: [
                    _DetailRow(label: 'Reference', value: ticket.reference),
                    const Divider(height: AppSpacing.lg),
                    _DetailRow(label: s.totalFare, value: ticket.fare.display),
                    const Divider(height: AppSpacing.lg),
                    _DetailRow(label: 'Status', value: ticket.status.wire),
                    const Divider(height: AppSpacing.lg),
                    _DetailRow(
                      label: 'Expires',
                      value: _formatTime(ticket.expiresAt),
                    ),
                  ],
                ),
              ),
            ),
            // Forwarding, the same as the vehicle-code ticket screen. A planned
            // trip is very often a group trip, and without this the only way to
            // get a friend's ticket to them is to photograph this screen.
            if (ticket.hasQr) ...[
              const SizedBox(height: AppSpacing.md),
              _SharePanel(ticket: ticket),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// Sends this ticket to whoever is travelling alongside.
///
/// Reuses the vehicle-code flow's share and SMS builders rather than a second
/// implementation, so a journey ticket and a boarding ticket are worded
/// identically and cannot drift apart in what they disclose — both carry
/// identifiers only, never the fare.
class _SharePanel extends ConsumerStatefulWidget {
  const _SharePanel({required this.ticket});

  final IssuedTicket ticket;

  @override
  ConsumerState<_SharePanel> createState() => _SharePanelState();
}

class _SharePanelState extends ConsumerState<_SharePanel> {
  /// WhatsApp may not be installed, and this device may have no telephony at
  /// all (an emulator, or a tablet with no SIM). Resolved once per screen
  /// rather than per tap, so the buttons render in the shape they can actually
  /// perform instead of failing when pressed.
  bool? _whatsappAvailable;
  bool? _smsAvailable;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final whatsapp = await ref
        .read(ticketShareServiceProvider)
        .isAvailable(ShareTarget.whatsapp);
    final sms = await ref.read(smsGatewayProvider).isAvailable();
    if (!mounted) return;
    setState(() {
      _whatsappAvailable = whatsapp;
      _smsAvailable = sms;
    });
  }

  /// The shared text for this ticket.
  ///
  /// A journey ticket has no vehicle code, so that line is omitted — see
  /// [TicketShareBuilder.build].
  String _buildMessage() {
    return const TicketShareBuilder().build(
      ticketReference: widget.ticket.reference,
      qrString: widget.ticket.credential!.toQrString(),
      vehicleRoute: widget.ticket.mode,
    );
  }

  Future<void> _share(ShareTarget target, {bool asImage = false}) async {
    try {
      if (asImage) {
        // Same renderer as the vehicle screen — the image must be the same
        // code the QR view paints, with the same text travelling as caption.
        final png = await renderTicketQrPng(
          qrString: widget.ticket.credential!.toQrString(),
        );
        if (!mounted) return;
        if (png == null) {
          await ref.read(ticketShareServiceProvider).shareText(
                text: _buildMessage(),
                target: target,
              );
        } else {
          await ref.read(ticketShareServiceProvider).shareQr(
                pngBytes: png,
                fileName: ticketQrFileName(widget.ticket.reference),
                text: _buildMessage(),
                target: target,
              );
        }
        return;
      }
      await ref.read(ticketShareServiceProvider).shareText(
            text: _buildMessage(),
            target: target,
          );
    } on Object catch (error) {
      if (!mounted) return;
      _report('Could not share this ticket: $error');
    }
  }

  Future<void> _sendSms() async {
    final body = const TicketSmsBuilder().build(
      ticketReference: widget.ticket.reference,
      qrString: widget.ticket.credential!.toQrString(),
    );

    // A real outcome, not an edge case: a credential too long for one message
    // has no shorter valid form, and sending a truncated QR would produce a
    // ticket that scans and then fails at the validator.
    if (body == null) {
      _report('This ticket is too long to send by SMS');
      return;
    }

    final phone = await _askForPhone();
    if (phone == null) return;

    try {
      await ref.read(smsGatewayProvider).send(phone: phone, body: body);
    } on Object catch (error) {
      if (!mounted) return;
      _report('Could not open the SMS app: $error');
    }
  }

  Future<String?> _askForPhone() async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send by SMS'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(hintText: '09xxxxxxxx'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();

    final trimmed = entered?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  void _report(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Send this ticket', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'One ticket = one boarding. Sharing it does not create another.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.inkMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (_whatsappAvailable == true)
                  OutlinedButton.icon(
                    onPressed: () => _share(ShareTarget.whatsapp),
                    icon: const Icon(Icons.chat_rounded, size: 18),
                    label: const Text('WhatsApp'),
                  ),
                if (_smsAvailable == true)
                  OutlinedButton.icon(
                    onPressed: _sendSms,
                    icon: const Icon(Icons.sms_rounded, size: 18),
                    label: const Text('SMS'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _share(ShareTarget.system),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Share'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _share(ShareTarget.system, asImage: true),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                  label: Text(AppStringsScope.of(context).shareTicketQr),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders the signed credential as a QR code.
///
/// The encoded string is exactly the backend's credential JSON — same bytes,
/// same signature. The app never re-signs or re-serialises it locally.
class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.ticket, required this.boardable});

  final IssuedTicket ticket;
  final bool boardable;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final accent = boardable ? AppColors.green : AppColors.yellowDark;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.divider),
              ),
              child: QrImageView(
                data: ticket.credential!.toQrString(),
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  boardable ? Icons.check_circle_rounded : Icons.info_outline,
                  color: accent,
                  size: 18,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  boardable ? s.ticketValid : s.ticketExpired,
                  style:
                      Theme.of(context).textTheme.titleMedium?.copyWith(color: accent),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the backend has not issued a credential yet.
class _NoCredentialPanel extends StatelessWidget {
  const _NoCredentialPanel({required this.ticket});

  final IssuedTicket ticket;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const Icon(
              Icons.hourglass_empty_rounded,
              size: 40,
              color: AppColors.inkMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Ticket not ready',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text('Status: ${ticket.status.wire}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'A QR code appears once the payment is confirmed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}
