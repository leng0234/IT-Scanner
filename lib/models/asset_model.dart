/// Represents a hardware asset returned by the Snipe-IT API.
/// Maps the fields from GET /api/v1/hardware/{id} and /bytag/{tag}.
class AssetModel {
  final int? id;
  final String? assetTag;
  final String? serial;
  final String? name;
  final AssetManufacturer? manufacturer;
  final AssetModel2? model;
  final AssetStatus? statusLabel;
  final AssetUser? assignedTo;
  final String? notes;
  final String? purchaseDate;
  final String? warrantyExpires;
  final String? lastCheckout;
  final String? createdAt;
  final String? updatedAt;

  const AssetModel({
    this.id,
    this.assetTag,
    this.serial,
    this.name,
    this.manufacturer,
    this.model,
    this.statusLabel,
    this.assignedTo,
    this.notes,
    this.purchaseDate,
    this.warrantyExpires,
    this.lastCheckout,
    this.createdAt,
    this.updatedAt,
  });

  factory AssetModel.fromJson(Map<String, dynamic> json) {
    return AssetModel(
      id: _parseInt(json['id']),
      assetTag: json['asset_tag'] as String?,
      serial: json['serial'] as String?,
      name: json['name'] as String?,
      manufacturer: json['manufacturer'] != null
          ? AssetManufacturer.fromJson(
              json['manufacturer'] as Map<String, dynamic>)
          : null,
      model: json['model'] != null
          ? AssetModel2.fromJson(json['model'] as Map<String, dynamic>)
          : null,
      statusLabel: json['status_label'] != null
          ? AssetStatus.fromJson(
              json['status_label'] as Map<String, dynamic>)
          : null,
      assignedTo: json['assigned_to'] != null
          ? AssetUser.fromJson(json['assigned_to'] as Map<String, dynamic>)
          : null,
      notes: json['notes'] as String?,
      purchaseDate: _parseDate(json['purchase_date']),
      warrantyExpires: _parseDate(json['warranty_expires']),
      lastCheckout: _parseDate(json['last_checkout']),
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
    );
  }

  Map<String, dynamic> toUpdateJson() => {
        if (serial != null) 'serial': serial,
        if (name != null) 'name': name,
        if (notes != null) 'notes': notes,
      };
}

class AssetManufacturer {
  final int? id;
  final String? name;

  const AssetManufacturer({this.id, this.name});

  factory AssetManufacturer.fromJson(Map<String, dynamic> json) =>
      AssetManufacturer(
        id: _parseInt(json['id']),
        name: json['name'] as String?,
      );
}

class AssetModel2 {
  final int? id;
  final String? name;

  const AssetModel2({this.id, this.name});

  factory AssetModel2.fromJson(Map<String, dynamic> json) => AssetModel2(
        id: _parseInt(json['id']),
        name: json['name'] as String?,
      );
}

class AssetStatus {
  final int? id;
  final String? name;
  final String? statusType;

  const AssetStatus({this.id, this.name, this.statusType});

  factory AssetStatus.fromJson(Map<String, dynamic> json) => AssetStatus(
        id: _parseInt(json['id']),
        name: json['name'] as String?,
        statusType: json['status_type'] as String?,
      );
}

class AssetUser {
  final int? id;
  final String? name;
  final String? username;
  final String? email;
  final String? type;

  const AssetUser({this.id, this.name, this.username, this.email, this.type});

  factory AssetUser.fromJson(Map<String, dynamic> json) => AssetUser(
        id: _parseInt(json['id']),
        name: json['name'] as String?,
        username: json['username'] as String?,
        email: json['email'] as String?,
        type: json['type'] as String?,
      );
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// Snipe-IT บางเวอร์ชันส่ง id เป็น String แทน int
int? _parseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}

/// Snipe-IT ส่ง date เป็น {"datetime": "...", "formatted": "..."}
/// หรือบางครั้งเป็น String ตรงๆ
String? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is Map) {
    return value['formatted']?.toString() ?? value['datetime']?.toString();
  }
  return null;
}