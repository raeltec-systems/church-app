import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/access_controllers.dart';
import '../application/review_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/membership_application.dart';
import '../domain/membership_review.dart';
import '../domain/phone_username.dart';
import 'member_detail_panel.dart';

/// Story 2.5, staff web, Admin only: membership applications (approve as a
/// new member, link to an existing member, ask for details, reject), member
/// records with and without a login (add a record, unlink an account), and
/// reclaiming a phone username someone else registered first. Shown only
/// while the server's current answer says Admin; the server refuses every
/// read and action otherwise. Duplicate candidates are a staff aid: nothing
/// is linked unless the Admin chooses to.
class MembershipReviewScreen extends ConsumerStatefulWidget {
  const MembershipReviewScreen({
    super.key,
    this.initialSection = MembershipReviewSection.applications,
    this.showSectionSelector = true,
  });

  final MembershipReviewSection initialSection;
  final bool showSectionSelector;

  @override
  ConsumerState<MembershipReviewScreen> createState() =>
      _MembershipReviewScreenState();
}

enum MembershipReviewSection { applications, members, reclaim }

class _MembershipReviewScreenState
    extends ConsumerState<MembershipReviewScreen> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'review notice');
  MembershipReviewSection _section = MembershipReviewSection.applications;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    _lifecycle = AppLifecycleListener(onResume: _reload);
    if (_section == MembershipReviewSection.members) {
      Future.microtask(() {
        if (mounted) ref.read(membershipReviewProvider.notifier).search(null);
      });
    }
    // Revisiting the screen asks the server again.
    if (ref.read(membershipReviewProvider).queueResult != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (mounted) ref.read(membershipReviewProvider.notifier).reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(membershipReviewProvider);
    final ctl = ref.read(membershipReviewProvider.notifier);
    ref.listen(membershipReviewProvider.select((x) => x.notice), (prev, next) {
      if (next == null || next == prev) return;
      final (_, title, message) = _noticeText(
        next,
        ref.read(membershipReviewProvider).noticeAction,
      );
      announce(context, '$title. $message');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      });
    });

    final children = <Widget>[];
    if (s.pending case final p?) {
      children.add(
        RequestStateBanner(
          key: const Key('review-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message: 'Waiting for the server about ${p.subject}.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(n, s.noticeAction);
      children.add(
        RequestStateBanner(
          key: Key('review-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == ReviewNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('review-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('review-dismiss'),
            ),
          ],
        ),
      );
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    final result = s.queueResult;
    if (result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('review-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading applications…',
          message: 'Only an Admin can see this list.',
        ),
      );
    } else if (result is! AccessReadOk<ReviewQueue>) {
      children.add(_readProblem(result));
    } else {
      final more = s.queueNext == null ? '' : '+';
      children.addAll([
        // The handoff's segmented track, as wide as its options.
        if (widget.showSectionSelector)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: RadioSegments<MembershipReviewSection>(
                key: const Key('review-sections'),
                label: 'Show',
                options: [
                  SegmentOption(
                    MembershipReviewSection.applications,
                    'Applications (${s.applications.length}$more)',
                  ),
                  const SegmentOption(
                    MembershipReviewSection.members,
                    'All members',
                  ),
                  const SegmentOption(
                    MembershipReviewSection.reclaim,
                    'Reclaim a username',
                  ),
                ],
                selected: _section,
                onChanged: (v) {
                  setState(() => _section = v);
                  if (v == MembershipReviewSection.members &&
                      s.searchResult == null) {
                    ctl.search(null);
                  }
                },
              ),
            ),
          ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        switch (_section) {
          MembershipReviewSection.applications => _applications(
            context,
            s,
            ctl,
          ),
          MembershipReviewSection.members => _MembersSection(state: s),
          MembershipReviewSection.reclaim => _ReclaimSection(state: s),
        },
      ]);
    }
    return ChurchPageScaffold(
      title: 'Members & applications',
      subtitle: 'Applications, member records and sign-in usernames',
      actions: [
        staffReloadButton(
          const Key('review-reload'),
          s.loading || s.busy ? null : ctl.reload,
        ),
      ],
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

  Widget _applications(
    BuildContext context,
    ReviewState s,
    MembershipReviewController ctl,
  ) {
    if (s.applications.isEmpty) {
      return ChurchCard(
        radius: 12,
        child: Text(
          'No applications are waiting.',
          key: const Key('review-no-applications'),
          style: ChurchType.staffBody.copyWith(
            color: ChurchColors.of(context).muted,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Check who the person is before approving or linking. A matching '
          'name or number is only a hint: nothing is linked unless you choose '
          'it, and the applicant never sees these hints.',
          style: ChurchType.secondary.copyWith(
            color: ChurchColors.of(context).muted,
          ),
        ),
        const SizedBox(height: 12),
        for (final a in s.applications) ...[
          _ApplicationCard(
            key: Key('application-${a.id}-r${a.application.revision}'),
            item: a,
            state: s,
          ),
          const SizedBox(height: 12),
        ],
        if (s.queueNext != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: OutlinedButton(
                key: const Key('review-more-applications'),
                onPressed: s.loading ? null : ctl.loadMoreApplications,
                child: const Text('Show more applications'),
              ),
            ),
          ),
      ],
    );
  }
}

Widget _readProblem<T>(AccessRead<T> r) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('review-denied-${denial.name}'),
    tone: StatusTone.warning,
    icon: Icons.lock_outline,
    title: switch (denial) {
      AccessDenial.signedOut => 'Not signed in',
      AccessDenial.untrustedSession => 'Please sign in again',
      AccessDenial.notGranted => 'Not available to you',
      AccessDenial.unavailable => 'Not available yet',
      _ => 'Access review required',
    },
    message: denial == AccessDenial.notGranted
        ? 'Members & applications needs the Admin role. Permissions are '
              'checked by the server each time.'
        : 'Nothing is shown until the server allows it.',
  ),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: const Key('review-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load the list',
    message: unreachable
        ? 'We couldn\'t reach the church server. Nothing is shown until it '
              'answers.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
};

