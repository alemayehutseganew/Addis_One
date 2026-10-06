import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/ticket.dart';
import '../../../../../core/models/ticket_validation.dart';
import '../../../../../core/models/vehicle.dart';
import '../../data/sms_gateway.dart';
import '../../data/ticket_share.dart';

/// The issued tickets for a vehicle — steps 10 to 16.
///
/// A group booking produces several tickets, each an independent, single-use
/// credential. The first is shown full-size for the passenger's own boarding;
/// the rest are listed so each can be forwarded to whoever it belongs to.
///
/// **No names anywhere.** There is no field on this screen, and none in the
/// share payload, that records who a ticket is for. That is what lets someone pay
/// for family and hand each person their QR without telling the system anything
/// about them — and it matches invariant I4, under which the credential carries
/// identifiers only.
///
/// A QR is rendered **only** when the backend issued a signed credential. With
/// no credential this screen says the ticket is not ready rather than showing an
/// empty or locally-generated code: a code that will not validate on board is
/// worse than an honest "not ready", because it sends the passenger to the front
/// of the queue only to be turned away.
class VehicleTicketScreen extends ConsumerStatefulWidget {
  const VehicleTicketScreen({
    super.key,
    required this.tickets,
    required this.vehicle,
    required this.quantityPaid,
  });

  final List<IssuedTicket> tickets;
  final VehicleProfile vehicle;
  final int quantityPaid;

  @override
  ConsumerState<VehicleTicketScreen> createState() =>
      _VehicleTicketScreenState();
}

class _VehicleTicketScreenState extends ConsumerState<VehicleTicketScreen> {
  /// Locally-held copies, so a refresh (step 15) updates what is on screen
  /// without needing to re-fetch. Keyed by ticket id so one validator scan
  /// updates just that ticket.
  late List<IssuedTicket> _tickets = List.of(widget.tickets);

  /// Index of the ticket currently shown full-size for the passenger's own use.
  int _selected = 0;

