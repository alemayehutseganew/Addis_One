import '../../../../core/models/reference.dart';
import '../../../../core/models/staff_session.dart';
import '../../../../core/models/trip.dart';
import '../../../../core/models/scan_outcome.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_failure.dart';
import '../../../../core/storage/token_storage.dart';

/// Server access for the staff app.
///
/// One class rather than per-feature gateways because the field surface is small
/// and every call shares the same session and failure handling. Splitting it
/// would add indirection without separating anything that can be reasoned about
/// independently.
class StaffRepository {
  StaffRepository({
    // ignore: prefer_initializing_formals
    required ApiClient api,
    // ignore: prefer_initializing_formals
    required TokenStorage tokens,
  })  :
        // ignore: prefer_initializing_formals
        _api = api,
        // ignore: prefer_initializing_formals
        _tokens = tokens;

  final ApiClient _api;
  final TokenStorage _tokens;

  // ── Sign-in ────────────────────────────────────────────────────────────────

  /// Requests a verification code for a staff phone number.
  ///
  /// The server answers 202 whether or not the number holds an account, which is
  /// what stops this endpoint enumerating staff. Nothing is returned to display
  /// and nothing is inferred here.
  Future<void> requestOtp(String phone) async {
    await _api.postJson('/auth/request-otp', body: {'phone': phone});
  }

  /// Completes OTP sign-in and persists the session.
  ///
  /// The server answers 200 with `ok: false` for a bad code rather than an error
  /// status, so the flag is checked explicitly — returning normally here would
  /// look like a successful sign-in with no token to show for it.
  Future<void> verifyOtp(String phone, String code) async {
    final data = await _api.postJson(
      '/auth/verify-otp',
      body: {'phone': phone, 'code': code},
    );
    if (data['ok'] != true || data['accessToken'] is! String) {
      throw const ApiException(
        ApiFailure.validation,
        message: 'That code was not accepted. Request a new one and try again.',
      );
    }
    await _persist(data, phone: phone);
  }

  /// Signs in without a verification code, for field testing only.
  ///
  /// Returns false when the server does not expose the route — which is the
  /// normal production answer, and is why the UI treats it as "not available"
  /// rather than as an error.
  Future<bool> devSignIn(String phone) async {
    try {
      final data = await _api.postJson('/auth/dev-login', body: {'phone': phone});
      if (data['ok'] != true || data['accessToken'] is! String) return false;
      await _persist(data, phone: phone);
      return true;
    } on ApiException catch (e) {
      // 404 is the documented "feature not armed" answer and is not worth
      // surfacing. Anything else is a genuine fault the officer should see.
      if (e.failure == ApiFailure.notFound) return false;
      rethrow;
    }
  }

  /// Whether the server currently offers the bypass route.
  ///
  /// Uses the side-effect-free capability endpoint rather than attempting a real
  /// sign-in: the POST route answers 404 both when it is unregistered and when a
  /// number is not staff, so it cannot answer this question.
  Future<bool> devSignInAvailable() async {
    try {
      final data = await _api.getJson('/auth/dev-login');
      return data['enabled'] == true;
    } on ApiException {
      return false;
    }
  }

  /// Whether the temporary fixed-credential test login is armed.
  ///
  /// Probes GET /auth/password-login, which 404s unless TEST_LOGIN_ENABLED
  /// is on. Fails closed: the screen simply does not show the form.
  Future<bool> passwordLoginAvailable() async {
    try {
      final data = await _api.getJson('/auth/password-login');
      return data['enabled'] == true;
    } on ApiException {
      return false;
    }
  }

