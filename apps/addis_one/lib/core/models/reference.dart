import 'package:equatable/equatable.dart';

/// Shared parsing helpers for the reference and administration records.
///
/// Collected here because every one of these models is defensive in the same way:
/// a field the server did not send reads as an absent optional rather than
/// throwing, because one renamed column must not blank out a whole screen an
/// administrator is in the middle of using.
abstract final class Json {
  /// A string, or `''` when absent. Never the text `"null"`.
  static String str(dynamic v) => v == null ? '' : '$v';

  /// An optional string, where an empty value means "not set".
  static String? optStr(dynamic v) {
    final s = '$v'.trim();
    return s.isEmpty || s == 'null' ? null : s;
  }

  static int? intOrNull(dynamic v) => (v as num?)?.toInt();

  static double? dblOrNull(dynamic v) => (v as num?)?.toDouble();

  static bool? boolOrNull(dynamic v) => v == null ? null : v == true;

  static DateTime? dateOrNull(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }

  /// Birr, from a fils figure.
  ///
  /// Null when the server sent nothing, which is different from zero: "this rule
  /// has no per-kilometre component" and "this rule charges zero per kilometre"
  /// are not the same claim, and rendering both as `ETB 0.00` would assert the
  /// second.
  static String? birr(Object? fils) {
    if (fils is! num) return null;
    return (fils / 100).toStringAsFixed(2);
  }
}

/// A stop on the network.
class Stop extends Equatable {
  const Stop({
    required this.id,
    required this.code,
    required this.name,
    this.nameAm,
    this.zone,
    this.latitude,
    this.longitude,
    this.hasShelter = false,
    this.isActive = true,
  });

  factory Stop.fromJson(Map<String, dynamic> json) => Stop(
        id: Json.str(json['id']),
        code: Json.str(json['code']),
        name: Json.str(json['name']),
        nameAm: Json.optStr(json['nameAm']),
        zone: Json.optStr(json['zone']),
        latitude: Json.dblOrNull(json['latitude']),
        longitude: Json.dblOrNull(json['longitude']),
        hasShelter: Json.boolOrNull(json['hasShelter']) ?? false,
        // Absent means active: these lists only include withdrawn records when
        // explicitly asked, so treating absent as inactive would show every
        // working stop as withdrawn.
        isActive: Json.boolOrNull(json['isActive']) ?? true,
      );

  final String id;
  final String code;
  final String name;
  final String? nameAm;

  /// `Z1` … `Z4`, or null for a stop outside the fare zones.
  final String? zone;
  final double? latitude;
  final double? longitude;
  final bool hasShelter;
  final bool isActive;

  @override
  List<Object?> get props =>
      [id, code, name, nameAm, zone, latitude, longitude, hasShelter, isActive];
}

/// A route.
class Route extends Equatable {
  const Route({
    required this.id,
    required this.code,
    required this.name,
    this.nameAm,
    this.mode = '',
    this.distanceMeters,
    this.isActive = true,
  });

  factory Route.fromJson(Map<String, dynamic> json) => Route(
        id: Json.str(json['id']),
        code: Json.str(json['code']),
        name: Json.str(json['name']),
        nameAm: Json.optStr(json['nameAm']),
        mode: Json.str(json['mode']),
        distanceMeters: Json.intOrNull(json['distanceMeters']),
        isActive: Json.boolOrNull(json['isActive']) ?? true,
      );

  final String id;
  final String code;
  final String name;
  final String? nameAm;
  final String mode;
  final int? distanceMeters;
  final bool isActive;

  /// `4.2 km`, or null when the server sent no distance.
  String? get distanceLabel {
    final m = distanceMeters;
    if (m == null) return null;
    return m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '$m m';
  }

  @override
  List<Object?> get props =>
      [id, code, name, nameAm, mode, distanceMeters, isActive];
}

/// A vehicle.
class Vehicle extends Equatable {
  const Vehicle({
    required this.id,
    required this.plateNumber,
    this.mode = '',
    this.make,
    this.model,
    this.capacity,
    this.status = '',
    this.isActive = true,
  });

  factory Vehicle.fromJson(Map<String, dynamic> json) => Vehicle(
        id: Json.str(json['id']),
        plateNumber: Json.str(json['plateNumber']),
        mode: Json.str(json['mode']),
        make: Json.optStr(json['make']),
        model: Json.optStr(json['model']),
        capacity: Json.intOrNull(json['capacity']),
        status: Json.str(json['status']),
        isActive: Json.boolOrNull(json['isActive']) ?? true,
      );

