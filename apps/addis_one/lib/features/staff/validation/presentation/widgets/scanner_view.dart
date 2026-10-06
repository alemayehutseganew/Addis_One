import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../../app/providers.dart';
import '../../../../../core/config/app_config.dart';
import '../../../../../core/network/api_failure.dart';
import '../../data/scan_submitter.dart';
import 'scanner_chrome.dart';

/// Camera scan surface.
///
/// The debounce here is the most consequential line in the app. A ticket held in
/// frame produces many detections per second; without a floor the officer records
/// the same passenger repeatedly while reading the previous verdict, and for
/// ALREADY_USED that manufactures fraud evidence against a paying passenger.
class ScannerView extends ConsumerStatefulWidget {
  const ScannerView({super.key, required this.onResult});

  final void Function(ScanSubmission submission) onResult;

  @override
  ConsumerState<ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends ConsumerState<ScannerView> {
  MobileScannerController? _controller;
  DateTime? _lastScanAt;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  void _startCamera() {
    try {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        // Barcodes only. A passenger's national ID and a payment QR are both QR
        // codes in a pocket full of them; scanning every format would push
        // unrelated personal data at the validation endpoint.
        formats: const [BarcodeFormat.qrCode],
      );
    } catch (_) {
      // Routed to manual entry rather than leaving a dead black rectangle.
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;

    final now = DateTime.now();
    final last = _lastScanAt;
    if (last != null && now.difference(last) < AppConfig.scanDebounce) return;

    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;

    // Stamped before the request, not after: a slow network must not let the
    // same ticket through again while this call is still in flight.
    _lastScanAt = now;
    await _submit(raw);
  }

  Future<void> _submit(String qrString) async {
    setState(() => _busy = true);
    try {
      final submitter = ref.read(scanSubmitterProvider);
      final submission = await submitter.submit(qrString);

      // Refreshed whether or not this scan queued anything: the count is what
      // tells the officer work is still unsent.
      ref.read(pendingScanCountProvider.notifier).state =
          await submitter.pendingCount;

      if (mounted) widget.onResult(submission);
    } on ApiException catch (e) {
      if (mounted) {
        _showError(e.failure == ApiFailure.unauthorized
            ? 'Your session has ended. Sign in again.'
            : 'Could not validate this ticket. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Accepts a pasted or typed credential.
  ///
  /// The length floor matches the server's DTO, so an obviously truncated paste
  /// is caught here rather than consuming one of the officer's five attempts.
  Future<void> _promptForCode() async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter ticket code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Paste the ticket credential',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Validate'),
          ),
        ],
      ),
    );

    // The server requires at least 20 characters; anything shorter is not a
    // ticket and would only waste an attempt.
    if (value == null || value.length < 20 || !mounted) return;
    await _submit(value);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (controller == null) {
      return CameraUnavailable(onManualEntry: _promptForCode);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: controller,
          onDetect: _onDetect,
          errorBuilder: (context, error, child) =>
              CameraUnavailable(onManualEntry: _promptForCode),
        ),
        const ScannerReticle(),
        if (_busy)
          const ColoredBox(
            color: Color(0x33000000),
            child: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
      ],
    );
  }
}
