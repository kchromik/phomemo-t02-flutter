import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A capture device owned only by the photo screen. Replaceable in UI tests.
abstract interface class PhotoCamera {
  bool get canSwitch;
  Widget buildPreview();
  Future<Uint8List> takePhoto();
  Future<void> dispose();
}

typedef PhotoCameraOpener = Future<PhotoCamera> Function(bool front);

Future<PhotoCamera> openPhotoCamera(bool front) async {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.iOS &&
          defaultTargetPlatform != TargetPlatform.android)) {
    throw const PhotoCameraError(
      'Photo mode is available on iPhone and Android.',
    );
  }
  final cameras = await availableCameras();
  if (cameras.isEmpty) {
    throw const PhotoCameraError('No camera found on this device.');
  }
  final direction = front
      ? CameraLensDirection.front
      : CameraLensDirection.back;
  final selected = cameras.where((c) => c.lensDirection == direction);
  final controller = CameraController(
    selected.isEmpty ? cameras.first : selected.first,
    ResolutionPreset.high,
    enableAudio: false,
  );
  try {
    await controller.initialize();
    await controller.setFlashMode(FlashMode.off);
    return _DeviceCamera(
      controller,
      canSwitch:
          cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
          cameras.any((c) => c.lensDirection == CameraLensDirection.back),
    );
  } catch (_) {
    await controller.dispose();
    rethrow;
  }
}

class PhotoCameraError implements Exception {
  final String message;
  const PhotoCameraError(this.message);
  @override
  String toString() => message;
}

String photoErrorMessage(Object error) {
  if (error is CameraException) {
    return switch (error.code) {
      'CameraAccessDenied' || 'CameraAccessDeniedWithoutPrompt' =>
        'Camera access denied. Allow camera access for T02 Studio in your device settings, then return to the app.',
      'CameraAccessRestricted' => 'Camera access is restricted on this device.',
      _ => 'Could not use the camera. Please try again.',
    };
  }
  return error.toString();
}

class _DeviceCamera implements PhotoCamera {
  final CameraController controller;
  @override
  final bool canSwitch;
  _DeviceCamera(this.controller, {required this.canSwitch});

  @override
  Widget buildPreview() => ValueListenableBuilder<CameraValue>(
    valueListenable: controller,
    builder: (context, value, _) {
      if (!value.isInitialized) return const SizedBox.expand();
      final orientation =
          value.previewPauseOrientation ??
          value.lockedCaptureOrientation ??
          value.deviceOrientation;
      final landscape =
          orientation == DeviceOrientation.landscapeLeft ||
          orientation == DeviceOrientation.landscapeRight;
      final ratio = landscape ? value.aspectRatio : 1 / value.aspectRatio;
      return ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 1000 * ratio,
              height: 1000,
              child: CameraPreview(controller),
            ),
          ),
        ),
      );
    },
  );

  @override
  Future<Uint8List> takePhoto() async {
    final file = await controller.takePicture();
    try {
      if (await file.length() > 20 * 1024 * 1024) {
        throw const FormatException(
          'The photo is too large. Please take another photo.',
        );
      }
      return await file.readAsBytes();
    } finally {
      // The original stays in memory for adjustments; do not retain captures
      // in the plugin's temporary directory or write to the photo library.
      try {
        await File(file.path).delete();
      } on FileSystemException {
        // OS cache cleanup may already have removed the temporary file.
      }
    }
  }

  @override
  Future<void> dispose() => controller.dispose();
}