(StatusTone, String, String) _noticeText(ReviewNotice n, ReviewAction? a) {
  final who = a?.subject ?? 'the person';
  return switch (n) {
    ReviewNotice.approved => (
      StatusTone.success,
      'Approved',
      '$who is now a church member. They need to sign in again on their '
          'device before member features open.',
    ),
    ReviewNotice.linked => (
      StatusTone.success,
      'Linked',
      '$who\'s account is linked to the existing member record; its member '
          'ID and history are kept, but no roles carry over. They need to sign '
          'in again.',
    ),
    ReviewNotice.detailsRequested => (
      StatusTone.success,
      'Details requested',
      '$who will see what the church asked for.',
    ),
    ReviewNotice.rejected => (
      StatusTone.success,
      'Not approved',
      '$who\'s request was not approved. They can send a new one after '
          '7 days.',
    ),
    ReviewNotice.memberCreated => (
      StatusTone.success,
      'Member record added',
      '$who was added without a login. If they create an account later, '
          'link it to this record.',
    ),
    ReviewNotice.unlinked => (
      StatusTone.success,
      'Account unlinked',
      '$who keeps their member record and history; the old account has no '
          'member access any more.',
    ),
    ReviewNotice.reclaimed => (
      StatusTone.success,
      'Username released',
      'The account that held $who can no longer sign in with it. The person '
          'it belongs to can now create an account with this number.',
    ),
    ReviewNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      'This was changed in another tab or by another Admin. The list was '
          'reloaded; check it and try again.',
    ),
    ReviewNotice.alreadyLinked => (
      StatusTone.warning,
      'Already linked',
      'That member, account or sign-in number already has a live account '
          'link. Unlink it first if that is right after checking.',
    ),
    ReviewNotice.phoneChanged => (
      StatusTone.warning,
      'Sign-in number changed',
      '$who\'s sign-in number changed after they applied. Ask them for '
          'details before approving.',
    ),
    ReviewNotice.emailUnverified => (
      StatusTone.warning,
      'Email not verified',
      '$who\'s account has an email that is not verified, so it cannot be '
          'approved into their sign-in details yet. Ask for details: "Confirm '
          'their email or remove it".',
    ),
    ReviewNotice.memberHeld => (
      StatusTone.warning,
      'Member on hold',
      'That member record is on hold and cannot be linked now.',
    ),
    ReviewNotice.lastAdmin => (
      StatusTone.warning,
      'The last Admin can\'t be unlinked',
      'Unlinking $who would leave the church without a usable Admin. Grant '
          'Admin to another member with access first.',
    ),
    ReviewNotice.selfAction => (
      StatusTone.warning,
      'Not allowed',
      'Another Admin must do this for your own record or account. Nothing '
          'was changed.',
    ),
    ReviewNotice.notFound => (
      StatusTone.neutral,
      'Not found',
      'No account or request matches. Nothing was changed.',
    ),
    ReviewNotice.invalid => (
      StatusTone.danger,
      'Check the form',
      'Some answers need fixing before this can be sent.',
    ),
    ReviewNotice.noLongerAdmin => (
      StatusTone.warning,
      'Not allowed',
      'Your account no longer has Admin access. Nothing was changed.',
    ),
    ReviewNotice.signInAgain => (
      StatusTone.warning,
      'Please sign in again',
      'This sign-in is no longer valid. Nothing was changed.',
    ),
    ReviewNotice.notAccepting => (
      StatusTone.neutral,
      'Not available yet',
      'Member records cannot be changed here until the church approves '
          'personal data handling.',
    ),
    ReviewNotice.refused => (
      StatusTone.warning,
      'Not changed',
      'The server refused the change. The list was reloaded.',
    ),
    ReviewNotice.unconfirmed => (
      StatusTone.warning,
      'Not confirmed',
      'We don\'t know whether the change for $who was made. Check again: '
          'the same request is sent, so it can\'t apply twice.',
    ),
    ReviewNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
  };
}