  bool _smsAvailable = false;
  bool _whatsappAvailable = false;
  bool _checking = false;
  bool _sending = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _probeSms();
    _probeWhatsapp();
  }

  IssuedTicket get _current => _tickets[_selected];

  /// True when fewer tickets came back than were paid for.
  bool get _isShort => _tickets.length < widget.quantityPaid;

  /// Replaces a ticket in place after a refresh, keeping its position in the
  /// list so the ordering the passenger saw does not shuffle under them.
  void _replaceTicket(IssuedTicket fresh) {
    final index = _tickets.indexWhere((t) => t.id == fresh.id);
    if (index < 0) return;
    setState(() {
      final next = List.of(_tickets);
      next[index] = fresh;
      _tickets = next;
    });
  }

  /// Whether SMS is offered is resolved BEFORE the button is shown.
  ///
  /// A control that is visible and does nothing is worse than one that is
  /// absent, so this runs on entry rather than failing on tap.
  Future<void> _probeSms() async {
    final available = await ref.read(smsGatewayProvider).isAvailable();
    if (!mounted) return;
    setState(() => _smsAvailable = available);
  }

  /// Whether the direct WhatsApp button is offered.
  ///
  /// Advisory: when WhatsApp is absent the system share sheet still works, so
  /// this only decides whether the one-tap shortcut is shown — it never decides
  /// whether sharing is possible at all.
  Future<void> _probeWhatsapp() async {
    final available =
        await ref.read(ticketShareServiceProvider).isAvailable(ShareTarget.whatsapp);
    if (!mounted) return;
    setState(() => _whatsappAvailable = available);
  }

  /// Forwards this ticket to other passengers.
  ///
  /// Opens a confirmation first. Not ceremony: the shared thing is ONE ticket
  /// that validates once, and forwarding it to a group of four is the single
  /// most likely way a passenger ends up with three people turned away at the
  /// validator. Saying so at the moment they hit share is far kinder than
  /// having the driver explain it at the door.
  Future<void> _share(ShareTarget target,
      {IssuedTicket? ticket, bool asImage = false}) async {
    if (_sharing) return;

    final subject = ticket ?? _current;
    final credential = subject.credential;
    if (credential == null) return;

    final s = AppStringsScope.of(context);
    final isGroup = _tickets.length > 1;

    // No confirmation dialog for a single ticket on a single-ticket booking:
    // there is nothing to misunderstand. For a group it is essential.
    if (isGroup) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.ios_share, color: AppColors.green),
          title: Text(s.shareTicketTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.shareTicketDetail),
              const SizedBox(height: AppSpacing.md),
              // Each ticket is separately valid and separately single-use, so
              // this is not a caveat about a limitation — it is an instruction
              // that makes the sharing correct.
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.greenLight,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      size: 18,
                      color: AppColors.green,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        s.groupShareHint,
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(s.shareTicket),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final index = _tickets.indexWhere((t) => t.id == subject.id);
    final message = const TicketShareBuilder().build(
      ticketReference: subject.reference,
      vehicleCode: widget.vehicle.code,
      qrString: credential.toQrString(),
      vehicleRoute: widget.vehicle.routeLabelFor(s.isAmharic),
      ticketNumber: index < 0 ? 1 : index + 1,
      totalTickets: _tickets.length,
    );

    setState(() => _sharing = true);
    final bool shared;
    if (asImage) {
      // Render from the same matrix the screen paints, then fall back to the
      // text share if encoding fails — a recipient holding no QR at all
      // boards; a recipient holding an unscannable one does not.
      final png = await renderTicketQrPng(qrString: credential.toQrString());
      if (!mounted) return;
      shared = png == null
          ? await ref
              .read(ticketShareServiceProvider)
              .shareText(text: message, target: target)
          : await ref.read(ticketShareServiceProvider).shareQr(
                pngBytes: png,
                fileName: ticketQrFileName(subject.reference),
                text: message,
                target: target,
              );
    } else {
      shared = await ref
          .read(ticketShareServiceProvider)
          .shareText(text: message, target: target);
    }
    if (!mounted) return;

    setState(() => _sharing = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(shared ? s.sharedToOthers : s.shareNotAvailable),
        ),
      );
  }

  /// Step 13: send the QR by SMS.
  ///
  /// Opens the system composer pre-filled and returns to this screen. It does
  /// NOT report delivery, and the confirmation says "sent", never "received" —
  /// Android hands the message to the telephony stack, and claiming delivery
  /// would be a promise the app cannot keep.
  Future<void> _sendBySms() async {
    final ticket = _current;
    final credential = ticket.credential;
    if (credential == null || _sending) return;

    final s = AppStringsScope.of(context);
    final phoneController = TextEditingController();

    final shouldSend = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _SmsDialog(
        controller: phoneController,
        s: s,
        // Null means the credential is too long to send intact. Saying so beats
        // truncating it into a message that will not validate on board.
        body: _messageFor(ticket),
      ),
    );

    final phone = phoneController.text.trim();
    phoneController.dispose();
    if (shouldSend != true || phone.isEmpty || !mounted) return;

    setState(() => _sending = true);
    final sent =
        await ref.read(smsGatewayProvider).send(phone: phone, body: _messageFor(ticket));
    if (!mounted) return;

    setState(() => _sending = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(sent ? s.sendQrBySms : s.smsNotAvailable)),
      );
  }

  /// The SMS body for [ticket], falling back to a bare marker if the
  /// credential will not fit. The SMS path never sends a truncated credential.
  String _messageFor(IssuedTicket ticket) {
    final credential = ticket.credential;
    if (credential == null) return '';
    return const TicketSmsBuilder().build(
          ticketReference: ticket.reference,
          vehicleCode: widget.vehicle.code,
          qrString: credential.toQrString(),
        ) ??
        '';
  }

  /// Steps 15–16 from the passenger's side: re-read the ticket so it shows
  /// VALIDATED once a validator has scanned it.
  ///
  /// Non-fatal by design. On a route with poor signal the validator may have
  /// been the only device with a connection, so this can legitimately fail while
  /// the QR on screen is perfectly valid — the passenger must never lose it.
  Future<void> _refreshStatus() async {
    if (_checking) return;
    setState(() => _checking = true);

    final fresh = await ref
        .read(vehicleCodeControllerProvider)
        .refresh(_current);

    if (!mounted) return;
    setState(() => _checking = false);
    if (fresh != null) _replaceTicket(fresh);
  }
