import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/access_controllers.dart';
import '../application/credential_controllers.dart';
import '../application/membership_lifecycle_controllers.dart';
import '../application/review_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/credential_review.dart' show CredentialCommands, HoldReason;
import '../domain/membership_lifecycle.dart'
    show DeactivationReason, LifecycleCommands;
import '../domain/membership_review.dart';
import 'access_screens.dart' show grantNoticeText;
import 'credential_screens.dart' show credentialReviewNoticeText;
import 'membership_lifecycle_screen.dart' show lifecycleNoticeText;

/// The command family the panel used last; its outcome shows in the panel.
enum _PanelSource { roles, hold, deactivate }

/// What the panel shows about its last action.
class _PanelOutcome {
  const _PanelOutcome({
    required this.busy,
    required this.text,
    required this.unconfirmed,
    required this.checkAgain,
    required this.dismiss,
  });

  final bool busy;
  final (StatusTone, String, String)? text;

  /// The outcome is unknown: Check again resends the same request.
  final bool unconfirmed;
  final Future<void> Function() checkAgain;
  final void Function() dismiss;
}

/// Members & applications → All members → a row: the handoff's right panel
/// for one member. Its details, the role toggles (Roles & access), unlinking
/// the app account (this screen's own command), an access review hold
/// (Access reviews) and deactivating the membership (Membership status).
/// Every action calls the same command as its own screen; the server checks
/// each one. Removing a role, placing a hold, unlinking and deactivating ask
/// first, naming the member and the consequence.
class MemberDetailPanel extends ConsumerStatefulWidget {
  const MemberDetailPanel({
    super.key,
    required this.member,
    required this.gone,
    required this.onClose,
  });

  /// The record as last listed (its revision is the one sent).
  final MemberRecord member;

  /// No longer in the list of approved members (deactivated just now, or
  /// changed elsewhere): the panel keeps the outcome and offers nothing.
  final bool gone;
  final VoidCallback onClose;

  @override
  ConsumerState<MemberDetailPanel> createState() => _MemberDetailPanelState();
}

class _MemberDetailPanelState extends ConsumerState<MemberDetailPanel> {
  _PanelSource? _source;

  MemberRecord get m => widget.member;

  /// Repeats the member search, so the list shows the new account standing
  /// and the next command sends the member's new revision.
  void _refreshMembers() {
    final q = ref.read(membershipReviewProvider).query;
    ref
        .read(membershipReviewProvider.notifier)
        .search(q == null || q.isEmpty ? null : q);
  }

