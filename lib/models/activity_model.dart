/// Represents one entry in the Snipe-IT activity/history log.
/// Maps fields from GET /api/v1/reports/activity
class ActivityModel {
  final int? id;
  final String? action; // 'checkout', 'checkin from', 'update', 'create', etc.
  final String? createdAt;
  final ActivityActor? actor;
  final ActivityTarget? target;
  final String? note;

  const ActivityModel({
    this.id,
    this.action,
    this.createdAt,
    this.actor,
    this.target,
    this.note,
  });

  factory ActivityModel.fromJson(Map<String, dynamic> json) {
    return ActivityModel(
      id: json['id'] as int?,
      action: json['action_type'] as String?,
      createdAt: json['created_at']?['formatted'] as String?,
      actor: json['actor'] != null
          ? ActivityActor.fromJson(json['actor'] as Map<String, dynamic>)
          : null,
      target: json['target'] != null
          ? ActivityTarget.fromJson(json['target'] as Map<String, dynamic>)
          : null,
      note: json['note'] as String?,
    );
  }

  /// Human-readable action label for display in the history list.
  String get actionLabel {
    switch (action) {
      case 'checkout':
        return 'Checked Out';
      case 'checkin from':
        return 'Checked In';
      case 'update':
        return 'Updated';
      case 'create':
        return 'Created';
      case 'delete':
        return 'Deleted';
      case 'upload':
        return 'File Uploaded';
      default:
        return action ?? 'Action';
    }
  }
}

class ActivityActor {
  final int? id;
  final String? name;

  const ActivityActor({this.id, this.name});

  factory ActivityActor.fromJson(Map<String, dynamic> json) => ActivityActor(
        id: json['id'] as int?,
        name: json['name'] as String?,
      );
}

class ActivityTarget {
  final int? id;
  final String? name;
  final String? type;

  const ActivityTarget({this.id, this.name, this.type});

  factory ActivityTarget.fromJson(Map<String, dynamic> json) => ActivityTarget(
        id: json['id'] as int?,
        name: json['name'] as String?,
        type: json['type'] as String?,
      );
}
