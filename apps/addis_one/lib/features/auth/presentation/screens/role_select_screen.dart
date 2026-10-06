import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../../../core/auth/app_role.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/localization.dart';

/// The fork at the top of the app: *who are you *
///
/// One question, asked once, before either sign-in flow runs. It is the whole
/// reason the two apps were merged into one binary -- a passenger and an officer
/// are different people doing different jobs, and neither should have to install
/// a build that is mostly the other's.
///
/// ## Why this is a screen and not a dropdown in a form
///
/// The choice determines which credential namespace is read and which client
/// policy applies. Burying it in a settings row would mean a person could reach
/// the staff sign-in having already attached a passenger token. Asking it up
/// front, in its own screen, makes the identity change explicit and auditable -- /// it is the one thing the app does not remember across launches, precisely
/// because it is the one that matters.
///
/// ## Why switching roles is offered
///
/// A conductor who inspects a bus in the morning and rides home in the evening
/// is the normal case for this system, not an edge case. Switching roles without
/// reinstalling is what makes one binary worth having -- but it must not silently
/// carry a credential across, so switching clears the session being left. See
/// `AddisOneApp._changeRole`.
class RoleSelectScreen extends StatelessWidget {
  const RoleSelectScreen({
    super.key,
    required this.onRoleSelected,
    required this.onChangeRole,
  });

  final ValueChanged<AppRole> onRoleSelected;

  /// Returns to this screen from inside a role, clearing that role's session.
  final VoidCallback onChangeRole;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    s.appName,
                    style: theme.textTheme.displaySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Choose how you are using Addis One today.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.inkMuted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  _RoleCard(
                    icon: Icons.directions_bus_filled_outlined,
                    title: 'Passenger',
                    subtitle: 'Plan journeys, buy tickets, show your QR',
                    onTap: () => onRoleSelected(AppRole.passenger),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _RoleCard(
                    icon: Icons.fact_check_outlined,
                    title: 'Staff',
                    subtitle: 'Scan tickets, run trips and shifts',
                    onTap: () => onRoleSelected(AppRole.staff),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const _BuildStamp(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One role, as a single large target.
///
/// Sized like a staff button rather than a passenger's list row. This screen is
/// the app's front door and is used with cold hands on a cracked screen, and the
/// cost of a mis-tap is signing in as the wrong kind of person.
class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Icon(icon, size: 34, color: AppColors.green),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which build this is, and which server it talks to.
///
/// A demo build and a live build must never be indistinguishable: otherwise a
/// screenshot of demo itineraries could be mistaken for a working production
/// app. The badge names the actual API URL so the two are always separable.
class _BuildStamp extends StatelessWidget {
  const _BuildStamp();

  @override
  Widget build(BuildContext context) {
    final demo = AppConfig.useDemoData;
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: demo ? AppColors.yellowLight : AppColors.greenLight,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: demo ? AppColors.yellow : AppColors.green,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                demo ? Icons.science_outlined : Icons.cloud_done_outlined,
                size: 14,
                color: demo ? AppColors.yellowDark : AppColors.green,
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  demo
                      ? 'Demo data -- ${AppConfig.apiBaseUrl}'
                      : 'Live -- ${AppConfig.apiBaseUrl}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: demo ? AppColors.yellowDark : AppColors.green,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Build ${AppConfig.buildFlavour} -- v${AppConfig.appVersion}',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: AppColors.inkMuted),
        ),
      ],
    );
  }
}