  Future<void> _toggleRole(RosterMember r, String role, bool held) async {
    final label = ChurchRoles.label(role);
    if (held) {
      final ok = await confirmStaffAction(
        context,
        title: 'Remove $label from ${m.displayName}?',
        message:
            '${m.displayName} loses $label access at their next request. You '
            'can give it again later; the change is recorded in the audit '
            'log.',
        confirmLabel: 'Remove $label',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _source = _PanelSource.roles);
    await ref.read(grantAdminProvider.notifier).setRole(r, role, grant: !held);
    if (!mounted) return;
    final s = ref.read(grantAdminProvider);
    if (s.notice case final n?) {
      final (_, title, message) = grantNoticeText(n, s.noticeAction);
      announce(context, '$title. $message');
    }
  }

  Future<void> _placeHold() async {
    // Read the queue now, so its first answer has arrived before the
    // command is sent.
    ref.read(credentialReviewProvider);
    HoldReason? reason;
    final ok = await confirmStaffAction(
      context,
      title: 'Place an access review hold on ${m.displayName}?',
      message:
          'Every device of ${m.displayName} will show only the access review '
          'screen until an Admin checks who they are and releases the hold '
          'under Access reviews.',
      confirmLabel: 'Place hold',
      canConfirm: () => reason != null,
      extra: (context, setState) => _ReasonChoices<HoldReason>(
        label: 'Why',
        keyPrefix: 'member-panel-hold-reason',
        values: const [
          HoldReason.ownershipDispute,
          HoldReason.securityConcern,
          HoldReason.lostDevice,
        ],
        wire: (r) => r.wire,
        text: (r) => r.label,
        value: reason,
        onChanged: (v) => setState(() => reason = v),
      ),
    );
    if (!ok || !mounted || reason == null) return;
    setState(() => _source = _PanelSource.hold);
    await ref
        .read(credentialReviewProvider.notifier)
        .placeHold(m.memberId, m.revision, m.displayName, reason!);
    if (!mounted) return;
    final s = ref.read(credentialReviewProvider);
    if (s.notice case final n?) {
      final (_, title, message) = credentialReviewNoticeText(n, s.subject);
      announce(context, '$title. $message');
      if (n == CredentialReviewNotice.holdPlaced) _refreshMembers();
    }
  }

  Future<void> _deactivate() async {
    ref.read(membershipLifecycleProvider);
    DeactivationReason? reason;
    final ok = await confirmStaffAction(
      context,
      title: 'Deactivate ${m.displayName}\'s membership?',
      message:
          'Every device of ${m.displayName} is signed out and their roles end. '
          'Their member record and history are kept; an Admin can restore the '
          'membership under Membership status.',
      confirmLabel: 'Deactivate membership',
      canConfirm: () => reason != null,
      extra: (context, setState) => _ReasonChoices<DeactivationReason>(
        label: 'Reason',
        keyPrefix: 'member-panel-deactivate-reason',
        values: DeactivationReason.values,
        wire: (r) => r.wire,
        text: (r) => r.label,
        value: reason,
        onChanged: (v) => setState(() => reason = v),
      ),
    );
    if (!ok || !mounted || reason == null) return;
    setState(() => _source = _PanelSource.deactivate);
    await ref.read(membershipLifecycleProvider.notifier).deactivate(m, reason!);
    if (!mounted) return;
    final s = ref.read(membershipLifecycleProvider);
    if (s.notice case final n?) {
      final (_, title, message) = lifecycleNoticeText(n, s.subject);
      announce(context, '$title. $message');
      if (n == LifecycleNotice.deactivated) _refreshMembers();
    }
  }

  Future<void> _unlink() async {
    UnlinkReason? reason;
    final ok = await confirmStaffAction(
      context,
      title: 'Unlink ${m.displayName}\'s app account?',
      message:
          'That account loses member access. ${m.displayName} keeps their '
          'member record and history, and an account can be linked to it '
          'again later.',
      confirmLabel: 'Unlink account',
      canConfirm: () => reason != null,
      extra: (context, setState) => KeyedSubtree(
        key: Key('unlink-reason-${m.memberId}'),
        child: _ReasonChoices<UnlinkReason>(
          label: 'Reason',
          keyPrefix: 'unlink-reason-${m.memberId}',
          values: UnlinkReason.values,
          wire: (r) => r.wire,
          text: (r) => r.label,
          value: reason,
          onChanged: (v) => setState(() => reason = v),
        ),
      ),
    );
    if (!ok || !mounted || reason == null) return;
    // The outcome shows at the top of the page, as before.
    await ref.read(membershipReviewProvider.notifier).unlink(m, reason!);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final roster = ref.watch(grantAdminProvider);
    final reviewBusy = ref.watch(
      membershipReviewProvider.select((s) => s.busy),
    );
    final me = ref.watch(myAccessProvider.select((a) => a.grants?.memberId));
    final self = me == m.memberId;

    final children = <Widget>[
      _header(context),
      const SizedBox(height: 14),
      ?_outcome(context, roster),
      if (!widget.gone) ...[
        _details(context),
        const SizedBox(height: 16),
        Divider(height: 1, color: c.line),
        const SizedBox(height: 14),
        _roles(context, roster, self),
        const SizedBox(height: 16),
        Divider(height: 1, color: c.line),
        const SizedBox(height: 14),
        ..._actions(context, roster, reviewBusy, self),
      ] else
        Text(
          '${m.displayName} is no longer in the list of approved members. '
          'Membership status lists deactivated members and restores them.',
          key: const Key('member-panel-gone'),
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
    ];
    return Semantics(
      container: true,
      label: 'Member details: ${m.displayName}',
      explicitChildNodes: true,
      child: ChurchCard(
        key: const Key('member-panel'),
        radius: churchCardRadiusOf(context),
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 20),
        child: DefaultTextStyle.merge(
          style: ChurchType.staffBody.copyWith(color: c.ink),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final c = ChurchColors.of(context);
    final phone = m.contactRoutes.isEmpty ? null : m.contactRoutes.first.phone;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  m.displayName,
                  style: ChurchType.cardTitle.copyWith(color: c.ink),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                phone ?? 'No contact number',
                style: phone == null
                    ? ChurchType.secondary.copyWith(color: c.muted)
                    : ChurchType.figures.copyWith(
                        color: c.muted,
                        fontWeight: FontWeight.w400,
                      ),
              ),
            ],
          ),
        ),
        FocusRing(
          radius: 22,
          child: IconButton(
            key: const Key('member-panel-close'),
            tooltip: 'Close details',
            onPressed: widget.onClose,
            icon: Icon(Icons.close, size: 20, color: c.muted),
          ),
        ),
      ],
    );
  }

  /// The pending command or the outcome of the panel's last action, read
  /// from the same controller its own screen uses.
  _PanelOutcome? _read(GrantAdminState roster) {
    switch (_source) {
      case null:
        return null;
      case _PanelSource.roles:
        final ctl = ref.read(grantAdminProvider.notifier);
        final mine = roster.noticeAction?.memberId == m.memberId;
        return _PanelOutcome(
          busy: roster.pending?.memberId == m.memberId,
          text: roster.notice == null || !mine
              ? null
              : grantNoticeText(roster.notice!, roster.noticeAction),
          unconfirmed: mine && roster.notice == GrantNotice.unconfirmed,
          checkAgain: ctl.checkAgain,
          dismiss: ctl.dismissNotice,
        );
      case _PanelSource.hold:
        final s = ref.watch(credentialReviewProvider);
        final ctl = ref.read(credentialReviewProvider.notifier);
        return _PanelOutcome(
          busy: s.pending?.command == CredentialCommands.placeHold,
          text: s.notice == null
              ? null
              : credentialReviewNoticeText(s.notice!, s.subject),
          unconfirmed: s.notice == CredentialReviewNotice.unconfirmed,
          checkAgain: ctl.checkAgain,
          dismiss: ctl.dismissNotice,
        );
      case _PanelSource.deactivate:
        final s = ref.watch(membershipLifecycleProvider);
        final ctl = ref.read(membershipLifecycleProvider.notifier);
        return _PanelOutcome(
          busy: s.pending?.command == LifecycleCommands.deactivate,
          text: s.notice == null
              ? null
              : lifecycleNoticeText(s.notice!, s.subject),
          unconfirmed: s.notice == LifecycleNotice.unconfirmed,
          checkAgain: ctl.checkAgain,
          dismiss: ctl.dismissNotice,
        );
    }
  }

  Widget? _outcome(BuildContext context, GrantAdminState roster) {
    final o = _read(roster);
    if (o == null) return null;
    if (o.busy) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 14),
        child: RequestStateBanner(
          key: Key('member-panel-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message: 'Nothing changes until the church server answers.',
        ),
      );
    }
    if (o.text case (final tone, final title, final message)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: RequestStateBanner(
          key: const Key('member-panel-notice'),
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (o.unconfirmed)
              BannerAction(
                'Check again',
                o.checkAgain,
                key: const Key('member-panel-check-again'),
                primary: true,
              ),
            BannerAction('Dismiss', () {
              o.dismiss();
              setState(() => _source = null);
            }, key: const Key('member-panel-dismiss')),
          ],
        ),
      );
    }
    return null;
  }

  Widget _details(BuildContext context) {
    final c = ChurchColors.of(context);
    final rows = <(String, Widget)>[
      ('Membership', const Text('Approved member')),
      (
        'Account',
        Text(switch (m.account) {
          AccountStanding.appAccount => 'App account',
          AccountStanding.noLogin => 'No login',
          AccountStanding.accessReview => 'Access review',
        }),
      ),
      (
        'Contact',
        m.contactRoutes.isEmpty
            ? Text('—', style: TextStyle(color: c.muted))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in m.contactRoutes) ...[
                    Text(r.phone, style: staffFigureStyle(context)),
                    Text(
                      '${r.owner.label}'
                      '${r.holderLabel == null ? '' : ': ${r.holderLabel}'}'
                      ' · not a login',
                      style: ChurchType.secondary.copyWith(
                        color: c.muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
      ),
      if (switch (m.origin) {
            'application' => 'Applied in the app',
            'admin_record' => 'Added by the church office',
            _ => null,
          }
          case final origin?)
        ('Record', Text(origin)),
      if (m.isSynthetic) ('Test data', const Text('Synthetic test record')),
    ];
    return Column(
      key: const Key('member-panel-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: Text(
                    label,
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
                ),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: ChurchType.secondary.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w500,
                    ),
                    child: value,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _roles(BuildContext context, GrantAdminState roster, bool self) {
    final c = ChurchColors.of(context);
    final r = roster.members.where((x) => x.memberId == m.memberId).firstOrNull;
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final Widget body;
    if (r != null) {
      body = Wrap(
        spacing: 4,
        runSpacing: 0,
        children: [
          for (final o in roster.roles)
            _RolePill(
              key: Key('member-panel-role-${o.role}'),
              label: ChurchRoles.label(o.role),
              held: r.grants.hasRole(o.role),
              // Separation of duty: the server refuses a grant to the
              // acting Admin; a role not offered here can only be removed.
              onTap:
                  roster.busy ||
                      (!r.grants.hasRole(o.role) && (!o.available || self))
                  ? null
                  : () => _toggleRole(r, o.role, r.grants.hasRole(o.role)),
            ),
        ],
      );
    } else if (roster.result == null || roster.loading || roster.next != null) {
      body = Text(
        'Loading roles…',
        key: const Key('member-panel-roles-loading'),
        style: muted,
      );
    } else if (roster.result is! AccessReadOk<GrantRoster>) {
      body = Text(
        'Roles couldn\'t be read. Roles & access lists them.',
        key: const Key('member-panel-roles-unavailable'),
        style: muted,
      );
    } else {
      body = Text(
        'No roles can be given to this record here.',
        key: const Key('member-panel-roles-none'),
        style: muted,
      );
    }
    final unavailable = [
      for (final o in roster.roles)
        if (!o.available) ChurchRoles.label(o.role),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Roles',
            style: ChurchType.label.copyWith(color: c.ink, fontSize: 15),
          ),
        ),
        const SizedBox(height: 4),
        body,
        const SizedBox(height: 4),
        Text(
          [
            if (self) 'Another Admin gives roles to your own record.',
            if (r != null && unavailable.isNotEmpty)
              '${unavailable.join(', ')}: not given here yet.',
            'Role changes are recorded in the audit log.',
          ].join(' '),
          style: muted.copyWith(fontSize: 13),
        ),
      ],
    );
  }

  List<Widget> _actions(
    BuildContext context,
    GrantAdminState roster,
    bool reviewBusy,
    bool self,
  ) {
    final c = ChurchColors.of(context);
    final busy =
        reviewBusy ||
        roster.busy ||
        (_source == _PanelSource.hold &&
            ref.watch(credentialReviewProvider.select((s) => s.busy))) ||
        (_source == _PanelSource.deactivate &&
            ref.watch(membershipLifecycleProvider.select((s) => s.busy)));
    final muted = ChurchType.secondary.copyWith(color: c.muted, fontSize: 13);
    Widget ring(Widget b) => FocusRing(child: b);
    return [
      if (self)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            'This is your own record: another Admin must place a hold, unlink '
            'or deactivate it.',
            key: const Key('member-panel-self'),
            style: muted,
          ),
        ),
      if (m.account == AccountStanding.appAccount) ...[
        ring(
          OutlinedButton(
            key: const Key('member-panel-hold'),
            onPressed: busy || self ? null : _placeHold,
            child: const Text('Place access review hold'),
          ),
        ),
        const SizedBox(height: 4),
      ] else if (m.account == AccountStanding.accessReview)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'The account is in access review: Access reviews releases or '
            'restores it.',
            key: const Key('member-panel-in-review'),
            style: muted,
          ),
        ),
      if (m.account != AccountStanding.noLogin) ...[
        ring(
          OutlinedButton(
            key: Key('unlink-${m.memberId}'),
            onPressed: busy || self ? null : _unlink,
            child: const Text('Unlink app account'),
          ),
        ),
        const SizedBox(height: 4),
      ],
      ring(
        OutlinedButton(
          key: const Key('member-panel-deactivate'),
          style: OutlinedButton.styleFrom(
            foregroundColor: c.redFg,
            side: BorderSide(
              color: c.redFg.withValues(alpha: 0.45),
              width: 1.5,
            ),
          ),
          onPressed: busy || self ? null : _deactivate,
          child: const Text('Deactivate membership'),
        ),
      ),
    ];
  }
}

