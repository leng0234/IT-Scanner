// import 'package:flutter/material.dart';

// import '../models/asset_model.dart';
// import '../services/snipeit_service.dart';
// import '../utils/app_constants.dart';
// import '../widgets/common_widgets.dart';
// import 'asset_details_screen.dart';

// /// Shown when a scanned barcode is NOT found in Snipe-IT.
// /// Lets the user fill in asset details and create the record.
// class CreateAssetScreen extends StatefulWidget {
//   /// The barcode value that was scanned (pre-filled as asset tag).
//   final String scannedTag;

//   const CreateAssetScreen({super.key, required this.scannedTag});

//   @override
//   State<CreateAssetScreen> createState() => _CreateAssetScreenState();
// }

// class _CreateAssetScreenState extends State<CreateAssetScreen> {
//   final _service = SnipeITService();
//   final _formKey = GlobalKey<FormState>();

//   // Form controllers
//   late final TextEditingController _nameController;
//   late final TextEditingController _serialController;
//   late final TextEditingController _notesController;

//   // Dropdown state
//   List<AssetManufacturer> _manufacturers = [];
//   List<AssetModel2> _models = [];
//   List<AssetStatus> _statuses = [];

//   AssetManufacturer? _selectedManufacturer;
//   AssetModel2? _selectedModel;
//   AssetStatus? _selectedStatus;

//   bool _isLoading = true;
//   bool _isSubmitting = false;
//   String? _error;

//   @override
//   void initState() {
//     super.initState();
//     _nameController = TextEditingController();
//     _serialController = TextEditingController();
//     _notesController = TextEditingController();
//     _loadDropdownData();
//   }

//   @override
//   void dispose() {
//     _nameController.dispose();
//     _serialController.dispose();
//     _notesController.dispose();
//     super.dispose();
//   }

//   // ── Data loading ───────────────────────────────────────────────────────────

//   Future<void> _loadDropdownData() async {
//     setState(() {
//       _isLoading = true;
//       _error = null;
//     });
//     try {
//       final results = await Future.wait([
//         _service.getManufacturers(),
//         _service.getStatusLabels(),
//       ]);
//       setState(() {
//         _manufacturers = results[0] as List<AssetManufacturer>;
//         _statuses = results[1] as List<AssetStatus>;
//       });
//     } catch (e) {
//       setState(() => _error = 'Failed to load form data: $e');
//     } finally {
//       setState(() => _isLoading = false);
//     }
//   }

//   Future<void> _onManufacturerChanged(AssetManufacturer? m) async {
//     setState(() {
//       _selectedManufacturer = m;
//       _selectedModel = null;
//       _models = [];
//     });
//     if (m == null) return;

//     try {
//       final models = await _service.getModels(manufacturerId: m.id);
//       setState(() => _models = models);
//     } catch (_) {}
//   }

//   // ── Form submission ────────────────────────────────────────────────────────

//   Future<void> _submit() async {
//     if (!_formKey.currentState!.validate()) return;
//     if (_selectedModel == null) {
//       ScaffoldMessenger.of(context).showSnackBar(
//         const SnackBar(content: Text('Please select a model')),
//       );
//       return;
//     }
//     if (_selectedStatus == null) {
//       ScaffoldMessenger.of(context).showSnackBar(
//         const SnackBar(content: Text('Please select a status')),
//       );
//       return;
//     }

//     setState(() => _isSubmitting = true);
//     try {
//       final created = await _service.createAsset(
//         modelId: _selectedModel!.id!,
//         statusId: _selectedStatus!.id!,
//         assetTag: widget.scannedTag,
//         serial: _serialController.text.trim().isNotEmpty
//             ? _serialController.text.trim()
//             : null,
//         name: _nameController.text.trim().isNotEmpty
//             ? _nameController.text.trim()
//             : null,
//         notes: _notesController.text.trim().isNotEmpty
//             ? _notesController.text.trim()
//             : null,
//       );

//       if (!mounted) return;

