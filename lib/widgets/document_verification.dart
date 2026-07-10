// import 'dart:convert';
// import 'dart:typed_data';

// import 'package:crypto/crypto.dart';

// /// Real SHA-256 based document verification, computed over the *entire*
// /// signature image (not just the first 32 bytes, which are mostly constant
// /// PNG header bytes and don't meaningfully distinguish signatures).
// ///
// /// The verification code is derived only from the asset tag, recipient
// /// name, date, action, and signature image hash — deliberately with no
// /// random nonce — so the exact same inputs always regenerate the exact same
// /// code and the document can be independently re-verified later, rather than
// /// only being checkable at generation time.
// class DocumentVerification {
//   DocumentVerification._();

//   static String sha256Hex(String input) {
//     return sha256.convert(utf8.encode(input)).toString();
//   }

//   static String sha256HexBytes(Uint8List bytes) {
//     return sha256.convert(bytes).toString();
//   }

//   static String generateVerificationCode({
//     required String assetTag,
//     required String assigneeName,
//     required String dateStr,
//     required String action,
//     required Uint8List sigBytes,
//   }) {
//     final sigFingerprint = sha256HexBytes(sigBytes);
//     final payload = '$assetTag|$assigneeName|$dateStr|$action|$sigFingerprint';
//     final hash = sha256Hex(payload);
//     // Take a readable slice of the full hash for display purposes; the
//     // full hash above is still cryptographically derived from all inputs,
//     // unlike a naive FNV-1a implementation which would be trivially
//     // collidable.
//     final code = hash.substring(0, 16).toUpperCase();
//     return '${code.substring(0, 4)}-${code.substring(4, 8)}-'
//         '${code.substring(8, 12)}-${code.substring(12, 16)}';
  
// }
