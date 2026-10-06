import 'package:equatable/equatable.dart';

/// The ways a call to the Addis One API can fail.
///
/// One enum for the whole app. The passenger half and the staff half each had
/// their own, and merging them into one is what stops a screen from having to
/// guess which vocabulary it is holding. The union is a superset of both:
///
///  * [timeout] came from the passenger half, where a payment that has not
///    settled inside the polling budget is its own outcome --?" distinct from a
///    transport failure, because the money may still be moving.
///  * [offline] came from the staff half, where a queued scan that could not
///    reach the server is not a failure to show the officer, it is a scan that
///    will settle later. Collapsing it into [network] would make the UI apologise
///    for something it is handling correctly.
///  * [unknown] is the passenger half's catch-all.
///
/// An enum rather than an exception hierarchy because callers branch on the
/// *cause* to decide what to say. An exhaustive switch on the cause is what
/// stops "no signal" and "server error" being reported with the same unhelpful
/// sentence.
enum ApiFailure {
  /// No route to the server, or the request timed out.
  network,

  /// Token missing, expired, or the caller is not permitted.
  unauthorized,

  /// The endpoint does not exist.
  notFound,

  /// The request was rejected as malformed, or a business rule refused it.
  validation,

  /// The payment or ticket did not settle within the polling budget.
  timeout,

  /// Anything else 5xx.
  server,

  /// The request was cancelled before completing.
  cancelled,

  /// Queued locally for later delivery rather than sent now.
  offline,

  /// Unclassified.
  unknown;

  /// Whether retrying the identical request could plausibly succeed.
  ///
  /// Used by the offline queue, which must not accumulate entries that will
  /// never be accepted: a 403 queued forever would replay a permanent failure
  /// on every reconnect. [timeout] counts as retryable because a payment can
  /// still settle after the client stopped watching it.
  bool get isRetryable =>
      this == ApiFailure.network ||
      this == ApiFailure.server ||
      this == ApiFailure.timeout ||
      this == ApiFailure.unknown;
}

/// A failed API call, carrying the cause and any server-provided explanation.
class ApiException extends Equatable implements Exception {
  const ApiException(
    this.failure, {
    this.message,
    this.statusCode,
  });

  final ApiFailure failure;

  /// Server-supplied text when present, otherwise null.
  final String? message;

  final int? statusCode;

  bool get isRetryable => failure.isRetryable;

  @override
  List<Object?> get props => [failure, message, statusCode];

  @override
  String toString() => 'ApiException($failure, $message, $statusCode)';
}