import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/membership_lifecycle_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/membership_lifecycle.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;

/// Story 2.10, staff web (Admin): disable a login (a hold), deactivate a
/// church membership, restore one after review, and see the handovers owning
/// modules recorded. Every action is checked by the server; staff never see
/// a password, a reason given to the member or any care or finance content.
class MembershipLifecycleScreen extends ConsumerStatefulWidget {
  const MembershipLifecycleScreen({super.key});

  @override
  ConsumerState<MembershipLifecycleScreen> createState() =>
      _MembershipLifecycleScreenState();
}

const _gap = SizedBox(height: ChurchGeometry.sectionGap);

class _MembershipLifecycleScreenState
    extends ConsumerState<MembershipLifecycleScreen> {
  final _checks = <String, IdentityCheck>{};
  final _reasons = <String, DeactivationReason>{};
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  MembershipLifecycleController get _ctl =>
      ref.read(membershipLifecycleProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(membershipLifecycleProvider);
    final children = <Widget>[
      Text(
        'A login hold signs the member out of every device and keeps their '
        'membership, cell and duties. Deactivating a membership also ends '
        'their roles and records what must be handed over. Restore only '
        'after checking who the member is.',
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      _gap,
    ];
    final notice = s.notice;
    if (notice != null) children.addAll([_noticeBanner(notice, s), _gap]);
    final r = s.result;
    final o = s.overview;
    if (s.loading && r == null) {
      children.add(
        const RequestStateBanner(
          key: Key('lifecycle-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading…',
          message: 'Waiting for the server.',
        ),
      );
    } else if (r is AccessReadDenied<MembershipLifecycleOverview>) {
      children.add(
        RequestStateBanner(
          key: Key('lifecycle-denied-${r.denial.name}'),
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
          title: 'Not available',
          message: r.denial == AccessDenial.notGranted
              ? 'Only an Admin can hold, deactivate or restore a membership.'
              : 'Sign in again, or contact the church office.',
        ),
      );
    } else if (r is AccessReadFailed<MembershipLifecycleOverview>) {
      children.add(
        RequestStateBanner(
          key: const Key('lifecycle-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: r.unreachable ? 'No connection' : 'Couldn\'t load',
          message: 'Nothing is shown until the server answers.',
          actions: [
            BannerAction(
              'Try again',
              _ctl.reload,
              key: const Key('lifecycle-retry'),
            ),
          ],
        ),
      );
    } else if (o != null) {
      children
        ..addAll(
          _section(
            'Deactivated memberships',
            [for (final m in o.deactivated) _deactivated(context, m, s.busy)],
            'No membership is deactivated.',
            'lifecycle-no-deactivated',
          ),
        )
        ..addAll(
          _section(
            'Login holds',
            [for (final h in o.loginHolds) _loginHold(context, h, s.busy)],
            'No login is on hold.',
            'lifecycle-no-login-holds',
          ),
        )
        ..addAll(
          _section(
            'Pending handovers',
            [for (final h in o.handovers) _handover(context, h)],
            'Nothing is waiting to be handed over.',
            'lifecycle-no-handovers',
          ),
        )
        ..addAll(_find(context, s));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Membership status')),
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

  List<Widget> _section(
    String title,
    List<Widget> items,
    String empty,
    String emptyKey,
  ) => [
    Semantics(header: true, child: Text(title, style: ChurchType.cardTitle)),
    const SizedBox(height: 8),
    if (items.isEmpty) Text(empty, key: Key(emptyKey)),
    for (final w in items) ...[w, const SizedBox(height: 12)],
    _gap,
  ];

  Widget _card(BuildContext context, Key key, List<Widget> children) {
    final c = ChurchColors.of(context);
    // A Material card, so the radio tiles paint their ink on the card.
    return Material(
      key: key,
      color: c.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _name(BuildContext context, String name) => Semantics(
    header: true,
    child: Text(
      name,
      style: ChurchType.cardTitle.copyWith(color: ChurchColors.of(context).ink),
    ),
  );

  Widget _checkPicker(String id, bool enabled) => RadioGroup<IdentityCheck>(
    groupValue: _checks[id],
    onChanged: (v) {
      if (!enabled || v == null) return;
      setState(() => _checks[id] = v);
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Identity check', style: ChurchType.cardTitle),
        for (final k in IdentityCheck.values)
          RadioListTile<IdentityCheck>(
            key: Key('lifecycle-$id-check-${k.wire}'),
            value: k,
            enabled: enabled,
            contentPadding: EdgeInsets.zero,
            title: Text(k.label),
          ),
      ],
    ),
  );

  Widget _synthetic(bool isSynthetic) => isSynthetic
      ? const Padding(
          padding: EdgeInsets.only(top: 8),
          child: StatusLabel(
            label: 'Synthetic test record',
            tone: StatusTone.neutral,
          ),
        )
      : const SizedBox.shrink();

  Widget _deactivated(BuildContext context, DeactivatedMember m, bool busy) {
    final id = 'restore-${m.memberId}';
    final check = _checks[id];
    final enabled = !busy && !m.ownMember;
    return _card(context, Key('lifecycle-deactivated-${m.memberId}'), [
      _name(context, m.displayName),
      const SizedBox(height: 4),
      const StatusLabel(
        label: 'Membership deactivated',
        tone: StatusTone.warning,
      ),
      const SizedBox(height: 8),
      if (m.reason != null) Text('Reason: ${m.reason!.label}'),
      Text(switch (m.account) {
        'no_login' => 'No app account',
        _ => 'App account kept, sign-in closed',
      }),
      Text(
        m.pendingObligations == 0
            ? 'Nothing waiting to be handed over'
            : '${m.pendingObligations} handover(s) still pending',
        key: Key('lifecycle-deactivated-obligations-${m.memberId}'),
      ),
      _synthetic(m.isSynthetic),
      if (m.ownMember) ...[
        const SizedBox(height: 8),
        const Text('This is your own record: another Admin must decide.'),
      ],
      const SizedBox(height: 12),
      _checkPicker(id, enabled),
      const Text(
        'Restoring gives back church membership only: roles are given again '
        'separately, and handovers stay with their owners.',
      ),
      const SizedBox(height: 12),
      FocusRing(
        child: FilledButton(
          key: Key('lifecycle-restore-${m.memberId}'),
          onPressed: !enabled || check == null
              ? null
              : () => _ctl.restore(m, check),
          child: const Text('Restore membership'),
        ),
      ),
    ]);
  }

  Widget _loginHold(BuildContext context, LoginHoldItem h, bool busy) {
    final id = 'release-${h.holdId}';
    final check = _checks[id];
    final enabled = !busy && !h.ownMember;
    return _card(context, Key('lifecycle-login-hold-${h.holdId}'), [
      _name(context, h.displayName),
      const SizedBox(height: 4),
      const Text('Login disabled. Membership, cell and duties are kept.'),
      _synthetic(h.isSynthetic),
      if (h.ownMember) ...[
        const SizedBox(height: 8),
        const Text('This is your own record: another Admin must decide.'),
      ],
      const SizedBox(height: 12),
      _checkPicker(id, enabled),
      FocusRing(
        child: FilledButton(
          key: Key('lifecycle-release-${h.holdId}'),
          onPressed: !enabled || check == null
              ? null
              : () => _ctl.releaseLoginHold(h, check),
          child: const Text('Release login hold'),
        ),
      ),
    ]);
  }

  Widget _handover(BuildContext context, HandoverItem h) =>
      _card(context, Key('lifecycle-handover-${h.obligationId}'), [
        _name(context, h.displayName),
        const SizedBox(height: 4),
        Text('${_label(h.obligationKind)} (owner: ${_label(h.ownerModule)})'),
        Text(
          h.membershipState == 'deactivated'
              ? 'Membership deactivated'
              : 'Membership restored; the handover is still open',
        ),
        const Text('Resolved in the owning section, not here.'),
      ]);

  static String _label(String code) => code.replaceAll('_', ' ');

  List<Widget> _find(BuildContext context, MembershipLifecycleState s) {
    final found = s.search;
    return [
      Semantics(
        header: true,
        child: Text('Find a member', style: ChurchType.cardTitle),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('lifecycle-search-field'),
              controller: _query,
              decoration: const InputDecoration(
                labelText: 'Member name or contact number',
              ),
              onSubmitted: _ctl.searchMembers,
            ),
          ),
          const SizedBox(width: 12),
          FocusRing(
            child: OutlinedButton(
              key: const Key('lifecycle-search'),
              onPressed: s.searching
                  ? null
                  : () => _ctl.searchMembers(_query.text),
              child: const Text('Search'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (found is AccessReadOk<List<MemberRecord>>)
        for (final m in found.value) ...[
          _target(context, m, s.busy),
          const SizedBox(height: 12),
        ],
      if (found is AccessReadOk<List<MemberRecord>> && found.value.isEmpty)
        const Text('No member found.', key: Key('lifecycle-none')),
    ];
  }

  Widget _target(BuildContext context, MemberRecord m, bool busy) {
    final reason = _reasons[m.memberId];
    return _card(context, Key('lifecycle-target-${m.memberId}'), [
      _name(context, m.displayName),
      _synthetic(m.isSynthetic),
      const SizedBox(height: 12),
      FocusRing(
        child: OutlinedButton(
          key: Key('lifecycle-hold-login-${m.memberId}'),
          onPressed: busy ? null : () => _ctl.holdLogin(m),
          child: const Text('Disable login (hold)'),
        ),
      ),
      const SizedBox(height: 12),
      RadioGroup<DeactivationReason>(
        groupValue: reason,
        onChanged: (v) {
          if (busy || v == null) return;
          setState(() => _reasons[m.memberId] = v);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reason for deactivating', style: ChurchType.cardTitle),
            for (final k in DeactivationReason.values)
              RadioListTile<DeactivationReason>(
                key: Key('lifecycle-${m.memberId}-reason-${k.wire}'),
                value: k,
                enabled: !busy,
                contentPadding: EdgeInsets.zero,
                title: Text(k.label),
              ),
          ],
        ),
      ),
      FocusRing(
        child: FilledButton(
          key: Key('lifecycle-deactivate-${m.memberId}'),
          onPressed: busy || reason == null
              ? null
              : () => _ctl.deactivate(m, reason),
          child: const Text('Deactivate membership'),
        ),
      ),
    ]);
  }

  Widget _noticeBanner(LifecycleNotice notice, MembershipLifecycleState s) {
    final who = s.subject ?? 'the member';
    final (tone, title, message) = switch (notice) {
      LifecycleNotice.loginHeld => (
        StatusTone.success,
        'Login on hold',
        'Every device of $who was signed out. Membership, cell and duties '
            'are kept.',
      ),
      LifecycleNotice.holdReleased => (
        StatusTone.success,
        'Login hold released',
        '$who signs in again to continue.',
      ),
      LifecycleNotice.deactivated => (
        StatusTone.success,
        'Membership deactivated',
        'Every device of $who was signed out and their roles ended. Pending '
            'handovers are listed below.',
      ),
      LifecycleNotice.restored => (
        StatusTone.success,
        'Membership restored',
        '$who signs in again. Give roles again separately if needed.',
      ),
      LifecycleNotice.lastAdmin => (
        StatusTone.danger,
        'Last Admin',
        '$who is the church\'s last usable Admin. Give another member the '
            'Admin role first.',
      ),
      LifecycleNotice.handoverRequired => (
        StatusTone.warning,
        'Hand over first',
        '$who is the last person responsible for something in another '
            'section. Hand it over there first, then deactivate.',
      ),
      LifecycleNotice.alreadyHeld => (
        StatusTone.info,
        'Already on hold',
        '$who\'s login is already on hold.',
      ),
      LifecycleNotice.notApproved => (
        StatusTone.info,
        'Not an active member',
        '$who is not an approved member now.',
      ),
      LifecycleNotice.notDeactivated => (
        StatusTone.info,
        'Not deactivated',
        '$who\'s membership is not deactivated.',
      ),
      LifecycleNotice.passwordResetRequired => (
        StatusTone.warning,
        'Password reset needed first',
        '$who must reset the password themselves before this hold can be '
            'released.',
      ),
      LifecycleNotice.changedElsewhere => (
        StatusTone.info,
        'Changed elsewhere',
        'The record changed since you loaded it. The list was reloaded; '
            'search again before acting.',
      ),
      LifecycleNotice.selfAction => (
        StatusTone.warning,
        'Not for your own record',
        'Another Admin must decide.',
      ),
      LifecycleNotice.noLongerAdmin => (
        StatusTone.danger,
        'Not allowed',
        'Your account no longer holds the Admin role.',
      ),
      LifecycleNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      LifecycleNotice.notAccepting => (
        StatusTone.neutral,
        'Not available here',
        'This can\'t be done right now. Nothing was changed.',
      ),
      LifecycleNotice.invalid => (
        StatusTone.danger,
        'Check the form',
        'Choose a reason or how you checked the member\'s identity.',
      ),
      LifecycleNotice.notFound => (
        StatusTone.info,
        'Not found',
        'The record no longer exists.',
      ),
      LifecycleNotice.refused => (
        StatusTone.danger,
        'Refused',
        'The server refused the request.',
      ),
      LifecycleNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed yet',
        'We couldn\'t confirm whether the decision arrived. Check again; it '
            'is sent once.',
      ),
      LifecycleNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured.',
      ),
    };
    return RequestStateBanner(
      key: Key('lifecycle-notice-${notice.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (notice == LifecycleNotice.unconfirmed)
          BannerAction(
            'Check again',
            _ctl.checkAgain,
            key: const Key('lifecycle-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          _ctl.dismissNotice,
          key: const Key('lifecycle-dismiss'),
        ),
      ],
    );
  }
}
