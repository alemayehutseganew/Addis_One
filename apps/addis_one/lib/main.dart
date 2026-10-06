import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

/// Single entry point for both roles.
///
/// One binary, one fork: the person using it says whether they are a passenger
/// or staff, and everything downstream --?" which token is read, which client
/// policy applies, which screens exist --?" follows from that answer.
void main() {
  // Runs before the first frame so an early failure is reported rather than
  // swallowed by the binding's default handler.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    // Mirrored to logcat: on a physical device there is no attached console, so
    // without this a crash is invisible to anyone debugging the app.
    debugPrint('[ADDIS] FlutterError: ${details.exceptionAsString()}');
    debugPrint('[ADDIS] Library: ${details.library}');
    if (details.stack != null) {
      debugPrint('[ADDIS] Stack: ${details.stack}');
    }
  };

  // Errors from the engine and from async gaps that FlutterError.onError does
  // not cover (a failed Future nobody awaited, for instance).
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[ADDIS] Uncaught: $error');
    debugPrint('[ADDIS] Stack: $stack');
    return true; // handled: do not also crash the isolate
  };

  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    // Portrait only: this is a one-handed, on-the-move app. A passenger
    // boarding a bus is not going to benefit from a landscape layout, and an
    // inspector holding a camera at a door gains nothing either. The camera
    // preview and the verdict card are both designed for a tall screen.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // ProviderScope wraps the whole app so every screen can reach the
    // composition root without a repository being passed down by hand.
    runApp(const ProviderScope(child: AddisOneApp()));
  }, (error, stack) {
    debugPrint('[ADDIS] Zone error: $error');
    debugPrint('[ADDIS] Stack: $stack');
  });
}