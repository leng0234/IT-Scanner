// import 'package:flutter/material.dart';

// import '../models/asset_model.dart';
// import '../services/snipeit_service.dart';
// import '../utils/app_constants.dart';
// import '../widgets/common_widgets.dart';

// /// Screen to edit an existing asset's mutable fields.
// /// Returns the updated [AssetModel] via [Navigator.pop] on success.
// class EditAssetScreen extends StatefulWidget {
//   final AssetModel asset;

//   const EditAssetScreen({super.key, required this.asset});

//   @override
//   State<EditAssetScreen> createState() => _EditAssetScreenState();
// }

// class _EditAssetScreenState extends State<EditAssetScreen> {
//   final _service = SnipeITService();
//   final _formKey = GlobalKey<FormState>();

//   late final TextEditingController _nameController;
//   late final TextEditingController _serialController;
//   late final TextEditingController _notesController;

//   List<AssetStatus> _statuses = [];
//   AssetStatus? _selectedStatus;

//   bool _isLoading = true;
//   bool _isSaving = false;
//   String? _error;

//   @override
//   void initState() {
//     super.initState();
//     _nameController =
//         TextEditingController(text: widget.asset.name ?? '');
//     _serialController =
//         TextEditingController(text: widget.asset.serial ?? '');
//     _notesController =
//         TextEditingController(text: widget.asset.notes ?? '');
//     _loadStatuses();
//   }

//   @override
//   void dispose() {
//     _nameController.dispose();
//     _serialController.dispose();
//     _notesController.dispose();
//     super.dispose();
//   }

//   Future<void> _loadStatuses() async {
//     try {
//       final statuses = await _service.getStatusLabels();
//       final current = statuses.firstWhere(
//         (s) => s.id == widget.asset.statusLabel?.id,
//         orElse: () => statuses.first,
//       );
//       if (mounted) {
//         setState(() {
//           _statuses = statuses;
//           _selectedStatus = current;
//         });
//       }
//     } catch (e) {
//       if (mounted) setState(() => _error = 'Failed to load statuses: $e');
//     } finally {
//       if (mounted) setState(() => _isLoading = false);
//     }
//   }

//   Future<void> _save() async {
//     if (!_formKey.currentState!.validate()) return;
//     setState(() {
//       _isSaving = true;
//       _error = null;
//     });

//     try {
//       final fields = <String, dynamic>{};
//       final name = _nameController.text.trim();
//       final serial = _serialController.text.trim();
//       final notes = _notesController.text.trim();

//       if (name != (widget.asset.name ?? '')) fields['name'] = name;
//       if (serial != (widget.asset.serial ?? '')) fields['serial'] = serial;
//       if (notes != (widget.asset.notes ?? '')) fields['notes'] = notes;
//       if (_selectedStatus?.id != widget.asset.statusLabel?.id) {
//         fields['status_id'] = _selectedStatus?.id;
//       }

//       if (fields.isEmpty) {
//         Navigator.of(context).pop(null); // Nothing changed
//         return;
//       }

//       final updated =
//           await _service.updateAsset(widget.asset.id!, fields);
//       if (mounted) Navigator.of(context).pop(updated);
//     } catch (e) {
//       setState(() => _error = 'Save failed: $e');
//     } finally {
//       if (mounted) setState(() => _isSaving = false);
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         title: Text('Edit — ${widget.asset.assetTag ?? "Asset"}'),
//         actions: [
//           TextButton(
//             onPressed: (_isSaving || _isLoading) ? null : _save,
//             child: _isSaving
//                 ? const SizedBox(
//                     width: 18,
//                     height: 18,
//                     child: CircularProgressIndicator(
//                         strokeWidth: 2, color: Colors.white),
//                   )
//                 : const Text(
//                     'Save',
//                     style: TextStyle(
//                       color: Colors.white,
//                       fontWeight: FontWeight.w600,
//                       fontSize: 15,
//                     ),
//                   ),
//           ),
//           const SizedBox(width: 8),
//         ],
//       ),
//       body: _isLoading
//           ? const Center(child: CircularProgressIndicator())
//           : Form(
//               key: _formKey,
//               child: ListView(
//                 children: [
//                   if (_error != null) ErrorBanner(message: _error!),

//                   // ── Read-only info ─────────────────────────────────────────
//                   const SectionHeader(title: 'Fixed Info (read-only)'),
//                   Card(
//                     child: Column(
//                       children: [
//                         InfoRow(
//                           label: 'Asset Tag',
//                           value: widget.asset.assetTag ?? '—',
//                         ),
//                         const CardDivider(),
//                         InfoRow(
//                           label: 'Manufacturer',
//                           value:
//                               widget.asset.manufacturer?.name ?? '—',
//                         ),
//                         const CardDivider(),
//                         InfoRow(
//                           label: 'Model',
//                           value: widget.asset.model?.name ?? '—',
//                         ),
//                       ],
//                     ),
//                   ),

//                   // ── Editable fields ────────────────────────────────────────
//                   const SectionHeader(title: 'Editable Info'),
//                   _field(
//                     controller: _nameController,
//                     label: 'Asset Name',
//                     icon: Icons.label_outline,
//                     validator: (v) => (v == null || v.isEmpty)
//                         ? 'Name is required'
//                         : null,
//                   ),
//                   _field(
//                     controller: _serialController,
//                     label: 'Serial Number',
//                     icon: Icons.fingerprint,
//                   ),

//                   // Status dropdown
//                   if (_statuses.isNotEmpty)
//                     Padding(
//                       padding: const EdgeInsets.symmetric(
//                           horizontal: 16, vertical: 6),
//                       child: DropdownButtonFormField<AssetStatus>(
//                         initialValue: _selectedStatus,
//                         isExpanded: true,
//                         decoration: const InputDecoration(
//                           labelText: 'Status',
//                           prefixIcon: Icon(Icons.circle_outlined),
//                         ),
//                         items: _statuses
//                             .map((s) => DropdownMenuItem(
//                                   value: s,
//                                   child: Text(s.name ?? '—'),
//                                 ))
//                             .toList(),
//                         onChanged: (s) =>
//                             setState(() => _selectedStatus = s),
//                       ),
//                     ),

//                   const SectionHeader(title: 'Notes'),
//                   Padding(
//                     padding:
//                         const EdgeInsets.symmetric(horizontal: 16),
//                     child: TextFormField(
//                       controller: _notesController,
//                       maxLines: 4,
//                       decoration: const InputDecoration(
//                         labelText: 'Notes',
//                         alignLabelWithHint: true,
//                         prefixIcon: Padding(
//                           padding: EdgeInsets.only(bottom: 56),
//                           child: Icon(Icons.notes_outlined),
//                         ),
//                       ),
//                     ),
//                   ),
//                   const SizedBox(height: 48),
//                 ],
//               ),
//             ),
//     );
//   }

//   Widget _field({
//     required TextEditingController controller,
//     required String label,
//     required IconData icon,
//     String? Function(String?)? validator,
//   }) {
//     return Padding(
//       padding:
//           const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
//       child: TextFormField(
//         controller: controller,
//         decoration: InputDecoration(
//           labelText: label,
//           prefixIcon: Icon(icon),
//         ),
//         validator: validator,
//       ),
//     );
//   }
// }
