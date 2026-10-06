import { StaffRole } from '@prisma/client';

/**
 * Every role list the API authorizes against, in one place.
 *
 * These were previously declared as private consts inside two different
 * controllers, and the dashboard then reached across module boundaries to import
 * `ADMIN_ROLES` from `AdminController` in order to compute a permission flag.
 * That coupling is what this file removes: a reporting screen importing from a
 * write-side controller to answer "can this person manage?" means the two
 * surfaces cannot be reasoned about, tested, or changed independently — deleting
 * a controller would silently break a permission.
 *
 * Policy now lives beside the guard that enforces it (`staff.guard.ts`), so both
 * halves of an authorization decision — who you are, and what you may do — can be
 * read in one file.
 *
 * The lists deliberately overlap in places. Overlap between author and approver
 * does not by itself grant self-approval, because the service layer separately
 * forbids a draft's own author from activating it; see `FARE_APPROVAL_ROLES`.
 */

/**
 * Roles that may change network reference data.
 *
 * Operators manage their own routes, vehicles and stops; the bureau manages the
 * whole city. No field role is here: a driver has no legitimate reason to edit a
 * fare or a roster.
 */
export const ADMIN_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.OPERATOR_ADMIN,
];

/**
 * Roles that may draft a fare change. Activation is narrower still — see
 * `FARE_APPROVAL_ROLES`.
 */
export const FARE_AUTHOR_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.FINANCE,
];

/**
 * Roles that may sign a fare off.
 *
 * Overlaps FARE_AUTHOR_ROLES by necessity — the same agency approves its own
 * fares — but the service additionally forbids the draft's own author from
 * approving it, so an overlap in the role lists cannot become self-approval.
 */
export const FARE_APPROVAL_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.FINANCE,
  StaffRole.AUDITOR,
];

/**
 * Roles allowed anywhere on the dashboard.
 *
 * A driver or conductor has no business reading network revenue, and the
 * ticket/finance panels are the sensitive ones. Field roles (driver, conductor,
 * inspector, agent, ticket officer) are excluded entirely rather than shown a
 * reduced view: a half-visible figure is still a leak, and a dashboard they can
 * never use is not a capability anyone was asking for.
 */
export const DASHBOARD_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.FINANCE,
  StaffRole.AUDITOR,
  StaffRole.OPERATOR_ADMIN,
  StaffRole.SUPERVISOR,
];

/**
 * Roles allowed to read money.
 *
 * Revenue and payment status are separated from operational counts. An operator
 * admin legitimately needs to see their own takings, but a supervisor needs
 * service volumes, not other people's margins.
 */
export const FINANCE_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.FINANCE,
  StaffRole.AUDITOR,
];

/**
 * Roles allowed to read database internals.
 *
 * Deliberately narrower than the rest of the dashboard. Table names, index names
 * and connection counts describe how the system is built rather than how it is
 * performing, and they are useful mainly to someone about to change it — which is
 * not every supervisor who needs the ticket counts. An auditor can see the
 * operational figures they are attesting to; only administration roles see the
 * plumbing behind them.
 */
export const DATABASE_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
];

/**
 * Roles allowed to record a ticket validation.
 *
 * Lives here rather than in the validation controller because the handheld needs
 * it too, not only the route that enforces it: the app is told whether to offer
 * a scanner at all, and a client-side copy of this list is a second thing to keep
 * correct. The server still enforces it on every request — see
 * `GET /auth/staff-session`, which reports the answer from this list so the app
 * never has to restate it.
 *
 * An INSPECTOR is the primary caller, but ticket officers, supervisors,
 * conductors and agents all stand at doors in practice.
 */
export const SCAN_ROLES: StaffRole[] = [
  StaffRole.INSPECTOR,
  StaffRole.TICKET_OFFICER,
  StaffRole.SUPERVISOR,
  StaffRole.AGENT,
  StaffRole.CONDUCTOR,
  StaffRole.OPERATOR_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.SUPER_ADMIN,
];

/**
 * Roles that work the complaint queue.
 *
 * Moved here from AssuranceController so the handheld can be told whether to offer
 * the screen. A capability the app cannot ask about is a capability an officer
 * discovers by pressing a button and reading a 403.
 */
export const ASSURANCE_ROLES: StaffRole[] = [
  StaffRole.SUPERVISOR,
  StaffRole.OPERATOR_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.SUPER_ADMIN,
  StaffRole.AUDITOR,
];

/**
 * Roles that run trips.
 *
 * Mounted under /driver rather than /mobility so the handheld's base URL reads as
 * the job being done. OPERATOR_ADMIN and SUPERVISOR are included because
 * dispatching on someone's behalf is a real task; the operator boundary in the
 * service still applies to them.
 */
export const DRIVER_ROLES: StaffRole[] = [
  StaffRole.DRIVER,
  StaffRole.CONDUCTOR,
  StaffRole.SUPERVISOR,
  StaffRole.OPERATOR_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.SUPER_ADMIN,
];

