import 'dart:async';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phomemo_t02/phomemo_t02.dart';
import 'photo_studio.dart';

void main() => runApp(const StudioApp());

const ink = Color(0xFF202922);
const paper = Color(0xFFF5F3EC);
const green = Color(0xFF2F634B);
const muted = Color(0xFF72766E);
const line = Color(0xFFDDDFD5);

class StudioApp extends StatelessWidget {
  final T02Client? client;
  const StudioApp({super.key, this.client});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'T02 Studio',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        brightness: Brightness.light,
        surface: paper,
        primary: green,
        onSurface: ink,
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontSize: 16, height: 1.45, color: ink),
        bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: ink),
        titleLarge: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: ink,
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: paper,
        indicatorColor: Color(0xFFE0E8DC),
        height: 70,
      ),
      dividerColor: line,
    ),
    home: StudioHome(client: client),
  );
}

class StudioHome extends StatefulWidget {
  final T02Client? client;
  const StudioHome({super.key, this.client});
  @override
  State<StudioHome> createState() => _StudioHomeState();
}

class _StudioHomeState extends State<StudioHome> with WidgetsBindingObserver {
  late final T02Client _client;
  late PrinterSnapshot _state;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _devices = <String, PrinterDevice>{};
  final _text = TextEditingController(
    text: 'Hello, T02!\n\nMy first print\nfrom a Flutter app.',
  );
  Timer? _scanTimer, _textTimer;
  bool _scanning = false,
      _showAll = false,
      _preparing = false,
      _paced = false,
      _dither = true;
  bool _previewValid = false;
  int _page = 0, _content = 0, _feed = 4, _previewVersion = 0;
  int _returnAfterConnect = 0;
  String? _notice;
  MonoBitmap _bitmap = MonoBitmap.testPattern();
  Uint8List? _preview, _sourceImage;
  String? _imageName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client ?? T02Client(transport: UniversalBleTransport());
    _state = _client.snapshot;
    _subscriptions.add(
      _client.states.listen((s) {
        if (mounted) setState(() => _state = s);
      }),
    );
    _subscriptions.add(
      _client.discoveries.listen((d) {
        if (mounted) setState(() => _devices[d.id] = d);
      }, onError: (Object e) => _error(e)),
    );
    _subscriptions.add(
      _client.diagnostics.listen((_) {
        if (mounted && _page == 2) setState(() {});
      }),
    );
    _preview = _bitmap.toPng();
    unawaited(_prepare());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_stopScan());
      if (_state.phase != PrinterPhase.disconnected) {
        unawaited(_client.disconnect());
        _notice =
            'App in background: disconnected. Buffered data may still print.';
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    _textTimer?.cancel();
    _text.dispose();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(_client.dispose());
    super.dispose();
  }

  void _error(Object e) {
    if (mounted) setState(() => _notice = e.toString());
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() => _notice = null);
    try {
      await action();
    } catch (e) {
      _error(e);
    }
  }

  bool get _working =>
      _state.phase == PrinterPhase.connecting ||
      _state.phase == PrinterPhase.initializing ||
      _state.isPrinting;

  Future<void> _scan() => _action(() async {
    setState(() {
      _devices.clear();
      _scanning = true;
    });
    try {
      await _client.startScan();
      _scanTimer?.cancel();
      _scanTimer = Timer(
        const Duration(seconds: 15),
        () => unawaited(_stopScan()),
      );
    } catch (_) {
      if (mounted) setState(() => _scanning = false);
      rethrow;
    }
  });
  Future<void> _stopScan() async {
    _scanTimer?.cancel();
    try {
      await _client.stopScan();
    } catch (e) {
      _error(e);
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(PrinterDevice device) => _action(() async {
    await _stopScan();
    await _client.connect(
      device,
      flowControl: _paced ? FlowControl.experimentalPaced : FlowControl.credits,
    );
    if (mounted) {
      setState(() {
        _page = _returnAfterConnect;
        _returnAfterConnect = 0;
      });
    }
  });

  Future<void> _prepare() async {
    final version = ++_previewVersion;
    setState(() {
      _preparing = true;
      _previewValid = false;
    });
    try {
      MonoBitmap bitmap;
      if (_content == 2 && _sourceImage != null) {
        bitmap = await compute(_decode, (_sourceImage!, _dither));
      } else {
        final bytes = await _renderText(_content == 1 ? _text.text : null);
        bitmap = await compute(_decode, (bytes, false));
      }
      final preview = bitmap.toPng();
      if (mounted && version == _previewVersion) {
        setState(() {
          _bitmap = bitmap;
          _previewValid = true;
          _preview = preview;
        });
      }
    } catch (e) {
      if (version == _previewVersion) _error(e);
    } finally {
      if (mounted && version == _previewVersion) {
        setState(() => _preparing = false);
      }
    }
  }

  Future<void> _pickImage() => _action(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg'],
          uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > 20 * 1024 * 1024) {
      throw const FormatException('Please choose an image smaller than 20 MB.');
    }
    final data = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _sourceImage = data;
      _imageName = file.name;
      _content = 2;
    });
    await _prepare();
  });
  Future<void> _print() => _action(() async {
    FocusScope.of(context).unfocus();
    final outcome = await _client.print(_bitmap, feed: _feed);
    if (mounted) {
      setState(
        () => _notice = outcome == PrintOutcome.confirmed
            ? 'Done. The T02 confirmed print completion.'
            : 'All data sent. The T02 did not confirm completion. Check the print and reconnect before the next job.',
      );
    }
  });

  String get _phaseLabel => switch (_state.phase) {
    PrinterPhase.disconnected => 'Disconnected',
    PrinterPhase.connecting => 'Connecting …',
    PrinterPhase.initializing => 'Initializing …',
    PrinterPhase.ready => 'Connected',
    PrinterPhase.printing => 'Sending …',
    PrinterPhase.waiting => 'Waiting for completion …',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
                child: Row(
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        color: ink,
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(11),
                        child: Icon(
                          Icons.print_outlined,
                          color: paper,
                          size: 24,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'T02 Studio',
                            style: TextStyle(
                              fontFamily: 'Georgia',
                              fontSize: 28,
                              letterSpacing: -1,
                              color: ink,
                            ),
                          ),
                          Text(
                            'SMALL IDEAS. ON PAPER.',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.6,
                              color: muted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Printer connection',
                      onPressed: () => setState(() {
                        _returnAfterConnect = _page == 3 ? 3 : 0;
                        _page = 1;
                      }),
                      icon: Icon(
                        _state.phase == PrinterPhase.ready
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth,
                        color: _state.phase == PrinterPhase.ready
                            ? green
                            : muted,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: IndexedStack(
                  index: _page == 3 ? 1 : 0,
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_notice != null) _noticeCard(),
                          if (_page == 0) ..._printPage(),
                          if (_page == 1) ..._devicePage(),
                          if (_page == 2) ..._logPage(),
                        ],
                      ),
                    ),
                    PhotoStudio(
                      client: _client,
                      active: _page == 3,
                      feed: _feed,
                      onConnect: () => setState(() {
                        _returnAfterConnect = 3;
                        _page = 1;
                      }),
                    ),
                  ],
                ),
              ),
              if (_page == 0) _printBar(),
            ],
          ),
        ),
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: const [0, 3, 1, 2].indexOf(_page),
      onDestinationSelected: (p) => setState(() {
        final destination = const [0, 3, 1, 2][p];
        if (destination == 1) _returnAfterConnect = _page == 3 ? 3 : 0;
        _page = destination;
      }),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long),
          label: 'Print',
        ),
        NavigationDestination(
          icon: Icon(Icons.camera_alt_outlined),
          selectedIcon: Icon(Icons.camera_alt),
          label: 'Photo',
        ),
        NavigationDestination(
          icon: Icon(Icons.bluetooth_outlined),
          label: 'Printer',
        ),
        NavigationDestination(
          icon: Icon(Icons.terminal_outlined),
          label: 'Log',
        ),
      ],
    ),
  );

  Widget _noticeCard() => Container(
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFEEE7D4),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(_notice!)),
        InkWell(
          onTap: () => setState(() => _notice = null),
          child: const Padding(
            padding: EdgeInsets.all(2),
            child: Icon(Icons.close, size: 18),
          ),
        ),
      ],
    ),
  );

  List<Widget> _printPage() => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your next print',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.6,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'A thought. A picture. A little strip of paper.',
                style: TextStyle(color: muted, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ),
    const SizedBox(height: 22),
    SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 0, label: Text('Test strip')),
        ButtonSegment(value: 1, label: Text('Text')),
        ButtonSegment(value: 2, label: Text('Image')),
      ],
      selected: {_content},
      showSelectedIcon: false,
      onSelectionChanged: _working
          ? null
          : (s) {
              setState(() => _content = s.first);
              unawaited(_prepare());
            },
    ),
    const SizedBox(height: 20),
    if (_content == 1) ...[
      TextField(
        controller: _text,
        maxLines: 4,
        maxLength: 1000,
        enabled: !_working,
        decoration: const InputDecoration(
          labelText: 'Your message',
          alignLabelWithHint: true,
        ),
        onChanged: (_) {
          _textTimer?.cancel();
          ++_previewVersion;
          setState(() {
            _preparing = true;
            _previewValid = false;
          });
          _textTimer = Timer(
            const Duration(milliseconds: 300),
            () => unawaited(_prepare()),
          );
        },
      ),
      const SizedBox(height: 12),
    ],
    if (_content == 2) ...[
      OutlinedButton.icon(
        onPressed: _working ? null : _pickImage,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(
          _imageName ?? 'Choose a PNG or JPEG',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Dither grayscale images'),
        subtitle: const Text(
          'For photos and smooth gradients',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        value: _dither,
        onChanged: _working
            ? null
            : (v) {
                setState(() => _dither = v);
                unawaited(_prepare());
              },
      ),
    ],
    Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EBE2),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _eyebrow('PRINT PREVIEW'),
              Text(
                '48 mm',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: ink.withValues(alpha: .6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            constraints: const BoxConstraints(maxWidth: 310),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: ink.withValues(alpha: .1),
                  blurRadius: 18,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: ClipPath(
              clipper: const _ReceiptClipper(),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
                child: _preview == null
                    ? const SizedBox(height: 200)
                    : Image.memory(
                        _preview!,
                        filterQuality: FilterQuality.none,
                        gaplessPlayback: true,
                        width: 310,
                        fit: BoxFit.fitWidth,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            _preparing
                ? 'Preparing preview …'
                : '${_bitmap.height} rows · ${_bitmap.heightMm.toStringAsFixed(1)} mm + feed',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: muted,
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 18),
    Row(
      children: [
        const Icon(Icons.check_circle_outline, size: 17, color: green),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            _content == 0
                ? 'Checks margins, orientation and fine patterns.'
                : 'The preview shows the exact raster sent to the printer.',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ),
      ],
    ),
  ];

  Widget _printBar() => Container(
    padding: const EdgeInsets.fromLTRB(24, 14, 24, 12),
    decoration: const BoxDecoration(
      color: paper,
      border: Border(top: BorderSide(color: line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _state.phase == PrinterPhase.ready ? green : muted,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                _state.isPrinting
                    ? '${_state.message} · ${(_state.progress * 100).round()} %'
                    : _phaseLabel,
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ),
            if (_state.phase == PrinterPhase.ready)
              Text(
                _state.device?.name ?? 'T02',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_state.isPrinting) ...[
          LinearProgressIndicator(
            value: _state.phase == PrinterPhase.waiting
                ? null
                : _state.progress,
            color: green,
            borderRadius: BorderRadius.circular(3),
          ),
          TextButton(
            onPressed: () => _action(_client.disconnect),
            child: const Text('Cancel & disconnect'),
          ),
        ] else
          FilledButton.icon(
            onPressed:
                _working ||
                    _preparing ||
                    !_previewValid ||
                    (_content == 2 && _sourceImage == null)
                ? null
                : _state.phase == PrinterPhase.ready
                ? _print
                : () => setState(() {
                    _returnAfterConnect = 0;
                    _page = 1;
                  }),
            icon: Icon(
              _state.phase == PrinterPhase.ready
                  ? Icons.print_outlined
                  : Icons.bluetooth_searching,
              size: 20,
            ),
            label: Text(
              _working
                  ? _phaseLabel
                  : _state.phase == PrinterPhase.ready
                  ? 'Print now'
                  : 'Connect printer',
              style: const TextStyle(fontSize: 16),
            ),
          ),
      ],
    ),
  );

  List<Widget> _devicePage() {
    final devices =
        _devices.values.where((d) => _showAll || d.likelyT02).toList()..sort(
          (a, b) => a.likelyT02 != b.likelyT02
              ? (a.likelyT02 ? -1 : 1)
              : (b.rssi ?? -100).compareTo(a.rssi ?? -100),
        );
    return [
      const Text(
        'Your printer',
        style: TextStyle(
          fontSize: 25,
          fontWeight: FontWeight.w600,
          letterSpacing: -.7,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Turn on the T02, load paper and disconnect the Phomemo app.',
        style: TextStyle(color: muted),
      ),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            const Icon(Icons.print_outlined, size: 40, color: paper),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _state.device?.name ?? 'Phomemo T02',
                    style: const TextStyle(
                      color: paper,
                      fontWeight: FontWeight.w600,
                      fontSize: 19,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _phaseLabel,
                    style: const TextStyle(color: Color(0xFFBDCBBB)),
                  ),
                ],
              ),
            ),
            if (_working)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: paper),
              ),
          ],
        ),
      ),
      if (_state.phase != PrinterPhase.disconnected) ...[
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => _action(_client.disconnect),
          child: const Text('Disconnect'),
        ),
        const SizedBox(height: 16),
        _statusRow('Paper', _state.paperPresent),
        _statusRow('Cover closed', _state.coverClosed),
        _statusRow('Temperature normal', _state.temperatureNormal),
      ] else ...[
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _scanning ? _stopScan : _scan,
          icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
          label: Text(_scanning ? 'Stop scanning' : 'Find printer'),
        ),
        if (_scanning)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        const SizedBox(height: 18),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              _scanning
                  ? 'Looking for your T02 …'
                  : 'Discovered printers appear here.',
              style: const TextStyle(color: muted),
            ),
          ),
        for (final d in devices)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: line),
              borderRadius: BorderRadius.circular(14),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: Icon(
                d.likelyT02 ? Icons.print_outlined : Icons.bluetooth,
                color: green,
              ),
              title: Text(
                d.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${d.rssi ?? '—'} dBm · ${d.id}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _working ? null : () => _connect(d),
            ),
          ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Show all BLE devices',
            style: TextStyle(fontSize: 14),
          ),
          value: _showAll,
          onChanged: (v) => setState(() => _showAll = v),
        ),
      ],
      const SizedBox(height: 24),
      const Divider(),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Print settings', style: TextStyle(fontSize: 15)),
        children: [
          Row(
            children: [
              const Expanded(child: Text('Feed after printing')),
              DropdownButton<int>(
                value: _feed,
                items: List.generate(
                  11,
                  (i) =>
                      DropdownMenuItem(value: i, child: Text('$i feed units')),
                ),
                onChanged: _working ? null : (v) => setState(() => _feed = v!),
              ),
            ],
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Experimental send mode'),
            subtitle: const Text(
              'Only if the T02 sends no credits: 20 bytes every 200 ms without printer flow control. May cause incomplete prints. Applies after reconnecting.',
              style: TextStyle(fontSize: 12),
            ),
            value: _paced,
            onChanged: _state.phase == PrinterPhase.disconnected && !_working
                ? (v) => setState(() => _paced = v)
                : null,
          ),
          const SizedBox(height: 16),
        ],
      ),
      const SizedBox(height: 18),
      const Text(
        'Keep the app open while printing. Unknown status values are shown as unknown.',
        style: TextStyle(fontSize: 12, color: muted),
      ),
    ];
  }

  Widget _statusRow(String label, bool? ok) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          ok == null
              ? 'unknown'
              : ok
              ? 'OK'
              : 'check',
          style: TextStyle(
            color: ok == null
                ? muted
                : ok
                ? green
                : Colors.deepOrange,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  List<Widget> _logPage() => [
    const Text(
      'What is happening?',
      style: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: -.7,
      ),
    ),
    const SizedBox(height: 8),
    const Text(
      'Connections, packets and replies from your T02. Use this log to diagnose printing issues.',
      style: TextStyle(color: muted),
    ),
    const SizedBox(height: 20),
    Row(
      children: [
        Expanded(child: _metric('PACKET', '${_state.packetSize} B')),
        const SizedBox(width: 12),
        Expanded(child: _metric('CREDITS', '${_state.credits}')),
        const SizedBox(width: 12),
        Expanded(child: _metric('SENT', '${_state.bytesSent} B')),
      ],
    ),
    const SizedBox(height: 16),
    OutlinedButton.icon(
      onPressed: () async {
        await Clipboard.setData(
          ClipboardData(text: _client.exportDiagnostics()),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Diagnostic log copied.')),
          );
        }
      },
      icon: const Icon(Icons.copy_outlined, size: 18),
      label: const Text('Copy log'),
    ),
    const SizedBox(height: 12),
    const Text(
      'Includes received bytes and short prefixes of sent packets. These may contain parts of your printed content.',
      style: TextStyle(fontSize: 11, color: muted),
    ),
    const SizedBox(height: 20),
    if (_client.log.isEmpty)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 30),
        child: Text(
          'No events yet. Connect a printer to get started.',
          style: TextStyle(color: muted),
        ),
      ),
    for (final entry in _client.log.reversed.take(120))
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry.time.toIso8601String().substring(11, 23)}  ${entry.kind.toUpperCase()}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: green,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(entry.message, style: const TextStyle(fontSize: 12)),
            if (entry.bytes != null)
              SelectableText(
                entry.bytes!
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join(' '),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: muted,
                ),
              ),
            const SizedBox(height: 10),
            const Divider(height: 1),
          ],
        ),
      ),
  ];
  Widget _metric(String title, String value) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _eyebrow(title),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
  Widget _eyebrow(String s) => Text(
    s,
    style: const TextStyle(
      fontSize: 9,
      letterSpacing: 1.2,
      color: muted,
      fontWeight: FontWeight.w600,
    ),
  );
}

