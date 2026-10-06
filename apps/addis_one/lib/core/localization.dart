import 'package:flutter/widgets.dart';

import '../app/theme.dart';

/// Amharic and English strings, with Amharic as the default.
///
/// Transport vocabulary here is regulatory — "ticket", "fare", "validate" have
/// specific legal meanings in this system. Translations are therefore
/// centralised rather than inlined in widgets, so terminology can be reviewed
/// in one place and a correction propagates everywhere.
///
/// Amharic is the default because it is the working language of the conductors
/// and ticket officers who issue assisted (cash) tickets.
class AppStrings {
  const AppStrings(this.locale);

  final AppLocale locale;

  bool get isAmharic => locale == AppLocale.am;

  static const AppStrings am = AppStrings(AppLocale.am);
  static const AppStrings en = AppStrings(AppLocale.en);

  // ── Common ────────────────────────────────────────────────────────────────
  String get appName => isAmharic ? 'አዲስ አንዝ' : 'Addis One';
  String get cancel => isAmharic ? 'ሰርዝ' : 'Cancel';
  String get confirm => isAmharic ? 'አረጋግጥ' : 'Confirm';
  String get continueLabel => isAmharic ? 'ቀጥል' : 'Continue';
  String get retry => isAmharic ? 'እንደገና ሞክር' : 'Retry';
  String get loading => isAmharic ? 'በመጫን ላይ...' : 'Loading...';
  String get error => isAmharic ? 'ስህተት' : 'Error';
  String get offline => isAmharic ? 'ከመስመር ውጭ' : 'Offline';
  String get notAvailable => isAmharic ? 'አይገኝም' : 'Not available';

  // ── Language ──────────────────────────────────────────────────────────────
  String get chooseLanguage => isAmharic ? 'ቋንቋ ይምረጡ' : 'Choose your language';
  String get languageSubtitle =>
      isAmharic ? 'የአፕሊኬሽኑን ቋንቋ ይምረጡ' : 'Select the language for the app';

  // ── Authentication ────────────────────────────────────────────────────────
  String get signIn => isAmharic ? 'ግባ' : 'Sign in';
  String get phoneNumber => isAmharic ? 'ስልክ ቁጥር' : 'Phone number';
  String get phoneHint => isAmharic ? '0911 234 567' : '0911 234 567';
  String get enterOtp => isAmharic ? 'የማረጋገጫ ኮድ ያስገቡ' : 'Enter verification code';
  String get otpSentTo => isAmharic ? 'ኮድ ወደ' : 'We sent a code to';
  String get verifyAndContinue => isAmharic ? 'አረጋግጥና ቀጥል' : 'Verify and continue';
  String get resendCode => isAmharic ? 'ኮድ እንደገና ላክ' : 'Resend code';
  String get invalidOtp => isAmharic ? 'ትክክል ያልሆነ ኮድ' : 'Incorrect code';
  String get invalidPhone => isAmharic ? 'ትክክል ያልሆነ ስልክ ቁጥር' : 'Invalid phone number';

  // ── Home ──────────────────────────────────────────────────────────────────
  String get home => isAmharic ? 'መነሻ' : 'Home';
  String get whereTo => isAmharic ? 'የት ልሂድ?' : 'Where do you want to go?';
  String get currentLocation => isAmharic ? 'የአሁኑ አካባቢ' : 'Current location';

  /// Shown while a GPS fix is being acquired, so the field does not look dead.
  String get locatingYou =>
      isAmharic ? 'ቦታዎን በመፈለግ ላይ...' : 'Finding you...';

  /// Shows the resolved stop and how far away it is, so the passenger can tell
  /// the app snapped to the stop they are standing at.
  String get nearestStop => isAmharic ? 'ቅርበ' : 'Nearest stop';

