import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/config/app_config.dart';
import '../../../../../core/localization.dart';
import '../../../auth/domain/auth_state.dart';

/// Account and settings.
///
/// The server address is shown on purpose. This is a transport system where a
/// passenger may be looking at a fare they doubt; being able to confirm which
/// backend answered — demo or live — is part of trusting the number.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key, required this.onLocaleSelected});

  final ValueChanged<AppLocale> onLocaleSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(passengerAuthStateProvider);
    final signedIn = state is PassengerAuthAuthenticated;

    return Scaffold(
      appBar: AppBar(title: Text(s.profile)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          // A card that reads "Sign in → My tickets" has to actually sign you in.
          // Card has no onTap of its own, so the tap target is an InkWell inside
          // it — leaving it inert would be a dead control, which is exactly the
          // failure this app already had once.
          Card(
            child: InkWell(
              onTap: signedIn
                  ? null
                  : () => context.pushNamed(Routes.passengerSignInName),
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: AppColors.greenLight,
                      child: Icon(
                        signedIn
                            ? Icons.person_rounded
                            : Icons.person_outline_rounded,
                        color: AppColors.green,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            // The E.164 form is the canonical identity: a local
                            // 09… prefix is ambiguous without the country code.
                            signedIn
                                ? '${s.signedInAs}${state.phoneE164}'
                                : s.notSignedIn,
                            style: theme.textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            signedIn
                                ? s.appName
                                : '${s.signIn} → ${s.myTickets}',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.inkMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _Section(
            title: s.settings,
            children: [
              ListTile(
                leading: const Icon(Icons.translate_rounded),
                title: Text(s.language),
                subtitle: Text(s.isAmharic ? 'አማርኛ' : 'English'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickLocale(context),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _Section(
            title: s.about,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(s.version),
                trailing: Text(AppConfig.appVersion),
              ),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(s.server),
                // Names the exact host so "why is the fare wrong?" has an answer
                // on screen instead of requiring a developer.
                subtitle: Text(AppConfig.apiBaseUrl),
                trailing: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppConfig.useDemoData
                        ? AppColors.yellowLight
                        : AppColors.greenLight,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    AppConfig.useDemoData ? 'DEMO' : 'LIVE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppConfig.useDemoData
                          ? AppColors.yellowDark
                          : AppColors.green,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (signedIn)
            OutlinedButton.icon(
              icon: const Icon(Icons.logout_rounded),
              label: Text(s.signOut),
              onPressed: () => _signOut(ref),
            ),
        ],
      ),
    );
  }

  void _signOut(WidgetRef ref) {
    // Fire-and-forget: the controller resets its own state, so the screen has
    // nothing to do afterwards and no context to await on.
    ref.read(passengerAuthControllerProvider).signOut();
  }

  void _pickLocale(BuildContext context) {
    final current = AppStringsScope.of(context).isAmharic;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: RadioGroup<AppLocale>(
          groupValue: current ? AppLocale.am : AppLocale.en,
          onChanged: (value) {
            if (value != null) onLocaleSelected(value);
            Navigator.of(sheetContext).pop();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in AppLocale.values)
                RadioListTile<AppLocale>(
                  value: option,
                  // Amharic and English are shown in their own script, never
                  // transliterated: the label IS the language.
                  title: Text(option == AppLocale.am ? 'አማርኛ' : 'English'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled group of settings rows.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.md, bottom: AppSpacing.sm),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(color: AppColors.inkMuted),
          ),
        ),
        Card(child: Column(children: children)),
      ],
    );
  }
}
