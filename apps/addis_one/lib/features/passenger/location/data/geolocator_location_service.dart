import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../../../core/models/journey.dart';
import '../domain/location_service.dart';

/// [LocationService] backed by the platform's location provider.
///
/// Coarse location is requested and accepted. Precise coordinates are not
/// needed to choose which stop to walk to, and asking for them raises the
/// permission bar for no benefit to the passenger. The manifest declares only
/// ACCESS_COARSE_LOCATION to match.
class GeolocatorLocationService implements LocationService {
  GeolocatorLocationService({
    this.timeout = const Duration(seconds: 15),
    GeolocatorPlatform? platform,
  }) : _platform = platform ?? GeolocatorPlatform.instance;

  /// A passenger standing at a stop will not wait indefinitely for a fix.
  final Duration timeout;

  final GeolocatorPlatform _platform;

  @override
  Future<LocationResult> currentPosition() async {
    try {
      if (!await _platform.isLocationServiceEnabled()) {
        return const LocationResult.failed(
          LocationFailureReason.serviceDisabled,
        );
      }

      var permission = await _platform.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await _platform.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        // Denied with "don't ask again", or blocked by policy. Re-requesting is
        // a no-op that returns instantly, so the app must not loop on it.
        return const LocationResult.failed(
          LocationFailureReason.permissionDeniedForever,
        );
      }
      if (permission == LocationPermission.denied) {
        return const LocationResult.failed(LocationFailureReason.permissionDenied);
      }

      final position = await _platform.getCurrentPosition(
        // The last known fix can be hours old; a stale position presented as
        // "current location" is worse than no answer, so a fresh one is required.
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 15),
        ),
      ).timeout(timeout);

      return LocationResult.success(
        GeoPoint(
          latitude: position.latitude,
          longitude: position.longitude,
        ),
        accuracyMeters: position.accuracy,
      );
    } on TimeoutException {
      return const LocationResult.failed(LocationFailureReason.timeout);
    } catch (_) {
      // Deliberately broad. A plugin can surface an exception for an unfamiliar
      // platform condition, and reporting "location is unavailable" is a better
      // outcome than crashing the planner over a GPS detail.
      return const LocationResult.failed(LocationFailureReason.unknown);
    }
  }
}