  final String id;

  /// The plate is what an officer recognises a bus by, so it leads the label.
  final String plateNumber;
  final String mode;
  final String? make;
  final String? model;
  final int? capacity;
  final String status;
  final bool isActive;

  /// `AB-123-C · Volvo B7R`, omitting whatever is missing.
  String get label {
    final parts = [
      plateNumber,
      if (make != null && model != null) '$make $model',
      if (mode.isNotEmpty) mode,
    ];
    return parts.isEmpty ? 'Vehicle' : parts.join(' · ');
  }

  @override
  List<Object?> get props =>
      [id, plateNumber, mode, make, model, capacity, status, isActive];
}
/// One version of a fare rule.
///
/// Never edited in place — the server writes a new version and supersedes the old
/// one, because an issued ticket must keep pointing at the exact numbers it was
/// priced with.
class FareRule extends Equatable {
  const FareRule({
    required this.id,
    required this.ruleKey,
    this.version,
    this.mode = '',
    this.baseFareFils,
    this.perKmFils,
    this.minimumFareFils,
    this.originZone,
    this.destinationZone,
    this.status = '',
    this.effectiveFrom,
    this.effectiveUntil,
    this.changeReason,
  });

  factory FareRule.fromJson(Map<String, dynamic> json) => FareRule(
        id: Json.str(json['id']),
        ruleKey: Json.str(json['ruleKey']),
        version: Json.intOrNull(json['version']),
        mode: Json.str(json['mode']),
        baseFareFils: Json.intOrNull(json['baseFareFils']),
        perKmFils: Json.intOrNull(json['perKmFils']),
        minimumFareFils: Json.intOrNull(json['minimumFareFils']),
        originZone: Json.optStr(json['originZone']),
        destinationZone: Json.optStr(json['destinationZone']),
        status: Json.str(json['status']),
        effectiveFrom: Json.dateOrNull(json['effectiveFrom']),
        effectiveUntil: Json.dateOrNull(json['effectiveUntil']),
        changeReason: Json.optStr(json['changeReason']),
      );

  final String id;
  final String ruleKey;
  final int? version;
  final String mode;
  final int? baseFareFils;
  final int? perKmFils;
  final int? minimumFareFils;
  final String? originZone;
  final String? destinationZone;

  /// `ACTIVE`, `DRAFT`, `SUPERSEDED`, …
  final String status;
  final DateTime? effectiveFrom;
  final DateTime? effectiveUntil;
  final String? changeReason;

  /// Whether this version is the one in force.
  ///
  /// Read from the status the server sent, never inferred from the version
  /// number: after a rollback the highest version is not the live one, and
  /// activating the wrong version is a revenue event.
  bool get isLive => status == 'ACTIVE';

  /// Whether this is awaiting sign-off.
  bool get isDraft => status == 'DRAFT' || status == 'PENDING';

  /// `Z1 → Z2`, or null when the rule is not zone-specific.
  String? get zonesLabel {
    if (originZone == null && destinationZone == null) return null;
    return '${originZone ?? 'any'} → ${destinationZone ?? 'any'}';
  }

  @override
  List<Object?> get props => [
        id,
        ruleKey,
        version,
        mode,
        baseFareFils,
        perKmFils,
        minimumFareFils,
        originZone,
        destinationZone,
        status,
        effectiveFrom,
        effectiveUntil,
        changeReason,
      ];
}
/// A staff member, as the roster screen sees them.
class StaffMember extends Equatable {
  const StaffMember({
    required this.id,
    required this.role,
    this.displayName = '',
    this.employeeCode,
    this.operatorId,
    this.isActive = true,
    this.terminatedAt,
  });

  factory StaffMember.fromJson(Map<String, dynamic> json) => StaffMember(
        id: Json.str(json['id']),
        role: Json.str(json['role']),
        // The roster names people differently from `/auth/staff-session`, so both
        // spellings are accepted and a rename on one side cannot blank the list.
        displayName:
            Json.optStr(json['displayName']) ?? Json.optStr(json['name']) ?? '',
        employeeCode: Json.optStr(json['employeeCode']),
        operatorId: Json.optStr(json['operatorId']),
        isActive: Json.boolOrNull(json['isActive']) ?? true,
        terminatedAt: Json.dateOrNull(json['terminatedAt']),
      );

  final String id;
  final String role;
  final String displayName;
  final String? employeeCode;
  final String? operatorId;
  final bool isActive;
  final DateTime? terminatedAt;

  bool get isTerminated => terminatedAt != null;

  bool get isWorking => isActive && !isTerminated;

