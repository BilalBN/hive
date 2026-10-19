import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../design/icons.g.dart';
import '../../design/tokens.g.dart';

/// The camera, looking for an invite's QR code. Pops with what it read.
class ScanInviteScreen extends StatefulWidget {
  const ScanInviteScreen({super.key});

  @override
  State<ScanInviteScreen> createState() => _ScanInviteScreenState();
}

class _ScanInviteScreenState extends State<ScanInviteScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _found(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final text = code.rawValue;
      if (text != null && text.startsWith('hive://join')) {
        _done = true;
        Navigator.of(context).pop(text);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _found,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(HiveSpace.lg),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Hive needs the camera to scan the invite. Allow it in Settings, or go back and type the code.'
                      : "The camera didn't start. Go back and type the code instead.",
                  textAlign: TextAlign.center,
                  style: HiveType.body.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
          // A frame to aim with.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: 'Close',
                    icon: const Icon(HiveIcons.x, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(HiveSpace.lg),
                  child: Text(
                    'Point the camera at the QR code in the invite.',
                    textAlign: TextAlign.center,
                    style: HiveType.headline.copyWith(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
