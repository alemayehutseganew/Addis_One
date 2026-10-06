import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sends the ticket QR to a phone number as SMS (step 13).
///
/// An interface rather than a direct plugin call, for two reasons: the send path
/// is security-relevant and must be testable without a device, and the app must
/// not hard-depend on a plugin that is absent from `pubspec.yaml`. The
/// implementation below uses a [MethodChannel] the Android host provides, and
/// degrades to a clear "not available" rather than a crash when it does not.
abstract interface class SmsGateway {
  /// Whether this device can send SMS at all.
  ///
  /// Checked before showing the option rather than after a failed send: a
  /// button that is present and does nothing is worse than one that is absent.
  Future<bool> isAvailable();

  /// Sends [body] to [phone].
  ///
  /// Returns true once the platform has accepted the message. This does NOT mean
  /// it was delivered — Android's composer hands off to the telephony stack, and
  /// true delivery is the carrier's business, not the app's. The UI says
  /// "sent", never "received".
  Future<bool> send({required String phone, required String body});
}

/// [SmsGateway] over a Flutter [MethodChannel].
class MethodChannelSmsGateway implements SmsGateway {
  const MethodChannelSmsGateway({
    @visibleForTesting MethodChannel? channel,
  }) : _channel = channel ?? defaultChannel;

  /// Must match the channel name registered in `MainActivity.kt`.
  static const MethodChannel defaultChannel =
      MethodChannel('addis_one_passenger/sms');

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() async {
    try {
      final available =
          await _channel.invokeMethod<bool>('isAvailable') ?? false;
      return available;
    } on MissingPluginException {
      // No host implementation — a test host, or a platform this app does not
      // ship on. Treated as "cannot send" so the UI hides the option.
      return false;
    } on PlatformException catch (e) {
      debugPrint('[ADDIS-SMS] availability check failed: ${e.code} ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> send({required String phone, required String body}) async {
    if (phone.trim().isEmpty) {
      throw ArgumentError.value(phone, 'phone', 'must not be empty');
    }
    try {
      final sent = await _channel.invokeMethod<bool>('send', {
        'phone': phone.trim(),
        'body': body,
      });
      return sent ?? false;
    } on MissingPluginException catch (e) {
      throw StateError('SMS is not available on this device: $e');
    } on PlatformException catch (e) {
      debugPrint('[ADDIS-SMS] send failed: ${e.code} ${e.message}');
      return false;
    }
  }
}

/// Builds the SMS body for a ticket.
///
/// The message carries the ticket reference, the vehicle code and the signed QR
/// string — identifiers only. It carries no fare and no route, matching I4: a
/// forwarded or photographed message must not disclose what someone paid.
///
/// Falls back to a shorter body if the full credential would exceed the
/// 160-segment budget of a concatenated SMS. Silently truncating is not an
/// option — a half-credential QR scans and then fails at the validator, which
/// looks to the passenger like being falsely rejected on board.
class TicketSmsBuilder {
  const TicketSmsBuilder({this.maxLength = 1400});

  /// Comfortably inside the multipart limit on a single SMS with a URL-style
  /// shortcode, leaving room for the header lines.
  final int maxLength;

  /// Builds the message, or null when the credential cannot fit.
  ///
  /// Null is a real outcome the UI must handle: it is better to say "this
  /// ticket is too long to send" than to send something that will not validate.
  String? build({
    required String ticketReference,
    required String qrString,
    String? vehicleCode,
    String appName = 'Addis One',
  }) {
    // Same rule as the share builder: a journey ticket has no single vehicle, so
    // the line is left out rather than showing a blank or a fake code.
    final header = StringBuffer()
      ..writeln('$appName ticket')
      ..writeln('Ref: $ticketReference');
    if (vehicleCode != null && vehicleCode.trim().isNotEmpty) {
      header.writeln('Vehicle: $vehicleCode');
    }

    final body = '$header$qrString';
    if (body.length <= maxLength) return body;

    // No shorter safe form exists: the credential IS the ticket, and there is
    // no short code the validator accepts in its place.
    return null;
  }
}