//       // Replace this screen with the new asset's detail screen.
//       Navigator.pushReplacement(
//         context,
//         MaterialPageRoute(
//           builder: (_) => AssetDetailsScreen(asset: created),
//         ),
//       );
//     } catch (e) {
//       setState(() => _error = 'Create failed: $e');
//     } finally {
//       if (mounted) setState(() => _isSubmitting = false);
//     }
//   }

//   // ── Build ──────────────────────────────────────────────────────────────────

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         title: const Text('Register New Asset'),
//         bottom: PreferredSize(
//           preferredSize: const Size.fromHeight(1),
//           child: Container(height: 1, color: Colors.white12),
//         ),
//       ),
//       body: _isLoading
//           ? const Center(child: CircularProgressIndicator())
//           : Stack(
//               children: [
//                 _buildForm(),
//                 if (_isSubmitting)
//                   const LoadingOverlay(message: 'Creating asset…'),
//               ],
//             ),
//     );
//   }

//   Widget _buildForm() {
//     return Form(
//       key: _formKey,
//       child: ListView(
//         children: [
//           // ── Scanned tag banner ───────────────────────────────────────────
//           Container(
//             margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
//             padding: const EdgeInsets.all(14),
//             decoration: BoxDecoration(
//               color: AppConstants.accentBlue.withOpacity(0.08),
//               borderRadius: BorderRadius.circular(10),
//               border: Border.all(
//                   color: AppConstants.accentBlue.withOpacity(0.25)),
//             ),
//             child: Row(
//               children: [
//                 const Icon(Icons.qr_code_2,
//                     color: AppConstants.accentBlue, size: 20),
//                 const SizedBox(width: 10),
//                 Column(
//                   crossAxisAlignment: CrossAxisAlignment.start,
//                   children: [
//                     const Text(
//                       'Scanned Tag',
//                       style: TextStyle(
//                           fontSize: 11,
//                           color: AppConstants.textSecondary,
//                           fontWeight: FontWeight.w600,
//                           letterSpacing: 0.8),
//                     ),
//                     Text(
//                       widget.scannedTag,
//                       style: const TextStyle(
//                         fontSize: 16,
//                         fontWeight: FontWeight.w700,
//                         color: AppConstants.accentBlue,
//                         letterSpacing: 0.5,
//                       ),
//                     ),
//                   ],
//                 ),
//                 const Spacer(),
//                 const Chip(
//                   label: Text('New'),
//                   backgroundColor: Color(0xFFE8F0FE),
//                   labelStyle: TextStyle(
//                     color: AppConstants.accentBlue,
//                     fontSize: 11,
//                     fontWeight: FontWeight.w600,
//                   ),
//                 ),
//               ],
//             ),
//           ),

//           if (_error != null) ErrorBanner(message: _error!),

//           const SectionHeader(title: 'Device Info'),

//           // Name / Asset Label
//           _FormField(
//             controller: _nameController,
//             label: 'Asset Name',
//             hint: 'e.g. Dell Latitude 5540 #3',
//             icon: Icons.computer_outlined,
//             validator: (v) =>
//                 (v == null || v.isEmpty) ? 'Name is required' : null,
//           ),

//           // Serial Number
//           _FormField(
//             controller: _serialController,
//             label: 'Serial Number',
//             hint: 'Device serial number',
//             icon: Icons.fingerprint,
//           ),

//           const SectionHeader(title: 'Manufacturer & Model'),

//           // Manufacturer dropdown
//           _DropdownField<AssetManufacturer>(
//             label: 'Manufacturer / Brand',
//             icon: Icons.business_outlined,
//             value: _selectedManufacturer,
//             items: _manufacturers,
//             itemLabel: (m) => m.name ?? '—',
//             onChanged: _onManufacturerChanged,
//           ),