  String get locationOff =>
      isAmharic ? 'የአካባቢ አገልጋጭው ጠፍቷል' : 'Location is switched off';
  String get locationPermissionDenied =>
      isAmharic ? 'የአካባቢ ፈቃድ አልተሰጠም' : 'Location permission denied';
  String get locationPermissionForever => isAmharic
      ? 'የአካባቢ ፈቃድ በቋሚ ፋር ተከልክሏል'
      : 'Location permission blocked in settings';
  String get locationNoFix =>
      isAmharic ? 'ቦታህን ማወቅ አልቻልንም' : 'Could not get a fix on your position';
  String get locationTooInaccurate => isAmharic
      ? 'የአካባቢዎ መረጃው በበቂ አይተለያመም'
      : 'Your position is not accurate enough';
  String get locationNoStopsNearby => isAmharic
      ? 'በአካባቢዎ ያለ ቁምር አልተገኘም'
      : 'No stops found near you';
  String get locationOutsideServiceArea => isAmharic
      ? 'ከአዲስ አበባ ውጪ ነዋሽ'
      : 'You appear to be outside Addis Ababa';
  String get locationLookupFailed => isAmharic
      ? 'አገልጋጭውን ማስተሳወር አልቻልንም'
      : 'Could not reach the server';
  String get tryAgain => isAmharic ? 'እንደገና ሞክር' : 'Try again';
  String get openSettings => isAmharic ? 'ቅንብሮች ክፈት' : 'Open settings';
  String get searchDestination => isAmharic ? 'መዳረሻ ፈልግ' : 'Search destination';
  String get planJourney => isAmharic ? 'ጉዞ እቅድ' : 'Plan journey';

  // ── Modes ─────────────────────────────────────────────────────────────────
  String get bus => isAmharic ? 'አውቶብስ' : 'Bus';
  String get taxi => isAmharic ? 'ታክሲ' : 'Taxi';
  String get train => isAmharic ? 'ባሕር' : 'Train';
  String get tickets => isAmharic ? 'ትክኬቶች' : 'Tickets';
  String get trips => isAmharic ? 'ጉዞዎች' : 'Trips';
  String get profile => isAmharic ? 'መገለጫ' : 'Profile';
  String get more => isAmharic ? 'ተጨማሪ' : 'More';

  // ── Journey ───────────────────────────────────────────────────────────────
  String get from => isAmharic ? 'ከ' : 'From';
  String get to => isAmharic ? 'ወደ' : 'To';
  String get results => isAmharic ? 'ውጤቶች' : 'Results';
  String get noRoutes => isAmharic ? 'መስመር አልተገኘም' : 'No routes found';
  String get walkLeg => isAmharic ? 'በእግር' : 'Walk';
  String get transfers => isAmharic ? 'ማለያ' : 'transfers';
  String get minutes => isAmharic ? 'ደቂቃ' : 'min';

  // ── Fares and tickets ─────────────────────────────────────────────────────
  String get fare => isAmharic ? 'ተመን' : 'Fare';

  // ── Group booking ──────────────────────────────────────────────────────────
  // One payment buys several tickets. There are deliberately NO name fields
  // anywhere in this flow — the QR is the ticket, and nothing on it or in a
  // forwarded copy identifies who is travelling.
  String get numberOfTickets => isAmharic ? 'የትክኬት ብዛት' : 'Number of tickets';
  String get passengers => isAmharic ? 'ተሳፋሪዎች' : 'passengers';
  String get ticketEach => isAmharic ? 'በእያንዳንዱ ትክኬት' : 'per ticket';
  String get total => isAmharic ? 'ጠቅላላ' : 'Total';
  String get payForTickets => isAmharic ? 'ክፈል' : 'Pay';
  String get ticketsIssued => isAmharic ? 'ትክኬቶች' : 'Tickets';

  /// Shown when fewer tickets were issued than were paid for. A passenger who
  /// paid for four and received three has a dispute, and must hear about it here
  /// rather than discovering it at the validator.
  String get shortIssued => isAmharic
      ? 'የተከፈሉት ትክኬት ከተከፈሉቱ ያነሰ ናቸው'
      : 'Fewer tickets were issued than were paid for';
  String get shortIssuedDetail => isAmharic
      ? 'እስከአሁን የተሰጡትን ትክኬቶች ይጠቀሙ። ለተጎዳው መጠን የድጎ ምልክት ያስቀምጡ'
      : 'Use the tickets you have. Ask the operator for a refund on the balance';

