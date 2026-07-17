import 'package:flutter/material.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:intl/intl.dart';

import '../models/activity_model.dart';
import '../models/asset_model.dart';
import '../services/snipeit_service.dart';
import '../utils/app_constants.dart';
import '../widgets/common_widgets.dart';
import '../widgets/signature_dialog.dart';
// EDIT FEATURE DISABLED: ไม่ใช้แล้วเพราะ flow ออกแบบให้แก้ asset ไม่ได้หลังสร้าง
// ถ้าต้องการเปิดใช้อีกครั้ง ให้ uncomment บรรทัดนี้ และจุดอื่นๆ ที่ comment ไว้ด้านล่าง
// import 'edit_asset_screen.dart';

// Snipe-IT returns custom-field values HTML-escaped (e.g. 14" comes back
// as `14&quot;`), so every value read via _cf() below is run through this
// decoder — same as the PDF generator in signature_dialog.dart does.
final HtmlUnescape _htmlUnescape = HtmlUnescape();

/// Reads a Snipe-IT custom field value out of [AssetModel.customFields] by
/// its exact field *name* (as configured in Snipe-IT, e.g. "RAM",
/// "Storage Type", "S/N Monitor", "Type", "Warranty Period",
/// "Warranty Provider"). Returns '—' when the field is missing/empty.
///
/// NOTE: the key must match the Snipe-IT field name exactly (case + spacing).
/// If a field shows '—' here even though you filled it in on the Fieldset,
/// double check the exact label used in Snipe-IT's "Custom Fields" admin.
String _cf(AssetModel asset, String key) {
  final field = (asset.customFields ?? {})[key];
  if (field == null) return '—';
  final raw = field['value']?.toString();
  if (raw == null || raw.trim().isEmpty) return '—';
  return _htmlUnescape.convert(raw);
}

/// Activity-log actions we want to surface to the user in the History tab.
/// Snipe-IT also logs a 'upload' entry every time we attach the signature
/// PNG (base64) to the asset/user record — that entry is just noise for
/// this screen (it's huge base64 text, not something the user needs to
/// read), so we filter the log down to just checkout/checkin here.
bool _isVisibleHistoryAction(String? action) {
  final a = action?.toLowerCase().trim() ?? '';
  return a.contains('checkout') || a.contains('checkin');
}

class AssetDetailsScreen extends StatefulWidget {
  final AssetModel asset;

  const AssetDetailsScreen({super.key, required this.asset});

  @override
  State<AssetDetailsScreen> createState() => _AssetDetailsScreenState();
}