//           // Model dropdown (populated after manufacturer selection)
//           _DropdownField<AssetModel2>(
//             label: 'Model',
//             icon: Icons.devices_outlined,
//             value: _selectedModel,
//             items: _models,
//             itemLabel: (m) => m.name ?? '—',
//             onChanged: (m) => setState(() => _selectedModel = m),
//             hint: _selectedManufacturer == null
//                 ? 'Select manufacturer first'
//                 : _models.isEmpty
//                     ? 'No models available'
//                     : 'Select model',
//             enabled: _selectedManufacturer != null && _models.isNotEmpty,
//           ),

//           const SectionHeader(title: 'Status'),

//           _DropdownField<AssetStatus>(
//             label: 'Initial Status',
//             icon: Icons.circle_outlined,
//             value: _selectedStatus,
//             items: _statuses,
//             itemLabel: (s) => s.name ?? '—',
//             onChanged: (s) => setState(() => _selectedStatus = s),
//           ),

//           const SectionHeader(title: 'Notes'),

//           Padding(
//             padding: const EdgeInsets.symmetric(horizontal: 16),
//             child: TextFormField(
//               controller: _notesController,
//               maxLines: 3,
//               decoration: const InputDecoration(
//                 labelText: 'Notes (optional)',
//                 alignLabelWithHint: true,
//                 prefixIcon: Padding(
//                   padding: EdgeInsets.only(bottom: 40),
//                   child: Icon(Icons.notes_outlined),
//                 ),
//               ),
//             ),
//           ),

//           const SizedBox(height: 24),

//           // Submit button
//           Padding(
//             padding: const EdgeInsets.symmetric(horizontal: 16),
//             child: ElevatedButton.icon(
//               onPressed: _isSubmitting ? null : _submit,
//               icon: const Icon(Icons.add_circle_outline, size: 20),
//               label: const Text('Create Asset'),
//               style: ElevatedButton.styleFrom(
//                 backgroundColor: AppConstants.accentGreen,
//                 minimumSize: const Size(double.infinity, 52),
//               ),
//             ),
//           ),

//           const SizedBox(height: 32),
//         ],
//       ),
//     );
//   }
// }

// // ── Reusable form field widget ─────────────────────────────────────────────

// class _FormField extends StatelessWidget {
//   final TextEditingController controller;
//   final String label;
//   final String? hint;
//   final IconData icon;
//   final String? Function(String?)? validator;

//   const _FormField({
//     required this.controller,
//     required this.label,
//     this.hint,
//     required this.icon,
//     this.validator,
//   });

//   @override
//   Widget build(BuildContext context) {
//     return Padding(
//       padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
//       child: TextFormField(
//         controller: controller,
//         decoration: InputDecoration(
//           labelText: label,
//           hintText: hint,
//           prefixIcon: Icon(icon),
//         ),
//         validator: validator,
//       ),
//     );
//   }
// }

// // ── Reusable dropdown widget ───────────────────────────────────────────────

// class _DropdownField<T> extends StatelessWidget {
//   final String label;
//   final IconData icon;
//   final T? value;
//   final List<T> items;
//   final String Function(T) itemLabel;
//   final ValueChanged<T?> onChanged;
//   final String? hint;
//   final bool enabled;

//   const _DropdownField({
//     required this.label,
//     required this.icon,
//     required this.value,
//     required this.items,
//     required this.itemLabel,
//     required this.onChanged,
//     this.hint,
//     this.enabled = true,
//   });

//   @override
//   Widget build(BuildContext context) {
//     return Padding(
//       padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
//       child: DropdownButtonFormField<T>(
//         initialValue: value,
//         isExpanded: true,
//         hint: Text(hint ?? 'Select ${label.toLowerCase()}'),
//         decoration: InputDecoration(
//           labelText: label,
//           prefixIcon: Icon(icon),
//         ),
//         items: enabled
//             ? items
//                 .map((item) => DropdownMenuItem<T>(
//                       value: item,
//                       child: Text(
//                         itemLabel(item),
//                         overflow: TextOverflow.ellipsis,
//                       ),
//                     ))
//                 .toList()
//             : [],
//         onChanged: enabled ? onChanged : null,
//       ),
//     );
//   }
// }