/// A role as a toggle pill: held is filled navy with a check, not held is
/// white with a 1 px line. A 44 px target; the state is in the semantics
/// (toggled) and in the check, never in colour alone.
class _RolePill extends StatelessWidget {
  const _RolePill({
    super.key,
    required this.label,
    required this.held,
    required this.onTap,
  });

  final String label;
  final bool held;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final enabled = onTap != null;
    final fg = held ? c.onPrimary : (enabled ? c.ink : c.muted);
    return FocusRing(
      radius: 24,
      child: Semantics(
        container: true,
        button: true,
        toggled: held,
        enabled: enabled,
        label: label,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: ExcludeSemantics(
              child: SizedBox(
                height: ChurchGeometry.minTarget,
                child: Center(
                  widthFactor: 1,
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: held ? c.primary : c.surface,
                      border: Border.all(color: held ? c.primary : c.line),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (held) ...[
                          Icon(Icons.check, size: 16, color: fg),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          label,
                          style: ChurchType.chip.copyWith(
                            color: fg,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A reason picker inside a confirmation: one radio per choice, keyed
/// `<keyPrefix>-<wire>`.
class _ReasonChoices<T> extends StatelessWidget {
  const _ReasonChoices({
    required this.label,
    required this.keyPrefix,
    required this.values,
    required this.wire,
    required this.text,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String keyPrefix;
  final List<T> values;
  final String Function(T) wire;
  final String Function(T) text;
  final T? value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => RadioGroup<T>(
    groupValue: value,
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ChurchType.label),
        for (final v in values)
          RadioListTile<T>(
            key: Key('$keyPrefix-${wire(v)}'),
            value: v,
            contentPadding: EdgeInsets.zero,
            title: Text(text(v)),
          ),
      ],
    ),
  );
}