MonoBitmap _decode((Uint8List, bool) request) =>
    MonoBitmap.fromEncodedImage(request.$1, dither: request.$2);

Future<Uint8List> _renderText(String? text) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final sample = text == null;
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: sample
          ? 'Hello, T02.\nThis is your first test print.'
          : (text.isEmpty ? ' ' : text),
      style: TextStyle(
        color: Colors.black,
        fontFamily: 'monospace',
        fontSize: sample ? 23 : 26,
        height: 1.3,
      ),
    ),
  )..layout(maxWidth: 336);
  final height = (painter.height + (sample ? 278 : 48)).ceil();
  if (height > MonoBitmap.maxHeight) {
    throw const FormatException('Text is too long for one print.');
  }
  canvas.drawRect(
    Rect.fromLTWH(0, 0, 384, height.toDouble()),
    Paint()..color = Colors.white,
  );
  painter.paint(canvas, const Offset(24, 24));
  if (sample) {
    final y = painter.height + 48;
    final rule = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;
    canvas.drawLine(Offset(24, y), Offset(360, y), rule);
    final pattern = MonoBitmap.testPattern();
    final black = Paint()..color = Colors.black;
    for (var row = 0; row < pattern.height; row++) {
      for (var x = 0; x < 384; x++) {
        if (pattern.blackAt(x, row)) {
          canvas.drawRect(
            Rect.fromLTWH(x.toDouble(), y + 18 + row, 1, 1),
            black,
          );
        }
      }
    }
    final footer = TextPainter(
      textDirection: TextDirection.ltr,
      text: const TextSpan(
        text: '384 DOTS  /  203 DPI\nFLUTTER + PHOMEMO T02',
        style: TextStyle(
          color: Colors.black,
          fontFamily: 'monospace',
          fontSize: 16,
          height: 1.4,
        ),
      ),
    )..layout(maxWidth: 336);
    footer.paint(canvas, Offset(24, y + 162));
    footer.dispose();
  }
  painter.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(384, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

class _ReceiptClipper extends CustomClipper<Path> {
  const _ReceiptClipper();
  @override
  Path getClip(Size size) {
    final path = Path()
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height - 6);
    for (double x = size.width; x > 0; x -= 12) {
      path.lineTo(x - 6, size.height);
      path.lineTo(x - 12, size.height - 6);
    }
    return path
      ..lineTo(0, 0)
      ..close();
  }

  @override
  bool shouldReclip(_ReceiptClipper oldClipper) => false;
}
