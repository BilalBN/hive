import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// How long the app waits for its saved settings before giving up and saying
/// so, instead of sitting on the launch screen forever.
const startupTimeout = Duration(seconds: 8);

/// Shown when the app can't finish starting. Deliberately plain: no theme,
/// fonts or providers, so it still appears when one of those is what failed.
/// The details are selectable so they can be copied into a bug report.
class StartupFailedApp extends StatelessWidget {
  const StartupFailedApp({super.key, required this.error, this.stack});

  final Object error;
  final StackTrace? stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                "Hive couldn't start",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Close Hive and open it again. If this keeps happening, '
                'send a screenshot of this page to whoever runs your home.',
              ),
              const SizedBox(height: 24),
              SelectableText(
                describeStartupError(error, stack),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String describeStartupError(Object error, StackTrace? stack) {
  final lines = stack?.toString().split('\n').take(8).join('\n') ?? '';
  return '$error\n\n$lines'.trim();
}

/// In release builds Flutter replaces a widget that failed to build with a
/// blank grey box. Show what went wrong instead, so a family member's
/// screenshot is enough to fix it.
void installReadableErrorWidget() {
  if (kDebugMode) return;
  ErrorWidget.builder = (details) => Material(
    color: const Color(0xFF1A1A1A),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        'Something on this screen failed to load.\n\n'
        '${describeStartupError(details.exception, details.stack)}',
        style: const TextStyle(color: Color(0xFFF2F2F2), fontSize: 12),
      ),
    ),
  );
}
