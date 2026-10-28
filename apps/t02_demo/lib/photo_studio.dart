import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:phomemo_t02/phomemo_t02.dart';

import 'photo_camera.dart';
import 'photo_print.dart';

class PhotoStudio extends StatefulWidget {
  final T02Client client;
  final bool active;
  final int feed;
  final VoidCallback onConnect;
  final PhotoCameraOpener openCamera;
  final PhotoRenderer render;

  const PhotoStudio({
    super.key,
    required this.client,
    required this.active,
    required this.feed,
    required this.onConnect,
    this.openCamera = openPhotoCamera,
    this.render = preparePhoto,
  });

  @override
  State<PhotoStudio> createState() => _PhotoStudioState();
}

class _PhotoStudioState extends State<PhotoStudio> with WidgetsBindingObserver {
  PhotoCamera? _camera;
  Future<void> _cameraQueue = Future.value();
  late StreamSubscription<PrinterSnapshot> _subscription;
  late PrinterSnapshot _printer;
  Uint8List? _photo;
  PhotoPrint? _printImage;
  String? _cameraError, _message;
  bool _front = false,
      _opening = false,
      _capturing = false,
      _preparing = false,
      _valid = false,
      _frame = true,
      _instant = false,
      _printing = false,
      _foreground = true;
  double _exposure = 0;
  int _cameraEpoch = 0, _captureEpoch = 0, _renderEpoch = 0;
  Timer? _adjustTimer;

