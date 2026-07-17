import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/snipeit_service.dart';
import '../utils/app_constants.dart';
import '../widgets/common_widgets.dart';
import 'asset_details_screen.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _service = SnipeITService();

  MobileScannerController? _controller;

  bool _isProcessing = false;
  String? _lastError;
  bool _torchOn = false;
  bool _cameraStarted = false;
  bool _permissionDenied = false;

  // True only while the native scanner session is actually running.
  // Distinct from _cameraStarted, which stays true across temporary
  // stop()/start() cycles (e.g. while looking up an asset). Any UI
  // action that talks to the controller (torch, switch camera) must
  // gate on this, not on _cameraStarted.
  bool _scannerActive = false;

  // True only after the MobileScanner widget has actually been built and
  // its platform view attached (i.e. after the post-frame callback in
  // _initCamera has run). Distinct from `_controller != null`, which
  // becomes true as soon as the controller object is constructed but
  // before the widget tree (and therefore the native platform view) has
  // been built. The app-lifecycle handler must gate on this flag, not on
  // `_controller != null`, otherwise a `resumed` event arriving in the gap
  // between controller construction and the post-frame callback (e.g.
  // right after returning from the OS permission dialog) will call
  // start() on a session whose platform view isn't attached yet, hitting
  // the same NullPointerException on the "scanner/method" channel that
  // autoStart: false was meant to avoid.
  bool _controllerAttached = false;

  // Guards against overlapping _restartCamera() calls if the user
  // taps refresh multiple times before the previous restart finishes.
  bool _restarting = false;

  late final AnimationController _lineController;
  late final Animation<double> _lineAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _lineController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _lineAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _lineController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initCamera() async {
    // ขอ permission กล้องก่อนเสมอ
    final status = await Permission.camera.request();
    if (!mounted) return;

    if (!status.isGranted) {
      setState(() {
        _permissionDenied = true;
        _cameraStarted = false;
        _scannerActive = false;
        _lastError = status.isPermanentlyDenied
            ? 'กรุณาเปิดอนุญาตกล้องในการตั้งค่าของโทรศัพท์'
            : 'กรุณาอนุญาตการใช้งานกล้อง';
      });
      return;
    }

    setState(() {
      _permissionDenied = false;
      _lastError = null;
    });

    // ได้ permission แล้วค่อยสร้าง controller
    //
    // IMPORTANT: autoStart is deliberately false. With autoStart: true,
    // mobile_scanner invokes start() on its method channel synchronously
    // during controller construction. When this construction happens right
    // after returning from the OS permission-grant activity, the native
    // platform view/method channel for the scanner is not guaranteed to be
    // re-attached yet, and that internal start() call throws a
    // NullPointerException on the "scanner/method" channel (native session
    // object is null). Starting manually after the widget has built avoids
    // the race.
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
      autoStart: false,
      // Barcode-only: restrict detection to common 1D linear symbologies
      // used on asset tags. QR / DataMatrix / Aztec / PDF417 (2D / stacked
      // codes) are intentionally excluded now that this screen is
      // barcode-only.
      formats: const [
        BarcodeFormat.code128,
        BarcodeFormat.code39,
        BarcodeFormat.code93,
        BarcodeFormat.codabar,
        BarcodeFormat.ean8,
        BarcodeFormat.ean13,
        BarcodeFormat.itf,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
      ],
    );
    _controllerAttached = false;
    if (mounted) {
      setState(() => _cameraStarted = true);
    }
    // Defer starting until after this frame, so the MobileScanner widget
    // (and its platform view) has actually been built and attached before
    // we ask the plugin to start the camera session.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controllerAttached = true;
        _safeStart();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_controller == null || !_controllerAttached) return;

    switch (state) {
      case AppLifecycleState.resumed:
        if (!_isProcessing) {
          _safeStart();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _safeStop();
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _lineController.dispose();
    super.dispose();
  }

  // ── Safe controller wrappers ────────────────────────────────────────────
  //
  // mobile_scanner's native session can be torn down (stop/dispose) while
  // an async op is still in flight. Calling start/stop/toggleTorch/
  // switchCamera on a torn-down session throws a NullPointerException on
  // the platform side (method channel "scanner/method"). These wrappers
  // centralize the state bookkeeping and swallow that failure mode instead
  // of letting it surface as a native crash log.

  Future<void> _safeStart() async {
    if (_controller == null || !mounted) return;
    try {
      await _controller!.start();
      if (mounted) setState(() => _scannerActive = true);
    } catch (_) {
      // Session may already be running or camera unavailable; ignore.
    }
  }

  Future<void> _safeStop() async {
    if (_controller == null) return;
    if (mounted) setState(() => _scannerActive = false);
    try {
      await _controller!.stop();
    } catch (_) {
      // Already stopped/disposed; nothing to do.
    }
  }

  // NOTE: torch toggle and camera switch are currently unused because the
  // corresponding AppBar buttons are commented out below. Left in place
  // (unused) in case the buttons are re-enabled later.
  Future<void> _safeToggleTorch() async {
    if (_controller == null || !_scannerActive) return;
    try {
      await _controller!.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (_) {
      // Ignore — session wasn't ready.
    }
  }

  Future<void> _safeSwitchCamera() async {
    if (_controller == null || !_scannerActive) return;
    try {
      await _controller!.switchCamera();
    } catch (_) {
      // Ignore — session wasn't ready.
    }
  }

  // ── Barcode handling ───────────────────────────────────────────────────────

  Future<void> _onBarcodeDetected(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final barcode = capture.barcodes.firstOrNull;
    final rawValue = barcode?.rawValue;
    if (rawValue == null || rawValue.isEmpty) return;
    await _lookupAsset(rawValue);
  }

  Future<void> _lookupAsset(String tag) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _lastError = null;
    });

    try {
      await _safeStop();
      final asset = await _service.getAssetByTag(tag);

      if (!mounted) return;

      if (asset != null) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AssetDetailsScreen(asset: asset),
          ),
        );
      } else {
        setState(() {
          _lastError = 'ไม่พบ Asset Tag "$tag" ในระบบ\n'
              'กรุณาตรวจสอบ Barcode หรือติดต่อผู้ดูแลระบบ';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _lastError = 'เกิดข้อผิดพลาด: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
        await Future.delayed(const Duration(milliseconds: 300));
        await _safeStart();
      }
    }
  }

  // ── Manual entry ───────────────────────────────────────────────────────────

  Future<void> _showManualEntry() async {
    await _safeStop();

    final controller = TextEditingController();
    final tag = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.search, color: AppConstants.accentBlue),
            SizedBox(width: 10),
            Text('ค้นหา Asset'),
          ],
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'กรอก Asset Tag',
            prefixIcon: Icon(Icons.barcode_reader),
          ),
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('ค้นหา'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (tag != null && tag.isNotEmpty) {
      await _lookupAsset(tag);
    } else {
      await _safeStart();
    }
  }

  // ── Restart camera ─────────────────────────────────────────────────────────

  Future<void> _restartCamera() async {
    if (_restarting) return;
    _restarting = true;
    try {
      setState(() {
        _cameraStarted = false;
        _scannerActive = false;
        _lastError = null;
        _permissionDenied = false;
      });
      _controllerAttached = false;
      final old = _controller;
      _controller = null;
      try {
        await old?.stop();
      } catch (_) {}
      try {
        await old?.dispose();
      } catch (_) {}
      // รอให้ระบบ release กล้องก่อนสร้างใหม่
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      await _initCamera();
    } finally {
      _restarting = false;
    }
  }

  // ── Open app settings (กรณี permission ถูก deny permanently) ──────────────

  void _openAppSettings() => openAppSettings();

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('IT Asset Scanner'),
        actions: [
          // Flash torch toggle — disabled for now, keep only restart camera
          // IconButton(
          //   icon: Icon(
          //     Icons.flash_on,
          //     color: _torchOn ? AppConstants.accentAmber : Colors.white70,
          //   ),
          //   // Gate on _scannerActive (not _cameraStarted) so this is
          //   // disabled while the session is stopped for a lookup or
          //   // for the manual-entry dialog.
          //   onPressed: _scannerActive ? _safeToggleTorch : null,
          //   tooltip: 'Toggle torch',
          // ),

          // Flip camera — disabled for now, keep only restart camera
          // IconButton(
          //   icon: const Icon(Icons.cameraswitch_outlined),
          //   onPressed: _scannerActive ? _safeSwitchCamera : null,
          //   tooltip: 'Flip camera',
          // ),

          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _restarting ? null : _restartCamera,
            tooltip: 'Restart camera',
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Camera feed ────────────────────────────────────────────────
          if (_permissionDenied)
            _PermissionDeniedView(
              isPermanent: _lastError?.contains('การตั้งค่า') ?? false,
              onRetry: _restartCamera,
              onOpenSettings: _openAppSettings,
            )
          else if (_controller != null && _cameraStarted)
            MobileScanner(
              controller: _controller!,
              onDetect: _onBarcodeDetected,
              errorBuilder: (context, error) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.camera_alt_outlined,
                          color: Colors.white54, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        'ไม่สามารถเปิดกล้องได้\n${error.errorCode}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _restartCamera,
                        icon: const Icon(Icons.refresh),
                        label: const Text('ลองใหม่'),
                      ),
                    ],
                  ),
                );
              },
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            ),

          // ── Scan overlay ───────────────────────────────────────────────
          if (_cameraStarted && !_permissionDenied)
            _ScanOverlay(lineAnimation: _lineAnim),

          // ── Bottom panel ───────────────────────────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomPanel(
              isProcessing: _isProcessing,
              error: _lastError,
              onManualEntry: _showManualEntry,
              onDismissError: () => setState(() => _lastError = null),
            ),
          ),

          // ── Loading overlay ────────────────────────────────────────────
          if (_isProcessing) const LoadingOverlay(message: 'กำลังค้นหา Asset…'),
        ],
      ),
    );
  }
}

