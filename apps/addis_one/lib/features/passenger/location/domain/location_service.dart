import '../../../../core/models/journey.dart';

/// Why a position could not be obtained.
///
/// These are separate cases rather than one `failure` flag because the app's
/// response to each is different: a disabled toggle can be fixed by the user in
/// settings, a denied permission can be re-requested, and a denied-forever
/// permission needs a trip to app settings. Collapsing them produces a dead end
/// — "location unavailable" with no action attached.
enum LocationFailureReason {
  /// Location is switched off at the OS level.
  serviceDisabled,

  /// The passenger declined this time. Asking again is reasonable.
  permissionDenied,

  /// Declined permanently, or blocked by policy. Only app settings can undo it.
  permissionDeniedForever,

  /// A fix was requested but never arrived — indoors, or a weak GNSS signal.
  timeout,

  /// A fix arrived, but it is too coarse to name a stop with confidence.
  tooInaccurate,

  /// The position is genuine but outside the area the service covers. A fix in
  /// another city resolves to no stop at all, and saying so is the honest
  /// answer.
  outsideServiceArea,

  /// The fix was fine and the stop lookup reached no usable answer â€” the request
  /// failed. Distinct from `unknown` so the message does not blame the GPS.
  lookupFailed,

  /// The platform reported something we have no specific handling for.
  unknown,
}

/// Outcome of a position request. Either a point, or a reason it failed.
class LocationResult {
  const LocationResult.success(GeoPoint this.point, {this.accuracyMeters})
      : failure = null;

  const LocationResult.failed(LocationFailureReason this.failure)
      : point = null,
        accuracyMeters = null;

  final GeoPoint? point;

  /// Estimated horizontal accuracy. Null when unknown or on failure.
  final double? accuracyMeters;

  final LocationFailureReason? failure;

  bool get isSuccess => point != null;

  /// A fix this poor cannot honestly be called "your location".
  ///
  /// A phone in a taxi in heavy traffic can report a fix accurate to hundreds of
  /// metres, which in a city with stops every few hundred metres would snap to
  /// the wrong stop. Anything beyond [maxUsableAccuracyMeters] is treated as no
  /// answer rather than a bad one.
  static const double maxUsableAccuracyMeters = 200;

  bool get isAccurateEnough =>
      accuracyMeters != null && accuracyMeters! <= maxUsableAccuracyMeters;
}

/// Acquires the passenger's position.
///
/// An interface so the plugin sits behind a seam: tests drive this with a fake
/// and never touch platform channels, and the app can be exercised end-to-end on
/// a machine with no GPS hardware at all.
abstract interface class LocationService {
  /// Returns the current position, or the reason one is unavailable.
  ///
  /// Requests runtime permission if needed. Must not throw: every failure mode
  /// is a value, because a thrown exception here would be caught as an
  /// unexpected error and reported to the passenger as a bug.
  Future<LocationResult> currentPosition();
}