/** Roles that hold cash or handhelds and therefore use the shift surface. */
export const SHIFT_ROLES: StaffRole[] = [
  StaffRole.AGENT,
  StaffRole.TICKET_OFFICER,
  StaffRole.SUPERVISOR,
  StaffRole.CONDUCTOR,
  StaffRole.DRIVER,
  StaffRole.OPERATOR_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.SUPER_ADMIN,
];

/**
 * Supervisors and administration only: who is short, and by how much.
 *
 * Deliberately narrower than SHIFT_ROLES. Holding a drawer is not the same as
 * auditing other people's drawers, and cash shortfalls are supervisory business.
 */
export const RECONCILE_ROLES: StaffRole[] = [
  StaffRole.SUPERVISOR,
  StaffRole.OPERATOR_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.SUPER_ADMIN,
  StaffRole.FINANCE,
];

/**
 * Roles that may change someone's role or employment state.
 *
 * Narrower than ADMIN_ROLES on purpose: an operator admin managing their own
 * roster does not need to mint supervisors or terminate a bureau employee, so
 * this is restricted to the bureau.
 */
export const STAFF_MANAGEMENT_ROLES: StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
];

/**
 * Everything a staff member may do, answered from the role.
 *
 * The handheld is a single binary serving eleven roles, so it has to know which
 * surfaces to offer — but a copy of these lists in Dart is exactly the failure
 * this file exists to prevent (see the `canValidate` regression in the staff
 * app's `StaffSession`, where a client-side table disagreed with the server and
 * offered a scan the server would refuse). So the server declares the answer and
 * the app renders it.
 *
 * **This is presentation, not security.** Every route below re-checks the same
 * list through `@Roles`, so a tampered or stale client gains nothing. The value
 * here is that an officer is not offered a button that exists only to fail.
 */
export interface StaffCapabilities {
  /** Open the scanner, and read this officer's own scan history. */
  canScan: boolean;

  /** Run trips: see today's work, start and complete a trip. */
  canOperateTrips: boolean;

  /** Open and close a cash shift, sell on a passenger's behalf, enrol devices. */
  canManageShift: boolean;

  /** Read cash variances across staff. Strictly wider than holding a drawer. */
  canReconcile: boolean;

  /** Work the complaint queue. */
  canHandleComplaints: boolean;

  /** Read operational reporting (overview, operations, network, passengers). */
  canViewReports: boolean;

  /** Read revenue and fare reporting. */
  canViewFinance: boolean;

  /** Read database internals. Narrower than the rest of reporting. */
  canViewDatabase: boolean;

  /** Edit stops, vehicles and routes. */
  canManageNetwork: boolean;

  /** Draft a fare change. */
  canAuthorFares: boolean;

  /** Sign a fare change off. Wider than authoring. */
  canApproveFares: boolean;

  /** Change a staff member's role or employment state. */
  canManageStaff: boolean;

  /** See every operator's data rather than only their own. */
  cityWide: boolean;
}

const CITY_WIDE: readonly StaffRole[] = [
  StaffRole.SUPER_ADMIN,
  StaffRole.TRANSPORT_BUREAU_ADMIN,
  StaffRole.FINANCE,
  StaffRole.AUDITOR,
];

/**
 * Derives the full capability set for [role].
 *
 * Every field is answered with `.includes(role)` against the same list that
 * guards the corresponding route, which is the whole point: there is no second
 * table to drift. Adding a role to `SCAN_ROLES` changes both the route guard and
 * the answer here in the same commit.
 *
 * Note that `canAuthorFares` and `canApproveFares` are both true for the same
 * people. That is intentional and matches the backend's own reasoning — overlap
 * between author and approver does not permit self-approval, because the service
 * separately refuses to let a draft's own author activate it. The client is told
 * the truth about both rights and is not told to pretend otherwise.
 */
export function capabilitiesFor(role: StaffRole): StaffCapabilities {
  return {
    canScan: SCAN_ROLES.includes(role),
    canOperateTrips: DRIVER_ROLES.includes(role),
    canManageShift: SHIFT_ROLES.includes(role),
    canReconcile: RECONCILE_ROLES.includes(role),
    canHandleComplaints: ASSURANCE_ROLES.includes(role),
    canViewReports: DASHBOARD_ROLES.includes(role),
    canViewFinance: FINANCE_ROLES.includes(role),
    canViewDatabase: DATABASE_ROLES.includes(role),
    canManageNetwork: ADMIN_ROLES.includes(role),
    canAuthorFares: FARE_AUTHOR_ROLES.includes(role),
    canApproveFares: FARE_APPROVAL_ROLES.includes(role),
    canManageStaff: STAFF_MANAGEMENT_ROLES.includes(role),
    cityWide: CITY_WIDE.includes(role),
  };
}