  String get groupShareHint => isAmharic
      ? 'እያንዳንዱ ትክኬት በቀጥታ ይሠራል። እያንዳንዱን ለስለዚህ ሰው በቀጥታ ይላኩ።'
      : 'Each ticket works on its own. Send each one to the person using it.';

  /// Confirms that no identity is attached to any ticket in the batch.
  String get noNamesNeeded => isAmharic
      ? 'ስም አያስፈልግም — እያንዳንዱ ትክኬት QR ኮድ ብቻ ነው'
      : 'No names needed — each ticket is just a QR code';
  String get totalFare => isAmharic ? 'ጠቅላላ ተመን' : 'Total fare';
  String get pay => isAmharic ? 'ክፈያ' : 'Pay';
  String get payWith => isAmharic ? 'በ' : 'Pay with';
  String get myTickets => isAmharic ? 'ትክኬቶችቴ' : 'My tickets';
  String get activeTickets => isAmharic ? 'ንቁ ትክኬቶች' : 'Active';
  String get ticketHistory => isAmharic ? 'ታሪክ' : 'History';
  String get showQr => isAmharic ? 'QR አሳያ' : 'Show QR';
  String get ticketValid => isAmharic ? 'ትክክል ነው' : 'Valid';
  String get ticketExpired => isAmharic ? 'ጊዜት አልፏል' : 'Expired';
  String get noTicketsYet =>
      isAmharic ? 'እስካሁን ትክኬት የለም' : 'No tickets yet';
  String get noTripsYet =>
      isAmharic ? 'እስካሁን ጉዞ የለም' : 'No trips yet';
  String get signInToSeeTrips => isAmharic
      ? 'ጉዞዎችዎን ለማየት ይግቡ'
      : 'Sign in to see your trips';
  String get signOut => isAmharic ? 'ውጣ' : 'Sign out';
  String get myAccount => isAmharic ? 'መለያዬ' : 'My account';
  String get notSignedIn => isAmharic ? 'ግብይት አልገቡም' : 'Not signed in';
  String get signedInAs => isAmharic ? 'እንደ ' : 'Signed in as ';
  String get settings => isAmharic ? 'ቅንብሮች' : 'Settings';
  String get language => isAmharic ? 'ቋንቋ' : 'Language';
  String get about => isAmharic ? 'ስለ መተግበሪያው' : 'About';
  String get version => isAmharic ? 'ስሪድ' : 'Version';
  String get server => isAmharic ? 'አገልጋጭ' : 'Server';

  // ── Payment ───────────────────────────────────────────────────────────────
  String get paymentProcessing =>
      isAmharic ? 'ክፍያ በሂደት ላይ...' : 'Processing payment...';
  String get paymentSuccess =>
      isAmharic ? 'ክፍያ ተሳክቷል' : 'Payment successful';
  String get paymentFailed => isAmharic ? 'ክፍያ አልተሳካም' : 'Payment failed';
  String get doNotCloseApp => isAmharic ? 'አፑን ያውጡ' : 'Please do not close the app';
  String get paymentPending =>
      isAmharic ? 'ክፍያ በመጠበቅ ላይ' : 'Payment pending';

  // ── Purchase flow ──────────────────────────────────────────────────────────
  // Each step names what the system is doing rather than "please wait", so a
  // passenger who was redirected to a provider knows their money is still being
  // processed rather than lost.
  String get creatingPayment =>
      isAmharic ? 'ክፍያ በመፍጠር ላይ...' : 'Creating payment...';
  String get awaitingPayment =>
      isAmharic ? 'ክፍያው እየተጠበቅ ነው' : 'Waiting for payment to settle';
  String get issuingTicket =>
      isAmharic ? 'ትክኬት በመጠበቅ ላይ' : 'Issuing your ticket';
  String get ticketReady =>
      isAmharic ? 'ትክኬትዎ ተዘጋጅቷል' : 'Your ticket is ready';