  /// Signs in with the fixed test username + password (until SMS approved).
  ///
  /// Returns false when the server does not expose the route; throws a
  /// validation ApiException with a plain message on bad credentials so the
  /// controller can show it directly.
  Future<bool> passwordLogin(String username, String password) async {
    try {
      final data = await _api.postJson('/auth/password-login', body: {
        'username': username,
        'password': password,
      });
      if (data['ok'] != true || data['accessToken'] is! String) return false;
      await _persist(data, phone: (data['phone'] as String?) ?? '');
      return true;
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.notFound) return false;
      if (e.failure == ApiFailure.unauthorized) {
        throw const ApiException(
          ApiFailure.validation,
          message: 'Invalid username or password.',
        );
      }
      rethrow;
    }
  }

  Future<void> _persist(
    Map<String, dynamic> data, {
    required String phone,
  }) async {
    await _tokens.save(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String?,
      phone: phone,
    );
  }

  /// Revokes the session server-side, then clears it locally.
  ///
  /// Local state is cleared even if the network call fails: an officer signing
  /// out must end up signed out on this device either way, and a stranded
  /// signed-in shell on a shared handheld is the worse outcome.
  Future<void> signOut() async {
    try {
      await _api.postJson('/auth/logout');
    } on ApiException {
      // Deliberately swallowed — see above.
    }
    await _tokens.clearSession();
  }

  // ── Session ────────────────────────────────────────────────────────────────

  /// Who is signed in and what they may do.
  ///
  /// `/auth/staff-session`, not `/dashboard/session`. The dashboard route sits
  /// behind DASHBOARD_ROLES, which excludes every field role by design — an
  /// inspector must not read network revenue. Pointing the handheld at it meant
  /// every INSPECTOR, CONDUCTOR and TICKET_OFFICER got a 403 at sign-in and
  /// reached the scanner with an empty role. The dedicated route answers the
  /// same question for anyone who is staff, because naming yourself is not
  /// privileged.
  Future<StaffSession> session() async {
    final data = await _api.getJson('/auth/staff-session');
    return StaffSession.fromJson(data);
  }

  Future<String?> get savedPhone => _tokens.phone;

  // ── Validation ─────────────────────────────────────────────────────────────

  /// Submits a scanned ticket for validation.
  ///
  /// Always reaches the server as a decision. This app never decides locally
  /// whether a ticket is valid: a handheld that could answer for itself could be
  /// modified to wave anyone through, which is a revenue-integrity failure.
  Future<ScanResult> scan(String qrString) async {
    final data = await _api.postJson(
      '/validation/scan',
      body: {'qrString': qrString},
    );
    return ScanResult.fromJson(data);
  }

  /// This officer's own recent scans, newest first.
  Future<List<ScanHistoryEntry>> recentScans({int take = 50}) async {
    final data = await _api.getJson(
      '/validation/mine',
      query: {'take': take.toString()},
    );
    final raw = data['validations'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => ScanHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  // ── Trips ──────────────────────────────────────────────────────────────────
  //
  // Every method below returns the server's answer rather than interpreting it.
  // The server owns the operator boundary and the trip state machine; the app's
  // job is to show what came back and, where a rule genuinely is a presentation
  // concern (which button is live), to derive it from a state the server named —
  // never from a guess about what is legal.

  /// Trips assigned to this officer, for a day.
  ///
  /// Returns the route's own `trips` key rather than "the first list in the
  /// envelope". The heuristic was hiding exactly the problem worth catching: a
  /// renamed collection would have silently produced an empty screen instead of
  /// a visible mismatch.
  Future<List<Trip>> myTrips({DateTime? date}) async {
    final query = <String, String>{if (date != null) 'date': _isoDay(date)};
    final data =
        await _api.getJson('/driver/trips', query: query.isEmpty ? null : query);
    return _listOf(data, 'trips', Trip.fromJson);
  }

  /// The passenger manifest for one trip.
  Future<TripManifest> manifest(String tripId) async {
    return TripManifest.fromJson(
      await _api.getJson('/driver/trips/$tripId/manifest'),
    );
  }

  /// Starts a trip. Server-enforced: a trip assigned to someone else answers 403.
  Future<Map<String, dynamic>> startTrip(String tripId) =>
      _api.postJson('/driver/trips/$tripId/start');

  /// Completes a trip.
  Future<Map<String, dynamic>> completeTrip(String tripId) =>
      _api.postJson('/driver/trips/$tripId/complete');

  // ── Shifts and devices ─────────────────────────────────────────────────────

  /// The officer's most recent shift, or null when they have never had one.
  ///
  /// Note the route returns the shift object *itself*, not `{ shift: ... }`, and
  /// it returns the most recent shift whether or not it is still open. Reading it
  /// as a wrapper would report "no shift" to an officer whose drawer is full, and
  /// reading it without checking the status would offer to close a shift that
  /// closed yesterday. The caller must therefore test the status; see
  /// [isShiftOpen].
  Future<Map<String, dynamic>?> myShift() async {
    final data = await _api.getJson('/staff/shifts/mine');
    // An empty envelope is how "you have never opened a drawer" is reported,
    // which is a normal state rather than a fault.
    return data.isEmpty ? null : data;
  }

  /// Whether a shift still has a live drawer.
  ///
  /// The server keeps a shift on the books after it closes — a closed shift is
  /// the audit record, and a reconciling one is exactly the case a supervisor
  /// needs to see. So "my shift" answering with a row does not mean the drawer is
  /// open, and the close-out form must only be offered for [ShiftStatus.open].
  ///
  /// An unrecognised status is treated as *not* open. Offering "Declare and close"
  /// on a state this build does not understand would send a call the server
  /// refuses, and would read to the officer as a fault in the app rather than as
  /// a state their build is too old to describe.
  static bool isShiftOpen(Map<String, dynamic> shift) =>
      shift['status'] == 'OPEN';

  /// The status vocabulary, for display.
  static const shiftStatuses = [
    'OPEN',
    'CLOSED',
    'RECONCILING',
    'RECONCILED',
    'DISPUTED',
  ];

  /// Opens a drawer with [openingCashFils] in it.
  Future<Map<String, dynamic>> openShift({
    required int openingCashFils,
    String? vehicleId,
    String? tripId,
  }) =>
      _api.postJson('/staff/shifts', body: {
        'openingCashFils': openingCashFils,
        'vehicleId': ?vehicleId,
        'tripId': ?tripId,
      });

  /// Closes a shift by declaring the cash physically in the drawer.
  Future<Map<String, dynamic>> declareCash({
    required String shiftId,
    required int declaredCashFils,
  }) =>
      _api.postJson(
        '/staff/shifts/$shiftId/declare',
        body: {'declaredCashFils': declaredCashFils},
      );

  /// Records a cash sale against the calling officer's open shift.
  ///
  /// [idempotencyKey] must be generated once by the app and reused for every retry
  /// of the *same* sale. A dropped response and a second tap would otherwise
  /// charge the passenger twice — or, worse, issue two tickets for one fare and
  /// leave the revenue unreconcilable against the drawer.
  ///
  /// The price is a claim, not a price: the server re-derives the fare from the
  /// two stops and ignores [amountFils] if it disagrees. That is why this method
  /// takes stops rather than letting the officer name a fare.
  ///
  /// The passenger is a phone number and the journey is a pair of stops because
  /// those are the only two things a conductor can actually read off someone
  /// standing at the door. This used to take a passenger UUID and a journey UUID,
  /// which made the sale impossible to complete in the field.
  Future<Map<String, dynamic>> sell({
    required String passengerPhone,
    required String originStopId,
    required String destinationStopId,
    required int amountFils,
    required String idempotencyKey,
  }) =>
      _api.postJson('/staff/sales', body: {
        'passengerPhone': passengerPhone,
        'originStopId': originStopId,
        'destinationStopId': destinationStopId,
        'amountFils': amountFils,
        'idempotencyKey': idempotencyKey,
      });

  /// Cash variances across staff. Narrower than holding a drawer.
  Future<List<CashVariance>> variances() async =>
      _rows('/staff/shifts/variances', CashVariance.fromJson);

  /// Handhelds this officer may enrol.
  Future<List<StaffDevice>> devices() async =>
      _rows('/staff/devices', StaffDevice.fromJson);

  /// Stops the conductor can pick from on a handheld.
  ///
  /// The public `/stops` list, not [adminStops]: a CONDUCTOR has no admin
  /// authority, so the reference-data screen would 403 exactly the officer who
  /// most needs to choose a destination. The admin route adds `isActive` and the
  /// inactive rows, neither of which a sale needs.
  Future<List<Stop>> stops() => _rows('/stops', Stop.fromJson);

  /// Stops, for the reference-data screens.
  Future<List<Stop>> adminStops({bool includeInactive = false}) => _rows(
        '/admin/stops',
        Stop.fromJson,
        includeInactive: includeInactive,
      );

  /// Vehicles, for the reference-data screens.
  Future<List<Vehicle>> adminVehicles({bool includeInactive = false}) => _rows(
        '/admin/vehicles',
        Vehicle.fromJson,
        includeInactive: includeInactive,
      );

  /// Routes, for the reference-data screens.
  Future<List<Route>> adminRoutes({bool includeInactive = false}) => _rows(
        '/admin/routes',
        Route.fromJson,
        includeInactive: includeInactive,
      );

  /// Fare rules with their version history.
  Future<List<FareRule>> fareRules({String? ruleKey}) => _rows(
        '/admin/fare-rules',
        FareRule.fromJson,
        query: ruleKey == null ? null : {'ruleKey': ruleKey},
      );

  /// Staff roster, for the management screen.
  Future<List<StaffMember>> staffRoster({bool includeInactive = false}) =>
      _rows(
        '/admin/staff',
        StaffMember.fromJson,
        includeInactive: includeInactive,
      );

  /// Enrols a handheld against this officer's record.
  ///
  /// Takes a server-issued device id rather than anything read off the device, so
  /// enrolling cannot invent a device by supplying an arbitrary string.
  Future<Map<String, dynamic>> enrollDevice(String deviceId) =>
      _api.postJson('/staff/devices/$deviceId/enroll');

  // ── Complaints ─────────────────────────────────────────────────────────────

  /// The complaint queue, optionally filtered by status.
  Future<List<Complaint>> complaints({String? status}) async {
    final data = await _api.getJson(
      '/complaints',
      query: status == null ? null : {'status': status},
    );
    return _listOf(data, 'complaints', Complaint.fromJson);
  }

  /// Moves a complaint to a new status, optionally with a resolution note.
  Future<Map<String, dynamic>> advanceComplaint({
    required String reference,
    required String status,
    String? resolution,
  }) =>
      _api.patchJson('/complaints/$reference', body: {
        'status': status,
        'resolution': ?resolution,
      });

  // ── Reporting ──────────────────────────────────────────────────────────────

  /// Operational overview for a date range.
  Future<Map<String, dynamic>> overview({String? from, String? to}) =>
      _api.getJson('/dashboard/overview', query: _range(from, to));

  /// Operations report for a date range.
  Future<Map<String, dynamic>> operations({String? from, String? to}) =>
      _api.getJson('/dashboard/operations', query: _range(from, to));

  /// Network shape: routes, stops and operators.
  Future<Map<String, dynamic>> network() => _api.getJson('/dashboard/network');

  /// Revenue report. Finance roles only — others receive 403.
  Future<Map<String, dynamic>> revenue({
    String? from,
    String? to,
    int? page,
    int? pageSize,
    String? status,
  }) =>
      _api.getJson('/dashboard/revenue', query: {
        ..._range(from, to),
        'page': ?page?.toString(),
        'pageSize': ?pageSize?.toString(),
        'status': ?status,
      });

  /// Fare reporting. Finance roles only.
  Future<Map<String, dynamic>> fareReport() => _api.getJson('/dashboard/fares');

  /// Database internals. The narrowest reporting list in the system.
  Future<Map<String, dynamic>> databaseStats() =>
      _api.getJson('/dashboard/database');

  // ── Administration ─────────────────────────────────────────────────────────

  /// Activates or deactivates a stop.
  Future<Map<String, dynamic>> setStopActive({
    required String stopId,
    required bool isActive,
  }) =>
      _api.putJson('/admin/stops/$stopId/active', body: {'isActive': isActive});

  /// Drafts a new version of a fare rule.
  ///
  /// Drafting only. Activation is a separate call carrying a separate right,
  /// because the server separately refuses to let an author approve their own
  /// draft — a rule this client can neither enforce nor second-guess.
  Future<Map<String, dynamic>> reviseFareRule(Map<String, dynamic> input) =>
      _api.postJson('/admin/fare-rules', body: input);

  /// Signs a drafted fare rule off, making it live.
  Future<Map<String, dynamic>> activateFareRule(String ruleId) =>
      _api.postJson('/admin/fare-rules/$ruleId/activate');

  /// Changes a staff member's role or employment state.
  Future<Map<String, dynamic>> updateStaff({
    required String staffId,
    required Map<String, dynamic> input,
  }) =>
      _api.patchJson('/admin/staff/$staffId', body: input);

  // ── Helpers ────────────────────────────────────────────────────────────────

  static Map<String, String> _range(String? from, String? to) => {
        'from': ?from,
        'to': ?to,
      };

  /// A bare `YYYY-MM-DD`, which is what the reporting routes expect.
  ///
  /// Built by hand rather than with `toIso8601String()` because that would emit a
  /// full timestamp in the device's local zone, and `?date=2026-10-04T09:43:00`
  /// is a different query from the `?date=2026-10-04` the server parses.
  static String _isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Reads a bare-array collection and parses each row.
  ///
  /// Every `/admin/*` list route, `/staff/devices` and `/staff/shifts/variances`
  /// answer with a plain JSON array rather than an envelope, so they go through
  /// [ApiClient.getListJson]. Reading them with `getJson` was silently returning
  /// an empty map and an empty screen.
  Future<List<T>> _rows<T>(
    String path,
    T Function(Map<String, dynamic>) parse, {
    Map<String, String>? query,
    bool includeInactive = false,
  }) async {
    final merged = <String, String>{
      ...?query,
      if (includeInactive) 'includeInactive': 'true',
    };
    final raw = await _api.getListJson(
      path,
      query: merged.isEmpty ? null : merged,
    );
    return [
      for (final item in raw)
        if (item is Map) parse(Map<String, dynamic>.from(item)),
    ];
  }

  /// Reads the named collection out of an envelope.
  ///
  /// The key is explicit on purpose. The earlier version took whichever list
  /// came first, which meant a renamed collection produced an empty screen
  /// rather than an obvious mismatch — the screen looked like "you have no
  /// complaints" when the truth was "the server said something else".
  ///
  /// Non-map entries are skipped rather than throwing: one malformed row should
  /// cost one row, not the whole list an officer is trying to work through.
  static List<T> _listOf<T>(
    Map<String, dynamic> data,
    String key,
    T Function(Map<String, dynamic>) parse,
  ) {
    final raw = data[key];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) parse(Map<String, dynamic>.from(item)),
    ];
  }
}
