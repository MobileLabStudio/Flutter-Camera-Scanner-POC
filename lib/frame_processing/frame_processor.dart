import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_ml_kit/google_ml_kit.dart';

import 'nv21_converter.dart';

class PreparedFrame {
  const PreparedFrame({
    required this.bytes,
    required this.format,
    required this.bytesPerRow,
    required this.size,
    required this.cropRect,
    required this.originalSize,
  });

  final Uint8List bytes;
  final InputImageFormat format;
  final int bytesPerRow;
  final Size size;
  final Rect cropRect;
  final Size originalSize;
}

class FrameProcessor {
  FrameProcessor({
    required this.processEveryNthFrame,
    this.roiSizePixels,
  });

  final int processEveryNthFrame;
  final int? roiSizePixels;

  bool _isProcessing = false;
  int _frameCounter = 0;

  Future<PreparedFrame?> process(CameraImage image) async {
    if (_isProcessing) return null;
    if ((_frameCounter++ % processEveryNthFrame) != 0) return null;

    _isProcessing = true;
    try {
      if (Platform.isAndroid) {
        if (image.planes.length < 3) return null;
        final message = Nv21ConversionMessage.fromCameraImage(image);
        final bytes = await compute(convertToNv21Isolate, message);
        final frame = PreparedFrame(
          bytes: bytes,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
          size: Size(image.width.toDouble(), image.height.toDouble()),
          cropRect: Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          originalSize: Size(image.width.toDouble(), image.height.toDouble()),
        );
        return _applyRegionOfInterest(frame);
      }

      final plane = image.planes.first;
      final frame = PreparedFrame(
        bytes: plane.bytes,
        format: InputImageFormat.bgra8888,
        bytesPerRow: plane.bytesPerRow,
        size: Size(image.width.toDouble(), image.height.toDouble()),
        cropRect: Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        ),
        originalSize: Size(image.width.toDouble(), image.height.toDouble()),
      );
      return _applyRegionOfInterest(frame);
    } finally {
      _isProcessing = false;
    }
  }

  void reset() {
    _isProcessing = false;
    _frameCounter = 0;
  }

  PreparedFrame _applyRegionOfInterest(PreparedFrame frame) {
    final desiredSide = roiSizePixels;
    if (desiredSide == null) return frame;

    final originalWidth = frame.size.width.toInt();
    final originalHeight = frame.size.height.toInt();
    if (desiredSide >= originalWidth && desiredSide >= originalHeight) {
      return frame;
    }

    switch (frame.format) {
      case InputImageFormat.nv21:
        final maxSide = min(originalWidth, originalHeight);
        var side = min(desiredSide, maxSide);
        if (side.isOdd) side -= 1;
        if (side < 2) return frame;
        if (side == originalWidth && side == originalHeight) return frame;

        var startX = ((originalWidth - side) / 2).floor();
        var startY = ((originalHeight - side) / 2).floor();

        startX = _ensureEvenWithinBounds(startX, side, originalWidth);
        startY = _ensureEvenWithinBounds(startY, side, originalHeight);

        final croppedBytes = _cropNv21(
          frame.bytes,
          srcWidth: originalWidth,
          srcHeight: originalHeight,
          roiSide: side,
          startX: startX,
          startY: startY,
        );

        return PreparedFrame(
          bytes: croppedBytes,
          format: frame.format,
          bytesPerRow: side,
          size: Size(side.toDouble(), side.toDouble()),
          cropRect: Rect.fromLTWH(
            startX.toDouble(),
            startY.toDouble(),
            side.toDouble(),
            side.toDouble(),
          ),
          originalSize: frame.originalSize,
        );
      case InputImageFormat.bgra8888:
        final maxSide = min(originalWidth, originalHeight);
        final side = min(desiredSide, maxSide);
        if (side < 1) return frame;
        if (side == originalWidth && side == originalHeight) return frame;

        final startX = ((originalWidth - side) / 2).floor();
        final startY = ((originalHeight - side) / 2).floor();
        final croppedBytes = _cropBgra(
          frame.bytes,
          bytesPerRow: frame.bytesPerRow,
          roiSide: side,
          startX: startX,
          startY: startY,
        );

        return PreparedFrame(
          bytes: croppedBytes,
          format: frame.format,
          bytesPerRow: side * 4,
          size: Size(side.toDouble(), side.toDouble()),
          cropRect: Rect.fromLTWH(
            startX.toDouble(),
            startY.toDouble(),
            side.toDouble(),
            side.toDouble(),
          ),
          originalSize: frame.originalSize,
        );
      default:
        return frame;
    }
  }

  Uint8List _cropNv21(
    Uint8List source, {
    required int srcWidth,
    required int srcHeight,
    required int roiSide,
    required int startX,
    required int startY,
  }) {
    final yPlaneLength = srcWidth * srcHeight;
    final cropped = Uint8List(roiSide * roiSide + (roiSide * roiSide) ~/ 2);
    var destIndex = 0;

    for (int row = 0; row < roiSide; row++) {
      final srcRow = startY + row;
      final srcStart = srcRow * srcWidth + startX;
      cropped.setRange(destIndex, destIndex + roiSide, source, srcStart);
      destIndex += roiSide;
    }

    final uvSrcOffset = yPlaneLength;
    final uvRowStride = srcWidth;
    final uvStartRow = startY ~/ 2;
    final uvRows = roiSide ~/ 2;

    for (int row = 0; row < uvRows; row++) {
      final srcRow = uvStartRow + row;
      final srcStart = uvSrcOffset + srcRow * uvRowStride + startX;
      cropped.setRange(destIndex, destIndex + roiSide, source, srcStart);
      destIndex += roiSide;
    }

    return cropped;
  }

  Uint8List _cropBgra(
    Uint8List source, {
    required int bytesPerRow,
    required int roiSide,
    required int startX,
    required int startY,
  }) {
    final bytesPerPixel = 4;
    final cropped = Uint8List(roiSide * roiSide * bytesPerPixel);
    var destIndex = 0;

    for (int row = 0; row < roiSide; row++) {
      final srcRow = startY + row;
      final srcStart = srcRow * bytesPerRow + startX * bytesPerPixel;
      final length = roiSide * bytesPerPixel;
      cropped.setRange(destIndex, destIndex + length, source, srcStart);
      destIndex += length;
    }

    return cropped;
  }

  int _ensureEvenWithinBounds(int proposedStart, int roiSide, int maxDimension) {
    int value = proposedStart;
    if (value < 0) value = 0;
    if (value + roiSide > maxDimension) {
      value = maxDimension - roiSide;
    }
    if (value < 0) value = 0;
    if (value.isOdd) value = value > 0 ? value - 1 : 0;
    while (value + roiSide > maxDimension && value >= 2) {
      value -= 2;
    }
    if (value < 0) value = 0;
    return value;
  }
}
