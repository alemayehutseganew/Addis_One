import 'dart:typed_data';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Renders the ticket QR payload to shareable PNG bytes.
///
/// One function, used by both ticket screens, so the image a recipient scans
/// can never drift from the code the app shows. It paints the *same validated
/// matrix* — same signed string, same auto-picked version, same L error
/// correction, same gapless square modules the `QrImageView`s use — then
/// frames it with a 4-module white quiet zone. The margin matters because a
/// validator crops to the code's edges and chat bubbles and dark themes merge
/// an edge-to-edge code into the background; a code without margin is a code
/// that fails at the door.
///
/// Returns null when the payload will not encode: callers fall back to the
/// existing text share rather than sending an image that cannot scan. A QR
/// that looks fine and fails validation sends a passenger to the front of the
/// queue only to be turned away.
Future<Uint8List?> renderTicketQrPng({
  required String qrString,
  int qrPixelSize = 1024,
  int quietModules = 4,
}) async {
  if (qrString.trim().isEmpty) return null;
  try {
    final validation = QrValidator.validate(
      data: qrString,
      version: QrVersions.auto,
    );
    final qr = validation.qrCode;
    if (!validation.isValid || qr == null) return null;

    // QrPainter.withQr with the validated matrix: the modules are
    // byte-identical to what the on-screen view paints. gapless: true mirrors
    // QrImageView's default — the painter's own default is false.
    final painter = QrPainter.withQr(qr: qr, gapless: true);
    final modules = qr.moduleCount;
    if (modules <= 0) return null;
    final marginPx = (qrPixelSize / modules * quietModules).round();
    final framedSize = qrPixelSize + marginPx * 2;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, framedSize.toDouble(), framedSize.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      )
      ..translate(marginPx.toDouble(), marginPx.toDouble());
    painter.paint(canvas, ui.Size.square(qrPixelSize.toDouble()));
    final image =
        await recorder.endRecording().toImage(framedSize, framedSize);
    try {
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      return byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
    } finally {
      image.dispose();
    }
  } on Exception catch (e) {
    debugPrint('[ADDIS-SHARE] QR render failed: $e');
    return null;
  }
}

/// File name for the shared QR image.
///
/// The ticket reference only — enough for a recipient to tell four forwarded
/// images apart, nothing that discloses fare, route or name. Sanitised because
/// the name crosses into the OS share sheet.
String ticketQrFileName(String ticketReference) {
  final safe = ticketReference.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return 'addis-one-ticket-$safe.png';
}


/// Where a shared ticket is sent.
enum ShareTarget {
  /// The system share sheet — the passenger picks the app.
  system('system'),

  /// WhatsApp specifically.
  ///
  /// WhatsApp is named explicitly rather than left in the system sheet because
  /// it is how groups are actually organised in Addis — a family or a
  /// mahber-era travelling together is one chat, and putting "forward this to
  /// the group" two taps deep behind a sheet is the difference between a
  /// feature people use and one they route around.
  whatsapp('whatsapp');

  const ShareTarget(this.wire);
  final String wire;

  static ShareTarget fromWire(String? value) {
    return ShareTarget.values.firstWhere(
      (t) => t.wire == value,
      orElse: () => ShareTarget.system,
    );
  }
}

/// Shares a ticket to another person.
///
/// An interface rather than a direct plugin call, for the same reasons as
/// [SmsGateway]: the path is security-relevant and must be testable without a
/// device, and the app must not hard-depend on a plugin that is absent.
///
/// Note on `share_plus`: it is genuinely incompatible with this app's pinned
/// `connectivity_plus ^6.1.0` — pub's solver refuses it outright, because
/// `share_plus` needs `web <0.5.0` while `connectivity_plus >=6.1.5` needs
/// `web >=0.5.0`. Taking it would mean downgrading a dependency the existing
/// connectivity handling depends on, so this uses a platform channel instead.
/// That also gives exact control over targeting WhatsApp, which the generic
/// plugin does not expose.
abstract interface class TicketShareService {
  /// Shares [text], optionally targeted at a specific app.
  ///
  /// Returns true once the platform accepted the request — NOT when the
  /// recipient received it. The UI must say "shared", never "sent to" anyone;
  /// this class has no idea who, if anyone, read it.
  Future<bool> shareText({
    required String text,
    ShareTarget target = ShareTarget.system,
  });

  /// Shares a ticket's QR code as an image with [text] as the caption.
  ///
  /// [pngBytes] must be the rendered code for the very credential the on-screen
  /// QR shows — the same signed string, the same error correction — and already
  /// framed by a quiet zone on white, because chat bubbles and dark themes
  /// merge an edge-to-edge code into the background and scanners reject it.
  /// [fileName] carries the ticket reference only, so a shared file tells the
  /// recipient which ticket it is without leaking fares or names.
  ///
  /// Returns true once the platform accepted the request. Same "shared, never
  /// sent to" contract as [shareText].
  Future<bool> shareQr({
    required Uint8List pngBytes,
    required String fileName,
    required String text,
    ShareTarget target = ShareTarget.system,
  });

