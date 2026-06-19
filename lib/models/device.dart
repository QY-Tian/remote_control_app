import 'dart:convert';

enum DeviceRole {
  controller,   // 控制端 (iOS)
  controlled,   // 被控端 (Android)
}

enum DeviceStatus {
  offline,
  online,
  connecting,
  connected,
  error,
}

enum DeviceType {
  ios,
  android,
  unknown,
}

class Device {
  final String id;
  final String name;
  final DeviceRole role;
  DeviceStatus status;
  final DeviceType type;
  final String? ipAddress;
  DateTime? lastSeen;
  String? pairingCode;
  
  Device({
    required this.id,
    required this.name,
    required this.role,
    this.status = DeviceStatus.offline,
    required this.type,
    this.ipAddress,
    this.lastSeen,
    this.pairingCode,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role.name,
    'status': status.name,
    'type': type.name,
    'ipAddress': ipAddress,
    'lastSeen': lastSeen?.toIso8601String(),
    'pairingCode': pairingCode,
  };

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    id: json['id'],
    name: json['name'],
    role: DeviceRole.values.firstWhere(
      (e) => e.name == json['role'],
      orElse: () => DeviceRole.controlled,
    ),
    status: DeviceStatus.values.firstWhere(
      (e) => e.name == json['status'],
      orElse: () => DeviceStatus.offline,
    ),
    type: DeviceType.values.firstWhere(
      (e) => e.name == json['type'],
      orElse: () => DeviceType.unknown,
    ),
    ipAddress: json['ipAddress'],
    lastSeen: json['lastSeen'] != null 
      ? DateTime.parse(json['lastSeen']) 
      : null,
    pairingCode: json['pairingCode'],
  );

  String toJsonString() => jsonEncode(toJson());
  
  factory Device.fromJsonString(String jsonString) => 
    Device.fromJson(jsonDecode(jsonString));

  Device copyWith({
    String? id,
    String? name,
    DeviceRole? role,
    DeviceStatus? status,
    DeviceType? type,
    String? ipAddress,
    DateTime? lastSeen,
    String? pairingCode,
  }) => Device(
    id: id ?? this.id,
    name: name ?? this.name,
    role: role ?? this.role,
    status: status ?? this.status,
    type: type ?? this.type,
    ipAddress: ipAddress ?? this.ipAddress,
    lastSeen: lastSeen ?? this.lastSeen,
    pairingCode: pairingCode ?? this.pairingCode,
  );

  @override
  String toString() => 'Device(id: $id, name: $name, role: $role, status: $status)';
}