  /// The name to show, falling back through identifiers an administrator would
  /// still recognise.
  String get label => displayName.isNotEmpty
      ? displayName
      : (employeeCode ?? (id.isEmpty ? '(unnamed)' : id));

  @override
  List<Object?> get props =>
      [id, role, displayName, employeeCode, operatorId, isActive, terminatedAt];
}

/// A passenger complaint, as the staff queue sees it.
///
/// The status vocabulary is not restated as an enum here on purpose: the set of
/// legal moves from each status is a server rule, and a client copy of it drifts.
/// The screen offers the whole vocabulary and lets the server refuse what is not
/// permitted, which is also the only place the reason for a refusal exists.
class Complaint extends Equatable {
  const Complaint({
    required this.reference,
    required this.status,
    this.category = '',
    this.description = '',
    this.complainantName = '',
    this.openedAt,
    this.closedAt,
    this.resolution,
  });

  factory Complaint.fromJson(Map<String, dynamic> json) => Complaint(
        reference: Json.str(json['reference']),
        status: Json.str(json['status']),
        category: Json.str(json['category']),
        description: Json.str(json['description']),
        complainantName: Json.str(json['complainantName']),
        openedAt: Json.dateOrNull(json['openedAt']),
        closedAt: Json.dateOrNull(json['closedAt']),
        resolution: Json.optStr(json['resolution']),
      );

  final String reference;
  final String status;
  final String category;
  final String description;
  final String complainantName;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final String? resolution;

  bool get isOpen => status == 'OPEN' || status == 'IN_PROGRESS';

  /// Whether this complaint is settled one way or the other.
  bool get isSettled => status == 'RESOLVED' || status == 'REJECTED';

  @override
  List<Object?> get props => [
        reference,
        status,
        category,
        description,
        complainantName,
        openedAt,
        closedAt,
        resolution,
      ];
}
/// A handheld enrolled against an officer.
class StaffDevice extends Equatable {
  const StaffDevice({
    required this.id,
    required this.deviceId,
    this.deviceCode = '',
    this.platform = '',
    this.appVersion,
    this.isEnrolled = false,
  });

  factory StaffDevice.fromJson(Map<String, dynamic> json) => StaffDevice(
        id: Json.str(json['id']),
        deviceId: Json.str(json['deviceId']),
        deviceCode: Json.str(json['deviceCode']),
        platform: Json.str(json['platform']),
        appVersion: Json.optStr(json['appVersion']),
        // The server sends `isEnrolled`, not an `enrolledAt` timestamp. Reading
        // the wrong key would leave every device looking unenrolled and offer to
        // enrol one that is already enrolled.
        isEnrolled: Json.boolOrNull(json['isEnrolled']) ?? false,
      );

  final String id;
  final String deviceId;
  final String deviceCode;
  final String platform;
  final String? appVersion;
  final bool isEnrolled;

  @override
  List<Object?> get props =>
      [id, deviceId, deviceCode, platform, appVersion, isEnrolled];
}

/// A closed shift that did not balance, awaiting a supervisor.
class CashVariance extends Equatable {
  const CashVariance({
    required this.id,
    required this.reference,
    required this.status,
    this.staffDisplayName = '',
    this.openingCashFils,
    this.expectedCashFils,
    this.declaredCashFils,
    this.varianceFils,
    this.openedAt,
  });

  factory CashVariance.fromJson(Map<String, dynamic> json) => CashVariance(
        id: Json.str(json['id']),
        reference: Json.str(json['reference']),
        status: Json.str(json['status']),
        staffDisplayName: Json.str(json['staffDisplayName']),
        openingCashFils: Json.intOrNull(json['openingCashFils']),
        expectedCashFils: Json.intOrNull(json['expectedCashFils']),
        declaredCashFils: Json.intOrNull(json['declaredCashFils']),
        varianceFils: Json.intOrNull(json['varianceFils']),
        openedAt: Json.dateOrNull(json['openedAt']),
      );

  final String id;
  final String reference;
  final String status;
  final String staffDisplayName;
  final int? openingCashFils;
  final int? expectedCashFils;
  final int? declaredCashFils;
  final int? varianceFils;
  final DateTime? openedAt;

  bool get isBalanced => varianceFils == 0;

  bool get isShort => (varianceFils ?? 0) < 0;

  @override
  List<Object?> get props => [
        id,
        reference,
        status,
        staffDisplayName,
        openingCashFils,
        expectedCashFils,
        declaredCashFils,
        varianceFils,
        openedAt,
      ];
}