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
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
      autoStart: true,
    );
    if (mounted) setState(() => _cameraStarted = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_controller == null) return;

    switch (state) {
      case AppLifecycleState.resumed:
        if (!_isProcessing) {
          _controller!.start();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _controller!.stop();
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
      await _controller?.stop();
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
              'กรุณาตรวจสอบ QR Code หรือติดต่อผู้ดูแลระบบ';
        });
      }
    } catch (e) {
      setState(() => _lastError = 'เกิดข้อผิดพลาด: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
        await Future.delayed(const Duration(milliseconds: 300));
        await _controller?.start();
      }
    }
  }

  // ── Manual entry ───────────────────────────────────────────────────────────

  Future<void> _showManualEntry() async {
    await _controller?.stop();

    final controller = TextEditingController();
    final tag = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
            prefixIcon: Icon(Icons.qr_code),
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

    if (tag != null && tag.isNotEmpty) {
      await _lookupAsset(tag);
    } else {
      await _controller?.start();
    }
  }

  // ── Restart camera ─────────────────────────────────────────────────────────

  Future<void> _restartCamera() async {
    setState(() {
      _cameraStarted = false;
      _lastError = null;
      _permissionDenied = false;
    });
    await _controller?.stop();
    await _controller?.dispose();
    _controller = null;
    // รอให้ระบบ release กล้องก่อนสร้างใหม่
    await Future.delayed(const Duration(milliseconds: 800));
    await _initCamera();
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
          IconButton(
            icon: Icon(
              Icons.flash_on,
              color: _torchOn ? AppConstants.accentAmber : Colors.white70,
            ),
            onPressed: _cameraStarted
                ? () {
                    _controller?.toggleTorch();
                    setState(() => _torchOn = !_torchOn);
                  }
                : null,
            tooltip: 'Toggle torch',
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch_outlined),
            onPressed: _cameraStarted ? () => _controller?.switchCamera() : null,
            tooltip: 'Flip camera',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _restartCamera,
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
              errorBuilder: (context, error, child) {
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
          if (_isProcessing)
            const LoadingOverlay(message: 'กำลังค้นหา Asset…'),
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
    const windowSize = 260.0;
    final top = (size.height - windowSize) / 2 - 60;
    final left = (size.width - windowSize) / 2;

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
                width: windowSize,
                height: windowSize,
                decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ]),
        ),
        Positioned(
            top: top, left: left, child: _CornerFrame(size: windowSize)),
        Positioned(
          top: top + 4,
          left: left + 4,
          child: SizedBox(
            width: windowSize - 8,
            height: windowSize - 8,
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
          top: top + windowSize + 16,
          left: 0,
          right: 0,
          child: const Text(
            'วาง QR Code ให้อยู่ในกรอบ',
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
  final double size;
  const _CornerFrame({required this.size});

  @override
  Widget build(BuildContext context) {
    const l = 24.0, s = 3.0;
    const color = AppConstants.accentBlue;
    return SizedBox(
      width: size,
      height: size,
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
        child: CustomPaint(
            painter: _CornerPainter(stroke: stroke, color: color)),
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
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(20)),
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
                border: Border.all(
                    color: AppConstants.accentRed.withOpacity(0.4)),
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
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.5)),
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