String _accountLabel(AccountStanding a) => switch (a) {
  AccountStanding.appAccount => 'App account',
  AccountStanding.noLogin => 'No login',
  AccountStanding.accessReview => 'Access review',
};

StatusTone _accountTone(AccountStanding a) => switch (a) {
  AccountStanding.appAccount => StatusTone.success,
  AccountStanding.noLogin => StatusTone.neutral,
  AccountStanding.accessReview => StatusTone.warning,
};

/// A bordered surface card. A [Material] (not a decorated box) so list
/// tiles inside it paint their ink on the card itself.
class _Card extends StatelessWidget {
  const _Card({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: child,
      ),
    );
  }
}

/// How the Admin checked who the person is: one row of radio choices (the
/// key is on each whole choice, label included).
Widget _identityCheckPicker({
  required String keyPrefix,
  required IdentityCheck? value,
  required bool enabled,
  required ValueChanged<IdentityCheck?> onChanged,
  bool optional = false,
}) => RadioGroup<IdentityCheck>(
  groupValue: value,
  onChanged: (v) {
    if (enabled) onChanged(v);
  },
  child: Builder(
    builder: (context) {
      final c = ChurchColors.of(context);
      return Wrap(
        spacing: 4,
        runSpacing: 0,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              optional ? 'Identity check (optional)' : 'Identity check',
              style: ChurchType.label.copyWith(color: c.ink),
            ),
          ),
          for (final k in IdentityCheck.values)
            _RadioChoice<IdentityCheck>(
              key: Key('$keyPrefix-check-${k.wire}'),
              value: k,
              label: k.label,
              enabled: enabled,
              onSelect: () => onChanged(k),
            ),
        ],
      );
    },
  ),
);

/// A radio and its label as one tappable choice, sized to its content
/// (a [RadioListTile] takes the full width).
class _RadioChoice<T> extends StatelessWidget {
  const _RadioChoice({
    super.key,
    required this.value,
    required this.label,
    required this.enabled,
    required this.onSelect,
  });