@override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);
    final ticket = _current;
    final boardable = ticket.isBoardableAt(DateTime.now());
    final validated = ticket.status == TicketStatus.validated ||
        ticket.status == TicketStatus.completed;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.myTickets),
        leading: IconButton(
          icon: const Icon(Icons.close),
          // Back to the start of the flow rather than into the payment screen
          // behind this one, whose idempotency key has already been spent.
          onPressed: () => context.go(Routes.passengerHome),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              s.ticketReadyForVehicle,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),

            // A partial issuance is stated before anything else, so a passenger
            // who paid for four and got three reads it immediately rather than
            // after scanning a QR that is not there.
            if (_isShort) ...[
              _Banner(
                icon: Icons.info_outline,
                title: s.shortIssued,
                detail: s.shortIssuedDetail,
                color: AppColors.yellowDark,
              ),
              const SizedBox(height: AppSpacing.md),
            ],

            if (ticket.hasQr)
              _QrPanel(ticket: ticket, boardable: boardable, validated: validated)
            else
              const _NoCredentialPanel(),

            const SizedBox(height: AppSpacing.md),
            Text(
              s.showThisQrToValidator,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),

            // The other tickets in the booking. Each is separately shareable, so
            // the payer can hand each person their own QR.
            if (_tickets.length > 1) ...[
              _GroupTicketList(
                tickets: _tickets,
                selected: _selected,
                sharing: _sharing,
                onSelect: (index) => setState(() => _selected = index),
                onShare: (t) => _share(ShareTarget.whatsapp, ticket: t),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // Step 11 — everything the QR is linked to, stated explicitly so a
            // passenger disputing a charge can see what the system recorded.
            _TicketFacts(ticket: ticket, vehicle: widget.vehicle),

            const SizedBox(height: AppSpacing.lg),
            // Steps 14–16: entry/exit, two scans rather than one used flag.
            _EntryExitPanel(
              ticket: ticket,
              checking: _checking,
              onRefresh: _refreshStatus,
            ),

            const SizedBox(height: AppSpacing.lg),
            _ShareRow(
              whatsappAvailable: _whatsappAvailable,
              sharing: _sharing,
              onWhatsapp: () => _share(ShareTarget.whatsapp),
              onSystem: () => _share(ShareTarget.system),
              onShareQrImage: () => _share(ShareTarget.system, asImage: true),
            ),
            if (_smsAvailable)
              OutlinedButton.icon(
                onPressed: _sending ? null : _sendBySms,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sms_outlined),
                label: Text(s.sendQrBySms),
              ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: () => context.go(Routes.passengerHome),
              child: Text(s.buyAnother),
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
/// same signature. The app never re-signs or re-serialises it: a fresh
/// signature would carry a new nonce, invalidating any screenshot the passenger
/// already has and looking like a replay to a validator.
class _QrPanel extends StatelessWidget {
  const _QrPanel({
    required this.ticket,
    required this.boardable,
    required this.validated,
  });

  final IssuedTicket ticket;
  final bool boardable;
  final bool validated;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final accent = validated
        ? AppColors.modeBus
        : (boardable ? AppColors.green : AppColors.yellowDark);

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
                  validated
                      ? Icons.verified_rounded
                      : (boardable
                          ? Icons.check_circle_rounded
                          : Icons.info_outline),
                  color: accent,
                  size: 18,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  validated
                      ? s.ticketValidated
                      : (boardable ? s.ticketValid : s.ticketExpired),
                  style:
                      Theme.of(context).textTheme.titleMedium?.copyWith(color: accent),
                ),
              ],
            ),
            if (ticket.isSimulatedPayment) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Test payment — no real money moved',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: AppColors.yellowDark),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown when the backend has not issued a credential yet.