class _AssetDetailsScreenState extends State<AssetDetailsScreen>
    with SingleTickerProviderStateMixin {
  final _service = SnipeITService();
  late TabController _tabController;

  late AssetModel _asset;

  List<ActivityModel> _history = [];
  bool _historyLoading = false;
  String? _historyError;

  bool _actionLoading = false;

  @override
  void initState() {
    super.initState();
    _asset = widget.asset;
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index == 1 && _history.isEmpty) {
        _loadHistory();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Data refresh ───────────────────────────────────────────────────────────

  Future<void> _refreshAsset() async {
    try {
      final refreshed = await _service.getAssetById(_asset.id!);
      if (mounted) setState(() => _asset = refreshed);
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    if (_asset.id == null) return;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final log = await _service.getAssetHistory(_asset.id!);
      // เก็บเฉพาะ checkin/checkout ตั้งแต่ตอนโหลด ไม่ต้องกรองซ้ำทุกครั้งที่ build
      final filtered =
          log.where((e) => _isVisibleHistoryAction(e.action)).toList();
      if (mounted) setState(() => _history = filtered);
    } catch (e) {
      if (mounted) setState(() => _historyError = e.toString());
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  // EDIT FEATURE DISABLED ───────────────────────────────────────────────────
  // เก็บฟังก์ชันนี้ไว้เผื่อใช้ในอนาคต ถ้าต้องการเปิดใช้:
  // 1. Uncomment import 'edit_asset_screen.dart' ด้านบน
  // 2. Uncomment ฟังก์ชันนี้
  // 3. Uncomment ปุ่ม Edit ใน AppBar actions ด้านล่าง
  //
  // Future<void> _openEditScreen() async {
  //   final updated = await Navigator.push<AssetModel>(
  //     context,
  //     MaterialPageRoute(builder: (_) => EditAssetScreen(asset: _asset)),
  //   );
  //   if (updated != null && mounted) {
  //     setState(() => _asset = updated);
  //   }
  // }

  /// เบิกอุปกรณ์ให้ User
  Future<void> _handleCheckOut() async {
    if (_asset.id == null) return;

    // 1. Search และเลือก user จากระบบ Snipe-IT
    final user = await _showUserSearchDialog();
    if (user == null || !mounted) return;

    // 2. Capture signature
    final sig = await showSignatureDialog(
      context: context,
      title: 'ลายเซ็นการเบิกอุปกรณ์',
      subtitle: 'เซ็นชื่อเพื่อยืนยันการรับ ${_asset.assetTag ?? _asset.serial}',
      asset: _asset,
      assigneeName: user.name,
      division: user.department, // ส่ง department ของ user ที่เลือก
      isCheckOut: true,
    );

    if (sig == null || sig.isEmpty || !mounted) return;

    setState(() => _actionLoading = true);
    try {
      await _service.checkOutAsset(
        assetId: _asset.id!,
        userId: user.id!,
        note: 'เบิกอุปกรณ์ผ่าน IT Asset Manager app',
      );

      try {
        final now = DateTime.now();
        final mm = now.month.toString().padLeft(2, '0');
        final dd = now.day.toString().padLeft(2, '0');
        final hh = now.hour.toString().padLeft(2, '0');
        final min = now.minute.toString().padLeft(2, '0');
        final filename = 'checkout_sig_${now.year}$mm${dd}_$hh$min.png';

        await _service.uploadSignatureToUser(
          userId: user.id!,
          pngBytes: sig,
          filename: filename,
        );
        try {
          await _service.uploadSignature(
            assetId: _asset.id!,
            pngBytes: sig,
            filename: filename,
          );
        } catch (_) {}
      } catch (uploadErr) {
        debugPrint('Upload error: $uploadErr');
      }

      await _refreshAsset();
      await _loadHistory();
      if (mounted) _showSuccessSnack('เบิกอุปกรณ์ให้ ${user.name} สำเร็จ');
    } catch (e) {
      if (mounted) _showErrorSnack('เบิกอุปกรณ์ล้มเหลว: $e');
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  /// คืนอุปกรณ์
  Future<void> _handleCheckIn() async {
    if (_asset.id == null) return;

    // fetch user เต็มเพื่อให้ได้ department (assigned_to ใน asset มีแค่ id/name)
    String? division;
    final assignedId = _asset.assignedTo?.id;
    if (assignedId != null) {
      try {
        final fullUser = await _service.getUserById(assignedId);
        division = fullUser?.department;
      } catch (_) {}
    }

    final sig = await showSignatureDialog(
      context: context,
      title: 'ลายเซ็นการคืนอุปกรณ์',
      subtitle: 'เซ็นชื่อเพื่อยืนยันการคืน ${_asset.assetTag ?? _asset.serial}',
      asset: _asset,
      assigneeName: _asset.assignedTo?.name,
      division: division,
      isCheckOut: false,
    );
    if (sig == null || sig.isEmpty || !mounted) return;

    setState(() => _actionLoading = true);
    try {
      await _service.checkInAsset(
        assetId: _asset.id!,
        note: 'คืนอุปกรณ์ผ่าน IT Asset Manager app',
      );

      try {
        final now = DateTime.now();
        final mm = now.month.toString().padLeft(2, '0');
        final dd = now.day.toString().padLeft(2, '0');
        final hh = now.hour.toString().padLeft(2, '0');
        final min = now.minute.toString().padLeft(2, '0');
        final filename = 'checkin_sig_${now.year}$mm${dd}_$hh$min.png';
        final assignedUserId = _asset.assignedTo?.id;

        if (assignedUserId != null) {
          try {
            await _service.uploadSignatureToUser(
              userId: assignedUserId,
              pngBytes: sig,
              filename: filename,
            );
          } catch (_) {}
        }

        try {
          await _service.uploadSignature(
            assetId: _asset.id!,
            pngBytes: sig,
            filename: filename,
          );
        } catch (_) {}
      } catch (uploadErr) {
        debugPrint('Upload error: $uploadErr');
      }

      await _refreshAsset();
      await _loadHistory();
      if (mounted) _showSuccessSnack('คืนอุปกรณ์สำเร็จ');
    } catch (e) {
      if (mounted) _showErrorSnack('คืนอุปกรณ์ล้มเหลว: $e');
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  // ── User search dialog ─────────────────────────────────────────────────────

  Future<AssetUser?> _showUserSearchDialog() async {
    return showDialog<AssetUser>(
      context: context,
      builder: (ctx) => _UserSearchDialog(service: _service),
    );
  }

  // ── Snackbars ──────────────────────────────────────────────────────────────

  void _showSuccessSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(msg)),
          ],
        ),
        backgroundColor: AppConstants.accentGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _showErrorSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppConstants.accentRed,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isCheckedOut =
        _asset.assignedTo != null && _asset.assignedTo!.id != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(_asset.assetTag ?? 'Asset Details'),
        // EDIT FEATURE DISABLED ─────────────────────────────────────────────
        // เก็บปุ่ม Edit ไว้เป็น comment เผื่อต้องการเปิดใช้ภายหลัง
        // actions: [
        //   IconButton(
        //     icon: const Icon(Icons.edit_outlined),
        //     onPressed: _actionLoading ? null : _openEditScreen,
        //     tooltip: 'Edit Info',
        //   ),
        // ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppConstants.accentBlue,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Details'),
            Tab(text: 'History'),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: [
              _DetailsTab(asset: _asset),
              _HistoryTab(
                history: _history,
                isLoading: _historyLoading,
                error: _historyError,
                onRetry: _loadHistory,
              ),
            ],
          ),
          if (_actionLoading) const LoadingOverlay(message: 'กำลังดำเนินการ…'),
        ],
      ),

      // ── Bottom action bar ──────────────────────────────────────────────────
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: AppConstants.surfaceCard,
            border:
                Border(top: BorderSide(color: AppConstants.divider, width: 1)),
          ),
          child: SizedBox(
            width: double.infinity,
            child: isCheckedOut
                ? OutlinedButton.icon(
                    onPressed: _actionLoading ? null : _handleCheckIn,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text(
                      'คืนอุปกรณ์',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppConstants.accentGreen,
                      side: const BorderSide(
                          color: AppConstants.accentGreen, width: 2),
                      minimumSize: const Size(double.infinity, 52),
                    ),
                  )
                : ElevatedButton.icon(
                    onPressed: _actionLoading ? null : _handleCheckOut,
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text(
                      'เบิกอุปกรณ์',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ── Details Tab ────────────────────────────────────────────────────────────

class _DetailsTab extends StatelessWidget {
  final AssetModel asset;

  const _DetailsTab({required this.asset});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppConstants.accentBlue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.laptop_mac,
                      color: AppConstants.accentBlue, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        asset.assetTag ?? asset.name ?? 'Unnamed Asset',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppConstants.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      StatusBadge(label: asset.statusLabel?.name),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        const SectionHeader(title: 'Device Info'),
        Card(
          child: Column(
            children: [
              InfoRow(label: 'Manufacturer', value: asset.manufacturer?.name),
              const CardDivider(),
              InfoRow(label: 'Model', value: asset.model?.name),
              const CardDivider(),
              InfoRow(label: 'Serial Number', value: asset.serial),
              const CardDivider(),
              InfoRow(label: 'Asset Tag', value: asset.assetTag),
            ],
          ),
        ),

        // ── Specifications (from the "Laptop Field Set" custom fields) ──────
        const SectionHeader(title: 'Specifications'),
        Card(
          child: Column(
            children: [
              InfoRow(label: 'RAM', value: _cf(asset, 'RAM')),
              const CardDivider(),
              InfoRow(
                label: 'Storage',
                value:
                    '${_cf(asset, 'Storage Type')} ${_cf(asset, 'Capacity')}'
                        .trim(),
              ),
              const CardDivider(),
              InfoRow(label: 'Monitor', value: _cf(asset, 'Monitor')),
              const CardDivider(),
              InfoRow(label: 'Monitor S/N', value: _cf(asset, 'Monitor S/N')),
              const CardDivider(),
              InfoRow(label: 'Type', value: _cf(asset, 'Type')),
            ],
          ),
        ),

        const SectionHeader(title: 'Assignment'),
        Card(
          child: Column(
            children: [
              InfoRow(
                label: 'Assigned To',
                valueWidget:
                    asset.assignedTo != null && asset.assignedTo!.id != null
                        ? Row(
                            children: [
                              const Icon(Icons.person,
                                  size: 16, color: AppConstants.accentBlue),
                              const SizedBox(width: 6),
                              Text(
                                asset.assignedTo!.name ?? '—',
                                style: const TextStyle(
                                  color: AppConstants.accentBlue,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          )
                        : const Text(
                            'ไม่มีผู้ถือครอง',
                            style: TextStyle(
                                color: AppConstants.textSecondary, fontSize: 13),
                          ),
              ),
              const CardDivider(),
              InfoRow(label: 'Last Checkout', value: asset.lastCheckout),
            ],
          ),
        ),

        const SectionHeader(title: 'Warranty'),
        Card(
          child: Column(
            children: [
              InfoRow(
                  label: 'Warranty Period', value: _cf(asset, 'Warranty Period')),
              const CardDivider(),
              InfoRow(
                  label: 'Warranty Provider',
                  value: _cf(asset, 'Warranty Provider')),
              const CardDivider(),
              InfoRow(
                  label: 'Object ID', value: _cf(asset, 'Object ID')),
              const CardDivider(),
              InfoRow(
                  label: 'PO number', value: _cf(asset, 'PO Number')),
              const CardDivider(),
              InfoRow(label: 'Last Updated', value: asset.updatedAt),
            ],
          ),
        ),

        if (asset.notes != null && asset.notes!.isNotEmpty) ...[
          const SectionHeader(title: 'Notes'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                asset.notes!,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppConstants.textSecondary,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],

        const SizedBox(height: 32),
      ],
    );
  }
}

class _WarrantyLabel extends StatelessWidget {
  final String expiresText;

  const _WarrantyLabel({required this.expiresText});

  @override
  Widget build(BuildContext context) {
    bool? isExpired;
    try {
      final date = DateFormat('yyyy-MM-dd').parse(expiresText);
      isExpired = date.isBefore(DateTime.now());
    } catch (_) {}

    final color = isExpired == true
        ? AppConstants.accentRed
        : isExpired == false
            ? AppConstants.accentGreen
            : AppConstants.textPrimary;

    return Row(
      children: [
        Text(expiresText,
            style: TextStyle(
                fontSize: 13, color: color, fontWeight: FontWeight.w500)),
        const SizedBox(width: 6),
        if (isExpired == true)
          const Chip(
            label: Text('Expired'),
            backgroundColor: Color(0xFFFFEBEE),
            labelStyle:
                TextStyle(color: AppConstants.accentRed, fontSize: 10),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

// ── History Tab ────────────────────────────────────────────────────────────
// NOTE: `history` ที่ส่งเข้ามาถูกกรองไว้แล้วตั้งแต่ _loadHistory() ใน
// AssetDetailsScreen (เหลือแค่ action ที่เป็น checkin/checkout) แต่ยังกรอง
// ซ้ำอีกชั้นตรงนี้ด้วย เผื่อในอนาคตมีที่อื่นส่ง history เข้ามาโดยไม่ได้
// กรองมาก่อน จะได้ไม่มี entry ประเภท upload หลุดมาแสดงโดยไม่ตั้งใจ
class _HistoryTab extends StatelessWidget {
  final List<ActivityModel> history;
  final bool isLoading;
  final String? error;
  final VoidCallback onRetry;

  const _HistoryTab({
    required this.history,
    required this.isLoading,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Center(child: CircularProgressIndicator());
    if (error != null) return ErrorBanner(message: error!, onRetry: onRetry);

    final visibleHistory =
        history.where((e) => _isVisibleHistoryAction(e.action)).toList();

    if (visibleHistory.isEmpty) {
      return const EmptyState(
        icon: Icons.history_toggle_off_outlined,
        message: 'ไม่พบประวัติการใช้งาน',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: visibleHistory.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) => _HistoryTile(entry: visibleHistory[i]),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final ActivityModel entry;

  const _HistoryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _iconForAction(entry.action);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              Container(width: 1, height: 20, color: AppConstants.divider),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      entry.actionLabel,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: color),
                    ),
                    if (entry.target?.name != null) ...[
                      const Text(' → ',
                          style: TextStyle(
                              color: AppConstants.textSecondary, fontSize: 13)),
                      Flexible(
                        child: Text(
                          entry.target!.name!,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppConstants.textPrimary,
                              fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (entry.actor?.name != null) ...[
                      const Icon(Icons.person_outline,
                          size: 11, color: AppConstants.textSecondary),
                      const SizedBox(width: 3),
                      Text(entry.actor!.name!,
                          style: const TextStyle(
                              fontSize: 11,
                              color: AppConstants.textSecondary)),
                      const SizedBox(width: 8),
                    ],
                    if (entry.createdAt != null)
                      Text(entry.createdAt!,
                          style: const TextStyle(
                              fontSize: 11,
                              color: AppConstants.textSecondary)),
                  ],
                ),
                if (entry.note != null && entry.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      entry.note!,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppConstants.textSecondary,
                          fontStyle: FontStyle.italic),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (IconData, Color) _iconForAction(String? action) {
    return switch (action) {
      'checkout' => (Icons.logout, AppConstants.accentBlue),
      'checkin from' => (Icons.login, AppConstants.accentGreen),
      'create' => (Icons.add_circle_outline, AppConstants.accentGreen),
      'update' => (Icons.edit_outlined, AppConstants.accentAmber),
      'delete' => (Icons.delete_outline, AppConstants.accentRed),
      'upload' => (Icons.upload_file_outlined, AppConstants.textSecondary),
      _ => (Icons.circle_outlined, AppConstants.textSecondary),
    };
  }
}

// ── User Search Dialog ─────────────────────────────────────────────────────

class _UserSearchDialog extends StatefulWidget {
  final SnipeITService service;

  const _UserSearchDialog({required this.service});

  @override
  State<_UserSearchDialog> createState() => _UserSearchDialogState();
}

class _UserSearchDialogState extends State<_UserSearchDialog> {
  final _searchController = TextEditingController();
  List<AssetUser> _results = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _error;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _isSearching = true;
      _error = null;
      _hasSearched = true;
    });
    try {
      final users = await widget.service.searchUsers(query.trim());
      if (mounted) setState(() => _results = users);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
            decoration: const BoxDecoration(
              color: AppConstants.primaryNavy,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.person_search,
                    color: Colors.white70, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'เลือกผู้รับอุปกรณ์',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white60),
                  onPressed: () => Navigator.of(context).pop(null),
                ),
              ],
            ),
          ),

          // ── Search box ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'พิมพ์ชื่อหรือ username…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _results = [];
                            _hasSearched = false;
                          });
                        },
                      )
                    : null,
              ),
              onChanged: (v) {
                setState(() {});
                if (v.trim().isNotEmpty) _search(v);
              },
              onSubmitted: _search,
            ),
          ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!,
                  style: const TextStyle(
                      color: AppConstants.accentRed, fontSize: 12)),
            ),

          // ── Results ──────────────────────────────────────────────────────
          Expanded(
            child: _isSearching
                ? const Center(child: CircularProgressIndicator())
                : !_hasSearched
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person_search,
                                size: 48, color: AppConstants.divider),
                            SizedBox(height: 12),
                            Text(
                              'พิมพ์ชื่อเพื่อค้นหา',
                              style: TextStyle(
                                  color: AppConstants.textSecondary,
                                  fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : _results.isEmpty
                        ? const Center(
                            child: Text(
                              'ไม่พบผู้ใช้งาน',
                              style: TextStyle(
                                  color: AppConstants.textSecondary,
                                  fontSize: 14),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (_, i) {
                              final user = _results[i];
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor:
                                      AppConstants.accentBlue.withOpacity(0.12),
                                  child: Text(
                                    (user.name?.isNotEmpty == true
                                            ? user.name![0]
                                            : '?')
                                        .toUpperCase(),
                                    style: const TextStyle(
                                      color: AppConstants.accentBlue,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  user.name ?? '—',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  [
                                    if (user.username != null) user.username!,
                                    if (user.department != null)
                                      user.department!,
                                  ].join(' · '),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppConstants.textSecondary),
                                ),
                                onTap: () => Navigator.of(context).pop(user),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}