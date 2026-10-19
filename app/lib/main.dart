import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/home_connection.dart';
import 'core/startup.dart';
import 'player/media_session.dart';

/// Starts Hive. Any failure before the first screen is shown on screen rather
/// than leaving the launch logo up forever.
void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      installReadableErrorWidget();
      final SharedPreferences prefs;
      try {
        prefs = await SharedPreferences.getInstance().timeout(startupTimeout);
      } catch (error, stack) {
        debugPrint('Hive startup failed: $error\n$stack');
        runApp(StartupFailedApp(error: error, stack: stack));
        return;
      }
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      await initAudio(container);
      // This device's saved sign-in, before the first screen decides where to go.
      await container
          .read(authLoadedProvider.future)
          .timeout(startupTimeout, onTimeout: () {});
      runApp(
        UncontrolledProviderScope(container: container, child: const HiveApp()),
      );
      // CI's Android smoke test waits for this line in the device log.
      debugPrint('Hive started');
    },
    (error, stack) {
      debugPrint('Hive error: $error\n$stack');
      // Nothing on screen yet means the failure happened before runApp.
      if (WidgetsBinding.instance.rootElement == null) {
        runApp(StartupFailedApp(error: error, stack: stack));
      }
    },
  );
}
