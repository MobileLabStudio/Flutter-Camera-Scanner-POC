import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'barcode/barcode_reader.dart';
import 'frame_processing/frame_processor.dart';

late List<CameraDescription> _cameras;

const _processEveryNthFrame = 3;
const int? _roiSidePixels = 600;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cameras = await availableCameras();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  CameraController? _cameraController;
  late final BarcodeReader barcodeReader;
  Object? error;
  StackTrace? stackTrace;
  Rect? _previewRoiRect;

  final FrameProcessor _frameProcessor = FrameProcessor(
    processEveryNthFrame: _processEveryNthFrame,
    roiSizePixels: _roiSidePixels,
  );

  Future<void> _analyzeCameraImage(CameraImage cameraImage) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final rotationDegrees = controller.description.sensorOrientation;

    try {
      final preparedFrame = await _frameProcessor.process(cameraImage);
      if (preparedFrame == null) return;
      _updatePreviewRoi(preparedFrame, rotationDegrees);
      await _readBarcode(preparedFrame, rotationDegrees);
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        error = e;
        stackTrace = st;
      });
    }
  }

  Future<void> _readBarcode(PreparedFrame frame, int rotationDegrees) async {
    try {
      final barcodes = await barcodeReader.read(
        frame,
        rotationDegrees: rotationDegrees,
      );
      if (barcodes.isNotEmpty) {
        final values = barcodes
            .map((barcode) => barcode.rawValue ?? barcode.displayValue ?? '')
            .where((value) => value.isNotEmpty)
            .toList();
        debugPrint(values.isEmpty ? barcodes.toString() : values.join(', '));
      }
    } catch (e, _) {
      debugPrint('$e');
    }
  }

  void _updatePreviewRoi(PreparedFrame frame, int rotationDegrees) {
    final original = frame.originalSize;
    if (original.width <= 0 || original.height <= 0) return;

    final normalizedRect = _normalizedRectForFrame(frame);
    final rotated = _rotateNormalizedRect(
      normalizedRect,
      rotationDegrees,
    );
    final clamped = _clampRect(rotated);

    const double epsilon = 1e-3;
    if (clamped.width >= 1 - epsilon && clamped.height >= 1 - epsilon) {
      if (_previewRoiRect != null && mounted) {
        setState(() {
          _previewRoiRect = null;
        });
      } else if (_previewRoiRect != null) {
        _previewRoiRect = null;
      }
      return;
    }

    if (_rectsClose(_previewRoiRect, clamped)) {
      return;
    }

    if (!mounted) {
      _previewRoiRect = clamped;
      return;
    }

    setState(() {
      _previewRoiRect = clamped;
    });
  }

  Rect _normalizedRectForFrame(PreparedFrame frame) {
    final width = frame.originalSize.width;
    final height = frame.originalSize.height;
    return Rect.fromLTWH(
      (frame.cropRect.left / width).clamp(0.0, 1.0),
      (frame.cropRect.top / height).clamp(0.0, 1.0),
      (frame.cropRect.width / width).clamp(0.0, 1.0),
      (frame.cropRect.height / height).clamp(0.0, 1.0),
    );
  }

  Rect _rotateNormalizedRect(Rect rect, int rotationDegrees) {
    final normalizedRotation = ((rotationDegrees % 360) + 360) % 360;
    if (normalizedRotation == 0) return rect;

    final points = <Offset>[
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ].map((point) => _rotatePoint(point, normalizedRotation)).toList();

    final xs = points.map((point) => point.dx);
    final ys = points.map((point) => point.dy);
    final minX = xs.reduce(math.min);
    final maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min);
    final maxY = ys.reduce(math.max);
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Offset _rotatePoint(Offset point, int rotationDegrees) {
    switch (rotationDegrees) {
      case 0:
        return point;
      case 90:
        return Offset(point.dy, 1.0 - point.dx);
      case 180:
        return Offset(1.0 - point.dx, 1.0 - point.dy);
      case 270:
        return Offset(1.0 - point.dy, point.dx);
      default:
        final radians = rotationDegrees * math.pi / 180.0;
        final cosTheta = math.cos(radians);
        final sinTheta = math.sin(radians);
        final translated = Offset(point.dx - 0.5, point.dy - 0.5);
        final rotated = Offset(
          translated.dx * cosTheta - translated.dy * sinTheta,
          translated.dx * sinTheta + translated.dy * cosTheta,
        );
        return rotated.translate(0.5, 0.5);
    }
  }

  Rect _clampRect(Rect rect) {
    double left = rect.left.clamp(0.0, 1.0);
    double right = rect.right.clamp(0.0, 1.0);
    if (right < left) {
      final temp = left;
      left = right;
      right = temp;
    }
    double top = rect.top.clamp(0.0, 1.0);
    double bottom = rect.bottom.clamp(0.0, 1.0);
    if (bottom < top) {
      final temp = top;
      top = bottom;
      bottom = temp;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  bool _rectsClose(Rect? current, Rect target, {double epsilon = 1e-3}) {
    if (current == null) return false;
    return (current.left - target.left).abs() < epsilon &&
        (current.top - target.top).abs() < epsilon &&
        (current.width - target.width).abs() < epsilon &&
        (current.height - target.height).abs() < epsilon;
  }

  @override
  void initState() {
    super.initState();
    barcodeReader = BarcodeReader();
    unawaited(_createControllerAndInitialize());
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _createControllerAndInitialize() async {
    final controller = CameraController(
      _cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.back),
      ResolutionPreset.high,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    _cameraController = controller;

    try {
      await controller.initialize();
      await controller.startImageStream(_analyzeCameraImage);
      if (!mounted) {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
        await controller.dispose();
        _cameraController = null;
        return;
      }
      setState(() {
        error = null;
        stackTrace = null;
        _previewRoiRect = null;
      });
      _frameProcessor.reset();
    } catch (e, st) {
      try {
        if (controller.value.isInitialized && controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {
        // Best effort; controller might not have finished initializing.
      }
      await controller.dispose();
      if (!mounted) {
        error = e;
        stackTrace = st;
        _previewRoiRect = null;
        _cameraController = null;
        return;
      }
      setState(() {
        error = e;
        stackTrace = st;
        _previewRoiRect = null;
        _cameraController = null;
      });
    }
  }

  @override
  void dispose() {
    final controller = _cameraController;
    if (controller != null) {
      if (controller.value.isInitialized && controller.value.isStreamingImages) {
        unawaited(controller.stopImageStream());
      }
      if (controller.value.isInitialized) {
        unawaited(controller.dispose());
      }
      _cameraController = null;
    }
    unawaited(barcodeReader.dispose());
    _frameProcessor.reset();
    _previewRoiRect = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final controller = _cameraController;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (controller == null) return;

      final wasInitialized = controller.value.isInitialized;
      final wasStreaming = wasInitialized && controller.value.isStreamingImages;

      _frameProcessor.reset();
      if (mounted) {
        setState(() {
          _cameraController = null;
          _previewRoiRect = null;
        });
      } else {
        _cameraController = null;
        _previewRoiRect = null;
      }

      if (wasStreaming) {
        unawaited(controller.stopImageStream());
      }
      if (wasInitialized) {
        unawaited(controller.dispose());
      }
    } else if (state == AppLifecycleState.resumed) {
      _frameProcessor.reset();
      if (mounted) {
        setState(() {
          _previewRoiRect = null;
        });
      } else {
        _previewRoiRect = null;
      }
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        unawaited(_createControllerAndInitialize());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final hasActiveController = controller != null && controller.value.isInitialized;
    final error = this.error;
    final stackTrace = this.stackTrace;

    return MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (hasActiveController)
              Center(
                child: CameraPreview(
                  controller!,
                  child: _previewRoiRect != null
                      ? LayoutBuilder(
                          builder: (context, constraints) {
                            final rect = _previewRoiRect!;
                            final left = rect.left * constraints.maxWidth;
                            final top = rect.top * constraints.maxHeight;
                            final width = rect.width * constraints.maxWidth;
                            final height = rect.height * constraints.maxHeight;
                            return IgnorePointer(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Positioned(
                                    left: left,
                                    top: top,
                                    width: width,
                                    height: height,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.greenAccent,
                                          width: 3,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        color: Colors.greenAccent.withOpacity(0.05),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        )
                      : null,
                ),
              )
            else
              Center(
                child: CircularProgressIndicator(),
              ),
            if (error != null || stackTrace != null)
              Container(
                color: Colors.black26,
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    spacing: 16,
                    children: [
                      if (error != null) Text(error.toString()),
                      if (stackTrace != null) Text(stackTrace.toString()),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
