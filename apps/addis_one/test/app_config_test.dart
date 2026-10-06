// Guards the build-flag defaults.
//
// `USE_DEMO_DATA` used to default to true, which meant the most likely way to
// produce an APK — `flutter build apk --release`, with no dart-define — was a
// build serving invented fares and itineraries to whoever installed it. The UI
// badges a demo build, but a badge sitting on another screen is a mitigation,
// not a guarantee: a tester screenshotting a planned itinerary captures the
// fabrication without it.
//
// These assertions read the compiled-in defaults, which is the point: a build
// with no flags gets exactly what is asserted here. Note the trade-off — running
// `flutter test --dart-define=USE_DEMO_DATA=true` to exercise the demo build
// will fail them. That is deliberate, because the alternative is a guard that
// silently stops guarding the moment someone defines the flag.
import 'package:addis_one/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a build with no flags does not serve demo data', () {
    expect(
      AppConfig.useDemoData,
      isFalse,
      reason: 'The default build must talk to the backend. Demo data is '
          'something you opt into, not something you get by forgetting a flag.',
    );
  });

  test('the build flavour agrees with the data source', () {
    // These two are read independently, so a plain `flutter build apk` would
    // otherwise be able to describe itself 'demo' while serving live data, or
    // the reverse — which is precisely how a build stops being trustworthy.
    expect(AppConfig.buildFlavour, 'live');
    expect(AppConfig.useDemoData, isFalse);
  });

  test('dev sign-in is not offered by default', () {
    // It hands out a session without an OTP. It is a development affordance for
    // skipping the phone-number screen, not a feature.
    expect(AppConfig.enableDevSignIn, isFalse);
  });
}