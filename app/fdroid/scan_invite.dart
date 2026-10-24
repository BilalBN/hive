// The F-Droid build's stand-in for lib/features/connect/scan_invite.dart
// (copied over it by tools/fdroid_prepare.py): no camera scanning, because
// the QR scanner uses Google's ML Kit, which isn't free software. Joining
// works by typing the invite's address and code.
import 'package:flutter/material.dart';

class ScanInviteScreen extends StatelessWidget {
  const ScanInviteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) Navigator.of(context).pop();
    });
    return const SizedBox.shrink();
  }
}
