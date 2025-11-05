import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

import '../frame_processing/frame_processor.dart';

class BarcodeReader {
  BarcodeReader({BarcodeScanner? scanner}) : _scanner = scanner ?? BarcodeScanner();

  final BarcodeScanner _scanner;

  Future<List<Barcode>> read(
    PreparedFrame frame, {
    required int rotationDegrees,
  }) async {
    final inputImage = InputImage.fromBytes(
      bytes: frame.bytes,
      metadata: InputImageMetadata(
        size: frame.size,
        rotation: InputImageRotationValue.fromRawValue(rotationDegrees) ?? InputImageRotation.rotation0deg,
        format: frame.format,
        bytesPerRow: frame.bytesPerRow,
      ),
    );
    return _scanner.processImage(inputImage);
  }

  Future<void> dispose() => _scanner.close();
}