  final T value;
  final String label;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: enabled ? onSelect : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Radio<T>(value: value, enabled: enabled),
              Flexible(
                child: Text(
                  label,
                  style: ChurchType.staffBody.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One open application with its decision controls.
class _ApplicationCard extends ConsumerStatefulWidget {
  const _ApplicationCard({super.key, required this.item, required this.state});
  final ReviewApplication item;
  final ReviewState state;

  @override
  ConsumerState<_ApplicationCard> createState() => _ApplicationCardState();
}

enum _Mode { none, details, reject, pick }

class _ApplicationCardState extends ConsumerState<_ApplicationCard> {
  IdentityCheck? _check;
  _Mode _mode = _Mode.none;
  final Set<DetailRequest> _requested = {};
  RejectReason? _reason;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final a = widget.item;
    final app = a.application;
    final s = widget.state;
    final ctl = ref.read(membershipReviewProvider.notifier);
    final id = a.id;
    final busy = s.busy;
    final canDecide = !busy && !a.ownAccount;
    final checked = _check != null;
    final cell = switch (app.cellChoice.kind) {
      CellChoiceKind.cell => 'Asked for a cell (confirmed separately)',
      CellChoiceKind.notSure => 'Not sure which cell',
      CellChoiceKind.notInCell => 'Not in a cell yet',
    };
    final details = <String>[
      app.phoneUsername,
      cell,
      if (a.priorNotApproved > 0)
        '${a.priorNotApproved} earlier '
            '${a.priorNotApproved == 1 ? 'request' : 'requests'} not approved',
    ];
    return _Card(
      key: Key('application-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                header: true,
                child: Text(
                  app.fullName,
                  style: ChurchType.cardTitle.copyWith(
                    color: c.ink,
                    fontSize: 17,
                  ),
                ),
              ),
              StatusLabel(
                label: app.churchStatus == ChurchStatus.detailsRequested
                    ? 'Details requested'
                    : 'Awaiting approval',
                tone: app.churchStatus == ChurchStatus.detailsRequested
                    ? StatusTone.warning
                    : StatusTone.info,
              ),
              if (app.isSynthetic)
                const StatusLabel(
                  label: 'Synthetic test record',
                  tone: StatusTone.neutral,
                ),
            ],
          ),
          const SizedBox(height: 4),
          // The sign-in number, the cell they asked about and any earlier
          // refusals: one grey line.
          Text(
            details.join(' · '),
            key: a.priorNotApproved > 0 ? Key('prior-$id') : null,
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          Text(
            'Sign-in number not verified',
            style: ChurchType.secondary.copyWith(color: c.muted, fontSize: 13),
          ),
          if (a.ownAccount)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: StatusLabel(
                label: 'Your own account: another Admin must decide this',
                tone: StatusTone.warning,
              ),
            ),
          if (a.candidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            // The handoff's amber notice: a possible existing record.
            Container(
              key: Key('duplicates-$id'),
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              decoration: BoxDecoration(
                color: c.amberBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Possible existing member records (staff only). Check '
                    'who they are before linking.',
                    style: ChurchType.secondary.copyWith(
                      color: c.amberFg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final cand in a.candidates)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            cand.displayName,
                            style: ChurchType.secondary.copyWith(
                              color: c.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // What matched, each its own phrase.
                          for (final why in [
                            _accountLabel(cand.account),
                            for (final sig in cand.signals)
                              DuplicateCandidate.signalLabel(sig),
                          ])
                            Text(
                              why,
                              style: ChurchType.secondary.copyWith(
                                color: c.amberFg,
                              ),
                            ),
                          FocusRing(
                            child: TextButton(
                              key: Key('link-$id-${cand.memberId}'),
                              onPressed:
                                  canDecide && checked && cand.linkEligible
                                  ? () => ctl.link(a, cand.memberId, _check!)
                                  : null,
                              style: TextButton.styleFrom(
                                foregroundColor: c.ink,
                              ),
                              child: Text(
                                cand.linkEligible
                                    ? 'Link to this member'
                                    : 'Cannot link (has a login or hold)',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Divider(height: 1, color: c.line),
          const SizedBox(height: 12),
          // Check first, then decide: the identity check sits before the
          // decisions it unlocks.
          _identityCheckPicker(
            keyPrefix: 'app-$id',
            value: _check,
            enabled: canDecide,
            onChanged: (v) => setState(() => _check = v),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FocusRing(
                child: FilledButton(
                  key: Key('approve-$id'),
                  onPressed: canDecide && checked
                      ? () => ctl.approve(a, _check!)
                      : null,
                  child: const Text('Approve as a new member'),
                ),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('pick-$id'),
                  onPressed: canDecide
                      ? () => setState(() => _mode = _Mode.pick)
                      : null,
                  child: const Text('Link existing'),
                ),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('details-$id'),
                  onPressed: canDecide
                      ? () => setState(() => _mode = _Mode.details)
                      : null,
                  child: const Text('Ask for details'),
                ),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('reject-$id'),
                  onPressed: canDecide
                      ? () => setState(() => _mode = _Mode.reject)
                      : null,
                  style: OutlinedButton.styleFrom(foregroundColor: c.redFg),
                  child: const Text('Reject'),
                ),
              ),
              if (!checked && canDecide)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'Record how you checked who they are to approve or link.',
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
                ),
            ],
          ),
          if (_mode == _Mode.details) ..._detailsForm(a, ctl, canDecide),
          if (_mode == _Mode.reject) ..._rejectForm(a, ctl, canDecide),
          if (_mode == _Mode.pick) ..._pickForm(a, ctl, canDecide, checked),
        ],
      ),
    );
  }

