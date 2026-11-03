import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/assisted_recovery_controllers.dart';
import '../application/credential_controllers.dart';
import '../application/member_deletion_controllers.dart';
import '../application/membership_lifecycle_controllers.dart';
import '../application/recovery_controllers.dart';
import '../application/user_management_controllers.dart';
import '../domain/user_management.dart';

/// Load one current, permission-checked target before mounting a support flow.
/// A member id in a route is not authority and never supplies a cached person.
class UserTargetWorkspace extends ConsumerStatefulWidget {
  const UserTargetWorkspace({
    super.key,
    required this.memberId,
    required this.area,
    required this.builder,
    required this.back,
    required this.showEveryone,
  });
  final String memberId;
  final String area;
  final Widget Function(UserDetail) builder;
  final VoidCallback back;
  final VoidCallback showEveryone;
  @override
  ConsumerState<UserTargetWorkspace> createState() =>
      _UserTargetWorkspaceState();
}

class _UserTargetWorkspaceState extends ConsumerState<UserTargetWorkspace> {
  @override
  void initState() {
    super.initState();
    Future.microtask(_refresh);
  }

  @override
  void didUpdateWidget(UserTargetWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.memberId != widget.memberId) Future.microtask(_refresh);
  }

  void _refresh() {
    if (mounted) {
      ref.read(userManagementProvider.notifier).select(widget.memberId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(userManagementProvider);
    final busy = switch (widget.area) {
      'access-reviews' => ref.watch(
        credentialReviewProvider.select((s) => s.busy || s.unconfirmed != null),
      ),
      'recovery-emails' => ref.watch(
        recoveryEmailReviewProvider.select(
          (s) => s.busy || s.unconfirmed != null,
        ),
      ),
      'recovery' => ref.watch(
        recoveryCasesProvider.select((s) => s.busy || s.unconfirmed != null),
      ),
      'membership' => ref.watch(
        membershipLifecycleProvider.select(
          (s) => s.busy || s.unconfirmed != null,
        ),
      ),
      'deletions' => ref.watch(
        memberDeletionAdminProvider.select(
          (s) => s.busy || s.unconfirmed != null,
        ),
      ),
      _ => s.unsettled,
    };
    // Refresh the target after the child workflow finishes a request. Child
    // commands remain the authority for success, denial and unknown outcomes.
    void completed(bool? before, bool after) {
      if (before == true && !after) _refresh();
    }

    switch (widget.area) {
      case 'access-reviews':
        ref.listen(credentialReviewProvider.select((s) => s.busy), completed);
      case 'recovery-emails':
        ref.listen(
          recoveryEmailReviewProvider.select((s) => s.busy),
          completed,
        );
      case 'recovery':
        ref.listen(recoveryCasesProvider.select((s) => s.busy), completed);
      case 'membership':
        ref.listen(
          membershipLifecycleProvider.select((s) => s.busy),
          completed,
        );
      case 'deletions':
        ref.listen(
          memberDeletionAdminProvider.select((s) => s.busy),
          completed,
        );
    }
    final detail = s.selectedId == widget.memberId ? s.detail : null;
    if (detail == null || s.detailLoading) {
      return SingleChildScrollView(
        padding: ChurchLayout.of(context).pagePadding,
        child: RequestStateBanner(
          tone: StatusTone.info,
          busy: s.detailLoading,
          title: s.detailLoading
              ? 'Loading selected person…'
              : 'Selected person unavailable',
          message: 'No other person is selected in their place. Check current access or return to the directory.',
          actions: [
            if (!s.detailLoading) BannerAction('Try again', _refresh),
            BannerAction('Back to people', widget.back),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Selected: ${detail.member.record.displayName}',
                key: const Key('users-selected-context'),
                style: ChurchType.label,
              ),
              OutlinedButton(
                key: const Key('users-back-to-person'),
                onPressed: busy ? null : widget.back,
                child: const Text('Back to person'),
              ),
              TextButton(
                onPressed: busy ? null : widget.showEveryone,
                child: const Text('Show everyone'),
              ),
              IconButton(
                tooltip: 'Refresh selected person',
                onPressed: busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(child: widget.builder(detail)),
      ],
    );
  }
}
