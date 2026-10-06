import 'package:equatable/equatable.dart';

/// What this officer may do, as declared by `GET /auth/staff-session`.
///
/// Every field is answered by the server from the same role list that guards the
/// corresponding route, so this class never has to carry a copy of the policy. It
/// is deliberately a dumb value object: it records what it was told and nothing
/// more. A missing key is read as `false`, which is the safe direction — an older
/// server that does not know about a capability withholds the surface rather than
/// offering something that would 403.
///
/// Not a security boundary. The server re-checks every one of these on every
/// request; a tampered local session or an edited capability set gains nothing but
/// a refusal.
class StaffCapabilities extends Equatable {
  const StaffCapabilities({
    this.canScan = false,
    this.canOperateTrips = false,
    this.canManageShift = false,
    this.canReconcile = false,
    this.canHandleComplaints = false,
    this.canViewReports = false,
    this.canViewFinance = false,
    this.canViewDatabase = false,
    this.canManageNetwork = false,
    this.canAuthorFares = false,
    this.canApproveFares = false,
    this.canManageStaff = false,
    this.cityWide = false,
  });

  factory StaffCapabilities.fromJson(Map<String, dynamic>? json) {
    // `?? false` rather than `?? true`: an undeclared capability means the server
    // is not offering it. The reverse default would mean an older server
    // silently unlocked every surface it had never heard of.
    if (json == null) return const StaffCapabilities();
    bool flag(String key) => json[key] == true;
    return StaffCapabilities(
      canScan: flag('canScan'),
      canOperateTrips: flag('canOperateTrips'),
      canManageShift: flag('canManageShift'),
      canReconcile: flag('canReconcile'),
      canHandleComplaints: flag('canHandleComplaints'),
      canViewReports: flag('canViewReports'),
      canViewFinance: flag('canViewFinance'),
      canViewDatabase: flag('canViewDatabase'),
      canManageNetwork: flag('canManageNetwork'),
      canAuthorFares: flag('canAuthorFares'),
      canApproveFares: flag('canApproveFares'),
      canManageStaff: flag('canManageStaff'),
      cityWide: flag('cityWide'),
    );
  }

  /// Open the scanner and read this officer's own scan history.
  final bool canScan;

  /// See today's trips, and start or complete one.
  final bool canOperateTrips;

  /// Open and close a cash shift, sell on a passenger's behalf, enrol a device.
  final bool canManageShift;

  /// Read cash variances across staff. Wider than holding a drawer.
  final bool canReconcile;

  /// Work the complaint queue.
  final bool canHandleComplaints;

  /// Read operational reporting.
  final bool canViewReports;

  /// Read revenue and fare reporting.
  final bool canViewFinance;

  /// Read database internals.
  final bool canViewDatabase;

  /// Edit stops, vehicles and routes.
  final bool canManageNetwork;

  /// Draft a fare change.
  final bool canAuthorFares;

  /// Sign a fare change off.
  final bool canApproveFares;

  /// Change a staff member's role or employment state.
  final bool canManageStaff;

  /// See every operator's data rather than only their own.
  final bool cityWide;

  /// Nothing at all.
  ///
  /// Reachable only when the server returned no capability block. Worth handling
  /// visibly rather than crashing on: it means the client is talking to something
  /// that is not a staff-session endpoint.
  bool get isEmpty =>
      !canScan &&
      !canOperateTrips &&
      !canManageShift &&
      !canReconcile &&
      !canHandleComplaints &&
      !canViewReports &&
      !canViewFinance &&
      !canViewDatabase &&
      !canManageNetwork &&
      !canAuthorFares &&
      !canApproveFares &&
      !canManageStaff;

  @override
  List<Object?> get props => [
        canScan,
        canOperateTrips,
        canManageShift,
        canReconcile,
        canHandleComplaints,
        canViewReports,
        canViewFinance,
        canViewDatabase,
        canManageNetwork,
        canAuthorFares,
        canApproveFares,
        canManageStaff,
        cityWide,
      ];
}

/// The signed-in officer, as returned by `GET /auth/staff-session`.
///
/// Read once after sign-in so the UI can name the person holding the handheld
/// and can hide controls the server would refuse. Presentation only — every
/// permission is still enforced server-side, so a tampered local session grants
/// nothing.
class StaffSession extends Equatable {
  const StaffSession({
    required this.displayName,
    required this.role,
    this.employeeCode,
    this.operatorId,
    required this.canValidate,
    required this.canManage,
    this.capabilities = const StaffCapabilities(),
  });

  factory StaffSession.fromJson(Map<String, dynamic> json) {
    final staff = json['staff'];
    final perms = json['permissions'];
    final s = staff is Map ? staff : const <String, dynamic>{};
    final p = perms is Map ? perms : const <String, dynamic>{};

    // canValidate comes from the server, which answers it from the same SCAN_ROLES
    // list that guards the scan route. This used to be recomputed here from a
    // duplicated role table, which is exactly the kind of copy that goes stale:
    // the two answers could disagree, and a handheld would then offer a scan the
    // server refuses. Falling back to the local list only when the field is
    // absent, so an older server still yields a usable answer.
    final canValidate =
        p['canValidate'] as bool? ?? _rolesWithScanRights.contains(
              (s['role'] as String?) ?? '',
            );

    // The newer `capabilities` block supersedes `permissions`. Read it when
    // present; otherwise derive the one legacy field from `permissions` so an
    // older server still opens the scanner rather than silently locking the
    // officer out of the only surface they had.
    final rawCaps = json['capabilities'];
    final capabilities = rawCaps is Map
        ? StaffCapabilities.fromJson(Map<String, dynamic>.from(rawCaps))
        : StaffCapabilities(canScan: canValidate);

    return StaffSession(
      displayName: (s['display'] ?? s['displayName']) as String? ?? 'Officer',
      role: (s['role'] as String?) ?? '',
      employeeCode: s['employeeCode'] as String?,
      operatorId: s['operatorId'] as String?,
      canValidate: canValidate,
      canManage: p['canManage'] as bool? ?? false,
      capabilities: capabilities,
    );
  }

  /// Fallback only — see [StaffSession.fromJson].
  static const _rolesWithScanRights = <String>{
    'INSPECTOR',
    'TICKET_OFFICER',
    'SUPERVISOR',
    'AGENT',
    'CONDUCTOR',
    'OPERATOR_ADMIN',
    'TRANSPORT_BUREAU_ADMIN',
    'SUPER_ADMIN',
  };

  final String displayName;
  final String role;
  final String? employeeCode;
  final String? operatorId;
  final bool canValidate;
  final bool canManage;

  /// The server's answer to "what may this officer do".
  ///
  /// Preferred over [canValidate]/[canManage] by anything new; those two survive
  /// only so an older build of the app keeps working against this server.
  final StaffCapabilities capabilities;

  /// True when the officer belongs to one operator rather than the city, which
  /// is worth showing so they understand why some records are out of scope.
  bool get isOperatorScoped => operatorId != null;

  @override
  List<Object?> get props => [
        displayName,
        role,
        employeeCode,
        operatorId,
        canValidate,
        canManage,
        capabilities,
      ];
}