  /// Whether [target] appears to be installed.
  ///
  /// Advisory only. Used to hide a WhatsApp button rather than let it fail on
  /// tap, but the share itself still falls back to the system sheet, because a
  /// package-visibility miss must not cost the passenger their only way to
  /// forward a ticket.
  Future<bool> isAvailable(ShareTarget target);
}

/// [TicketShareService] over a Flutter [MethodChannel].
class MethodChannelTicketShareService implements TicketShareService {
  const MethodChannelTicketShareService({@visibleForTesting MethodChannel? channel})
      : _channel = channel ?? defaultChannel;

  /// Must match the channel name registered in `MainActivity.kt`.
  static const MethodChannel defaultChannel =
      MethodChannel('addis_one_passenger/share');

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable(ShareTarget target) async {
    try {
      return await _channel.invokeMethod<bool>(
            'isAvailable',
            {'target': target.wire},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[ADDIS-SHARE] availability failed: ${e.code} ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> shareText({
    required String text,
    ShareTarget target = ShareTarget.system,
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    try {
      final shared = await _channel.invokeMethod<bool>('share', {
        'text': text,
        'target': target.wire,
      });
      return shared ?? false;
    } on MissingPluginException catch (e) {
      throw StateError('Sharing is not available on this device: $e');
    } on PlatformException catch (e) {
      debugPrint('[ADDIS-SHARE] share failed: ${e.code} ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> shareQr({
    required Uint8List pngBytes,
    required String fileName,
    required String text,
    ShareTarget target = ShareTarget.system,
  }) async {
    if (pngBytes.isEmpty) {
      throw ArgumentError.value(pngBytes, 'pngBytes', 'must not be empty');
    }
    if (fileName.trim().isEmpty) {
      throw ArgumentError.value(fileName, 'fileName', 'must not be empty');
    }
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    try {
      // PNG travels as raw bytes over the channel: writing the file lives with
      // the host OS (FileProvider perms, cache dir ownership), and routing the
      // pixels through a string would corrupt them and a temp path would couple
      // this to whatever app sandbox the host grants us.
      final shared = await _channel.invokeMethod<bool>('shareQr', {
        'pngBytes': pngBytes,
        'fileName': fileName,
        'text': text,
        'target': target.wire,
      });
      return shared ?? false;
    } on MissingPluginException catch (e) {
      throw StateError('Sharing is not available on this device: $e');
    } on PlatformException catch (e) {
      debugPrint('[ADDIS-SHARE] share QR failed: ${e.code} ${e.message}');
      return false;
    }
  }
}

/// Builds the message used to forward a ticket.
///
/// The content is **identifiers only** — ticket reference, vehicle code, and
/// the signed credential. No fare, no route, no passenger name. This is the
/// same constraint the QR payload itself obeys (I4), extended to the forwarded
/// copy: a ticket ends up in group chats that get screenshotted and forwarded,
/// and a message that discloses what someone paid or where they were going
/// spreads further than the ticket did.
///
/// `shareRiderCount` appears because the shared thing is one ticket, and a
/// passenger forwarding it is usually doing so on behalf of several people. The
/// wording is deliberately plain about that rather than implying the recipient
/// has their own fare paid for.
class TicketShareBuilder {
  const TicketShareBuilder({this.appName = 'Addis One'});

  final String appName;

  String build({
    required String ticketReference,
    required String qrString,
    String? vehicleCode,
    String? vehicleRoute,
    int ticketNumber = 1,
    int totalTickets = 1,
  }) {
    final buffer = StringBuffer()
      ..writeln('$appName ticket')
      ..writeln('Ref: $ticketReference');

    // A journey ticket is not tied to one vehicle — the passenger may take any
    // bus on the planned route — so the line is omitted rather than filled with a
    // placeholder a recipient could try to match at the door. Omitting it keeps
    // the payload to identifiers only, exactly as a vehicle ticket does.
    if (vehicleCode != null && vehicleCode.trim().isNotEmpty) {
      buffer.writeln('Vehicle: $vehicleCode');
    }

    // The route is a label the recipient needs to know they are boarding the
    // right vehicle, and it is not personal data — unlike the fare, it does not
    // say anything about who is travelling.
    if (vehicleRoute != null && vehicleRoute.trim().isNotEmpty) {
      buffer.writeln('Route: $vehicleRoute');
    }

    // Position within a group booking. Tells the recipient which of several
    // forwarded tickets is theirs, without ever saying whose it is.
    if (totalTickets > 1) {
      buffer.writeln('Ticket $ticketNumber of $totalTickets');
    }

    buffer
      ..writeln()
      ..writeln(qrString)
      ..writeln();

    // Always stated, for every ticket, because the message lands in a group
    // chat where it may be forwarded onward by someone who never read it. Each
    // ticket validates once; forwarding it does not mint more.
    buffer.writeln(
      'One ticket = one boarding. Sharing this does not create another ticket.',
    );

    return buffer.toString();
  }
}