class _NoCredentialPanel extends StatelessWidget {
  const _NoCredentialPanel();

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

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
            Text(s.issuingTicket, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              s.ticketReady,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 11: everything the QR is linked to.
///
/// Shown to the passenger rather than kept internal, because a fare dispute is
/// settled by evidence — the vehicle, the transaction and the time must be
/// readable by the person who paid.
class _TicketFacts extends StatelessWidget {
  const _TicketFacts({required this.ticket, required this.vehicle});

  final IssuedTicket ticket;
  final VehicleProfile vehicle;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            _FactRow(label: s.vehicleCode, value: vehicle.code),
            const Divider(height: AppSpacing.lg),
            _FactRow(label: s.route, value: vehicle.routeLabelFor(s.isAmharic)),
            const Divider(height: AppSpacing.lg),
            _FactRow(
              label: s.operator,
              value: vehicle.operatorNameFor(s.isAmharic),
            ),
            const Divider(height: AppSpacing.lg),
            _FactRow(label: 'Reference', value: ticket.reference),
            const Divider(height: AppSpacing.lg),
            _FactRow(label: s.fare, value: ticket.fare.display),
            const Divider(height: AppSpacing.lg),
            _FactRow(label: s.paymentTransaction, value: ticket.reference),
            const Divider(height: AppSpacing.lg),
            _FactRow(
              label: s.ticketHistory,
              value: _formatTime(ticket.issuedAt),
            ),
            const Divider(height: AppSpacing.lg),
            _FactRow(label: s.ticketExpired, value: _formatTime(ticket.expiresAt)),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} $hh:$mm';
  }
}
/// The entry/exit record — the Chennai-style half of the lifecycle.
///
/// **Two scans, not one "used" flag.** Boarding is recorded by an entry scan and
/// the ride is closed by an exit scan. Two reasons this matters:
///
///  1. The middle state — entered, not yet exited — is *normal*. A passenger
///     mid-journey is exactly where they should be, so it renders as a calm
///     confirmation with the instruction to show the QR again on the way off,
///     never as a warning. A single flag has nowhere to put that state, which is
///     why flat "mark as used" designs mislead people mid-ride.
///
///  2. The pairing is what enforces single use. A second entry scan is refused
///     by the server, so one fare cannot board two people. That control simply
///     does not exist in a design with one boolean.
class _EntryExitPanel extends StatelessWidget {
  const _EntryExitPanel({
    required this.ticket,
    required this.checking,
    required this.onRefresh,
  });

  final IssuedTicket ticket;
  final bool checking;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);

    final entry = ticket.entryValidation;
    final exit = ticket.exitValidation;

    final (headline, detail, accent) = switch (ticket.journeyStage) {
      JourneyStage.notYetBoarded => (
          s.presentToValidator,
          s.showThisQrToValidator,
          AppColors.green,
        ),
      JourneyStage.onboard => (
          s.currentlyOnboard,
          s.currentlyOnboardDetail,
          AppColors.modeBus,
        ),
      JourneyStage.alighted => (
          s.rideComplete,
          s.ticketUsed,
          AppColors.inkMuted,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                switch (ticket.journeyStage) {
                  JourneyStage.notYetBoarded => Icons.directions_bus_filled_rounded,
                  JourneyStage.onboard => Icons.airline_seat_recline_normal,
                  JourneyStage.alighted => Icons.check_circle_rounded,
                },
                color: accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  headline,
                  style: theme.textTheme.titleMedium?.copyWith(color: accent),
                ),
              ),
              if (checking)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(detail, style: theme.textTheme.bodySmall),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: _ScanChip(
                  label: s.entryScan,
                  at: entry?.scannedAt,
                  done: entry != null,
                  pendingLabel: s.notScannedYet,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _ScanChip(
                  label: s.exitScan,
                  at: exit?.scannedAt,
                  done: exit != null,
                  pendingLabel: s.notScannedYet,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Always available, not only when a validator is expected. The
          // passenger cannot know whether someone already scanned them, and a
          // hidden refresh leaves them unsure whether to board.
          OutlinedButton(
            onPressed: checking ? null : onRefresh,
            child: Text(s.refreshStatus),
          ),
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            value,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

/// Collects the recipient number and shows the exact message that will be sent.
class _SmsDialog extends StatefulWidget {
  const _SmsDialog({
    required this.controller,
    required this.s,
    required this.body,
  });

  final TextEditingController controller;
  final AppStrings s;

  /// The message body, or null when the credential is too long to send intact.
  final String? body;

  @override
  State<_SmsDialog> createState() => _SmsDialogState();
}

class _SmsDialogState extends State<_SmsDialog> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = widget.body;

    return AlertDialog(
      title: Text(widget.s.sendQrBySms),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: widget.s.phoneNumber),
          ),
          const SizedBox(height: AppSpacing.md),
          if (body == null)
            Text(
              'This ticket is too long to send by SMS. Show the QR directly.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.red),
            )
          else ...[
            Text(widget.s.smsBodyPreview, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.xs),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 140),
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: SingleChildScrollView(
                child: Text(
                  body,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(widget.s.cancel),
        ),
        FilledButton(
          // Disabled when the body is null: sending a truncated credential
          // would produce a message that scans and then fails validation.
          onPressed: body == null
              ? null
              : () => Navigator.of(context).pop(true),
          child: Text(widget.s.sendQrBySms),
        ),
      ],
    );
  }
}
/// One-line journey stage for a ticket in the group list.
String _stageLabel(IssuedTicket ticket, AppStrings s) {
  return switch (ticket.journeyStage) {
    JourneyStage.notYetBoarded => s.notScannedYet,
    JourneyStage.onboard => s.currentlyOnboard,
    JourneyStage.alighted => s.rideComplete,
  };
}