  // ── Entry / exit validation ─────────────────────────────────────────────────
  // Two scans, not one "used" flag. Wording for the middle state matters most:
  // a passenger between entry and exit is exactly where they should be, and
  // must not be told something is wrong.
  String get entryScan => isAmharic ? 'መግባት' : 'Entry';
  String get exitScan => isAmharic ? 'መውጫ' : 'Exit';
  String get notScannedYet => isAmharic ? 'ገና አልተመዘገበም' : 'Not scanned yet';
  String get boardedAt => isAmharic ? 'የገባው ሰዓት' : 'Boarded at';
  String get alightedAt => isAmharic ? 'የወጣው ሰዓት' : 'Alighted at';
  String get currentlyOnboard => isAmharic
      ? 'በተሽከርኪያው ላይ ነዎት' : 'You are on board';
  String get currentlyOnboardDetail => isAmharic
      ? 'ትክኬቱ እየተጠቀመል ነው። ማውጣት ሲደርሱ እንደገና ያሳዩ'
      : 'Your ticket is in use. Show it again when you get off';
  String get rideComplete => isAmharic ? 'ጉዞው ተጠናቋል' : 'Ride complete';
  String get scanRefusedAlready =>
      isAmharic ? 'ይህ ትክኬት አስቀድሞ ተመዝግቧል' : 'This ticket was already scanned';
  String get scanRefusedAlreadyDetail => isAmharic
      ? 'በመግቢያው መውጫ ይጠቀሙ — ሁለቱም እንደተመዘግበም አይችሉም'
      : 'Use it to get off — both ends have already been scanned';
  String get scanRefusedNoEntry => isAmharic
      ? 'መውጫ ከመግቢያ በፊት አይሆንም' : 'No entry was recorded for this ticket';
  String get scanRefusedExpired => isAmharic
      ? 'የትክኬቱ ጊዜ አልፏል' : 'This ticket has expired';
  String get scanRefusedGeneric => isAmharic
      ? 'ትክኬቱ አልተረጋገጠም' : 'The ticket was not accepted';

  // ── Vehicle code flow ──────────────────────────────────────────────────────
  // The boarding flow. Wording is deliberately plain: a passenger reads this
  // while standing at a vehicle, one-handed, in a hurry.
  String get vehicleCode => isAmharic ? 'የተሽከርኪያ ኮድ' : 'Vehicle code';
  String get vehicleCodeTitle => isAmharic ? 'በተሽከርኪያ ኮድ ይግቡ' : 'Enter vehicle code';
  String get vehicleCodeHint => isAmharic ? 'ለምሳሌ AA 12345' : 'e.g. AA 12345';
  String get vehicleCodeHelp => isAmharic
      ? 'ኮዱን በተሽከርኪያው ላይ ያለው ሰሌዳ ላይ ያውጡ'
      : 'Enter the code printed on the plate beside the vehicle';
  String get searchVehicle => isAmharic ? 'ተሽከርኪያ ፈልግ' : 'Search vehicle';
  String get searchingVehicle =>
      isAmharic ? 'ተሽከርኪያውን በመፈለግ ላይ...' : 'Searching for vehicle...';

  /// Step 3, NO branch. Terminal — the flow stops here.
  String get vehicleNotFound => isAmharic ? 'ተሽከርኪያ አልተገኘም' : 'Vehicle Not Found';
  String get vehicleNotFoundDetail => isAmharic
      ? 'ኮዱን ያረጋግጡ ወይም በተሽከርኪያው ላይ ያለውን ኮድ ይጠቀሙ'
      : 'Check the code and try again with the code on the vehicle';
  String get checkCodeAndRetry =>
      isAmharic ? 'ኮዱን አረጋግጥ' : 'Check the code';

  /// The vehicle is known but is not selling tickets.
  String get vehicleUnavailable => isAmharic
      ? 'ተሽከርኪያው አሁን አይሸገርም' : 'This vehicle is not taking passengers';
  String get vehicleRetired => isAmharic ? 'ተሽከርኪያው አገልግᎎ ላይ ነው' : 'This vehicle is retired';
  String get noFarePublished => isAmharic
      ? 'ለዚህ ተሽከርኪያ ተመን አልተዘጋጀም' : 'No fare is published for this vehicle';