// ── Permission denied view ────────────────────────────────────────────────

class _PermissionDeniedView extends StatelessWidget {
  final bool isPermanent;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  const _PermissionDeniedView({
    required this.isPermanent,
    required this.onRetry,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                color: Colors.white54, size: 64),
            const SizedBox(height: 16),
            Text(
              isPermanent
                  ? 'กรุณาเปิดอนุญาตกล้องในการตั้งค่าของโทรศัพท์'
                  : 'แอปต้องการสิทธิ์เข้าถึงกล้องเพื่อสแกนบาร์โค้ด',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 24),
            if (isPermanent)
              ElevatedButton.icon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('เปิดการตั้งค่า'),
              )
            else
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('อนุญาตกล้อง'),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Scan overlay ──────────────────────────────────────────────────────────

class _ScanOverlay extends StatelessWidget {
  final Animation<double> lineAnimation;
  const _ScanOverlay({required this.lineAnimation});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Barcode-only scan window: 1D barcodes are wide and short, so the
    // window is a narrow horizontal band rather than the square used for
    // QR codes. This also lets the user scan from further away since the
    // camera no longer needs to resolve a large square area.
    const windowWidth = 260.0;
    const windowHeight = 120.0;
    final top = (size.height - windowHeight) / 2 - 60;
    final left = (size.width - windowWidth) / 2;