  List<Widget> _detailsForm(
    ReviewApplication a,
    MembershipReviewController ctl,
    bool canDecide,
  ) => [
    const SizedBox(height: 12),
    Text('Ask for', style: ChurchType.cardTitle),
    for (final r in DetailRequest.values)
      CheckboxListTile(
        key: Key('ask-${a.id}-${r.wire}'),
        value: _requested.contains(r),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(r.label),
        onChanged: canDecide
            ? (v) => setState(
                () => v == true ? _requested.add(r) : _requested.remove(r),
              )
            : null,
      ),
    FocusRing(
      child: FilledButton(
        key: Key('send-details-${a.id}'),
        onPressed: canDecide && _requested.isNotEmpty
            ? () => ctl.askDetails(a, _requested, check: _check)
            : null,
        child: const Text('Send request for details'),
      ),
    ),
  ];

  List<Widget> _rejectForm(
    ReviewApplication a,
    MembershipReviewController ctl,
    bool canDecide,
  ) => [
    const SizedBox(height: 12),
    Text(
      'Reason shown to the applicant (optional)',
      style: ChurchType.cardTitle,
    ),
    RadioGroup<RejectReason?>(
      groupValue: _reason,
      onChanged: (v) {
        if (canDecide) setState(() => _reason = v);
      },
      child: Column(
        children: [
          RadioListTile<RejectReason?>(
            key: Key('reason-${a.id}-none'),
            value: null,
            contentPadding: EdgeInsets.zero,
            title: const Text('No reason'),
          ),
          for (final r in RejectReason.values)
            RadioListTile<RejectReason?>(
              key: Key('reason-${a.id}-${r.wire}'),
              value: r,
              contentPadding: EdgeInsets.zero,
              title: Text(r.label),
            ),
        ],
      ),
    ),
    FocusRing(
      child: FilledButton(
        key: Key('confirm-reject-${a.id}'),
        onPressed: canDecide
            ? () => ctl.reject(a, reason: _reason, check: _check)
            : null,
        child: const Text('Confirm: not approved'),
      ),
    ),
  ];