  // Vehicle details — step 4.
  String get route => isAmharic ? 'መስመር' : 'Route';
  String get operator => isAmharic ? 'ኦፕሬተር' : 'Operator';
  String get plateNumber => isAmharic ? 'ሰሌዳ' : 'Plate';
  String get capacity => isAmharic ? 'ተሳፋሪዎች' : 'Capacity';
  String get confirmAndPay => isAmharic ? 'አረጋግጥና ክፈል' : 'Confirm and pay';
  String get confirmVehicle => isAmharic ? 'ተሽከርኪያውን አረጋግጥ' : 'Confirm vehicle';

  /// Step 6 — the payment section heading.
  String get paymentFor => isAmharic ? 'የክፍያ ክፍል' : 'Payment';
  String get payForVehicle => isAmharic ? 'ክፈል' : 'Pay fare';
  String get cancelPayment => isAmharic ? 'ክፍያ ውድቅ' : 'Cancel payment';

  /// Step 9, NO branch.
  String get paymentDidNotSucceed =>
      isAmharic ? 'ክፍያው አልተሳካም' : 'Payment failed';
  String get paymentFailedNoMoney => isAmharic
      ? 'ገንዘብዎ አልተነሳም። እንደገና ሞክር ወይም ውድቅ ያድርጉ'
      : 'No money was taken. Try again or cancel';
  String get tryAnotherMethod =>
      isAmharic ? 'ሌላ የክፍያ ዘዴ ይሞክር' : 'Try another payment method';

  // Steps 10–13.
  String get ticketReadyForVehicle =>
      isAmharic ? 'ትክኬትዎ ተዘጋጅቷል' : 'Your ticket is ready';
  String get showThisQrToValidator => isAmharic
      ? 'ይህን QR ኮድ ለመረጃ ሰጪው ያሳዩ'
      : 'Show this QR to the validator';
  String get paymentTransaction => isAmharic ? 'የክፍያ ደረሰኝ' : 'Transaction';
  String get sendQrBySms => isAmharic ? 'በSMS ይላኩ' : 'Send QR by SMS';
  String get sendQrBySmsDetail => isAmharic
      ? 'QR ኮዱን ለራስዎ ወይም ለሌላ ሰው ይላኩ'
      : 'Send the QR to yourself or someone else by SMS';
  String get smsNotAvailable => isAmharic
      ? 'በዚህ ስልክ የSMS አገልግሎት የለም' : 'SMS is not available on this device';
  String get smsBodyPreview => isAmharic ? 'የላከው መልዕክት' : 'Message to send';

  // ── Sharing a ticket ──────────────────────────────────────────────────────
  // Forwarding a ticket to people travelling together is the normal way a group
  // pays once and rides together. The wording is blunt about the consequence,
  // because that is the part passengers are surprised by at the validator.
  String get shareTicket => isAmharic ? 'ትክኬቱን አጋራ' : 'Share ticket';
  String get shareToWhatsapp =>
      isAmharic ? 'በWhatsApp አጋራ' : 'Share on WhatsApp';
  String get shareMore => isAmharic ? 'ተጨማሪ አጋራ' : 'Share';
  String get shareTicketTitle =>
      isAmharic ? 'ትክኬቱን ለሌላ ሰው ይጋሩ' : 'Share this ticket';
  String get shareTicketDetail => isAmharic
      ? 'QR ኮዱን ለሚጋሩ ሰዎች ይላኩ። ትክኬቱ በአንድ ጊዜ ብቻ ይሠራል።'
      : 'Forward the QR to the people you are travelling with. '
          'A ticket is good for one boarding.';
  String get sharedToOthers =>
      isAmharic ? 'ተጋርቷል' : 'Ticket shared';
  String get shareTicketQr =>
      isAmharic ? 'የQR ምስሉን አጋራ' : 'Share QR image';
  String get shareTicketQrDetail =>
      isAmharic
          ? 'የሚቃኝ ምስል ከጽሑፉ ጋር ይላካል።'
          : 'Sends a scannable QR image along with the ticket text.';
  String get shareNotAvailable => isAmharic
      ? 'ማጋራት በዚህ ስልክ አይቻልም' : 'Sharing is not available on this device';
  String get whatsAppNotInstalled => isAmharic
      ? 'WhatsApp ላይ አልተገኘም' : 'WhatsApp is not installed';

