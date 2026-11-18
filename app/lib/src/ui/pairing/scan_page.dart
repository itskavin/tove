import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/tokens.dart';

/// Opens the camera and returns the first QR code's text, or null when the
/// user goes back. The camera permission is requested here, when the user
/// tapped "Scan QR code", never earlier.
typedef QrScanner = Future<String?> Function(BuildContext context);

Future<String?> scanQrCode(BuildContext context) =>
    Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  /// Returned when the user chose to type the code instead.
  static const enterByHand = '\u0000enter-by-hand';

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final text = b.rawValue;
      if (text != null && text.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(text);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the QR code')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraProblem(
              denied:
                  error.errorCode == MobileScannerErrorCode.permissionDenied,
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.sheet,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(
                      'Point the camera at the QR code Hermes showed you.',
                      style: t.row.hermesWeight(400),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraProblem extends StatelessWidget {
  const _CameraProblem({required this.denied});
  final bool denied;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return ColoredBox(
      color: t.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_rounded, size: 40, color: t.textMuted),
              const SizedBox(height: 16),
              Text(
                denied
                    ? 'Tove needs the camera only to read the QR code. Allow '
                          'it in the phone’s settings, or enter the code by '
                          'hand instead.'
                    : 'The camera isn’t available. Enter the code by hand '
                          'instead.',
                style: t.row.copyWith(color: t.textMuted).hermesWeight(400),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(ScanPage.enterByHand),
                child: const Text('Enter the code instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
