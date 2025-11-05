import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';

class PlaneMessage {
  PlaneMessage({
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
    required this.width,
    required this.height,
  });

  final TransferableTypedData bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
  final int? width;
  final int? height;

  factory PlaneMessage.fromPlane(Plane plane) {
    return PlaneMessage(
      bytes: TransferableTypedData.fromList([plane.bytes]),
      bytesPerRow: plane.bytesPerRow,
      bytesPerPixel: plane.bytesPerPixel,
      width: plane.width,
      height: plane.height,
    );
  }
}

class Nv21ConversionMessage {
  Nv21ConversionMessage({
    required this.width,
    required this.height,
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
  });

  final int width;
  final int height;
  final PlaneMessage yPlane;
  final PlaneMessage uPlane;
  final PlaneMessage vPlane;

  factory Nv21ConversionMessage.fromCameraImage(CameraImage image) {
    return Nv21ConversionMessage(
      width: image.width,
      height: image.height,
      yPlane: PlaneMessage.fromPlane(image.planes[0]),
      uPlane: PlaneMessage.fromPlane(image.planes[1]),
      vPlane: PlaneMessage.fromPlane(image.planes[2]),
    );
  }
}

Uint8List convertToNv21Isolate(Nv21ConversionMessage message) {
  Uint8List materialize(TransferableTypedData data) {
    final byteBuffer = data.materialize();
    return byteBuffer.asUint8List();
  }

  final width = message.width;
  final height = message.height;
  final yBytes = materialize(message.yPlane.bytes);
  final uBytes = materialize(message.uPlane.bytes);
  final vBytes = materialize(message.vPlane.bytes);

  final nv21Length = width * height + (width * height ~/ 2);
  final bytes = Uint8List(nv21Length);
  int outputIndex = 0;

  for (int row = 0; row < height; row++) {
    final rowStart = row * message.yPlane.bytesPerRow;
    bytes.setRange(outputIndex, outputIndex + width, yBytes, rowStart);
    outputIndex += width;
  }

  final uvWidth = message.uPlane.width ?? ((width + 1) >> 1);
  final uvHeight = message.uPlane.height ?? ((height + 1) >> 1);
  final uRowStride = message.uPlane.bytesPerRow;
  final vRowStride = message.vPlane.bytesPerRow;
  final uPixelStride = message.uPlane.bytesPerPixel ?? 1;
  final vPixelStride = message.vPlane.bytesPerPixel ?? 1;

  for (int row = 0; row < uvHeight; row++) {
    final uRowStart = row * uRowStride;
    final vRowStart = row * vRowStride;
    if (uRowStart >= uBytes.length || vRowStart >= vBytes.length) {
      break;
    }

    final maxUCols = (uBytes.length - uRowStart) ~/ uPixelStride;
    final maxVCols = (vBytes.length - vRowStart) ~/ vPixelStride;
    final rowUvWidth = min(uvWidth, min(maxUCols, maxVCols));
    if (rowUvWidth <= 0) {
      break;
    }

    for (int col = 0; col < rowUvWidth; col++) {
      final uIndex = uRowStart + col * uPixelStride;
      final vIndex = vRowStart + col * vPixelStride;
      if (outputIndex >= bytes.length) {
        break;
      }
      bytes[outputIndex++] = vBytes[vIndex];
      if (outputIndex >= bytes.length) {
        break;
      }
      bytes[outputIndex++] = uBytes[uIndex];
    }
  }

  return bytes;
}