  /// Shown before forwarding, because this is the one thing people get wrong:
  /// a shared QR is still ONE ticket, and it validates once.
  String get oneTicketOneBoarding => isAmharic
      ? 'አንድ ትክኬት = አንድ ጊዜ መሳፈጥ። ማጋረት አዲስ ትክኬት አያስፈጥርም — ለእያንዳንዱ ሰው መተመን ያስፈልጋል።'
      : 'One ticket = one boarding. Sharing does not create another ticket — '
          'each person needs their own fare.';

  // Steps 14–16.
  String get presentToValidator =>
      isAmharic ? 'ለመረጃ ሰጪ ያቀረቡ' : 'Present to validator';
  String get checkingTicketStatus =>
      isAmharic ? 'የትክኬት ሁኔታ በመፈለግ ላይ...' : 'Checking ticket status...';
  String get ticketValidated => isAmharic
      ? 'ትክኬትው ተረጋግጧል' : 'Ticket validated';
  String get ticketUsed => isAmharic ? 'ተጠቅመል' : 'Used';
  String get refreshStatus => isAmharic ? 'ሁኔታ አድስ' : 'Refresh status';
  String get validatedOnBoard =>
      isAmharic ? 'ተሽከርኪያው ላይ ተጠቅመል' : 'Used on board';
  String get buyAnother => isAmharic ? 'ሌላ ተሽከርኪያ' : 'Buy another';

  // ── Errors ────────────────────────────────────────────────────────────────
  String get networkError => isAmharic ? 'የኔትወርክ ችግር' : 'Network problem';
  String get networkErrorDetail =>
      isAmharic ? 'እንደገና ይሞክሩ' : 'Check your connection and try again';
  String get genericError => isAmharic ? 'ስህተት ተከስቷል' : 'Something went wrong';

  /// Distinct, actionable messages. A single "something went wrong" leaves the
  /// passenger unable to tell whether to retry, sign in again, or replan.
  String get errorNetwork =>
      isAmharic ? 'ከኔትወርክ ጋር አልተገናኘም' : 'Could not reach the server';
  String get errorSession =>
      isAmharic ? 'ክፍያዎ ጊዜው አልፏል' : 'Your session expired';
  String get errorTimeout =>
      isAmharic ? 'ጊዜው አልፏል' : 'That took too long';
  String get errorReplan =>
      isAmharic ? 'እባክዎ ጉዞውን እንደገና ይቅደሙ' : 'Please plan the journey again';
  String get errorGeneric =>
      isAmharic ? 'ስህተት ተከስቷል' : 'Something went wrong';

  static AppStrings of(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode;
    return code == 'am' ? AppStrings.am : AppStrings.en;
  }
}

/// Wires [AppStrings] into the widget tree.
class AppLocalizationsDelegate extends LocalizationsDelegate<AppStrings> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLocale.values.any((l) => l.code == locale.languageCode);

  @override
  Future<AppStrings> load(Locale locale) async =>
      locale.languageCode == 'am' ? AppStrings.am : AppStrings.en;

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}

/// Convenience scope, so widgets can read strings without a lookup ceremony.
class AppStringsScope extends InheritedWidget {
  const AppStringsScope({
    super.key,
    required this.strings,
    required super.child,
  });

  final AppStrings strings;

  static AppStrings of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppStringsScope>();
    return scope?.strings ?? AppStrings.am;
  }

  @override
  bool updateShouldNotify(AppStringsScope oldWidget) =>
      oldWidget.strings.locale != strings.locale;
}
