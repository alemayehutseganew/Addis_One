/// Which half of the app a person is signed in as.
///
/// Chosen at launch, before either sign-in flow runs, and it decides three
/// things that must never be mixed:
///
///  1. Which secure-storage namespace the bearer token is read from.
///  2. Whether a 401 is refreshed silently or surfaced.
///  3. Which set of destinations the router will allow.
///
/// The last point is the reason this is a type rather than a bool: there is no
/// third state to accidentally treat as "passenger", and every exhaustive switch
/// over the app's top-level structure has to answer it.
enum AppRole {
  /// Plans journeys, buys tickets, presents a QR.
  passenger(
    label: 'Passenger',
    storagePrefix: 'passenger',
  ),

  /// Scans, works trips, opens shifts, runs the network.
  staff(
    label: 'Staff',
    storagePrefix: 'staff',
  );

  const AppRole({required this.label, required this.storagePrefix});

  /// Shown on the role picker, where a wrong guess sends someone into the wrong
  /// half of the app and looks like a broken sign-in rather than a wrong choice.
  final String label;

  /// Namespace for [TokenStorage] keys.
  ///
  /// A passenger session and a staff session are different credentials for the
  /// same server. Keeping them under distinct prefixes is what stops a passenger
  /// token being presented to a privileged route (or the reverse) if the wrong
  /// half's request is ever issued --?" the server would refuse it, but the attempt
  /// would be in the audit trail either way.
  final String storagePrefix;
}