  List<Widget> _pickForm(
    ReviewApplication a,
    MembershipReviewController ctl,
    bool canDecide,
    bool checked,
  ) {
    final s = widget.state;
    return [
      const SizedBox(height: 12),
      Text('Find the existing member record', style: ChurchType.cardTitle),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: Key('pick-query-${a.id}'),
              controller: _search,
              decoration: const InputDecoration(
                labelText: 'Name or contact number',
              ),
              onSubmitted: (v) => ctl.search(v),
            ),
          ),
          const SizedBox(width: 8),
          FocusRing(
            child: OutlinedButton(
              key: Key('pick-search-${a.id}'),
              onPressed: s.searching ? null : () => ctl.search(_search.text),
              child: const Text('Search'),
            ),
          ),
        ],
      ),
      for (final m in s.members)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(m.displayName),
              StatusLabel(
                label: _accountLabel(m.account),
                tone: _accountTone(m.account),
              ),
              FocusRing(
                child: TextButton(
                  key: Key('pick-link-${a.id}-${m.memberId}'),
                  onPressed: canDecide && checked && m.linkEligible
                      ? () => ctl.link(a, m.memberId, _check!)
                      : null,
                  child: Text(
                    m.linkEligible
                        ? 'Link to this member'
                        : 'Cannot link (has a login or hold)',
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }
}

/// All members (with and without a login), add a record, unlink.
class _MembersSection extends ConsumerStatefulWidget {
  const _MembersSection({required this.state});
  final ReviewState state;

  @override
  ConsumerState<_MembersSection> createState() => _MembersSectionState();
}

class _MembersSectionState extends ConsumerState<_MembersSection> {
  final _query = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _holder = TextEditingController();
  ConsentBasis? _consent;
  ContactOwner _owner = ContactOwner.member;
  bool _adding = false;
  String? _nameError;
  String? _phoneError;
  String? _consentError;

  /// The member whose detail panel is open (as last listed).
  MemberRecord? _selected;

  @override
  void dispose() {
    _query.dispose();
    _name.dispose();
    _phone.dispose();
    _holder.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    String? phone;
    String? phoneError;
    if (_phone.text.trim().isNotEmpty) {
      final r = normalizePhoneUsername(_phone.text, defaultDialingCountry);
      phone = r.value;
      if (phone == null) {
        phoneError =
            'Enter the number with its country code, e.g. +1 202 555 0100.';
      }
    }
    setState(() {
      _nameError = name.isEmpty ? 'Enter the person\'s full name.' : null;
      _phoneError = phoneError;
      _consentError = _consent == null
          ? 'Record how the person agreed to be added.'
          : null;
    });
    if (_nameError != null || _phoneError != null || _consent == null) return;
    ref
        .read(membershipReviewProvider.notifier)
        .createMember(
          fullName: name,
          consent: _consent!,
          contactPhone: phone,
          contactOwner: phone == null ? null : _owner,
          holderLabel: _owner == ContactOwner.member ? null : _holder.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = widget.state;
    final ctl = ref.read(membershipReviewProvider.notifier);
    final server = s.noticeAction?.command == ReviewCommands.createMember
        ? s.fieldErrors
        : const <String, String>{};
    final result = s.searchResult;
    final shown = s.members.length;
    // Roles for the Roles column and the detail panel come from the Roles &
    // access roster, read page by page (a church of under 200 members).
    final roster = ref.watch(grantAdminProvider);
    if (roster.next != null && !roster.loading) {
      Future.microtask(ref.read(grantAdminProvider.notifier).loadMore);
    }
    final rosterRead = roster.result is AccessReadOk<GrantRoster>;
    final roles = {for (final r in roster.members) r.memberId: r.grants.roles};
    final chosen = _selected;
    final current = chosen == null
        ? null
        : s.members.where((x) => x.memberId == chosen.memberId).firstOrNull;
    final listed = result is AccessReadOk<MemberSearchPage> && !s.searching;
    final panel = chosen == null
        ? null
        : MemberDetailPanel(
            key: ValueKey('member-panel-${chosen.memberId}'),
            member: current ?? chosen,
            gone: current == null && listed,
            onClose: () => setState(() => _selected = null),
          );
    void search(String q) {
      setState(() => _selected = null);
      ctl.search(q);
    }

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result != null && result is! AccessReadOk<MemberSearchPage>)
          _readProblem(result)
        else if (result != null && s.members.isEmpty)
          ChurchCard(
            radius: 12,
            child: Text(
              'No members match.',
              key: const Key('member-none'),
              style: ChurchType.staffBody.copyWith(color: c.muted),
            ),
          )
        else if (shown > 0) ...[
          _MemberTable(
            members: s.members,
            roles: rosterRead && roster.next == null ? roles : null,
            selectedId: chosen?.memberId,
            onSelect: (m) => setState(
              () => _selected = _selected?.memberId == m.memberId ? null : m,
            ),
          ),
        ],
        if (s.membersNext != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FocusRing(
                child: OutlinedButton(
                  key: const Key('member-more'),
                  onPressed: s.searching ? null : ctl.loadMoreMembers,
                  child: const Text('Show more members'),
                ),
              ),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The toolbar: search, and the section's own job (add a record for
        // someone without a login).
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: TextField(
                key: const Key('member-query'),
                controller: _query,
                decoration: const InputDecoration(
                  labelText: 'Search by name or contact number',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
                onSubmitted: search,
              ),
            ),
            FocusRing(
              child: OutlinedButton(
                key: const Key('member-search'),
                onPressed: s.searching ? null : () => search(_query.text),
                child: const Text('Search'),
              ),
            ),
            if (!_adding)
              FocusRing(
                child: FilledButton.icon(
                  key: const Key('add-member-record'),
                  onPressed: () => setState(() => _adding = true),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Add member record (no login)'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        // The add form opens where it was asked for, above the list.
        if (_adding) ...[
          _Card(
            key: const Key('add-member-form'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'For someone without a personal account, with their '
                  'permission. No email or login is created.',
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
                TextField(
                  key: const Key('add-member-name'),
                  controller: _name,
                  readOnly: s.busy,
                  decoration: InputDecoration(
                    labelText: 'Full name',
                    errorText:
                        _nameError ??
                        (server.containsKey('full_name')
                            ? 'Check the name.'
                            : null),
                  ),
                ),
                const SizedBox(height: 12),
                RadioGroup<ConsentBasis>(
                  groupValue: _consent,
                  onChanged: (v) {
                    if (!s.busy) {
                      setState(() {
                        _consent = v;
                        _consentError = null;
                      });
                    }
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Their permission', style: ChurchType.cardTitle),
                      for (final b in ConsentBasis.values)
                        RadioListTile<ConsentBasis>(
                          key: Key('consent-${b.wire}'),
                          value: b,
                          contentPadding: EdgeInsets.zero,
                          title: Text(b.label),
                        ),
                    ],
                  ),
                ),
                if (_consentError != null)
                  Text(
                    _consentError!,
                    key: const Key('consent-error'),
                    style: ChurchType.secondary.copyWith(color: c.redFg),
                  ),
                TextField(
                  key: const Key('add-member-phone'),
                  controller: _phone,
                  readOnly: s.busy,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Contact number (optional, with country code)',
                    helperText:
                        'A contact route only; it never signs anyone in.',
                    errorText:
                        _phoneError ??
                        (server.keys.any((k) => k.startsWith('contact_route'))
                            ? 'Check the contact number and whose it is.'
                            : null),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButton<ContactOwner>(
                  key: const Key('add-member-owner'),
                  value: _owner,
                  items: [
                    for (final o in ContactOwner.values)
                      DropdownMenuItem(value: o, child: Text(o.label)),
                  ],
                  onChanged: s.busy
                      ? null
                      : (v) => setState(() => _owner = v ?? _owner),
                ),
                if (_owner != ContactOwner.member)
                  TextField(
                    key: const Key('add-member-holder'),
                    controller: _holder,
                    readOnly: s.busy,
                    decoration: const InputDecoration(
                      labelText: 'Whose number is it? (e.g. Daughter)',
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    FocusRing(
                      child: FilledButton(
                        key: const Key('add-member-save'),
                        onPressed: s.busy ? null : _create,
                        child: const Text('Add member record'),
                      ),
                    ),
                    FocusRing(
                      child: OutlinedButton(
                        key: const Key('add-member-cancel'),
                        onPressed: s.busy
                            ? null
                            : () => setState(() => _adding = false),
                        child: const Text('Cancel'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: ChurchGeometry.sectionGap),
        ],
        if (result is AccessReadOk<MemberSearchPage> && shown > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '$shown ${shown == 1 ? 'member' : 'members'} shown'
              '${s.membersNext == null ? '' : ', more below'}. Choose one '
              'for their roles, holds and membership.',
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ),
        // The handoff's All members: the table, and the chosen member's
        // panel on its right (above it when the window is narrow), both
        // starting on one line.
        LayoutBuilder(
          builder: (context, box) {
            if (panel == null) return list;
            if (box.maxWidth >= 1000) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: list),
                  const SizedBox(width: 24),
                  SizedBox(width: 340, child: panel),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [panel, const SizedBox(height: 16), list],
            );
          },
        ),
      ],
    );
  }
}

/// Reclaim a phone username someone else registered first (F1).
class _ReclaimSection extends ConsumerStatefulWidget {
  const _ReclaimSection({required this.state});
  final ReviewState state;

  @override
  ConsumerState<_ReclaimSection> createState() => _ReclaimSectionState();
}

class _ReclaimSectionState extends ConsumerState<_ReclaimSection> {
  final _phone = TextEditingController();
  IdentityCheck? _check;
  ReclaimReason? _reason;
  String? _phoneError;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  void _send() {
    final r = normalizePhoneUsername(_phone.text, defaultDialingCountry);
    setState(
      () => _phoneError = r.value == null
          ? 'Enter the number with its country code.'
          : null,
    );
    if (r.value == null || _check == null) return;
    ref
        .read(membershipReviewProvider.notifier)
        .reclaim(r.value!, _check!, reason: _reason);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = widget.state;
    return _Card(
      key: const Key('reclaim-form'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Use this when a person cannot create an account because someone '
            'else registered their number first. Check who they are first. '
            'The other account is not deleted or merged: it loses the number, '
            'is blocked from signing in and its open request is withdrawn. A '
            'number used by a linked member account is refused; unlink that '
            'account first if that is right.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('reclaim-phone'),
            controller: _phone,
            readOnly: s.busy,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Phone username with country code',
              errorText: _phoneError,
            ),
          ),
          const SizedBox(height: 12),
          _identityCheckPicker(
            keyPrefix: 'reclaim',
            value: _check,
            enabled: !s.busy,
            onChanged: (v) => setState(() => _check = v),
          ),
          DropdownButton<ReclaimReason>(
            key: const Key('reclaim-reason'),
            hint: const Text('Reason (optional)'),
            value: _reason,
            items: [
              for (final r in ReclaimReason.values)
                DropdownMenuItem(value: r, child: Text(r.label)),
            ],
            onChanged: s.busy ? null : (v) => setState(() => _reason = v),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: FilledButton(
                key: const Key('reclaim-send'),
                onPressed: s.busy || _check == null ? null : _send,
                child: const Text('Release this username'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// All members as a table: rules and alignment, 12 px grey sentence-case
/// headers, one status mark per row (the account). A row opens the member's
/// detail panel (roles, unlink, hold, membership). Below 640 px each member
/// is a two-line row instead.
class _MemberTable extends StatelessWidget {
  const _MemberTable({
    required this.members,
    required this.roles,
    required this.selectedId,
    required this.onSelect,
  });

  final List<MemberRecord> members;

  /// Each member's roles from the Roles & access roster; null while it is
  /// read (or when it can't be), shown as a grey dash.
  final Map<String, List<String>>? roles;
  final String? selectedId;
  final void Function(MemberRecord m) onSelect;

  static const _columns = [
    StaffColumn('Name', flex: 5),
    StaffColumn('Roles', flex: 3),
    StaffColumn('Account', flex: 2),
    StaffColumn('', width: 20),
  ];

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('member-table'),
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 640;
          return StaffTableFrame(
            children: [
              if (wide) const StaffTableHeader(columns: _columns),
              for (var i = 0; i < members.length; i++)
                _row(context, members[i], wide: wide, divider: i > 0),
            ],
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context,
    MemberRecord m, {
    required bool wide,
    required bool divider,
  }) {
    final c = ChurchColors.of(context);
    final routes = m.contactRoutes;
    final subline = [
      if (routes.isNotEmpty)
        '${routes.first.phone}'
            '${routes.first.owner == ContactOwner.member ? '' : ' (${routes.first.holderLabel ?? routes.first.owner.label})'}'
            '${routes.length > 1 ? ' +${routes.length - 1}' : ''}'
      else
        'No contact number',
      if (m.isSynthetic) 'Synthetic test record',
    ].join(' · ');
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          m.displayName,
          style: ChurchType.staffBody.copyWith(
            color: c.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          subline,
          style: ChurchType.secondary.copyWith(
            color: c.muted,
            fontSize: 13,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
    final held = roles?[m.memberId];
    final rolesText = roles == null
        ? Text('—', style: ChurchType.staffBody.copyWith(color: c.muted))
        : Text(
            held == null || held.isEmpty
                ? 'Member'
                : held.map(ChurchRoles.label).join(', '),
            style: ChurchType.secondary.copyWith(
              color: held == null || held.isEmpty ? c.muted : c.ink,
            ),
          );
    final account = StatusLabel(
      label: _accountLabel(m.account),
      tone: _accountTone(m.account),
    );
    final selected = selectedId == m.memberId;
    final chevron = ExcludeSemantics(
      child: Icon(
        selected ? Icons.chevron_left : Icons.chevron_right,
        size: 20,
        color: c.muted,
      ),
    );
    return StaffTableRow(
      key: Key('member-record-${m.memberId}'),
      divider: divider,
      selected: selected,
      onTap: () => onSelect(m),
      semanticLabel:
          '${m.displayName}, ${_accountLabel(m.account)}. '
          '${selected ? 'Close details' : 'Open details'}',
      padding: EdgeInsets.fromLTRB(wide ? 20 : 16, 10, 14, 10),
      minHeight: 56,
      child: wide
          ? StaffColumnsRow(
              columns: _columns,
              cells: [name, rolesText, account, chevron],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      name,
                      const SizedBox(height: 2),
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontSize: 13),
                        child: rolesText,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                account,
                const SizedBox(width: 4),
                chevron,
              ],
            ),
    );
  }
}
