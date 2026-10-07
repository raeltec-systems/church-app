import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/review_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/membership_application.dart';
import '../domain/membership_review.dart';
import '../domain/phone_username.dart';

/// Story 2.5, staff web, Admin only: membership applications (approve as a
/// new member, link to an existing member, ask for details, reject), member
/// records with and without a login (add a record, unlink an account), and
/// reclaiming a phone username someone else registered first. Shown only
/// while the server's current answer says Admin; the server refuses every
/// read and action otherwise. Duplicate candidates are a staff aid: nothing
/// is linked unless the Admin chooses to.
class MembershipReviewScreen extends ConsumerStatefulWidget {
  const MembershipReviewScreen({super.key});

  @override
  ConsumerState<MembershipReviewScreen> createState() =>
      _MembershipReviewScreenState();
}

enum _Section { applications, members, reclaim }

class _MembershipReviewScreenState
    extends ConsumerState<MembershipReviewScreen> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'review notice');
  _Section _section = _Section.applications;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
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
      children.addAll([
        SegmentedButton<_Section>(
          key: const Key('review-sections'),
          segments: [
            ButtonSegment(
              value: _Section.applications,
              label: Text('Applications (${s.applications.length})'),
            ),
            const ButtonSegment(
              value: _Section.members,
              label: Text('All members'),
            ),
            const ButtonSegment(
              value: _Section.reclaim,
              label: Text('Reclaim a username'),
            ),
          ],
          selected: {_section},
          onSelectionChanged: (v) {
            setState(() => _section = v.first);
            if (v.first == _Section.members && s.searchResult == null) {
              ctl.search(null);
            }
          },
        ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        switch (_section) {
          _Section.applications => _applications(context, s, ctl),
          _Section.members => _MembersSection(state: s),
          _Section.reclaim => _ReclaimSection(state: s),
        },
      ]);
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: OutlinedButton.icon(
            key: const Key('review-reload'),
            onPressed: s.loading || s.busy ? null : ctl.reload,
            icon: const Icon(Icons.refresh),
            label: const Text('Reload'),
          ),
        ),
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: const Text('Members & applications')),
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
      return const Text(
        'No applications are waiting.',
        key: Key('review-no-applications'),
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
          'ID and history are kept. They need to sign in again.',
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
          'approved into their sign-in details yet.',
    ),
    ReviewNotice.memberHeld => (
      StatusTone.warning,
      'Member on hold',
      'That member record is on hold and cannot be linked now.',
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
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        optional ? 'Identity check (optional)' : 'Identity check',
        style: ChurchType.cardTitle,
      ),
      for (final k in IdentityCheck.values)
        RadioListTile<IdentityCheck>(
          key: Key('$keyPrefix-check-${k.wire}'),
          value: k,
          contentPadding: EdgeInsets.zero,
          title: Text(k.label),
        ),
    ],
  ),
);

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
    return _Card(
      key: Key('application-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                header: true,
                child: Text(
                  app.fullName,
                  style: ChurchType.cardTitle.copyWith(color: c.ink),
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
          Text('Sign-in username (not verified): ${app.phoneUsername}'),
          Text(cell),
          if (a.priorNotApproved > 0)
            Text(
              'Earlier requests from this account not approved: '
              '${a.priorNotApproved}',
              key: Key('prior-$id'),
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
            Container(
              key: Key('duplicates-$id'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Possible existing member records (staff only)',
                    style: ChurchType.cardTitle.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 4),
                  for (final cand in a.candidates)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(cand.displayName),
                          StatusLabel(
                            label: _accountLabel(cand.account),
                            tone: _accountTone(cand.account),
                          ),
                          for (final sig in cand.signals)
                            StatusLabel(
                              label: DuplicateCandidate.signalLabel(sig),
                              tone: StatusTone.warning,
                            ),
                          FocusRing(
                            child: TextButton(
                              key: Key('link-$id-${cand.memberId}'),
                              onPressed:
                                  canDecide && checked && cand.linkEligible
                                  ? () => ctl.link(a, cand.memberId, _check!)
                                  : null,
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
          _identityCheckPicker(
            keyPrefix: 'app-$id',
            value: _check,
            enabled: canDecide,
            onChanged: (v) => setState(() => _check = v),
          ),
          if (!checked)
            Text(
              'Record how you checked who they are before approving or '
              'linking.',
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
                  child: const Text('Reject'),
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
  final Map<String, UnlinkReason> _unlinkReasons = {};

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('member-query'),
                controller: _query,
                decoration: const InputDecoration(
                  labelText: 'Search by name or contact number',
                ),
                onSubmitted: (v) => ctl.search(v),
              ),
            ),
            const SizedBox(width: 8),
            FocusRing(
              child: OutlinedButton(
                key: const Key('member-search'),
                onPressed: s.searching ? null : () => ctl.search(_query.text),
                child: const Text('Search'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (result != null && result is! AccessReadOk<MemberSearchPage>)
          _readProblem(result)
        else if (result != null && s.members.isEmpty)
          const Text('No members match.', key: Key('member-none')),
        for (final m in s.members) ...[
          _Card(
            key: Key('member-record-${m.memberId}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      m.displayName,
                      style: ChurchType.cardTitle.copyWith(color: c.ink),
                    ),
                    StatusLabel(
                      label: _accountLabel(m.account),
                      tone: _accountTone(m.account),
                    ),
                    if (m.isSynthetic)
                      const StatusLabel(
                        label: 'Synthetic test record',
                        tone: StatusTone.neutral,
                      ),
                  ],
                ),
                for (final r in m.contactRoutes)
                  Text(
                    'Contact: ${r.phone} (${r.owner.label}'
                    '${r.holderLabel == null ? '' : ': ${r.holderLabel}'}). '
                    'Not a login.',
                  ),
                if (m.account != AccountStanding.noLogin) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<UnlinkReason>(
                        key: Key('unlink-reason-${m.memberId}'),
                        hint: const Text('Reason to unlink'),
                        value: _unlinkReasons[m.memberId],
                        items: [
                          for (final r in UnlinkReason.values)
                            DropdownMenuItem(value: r, child: Text(r.label)),
                        ],
                        onChanged: s.busy
                            ? null
                            : (v) => setState(() {
                                if (v != null) _unlinkReasons[m.memberId] = v;
                              }),
                      ),
                      FocusRing(
                        child: OutlinedButton(
                          key: Key('unlink-${m.memberId}'),
                          onPressed:
                              s.busy || _unlinkReasons[m.memberId] == null
                              ? null
                              : () =>
                                    ctl.unlink(m, _unlinkReasons[m.memberId]!),
                          child: const Text('Unlink account'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (s.membersNext != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: OutlinedButton(
                key: const Key('member-more'),
                onPressed: s.searching ? null : ctl.loadMoreMembers,
                child: const Text('Show more members'),
              ),
            ),
          ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        if (!_adding)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: FilledButton.icon(
                key: const Key('add-member-record'),
                onPressed: () => setState(() => _adding = true),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Add member record (no login)'),
              ),
            ),
          )
        else
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
