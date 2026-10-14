import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/notification_settings_controllers.dart';
import '../application/push_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/notification_settings.dart';
import 'shell_routing.dart';

/// Story 3.7 (both clients, `/notification-settings`): phone notifications
/// on or off by reminder category. The server holds the setting; turning a
/// category off never removes anything from the inbox. Staff web shows the
/// same settings (browser push is not used: the website shows reminders in
/// its Inbox only).
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
  }

  void _refresh() {
    if (!mounted) return;
    ref.read(notificationSettingsProvider.notifier).refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(notificationSettingsProvider);
    final settings = s.settings;
    final children = <Widget>[
      Text(
        'Choose which reminders may also arrive as phone notifications. '
        'Every reminder still appears in your Inbox, whatever you choose '
        'here.',
        key: const Key('notification-settings-intro'),
      ),
      const SizedBox(height: 12),
      _DeviceNote(liveDevices: settings?.liveDevices),
      const SizedBox(height: ChurchGeometry.sectionGap),
    ];
    if (s.result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('notification-settings-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading your settings…',
          message: 'The server checks your access every time.',
        ),
      );
    } else if (settings == null) {
      children.add(_settingsProblem(s.result!));
    } else if (settings.categories.isEmpty) {
      children.add(
        const RequestStateBanner(
          key: Key('notification-settings-empty'),
          tone: StatusTone.neutral,
          icon: Icons.notifications_none,
          title: 'No reminder types yet',
          message: 'Reminder types appear here as church features arrive.',
        ),
      );
    } else {
      children.add(
        Semantics(
          header: true,
          child: Text(
            'Phone notifications',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
      );
      for (final category in settings.categories) {
        children.add(
          _CategoryRow(
            category: category,
            saving: s.saving == category.key,
            enabled: s.saving == null && !s.loading,
            onChanged: (on) => ref
                .read(notificationSettingsProvider.notifier)
                .setPush(category, on),
          ),
        );
      }
    }
    if (s.notice != null) {
      children.addAll([
        const SizedBox(height: 12),
        _noticeBanner(
          s.notice!,
          () => ref.read(notificationSettingsProvider.notifier).retry(),
        ),
      ]);
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('refresh-notification-settings'),
              onPressed: s.loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ),
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('settings-back-to-inbox'),
              onPressed: () => context.go(ClientPaths.inbox),
              icon: const Icon(Icons.inbox_outlined),
              label: const Text('Back to inbox'),
            ),
          ),
        ],
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: const Text('Notification settings')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: DefaultTextStyle.merge(
                style: layout.body.copyWith(color: c.ink),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What this device does with notifications (never a claim of delivery).
class _DeviceNote extends ConsumerWidget {
  const _DeviceNote({required this.liveDevices});

  final int? liveDevices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final status = ref.watch(pushRegistrationProvider).status;
    final String text;
    if (kIsWeb) {
      text =
          'This website does not show notifications: your reminders are in '
          'the Inbox. These settings apply to your phones.';
    } else {
      text = switch (status) {
        PushRegistrationStatus.unsupported =>
          'Phone notifications are not switched on in this version of the '
              'app yet. Your reminders are in the Inbox.',
        PushRegistrationStatus.permissionDenied =>
          'Notifications for this app are off in your phone\'s settings. '
              'Your reminders are still in the Inbox.',
        PushRegistrationStatus.registered =>
          'This phone is registered for notifications.',
        PushRegistrationStatus.failed =>
          'This phone could not be registered for notifications just now. '
              'Your reminders are still in the Inbox.',
        _ => 'Your reminders are always in the Inbox.',
      };
    }
    final devices = liveDevices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, key: const Key('notification-settings-device')),
        if (devices != null)
          Text(
            devices == 1
                ? '1 phone on your account is registered for notifications.'
                : '$devices phones on your account are registered for '
                      'notifications.',
            key: const Key('notification-settings-devices'),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.saving,
    required this.enabled,
    required this.onChanged,
  });

  final PushCategory category;
  final bool saving;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return SwitchListTile(
      key: Key('push-category-${category.sourceType}-${category.reminderKind}'),
      contentPadding: EdgeInsets.zero,
      value: category.pushEnabled,
      onChanged: enabled ? onChanged : null,
      title: Text(category.title),
      subtitle: Text(
        saving
            ? 'Saving…'
            : category.pushEnabled
            ? 'Phone notifications on. Also in your Inbox.'
            : 'Phone notifications off. Still in your Inbox.',
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
    );
  }
}

Widget _settingsProblem(AccessRead<NotificationSettings> r) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('notification-settings-denied-${denial.name}'),
    tone: StatusTone.neutral,
    icon: Icons.lock_outline,
    title: switch (denial) {
      AccessDenial.signedOut => 'Not signed in',
      AccessDenial.untrustedSession => 'Please sign in again',
      AccessDenial.notLinked => 'No member access yet',
      AccessDenial.reviewRequired => 'Access review required',
      AccessDenial.notGranted => 'Not available to you',
      AccessDenial.unavailable => 'Not available yet',
    },
    message: switch (denial) {
      AccessDenial.signedOut => 'Sign in to change your notification settings.',
      AccessDenial.unavailable =>
        'Notification settings are not available here yet.',
      _ => 'Your account cannot change notification settings right now.',
    },
  ),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: const Key('notification-settings-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load your settings',
    message: unreachable
        ? 'We couldn\'t reach the church server. Try again; nothing changed.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
};

Widget _noticeBanner(PushSettingNotice notice, VoidCallback retry) =>
    switch (notice) {
      PushSettingNotice.saved => const RequestStateBanner(
        key: Key('push-setting-saved'),
        tone: StatusTone.success,
        icon: Icons.check_circle_outline,
        title: 'Saved',
        message: 'The server saved your choice. Your Inbox is unchanged.',
      ),
      PushSettingNotice.changedElsewhere => const RequestStateBanner(
        key: Key('push-setting-changed-elsewhere'),
        tone: StatusTone.warning,
        icon: Icons.sync_problem,
        title: 'Changed on another device',
        message:
            'This setting was changed elsewhere first. The latest settings '
            'are shown; choose again if needed.',
      ),
      PushSettingNotice.refused => const RequestStateBanner(
        key: Key('push-setting-refused'),
        tone: StatusTone.danger,
        icon: Icons.error_outline,
        title: 'Not saved',
        message: 'The server did not accept the change. Nothing changed.',
      ),
      PushSettingNotice.unknown => RequestStateBanner(
        key: const Key('push-setting-unknown'),
        tone: StatusTone.danger,
        icon: Icons.help_outline,
        title: 'We don\'t know yet if it was saved',
        message:
            'The server did not answer. Try again: it sends the same request '
            'and the server tells us what happened.',
        actions: [
          BannerAction(
            'Try again',
            retry,
            key: const Key('push-setting-retry'),
            primary: true,
          ),
        ],
      ),
      PushSettingNotice.notSent => const RequestStateBanner(
        key: Key('push-setting-not-sent'),
        tone: StatusTone.neutral,
        icon: Icons.cloud_off_outlined,
        title: 'Not sent',
        message: 'This build has no server configured.',
      ),
    };