    return Stack(
      children: [
        ColorFiltered(
          colorFilter: ColorFilter.mode(
              Colors.black.withOpacity(0.55), BlendMode.srcOut),
          child: Stack(children: [
            Container(
                decoration: const BoxDecoration(
                    color: Colors.black,
                    backgroundBlendMode: BlendMode.dstOut)),
            Positioned(
              top: top,
              left: left,
              child: Container(
                width: windowWidth,
                height: windowHeight,
                decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ]),
        ),
        Positioned(
            top: top,
            left: left,
            child: _CornerFrame(width: windowWidth, height: windowHeight)),
        Positioned(
          top: top + 4,
          left: left + 4,
          child: SizedBox(
            width: windowWidth - 8,
            height: windowHeight - 8,
            child: AnimatedBuilder(
              animation: lineAnimation,
              builder: (_, __) => Align(
                alignment: Alignment(0, (lineAnimation.value * 2) - 1),
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      AppConstants.accentBlue.withOpacity(0),
                      AppConstants.accentBlue,
                      AppConstants.accentBlue.withOpacity(0),
                    ]),
                    borderRadius: BorderRadius.circular(1),
                    boxShadow: [
                      BoxShadow(
                          color: AppConstants.accentBlue.withOpacity(0.4),
                          blurRadius: 6,
                          spreadRadius: 1)
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: top + windowHeight + 16,
          left: 0,
          right: 0,
          child: const Text(
            'วาง Barcode ให้อยู่ในกรอบ',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w400),
          ),
        ),
      ],
    );
  }
}

class _CornerFrame extends StatelessWidget {
  final double width;
  final double height;
  const _CornerFrame({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    const l = 24.0, s = 3.0;
    const color = AppConstants.accentBlue;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(children: [
        Positioned(
            top: 0,
            left: 0,
            child: _Corner(length: l, stroke: s, color: color)),
        Positioned(
            top: 0,
            right: 0,
            child: Transform.rotate(
                angle: 1.5708,
                child: _Corner(length: l, stroke: s, color: color))),
        Positioned(
            bottom: 0,
            left: 0,
            child: Transform.rotate(
                angle: -1.5708,
                child: _Corner(length: l, stroke: s, color: color))),
        Positioned(
            bottom: 0,
            right: 0,
            child: Transform.rotate(
                angle: 3.1416,
                child: _Corner(length: l, stroke: s, color: color))),
      ]),
    );
  }
}

class _Corner extends StatelessWidget {
  final double length, stroke;
  final Color color;
  const _Corner(
      {required this.length, required this.stroke, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: length,
        height: length,
        child:
            CustomPaint(painter: _CornerPainter(stroke: stroke, color: color)),
      );
}

class _CornerPainter extends CustomPainter {
  final double stroke;
  final Color color;
  _CornerPainter({required this.stroke, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), p);
    canvas.drawLine(Offset.zero, Offset(0, size.height), p);
  }

  @override
  bool shouldRepaint(_CornerPainter o) =>
      o.stroke != stroke || o.color != color;
}

// ── Bottom panel ──────────────────────────────────────────────────────────

class _BottomPanel extends StatelessWidget {
  final bool isProcessing;
  final String? error;
  final VoidCallback onManualEntry;
  final VoidCallback onDismissError;

  const _BottomPanel({
    required this.isProcessing,
    required this.error,
    required this.onManualEntry,
    required this.onDismissError,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppConstants.primaryNavy.withOpacity(0.92),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.paddingOf(context).bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppConstants.accentRed.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: AppConstants.accentRed.withOpacity(0.4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppConstants.accentRed, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(error!,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13, height: 1.5)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white54, size: 18),
                    onPressed: onDismissError,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: isProcessing ? null : onManualEntry,
              icon: const Icon(Icons.keyboard_outlined, size: 18),
              label: const Text('กรอก Asset Tag'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}