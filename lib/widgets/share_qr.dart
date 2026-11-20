import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// White modules either side of the symbol. The QR spec asks for 4; scanners
/// need it to find the edge, especially on a busy photo.
const int kShareQrQuietZone = 4;

/// Encodes [data] as a QR symbol at medium error correction, which survives
/// the recompression social networks apply to shared images.
QrImage shareQrImage(String data) => QrImage(QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ));

/// Paints [data] as a QR code, black on white, with its quiet zone, filling
/// a square canvas. Plain [CustomPaint] so the share card stays pixels only
/// when captured by `renderShareCardPng`.
class ShareQrPainter extends CustomPainter {
  ShareQrPainter(this.data) : _image = shareQrImage(data);

  /// The text encoded (public for tests).
  final String data;
  final QrImage _image;

  /// Modules across, quiet zone included.
  int get totalModules => _image.moduleCount + 2 * kShareQrQuietZone;

  /// The QR version (1-40), for tests that keep the symbol small.
  int get typeNumber => _image.typeNumber;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    canvas.drawRect(
        Offset.zero & Size(side, side), Paint()..color = Colors.white);
    final module = side / totalModules;
    final path = Path();
    for (var row = 0; row < _image.moduleCount; row++) {
      for (var col = 0; col < _image.moduleCount; col++) {
        if (!_image.isDark(row, col)) continue;
        // A hair of overlap so antialiasing seams can't open between
        // neighbouring modules at fractional sizes.
        path.addRect(Rect.fromLTWH(
          (col + kShareQrQuietZone) * module,
          (row + kShareQrQuietZone) * module,
          module + 0.01,
          module + 0.01,
        ));
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(ShareQrPainter oldDelegate) => oldDelegate.data != data;
}

/// A square QR code of [data], [size] logical pixels across.
class ShareQr extends StatelessWidget {
  const ShareQr({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: ShareQrPainter(data)),
      );
}