  bool get _ready => _printer.phase == PrinterPhase.ready;
  bool get _printerBusy =>
      _printer.phase == PrinterPhase.connecting ||
      _printer.phase == PrinterPhase.initializing ||
      _printer.isPrinting;
  bool get _busy => _capturing || _printing || _printerBusy;
  bool get _wantsCamera =>
      mounted && widget.active && _foreground && _photo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _printer = widget.client.snapshot;
    _subscription = widget.client.states.listen((value) {
      if (mounted) setState(() => _printer = value);
    });
    if (widget.active) unawaited(_syncCamera());
  }

  @override
  void didUpdateWidget(PhotoStudio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      ++_captureEpoch; // A late capture must never auto-print after navigation.
      unawaited(_syncCamera());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    ++_captureEpoch;
    unawaited(_syncCamera());
  }

  /// Serialize native open/dispose calls, including an in-flight permission
  /// dialog. Stale initializations are disposed instead of shown or captured.
  Future<void> _syncCamera() {
    final epoch = ++_cameraEpoch;
    final wanted = _wantsCamera;
    final previous = _camera;
    setState(() {
      _camera = null;
      _opening = wanted;
      _cameraError = null;
    });
    _cameraQueue = _cameraQueue
        .then((_) async {
          await previous?.dispose();
          if (epoch != _cameraEpoch || !_wantsCamera || !wanted) return;
          final camera = await widget.openCamera(_front);
          if (epoch != _cameraEpoch || !_wantsCamera) {
            await camera.dispose();
            return;
          }
          setState(() {
            _camera = camera;
            _opening = false;
          });
        })
        .catchError((Object error) {
          if (mounted && epoch == _cameraEpoch) {
            setState(() {
              _cameraError = photoErrorMessage(error);
              _opening = false;
            });
          }
        });
    return _cameraQueue;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_cameraEpoch;
    ++_captureEpoch;
    ++_renderEpoch;
    _adjustTimer?.cancel();
    unawaited(_subscription.cancel());
    // Await an outstanding native open before closing its eventual device.
    unawaited(
      _cameraQueue
          .then((_) async {
            final camera = _camera;
            _camera = null;
            await camera?.dispose();
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  bool _captureCurrent(int epoch) =>
      mounted && widget.active && _foreground && epoch == _captureEpoch;

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || _opening || _busy || !_wantsCamera) return;
    if (_instant && !_ready) {
      widget.onConnect();
      return;
    }
    final epoch = ++_captureEpoch;
    final printImmediately = _instant;
    setState(() {
      _capturing = true;
      _message = null;
    });
    try {
      final bytes = await camera.takePhoto();
      if (!_captureCurrent(epoch)) return;
      setState(() {
        _photo = bytes;
        _printImage = null;
        _valid = false;
      });
      await _syncCamera();
      if (!mounted) return;
      await _render();
      if (printImmediately && _captureCurrent(epoch) && _valid) {
        if (_ready) {
          await _print();
        } else {
          setState(
            () => _message = 'Photo ready. Connect the printer to print it.',
          );
        }
      }
    } catch (error) {
      if (_captureCurrent(epoch)) {
        setState(() => _message = photoErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _render() async {
    final photo = _photo;
    if (photo == null) return;
    final epoch = ++_renderEpoch;
    setState(() {
      _preparing = true;
      _valid = false;
    });
    try {
      final result = await widget.render(
        PhotoOptions(photo, frame: _frame, exposure: _exposure),
      );
      if (mounted && epoch == _renderEpoch) {
        setState(() {
          _printImage = result;
          _valid = true;
        });
      }
    } catch (error) {
      if (mounted && epoch == _renderEpoch) {
        setState(() => _message = photoErrorMessage(error));
      }
    } finally {
      if (mounted && epoch == _renderEpoch) setState(() => _preparing = false);
    }
  }

  void _adjust(VoidCallback change) {
    if (_busy) return;
    _adjustTimer?.cancel();
    ++_renderEpoch;
    setState(() {
      change();
      _valid = false;
      _preparing = _photo != null;
    });
    if (_photo != null) {
      _adjustTimer = Timer(
        const Duration(milliseconds: 160),
        () => unawaited(_render()),
      );
    }
  }

  Future<void> _print() async {
    if (_printing ||
        !_valid ||
        _preparing ||
        _printImage == null ||
        !_ready ||
        !widget.active ||
        !_foreground) {
      return;
    }
    final bitmap = _printImage!.bitmap;
    setState(() {
      _printing = true;
      _message = null;
    });
    try {
      final outcome = await widget.client.print(bitmap, feed: widget.feed);
      if (mounted) {
        setState(
          () => _message = outcome == PrintOutcome.confirmed
              ? 'Your instant photo is ready. The T02 confirmed completion.'
              : 'Photo sent, completion not confirmed. Check the print before printing again.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _message = photoErrorMessage(error));
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  void _retake() {
    if (_busy) return;
    ++_captureEpoch;
    ++_renderEpoch;
    _adjustTimer?.cancel();
    setState(() {
      _photo = null;
      _printImage = null;
      _valid = false;
      _preparing = false;
      _message = null;
    });
    unawaited(_syncCamera());
  }

  Future<void> _cancelPrint() async {
    try {
      await widget.client.disconnect();
    } catch (error) {
      if (mounted) setState(() => _message = photoErrorMessage(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _photo != null;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasPhoto
                                ? 'Your instant photo'
                                : 'A moment. On paper.',
                            style: const TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -.6,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            hasPhoto
                                ? 'This is how your photo will look on paper.'
                                : 'Point, capture, print.',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!hasPhoto)
                      IconButton(
                        tooltip: 'Switch camera',
                        onPressed:
                            _busy || _opening || !(_camera?.canSwitch ?? false)
                            ? null
                            : () {
                                setState(() => _front = !_front);
                                unawaited(_syncCamera());
                              },
                        icon: const Icon(Icons.cameraswitch_outlined),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                if (_message != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEE7D4),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      _message!,
                      key: const ValueKey('photo-message'),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: hasPhoto ? _review() : _viewfinder(),
                  ),
                ),
                const SizedBox(height: 18),
                if (hasPhoto) ...[
                  Row(
                    children: [
                      const Icon(Icons.brightness_6_outlined, size: 20),
                      const SizedBox(width: 9),
                      const Expanded(child: Text('Brightness')),
                      Text(
                        _exposure == 0
                            ? 'Normal'
                            : _exposure > 0
                            ? 'Brighter'
                            : 'Darker',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('photo-exposure'),
                    value: _exposure,
                    min: -1,
                    max: 1,
                    divisions: 8,
                    onChanged: _busy
                        ? null
                        : (value) => _adjust(() => _exposure = value),
                  ),
                ],
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Instant photo frame'),
                  subtitle: const Text(
                    'White border with space below the photo.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _frame,
                  onChanged: _busy
                      ? null
                      : (value) => _adjust(() => _frame = value),
                ),
                if (!hasPhoto)
                  SwitchListTile.adaptive(
                    key: const ValueKey('instant-print'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Instant print'),
                    subtitle: const Text(
                      'Taking a photo starts printing immediately.',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _instant,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _instant = value),
                  ),
                if (!hasPhoto)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Square crop. Photos are not saved to your photo library.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF72766E)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        _actions(hasPhoto),
      ],
    );
  }

  Widget _viewfinder() => AspectRatio(
    aspectRatio: 1,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: ColoredBox(
        color: const Color(0xFF202922),
        child: _cameraError != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.no_photography_outlined,
                          size: 38,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _cameraError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => unawaited(_syncCamera()),
                          child: const Text(
                            'Try again',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : _camera != null && !_opening
            ? _camera!.buildPreview()
            : _opening
            ? const Center(
                child: CircularProgressIndicator(color: Colors.white),
              )
            : const Center(
                child: Icon(
                  Icons.camera_alt_outlined,
                  color: Colors.white,
                  size: 40,
                ),
              ),
      ),
    ),
  );

  Widget _review() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFE8EBE2),
      borderRadius: BorderRadius.circular(22),
    ),
    child: Column(
      children: [
        if (_printImage != null)
          AspectRatio(
            aspectRatio: MonoBitmap.width / _printImage!.bitmap.height,
            child: Image.memory(
              _printImage!.preview,
              key: const ValueKey('photo-preview'),
              width: 384,
              gaplessPlayback: true,
              filterQuality: FilterQuality.none,
            ),
          )
        else
          const AspectRatio(
            aspectRatio: 1,
            child: Center(child: Icon(Icons.photo_outlined, size: 50)),
          ),
        const SizedBox(height: 12),
        if (_preparing)
          const LinearProgressIndicator()
        else
          Text(
            _valid
                ? 'Black-and-white preview · 48 mm wide'
                : 'Could not prepare the photo.',
            style: const TextStyle(fontSize: 12),
          ),
      ],
    ),
  );

  Widget _actions(bool hasPhoto) => Container(
    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _printer.isPrinting
              ? '${_printer.message ?? 'Printing'} · ${(_printer.progress * 100).round()} %'
              : _ready
              ? 'Connected to ${_printer.device?.name ?? 'T02'}'
              : 'Printer disconnected',
          style: const TextStyle(fontSize: 12, color: Color(0xFF72766E)),
        ),
        const SizedBox(height: 9),
        if (_printer.isPrinting) ...[
          LinearProgressIndicator(
            value: _printer.phase == PrinterPhase.waiting
                ? null
                : _printer.progress,
          ),
          TextButton(
            onPressed: _cancelPrint,
            child: const Text('Cancel & disconnect'),
          ),
        ] else if (hasPhoto) ...[
          FilledButton.icon(
            key: const ValueKey('print-photo'),
            onPressed: _busy || _preparing || !_valid
                ? null
                : _ready
                ? _print
                : widget.onConnect,
            icon: Icon(
              _ready ? Icons.print_outlined : Icons.bluetooth_searching,
            ),
            label: Text(
              _preparing
                  ? 'Preparing photo …'
                  : _ready
                  ? 'Print photo'
                  : 'Connect printer',
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _retake,
            child: const Text('Take another photo'),
          ),
        ] else
          FilledButton.icon(
            key: const ValueKey('capture-photo'),
            onPressed: _busy || _opening || _camera == null
                ? null
                : _instant && !_ready
                ? widget.onConnect
                : _capture,
            icon: Icon(
              _instant && !_ready
                  ? Icons.bluetooth_searching
                  : Icons.camera_alt_outlined,
            ),
            label: Text(
              _capturing
                  ? 'Taking photo …'
                  : _instant
                  ? _ready
                        ? 'Capture & print'
                        : 'Connect printer'
                  : 'Take photo',
            ),
          ),
      ],
    ),
  );
}