/// One end of the journey: scanned at a time, or not yet.
class _ScanChip extends StatelessWidget {
  const _ScanChip({
    required this.label,
    required this.at,
    required this.done,
    required this.pendingLabel,
  });

  final String label;
  final DateTime? at;
  final bool done;
  final String pendingLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = done ? AppColors.green : AppColors.inkMuted;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        // Filled once recorded, hollow before. The difference reads at a
        // glance, which matters when a phone is held at arm's length at a
        // vehicle door rather than looked at properly.
        color: done ? AppColors.greenLight : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: done ? AppColors.green : AppColors.divider),
      ),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                Text(
                  done ? _clock(at!) : pendingLabel,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// The other tickets in a group booking.
///
/// Each row is one fare, separately valid and separately single-use. Tapping a
/// row selects it for the big QR; the share button on it forwards that specific
/// ticket. That split is what makes "pay for four people" work: the payer sends
/// four different codes, not one code four times.
class _GroupTicketList extends StatelessWidget {
  const _GroupTicketList({
    required this.tickets,
    required this.selected,
    required this.sharing,
    required this.onSelect,
    required this.onShare,
  });

  final List<IssuedTicket> tickets;
  final int selected;
  final bool sharing;
  final ValueChanged<int> onSelect;
  final ValueChanged<IssuedTicket> onShare;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.ticketsIssued, style: theme.textTheme.titleMedium),
            Text(
              s.noNamesNeeded,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (var i = 0; i < tickets.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                selected: i == selected,
                // Position is the only thing distinguishing them — there are no
                // names, by design.
                title: Text(tickets[i].reference),
                // Per-ticket journey stage: in a group booking each person is
                // scanned separately, so one being onboard says nothing about
                // the others.
                subtitle: Text(_stageLabel(tickets[i], s)),
                leading: Icon(
                  switch (tickets[i].journeyStage) {
                    JourneyStage.notYetBoarded => Icons.circle_outlined,
                    JourneyStage.onboard => Icons.airline_seat_recline_normal,
                    JourneyStage.alighted => Icons.check_circle_rounded,
                  },
                  size: 18,
                  color: tickets[i].journeyStage == JourneyStage.notYetBoarded
                      ? AppColors.inkMuted
                      : AppColors.green,
                ),
                onTap: () => onSelect(i),
                trailing: IconButton(
                  tooltip: s.shareTicket,
                  onPressed: sharing ? null : () => onShare(tickets[i]),
                  icon: const Icon(Icons.ios_share, size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline notice strip with a title and supporting detail.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.title,
    required this.detail,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(color: color),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The share controls.
///
/// WhatsApp gets its own button when installed, because forwarding a ticket to
/// the family or work group chat is the overwhelmingly common case and burying
/// it two taps deep in a system sheet is how a feature gets worked around. The
/// system sheet is always available alongside it as the fallback, so nothing is
/// lost when WhatsApp is not there.
class _ShareRow extends StatelessWidget {
  const _ShareRow({
    required this.whatsappAvailable,
    required this.sharing,
    required this.onWhatsapp,
    required this.onSystem,
    required this.onShareQrImage,
  });

  final bool whatsappAvailable;
  final bool sharing;
  final VoidCallback onWhatsapp;
  final VoidCallback onSystem;
  final VoidCallback onShareQrImage;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    final icon = sharing
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.ios_share);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (whatsappAvailable) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: sharing ? null : onWhatsapp,
                  icon: sharing
                      ? icon
                      : const Icon(Icons.chat, color: Color(0xFF25D366)),
                  label: Text(s.shareToWhatsapp),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(
              child: OutlinedButton.icon(
                onPressed: sharing ? null : onSystem,
                icon: icon,
                label: Text(s.shareMore),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        // Image alongside text: recipients holding a scannable QR hand it to
        // the validator; recipients holding only the identifiers quote a
        // reference that needs typing in somewhere. The image carries the
        // boarding power of the ticket itself, so it shares the same entry
        // point and the same one-ticket warning as the text share — it is a
        // different format of the same forward, not a separate feature.
        OutlinedButton.icon(
          onPressed: sharing ? null : onShareQrImage,
          icon: sharing ? icon : const Icon(Icons.qr_code_2_rounded),
          label: Text(s.shareTicketQr),
        ),
      ],
    );
  }
}

/// Label/value row for the ticket facts card.