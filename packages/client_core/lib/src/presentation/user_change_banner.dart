import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/user_management_controllers.dart';

String userChangeMessage(UserManagementState s) {
  if (s.busy) return 'Waiting for confirmation about ${s.pending!.subject}.';
  return switch (s.notice) {
    UserChangeNotice.saved =>
      '${s.change?.label ?? 'Change saved'} for ${s.change?.subject ?? 'the selected person'}.',
    UserChangeNotice.conflict =>
      s.fieldErrors.values.contains('handover_required')
          ? 'Nothing changed. Complete the responsible ministry handover first.'
          : 'The record changed elsewhere. Review the refreshed details before trying again.',
    UserChangeNotice.invalid =>
      'Nothing changed. Check the name, contact details and consent choice.',
    UserChangeNotice.refused =>
      s.fieldErrors.values.contains('last_admin') ||
              s.fieldErrors['role'] == 'unsupported'
          ? 'The last usable Admin cannot be removed. Another eligible Admin must be available first.'
          : 'The server refused this change. Check the person\'s current state and the required identity or approval steps.',
    UserChangeNotice.unknown => 'The outcome is not confirmed. Check the same request before making another change.',
    UserChangeNotice.notSent => 'The change was not sent. Check your connection and retry the same request.',
    null => '',
  };
}

class UserChangeBanner extends ConsumerWidget {
  const UserChangeBanner({super.key, required this.state});
  final UserManagementState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) => RequestStateBanner(
    key: const Key('user-change-notice'),
    tone: state.notice == UserChangeNotice.saved
        ? StatusTone.success
        : StatusTone.info,
    busy: state.busy,
    title: state.busy
        ? 'Sending…'
        : state.notice == UserChangeNotice.saved
        ? 'Saved'
        : 'Review needed',
    message: userChangeMessage(state),
    actions: [
      if (state.retry != null && !state.busy)
        BannerAction(
          'Check again',
          () => ref.read(userManagementProvider.notifier).checkAgain(),
          key: const Key('user-change-check-again'),
          primary: true,
        ),
      if (!state.unsettled)
        BannerAction(
          'Dismiss',
          () => ref.read(userManagementProvider.notifier).dismissNotice(),
        ),
    ],
  );
}
