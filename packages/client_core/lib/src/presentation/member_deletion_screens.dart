import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/member_deletion_controllers.dart';
import '../application/providers.dart';
import '../domain/access_grants.dart';
import '../domain/member_deletion.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;
import 'shell_routing.dart';

const _gap = SizedBox(height: ChurchGeometry.sectionGap);

Widget _page(BuildContext context, String title, List<Widget> children) {
  final c = ChurchColors.of(context);
  final layout = ChurchLayout.of(context);
  return Scaffold(
    appBar: AppBar(title: Text(title)),
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

// ---------------------------------------------------------------------------
// Mobile: delete my account
// ---------------------------------------------------------------------------

/// Story 2.11, mobile: the member deletes their own account. Access ends at
/// once (every device is signed out and the account can no longer sign in);
/// the church then erases the data step by step.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _password = TextEditingController();
  bool _understood = false;
  bool _show = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  MyDeletionController get _ctl => ref.read(myDeletionProvider.notifier);

  void _submit() {
    if (!_understood || _password.text.isEmpty) return;
    final pw = _password.text;
    _password.clear();
    _ctl.request(pw);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(myDeletionProvider);
    final signedIn =
        ref.watch(accountProvider.select((a) => a.accountId)) != null;
    final children = <Widget>[];
    if (s.requested) {
      children.addAll([
        RequestStateBanner(
          key: const Key('delete-requested'),
          tone: StatusTone.success,
          icon: Icons.check_circle_outline,
          title: 'Your account is being deleted',
          message:
              'You were signed out on every device and this account can no '
              'longer sign in. The church now erases your membership details, '
              'cell membership and app account. Records the church must keep '
              'are kept without your name.',
          actions: [
            BannerAction(
              'Done',
              () => context.go(ClientPaths.status),
              key: const Key('delete-done'),
              primary: true,
            ),
          ],
        ),
      ]);
      return _page(context, 'Delete my account', children);
    }
    if (!signedIn) {
      children.add(
        const Text(
          'Sign in with your phone number and password to delete your account.',
          key: Key('delete-signed-out'),
        ),
      );
      return _page(context, 'Delete my account', children);
    }
    final notice = s.notice;
    if (notice != null) children.addAll([_noticeBanner(notice), _gap]);
    children.addAll([
      Text(
        'Deleting your account cannot be undone.',
        style: ChurchType.cardTitle.copyWith(color: c.ink),
      ),
      const SizedBox(height: 8),
      const Text(
        '• You are signed out on every device at once, and you cannot sign '
        'in with this account again.\n'
        '• Your church membership ends and your roles are removed.\n'
        '• Your membership details, cell membership and app account are '
        'erased. Church records that must be kept stay without your name.\n'
        '• If you look after something for the church, it is handed over '
        'first; that can delay the erasure, never the sign-out.',
      ),
      _gap,
      CheckboxListTile(
        key: const Key('delete-understand'),
        value: _understood,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: const Text('I understand that this cannot be undone'),
        onChanged: s.busy
            ? null
            : (v) => setState(() => _understood = v ?? false),
      ),
      const SizedBox(height: 12),
      RevealOnFocus(
        child: TextField(
          key: const Key('delete-password-field'),
          controller: _password,
          readOnly: s.busy,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => s.busy ? null : _submit(),
          decoration: InputDecoration(
            labelText: 'Your password',
            helperText: 'To confirm it is you.',
            suffixIcon: FocusRing(
              child: IconButton(
                key: const Key('delete-show-password'),
                tooltip: _show ? 'Hide password' : 'Show password',
                icon: Icon(
                  _show
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
          ),
        ),
      ),
      _gap,
      FocusRing(
        child: FilledButton(
          key: const Key('delete-account-submit'),
          onPressed: s.busy || !_understood || _password.text.isEmpty
              ? null
              : _submit,
          child: Text(s.busy ? 'Deleting…' : 'Delete my account'),
        ),
      ),
    ]);
    return _page(context, 'Delete my account', children);
  }

  Widget _noticeBanner(MyDeletionNotice notice) {
    final (tone, title, message) = switch (notice) {
      MyDeletionNotice.wrongPassword => (
        StatusTone.danger,
        'Password not accepted',
        'Check your password and try again.',
      ),
      MyDeletionNotice.rateLimited => (
        StatusTone.warning,
        'Too many attempts',
        'Wait a little, then try again.',
      ),
      MyDeletionNotice.unreachable => (
        StatusTone.danger,
        'No connection',
        'Nothing was changed. Try again when you are online.',
      ),
      MyDeletionNotice.reauthenticate => (
        StatusTone.warning,
        'Confirm your password again',
        'Enter your password once more, then delete.',
      ),
      MyDeletionNotice.lastAdmin => (
        StatusTone.danger,
        'You are the last Admin',
        'Give another member the Admin role first, so the church is not '
            'left without one.',
      ),
      MyDeletionNotice.alreadyRequested => (
        StatusTone.info,
        'Already requested',
        'This account is already being deleted.',
      ),
      MyDeletionNotice.notMember => (
        StatusTone.warning,
        'Not available for this account',
        'Contact the church office: staff can delete a membership for you.',
      ),
      MyDeletionNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      MyDeletionNotice.notAccepting => (
        StatusTone.neutral,
        'Not available right now',
        'Nothing was changed. Try again later or contact the church office.',
      ),
      MyDeletionNotice.invalid || MyDeletionNotice.refused => (
        StatusTone.danger,
        'Refused',
        'The server refused the request. Nothing was changed.',
      ),
      MyDeletionNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed yet',
        'We could not confirm whether the request arrived. Check again; it '
            'is sent once. If you can no longer sign in, the deletion has '
            'started.',
      ),
      MyDeletionNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured.',
      ),
    };
    return RequestStateBanner(
      key: Key('delete-notice-${notice.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (notice == MyDeletionNotice.unconfirmed)
          BannerAction(
            'Check again',
            _ctl.checkAgain,
            key: const Key('delete-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          _ctl.dismissNotice,
          key: const Key('delete-dismiss'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Staff web (Admin): member deletions
// ---------------------------------------------------------------------------

/// Story 2.11, staff web (Admin): every deletion with its steps, and the
/// staff route for a member who cannot use the app (no login, a held login,
/// or a deactivated membership) after an identity check. Staff never see a
/// password, a contact detail or any care or finance content.
class MemberDeletionScreen extends ConsumerStatefulWidget {
  const MemberDeletionScreen({super.key});

  @override
  ConsumerState<MemberDeletionScreen> createState() =>
      _MemberDeletionScreenState();
}

class _MemberDeletionScreenState extends ConsumerState<MemberDeletionScreen> {
  final _checks = <String, IdentityCheck>{};
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  MemberDeletionAdminController get _ctl =>
      ref.read(memberDeletionAdminProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(memberDeletionAdminProvider);
    final children = <Widget>[
      Text(
        'A member deletes their own account in the app. Here an Admin asks '
        'for the deletion of a member who cannot use the app, after checking '
        'who they are. Access ends at once; the account and the data are then '
        'erased step by step.',
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
          key: Key('deletions-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading…',
          message: 'Waiting for the server.',
        ),
      );
    } else if (r is AccessReadDenied<MemberDeletionOverview>) {
      children.add(
        RequestStateBanner(
          key: Key('deletions-denied-${r.denial.name}'),
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
          title: 'Not available',
          message: r.denial == AccessDenial.notGranted
              ? 'Only an Admin can see and request member deletions.'
              : 'Sign in again, or contact the church office.',
        ),
      );
    } else if (r is AccessReadFailed<MemberDeletionOverview>) {
      children.add(
        RequestStateBanner(
          key: const Key('deletions-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: r.unreachable ? 'No connection' : 'Couldn\'t load',
          message: 'Nothing is shown until the server answers.',
          actions: [
            BannerAction(
              'Try again',
              _ctl.reload,
              key: const Key('deletions-retry'),
            ),
          ],
        ),
      );
    } else if (o != null) {
      if (!o.accepting) {
        children.addAll([
          const RequestStateBanner(
            key: Key('deletions-erasure-gated'),
            tone: StatusTone.neutral,
            title: 'Erasure waits for the church\'s retention decision',
            message:
                'Requests still close access at once. Erasing data waits until '
                'the retention and backup periods are approved.',
          ),
          _gap,
        ]);
      }
      children
        ..add(
          Semantics(
            header: true,
            child: Text('Deletions', style: ChurchType.cardTitle),
          ),
        )
        ..add(const SizedBox(height: 8));
      if (o.deletions.isEmpty) {
        children.add(
          const Text('No member is being deleted.', key: Key('deletions-none')),
        );
      }
      for (final d in o.deletions) {
        children.addAll([_deletion(context, d), const SizedBox(height: 12)]);
      }
      children
        ..add(_gap)
        ..add(
          Semantics(
            header: true,
            child: Text(
              'Delete a member who cannot use the app',
              style: ChurchType.cardTitle,
            ),
          ),
        )
        ..add(const SizedBox(height: 8));
      for (final m in o.deactivated) {
        children.addAll([
          _target(
            context,
            key: 'deactivated-${m.memberId}',
            memberId: m.memberId,
            name: m.displayName,
            revision: m.revision,
            account: m.account,
            own: m.ownMember,
            synthetic: m.isSynthetic,
            busy: s.busy,
            note: 'Membership deactivated',
          ),
          const SizedBox(height: 12),
        ]);
      }
      children.addAll(_find(context, s));
    }
    return _page(context, 'Member deletions', children);
  }

  Widget _card(BuildContext context, Key key, List<Widget> children) {
    final c = ChurchColors.of(context);
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

  Widget _synthetic(bool isSynthetic) => isSynthetic
      ? const Padding(
          padding: EdgeInsets.only(top: 8),
          child: StatusLabel(
            label: 'Synthetic test record',
            tone: StatusTone.neutral,
          ),
        )
      : const SizedBox.shrink();

  static String _waiting(String reason) => switch (reason) {
    'handover_pending' =>
      'Waiting for a handover in another section before erasing.',
    'policy_gate_closed' =>
      'Erasure waits for the church\'s retention decision.',
    'restore_held' => 'Waiting until a restored backup is reconciled.',
    _ => 'Waiting.',
  };

  Widget _deletion(BuildContext context, MemberDeletion d) {
    return _card(context, Key('deletion-${d.deletionId}'), [
      _name(context, d.displayName),
      const SizedBox(height: 4),
      StatusLabel(
        key: Key('deletion-state-${d.deletionId}'),
        label: d.completed
            ? 'Deleted'
            : 'Deleting (${d.doneSteps} of ${d.steps.length} steps)',
        tone: d.completed ? StatusTone.success : StatusTone.warning,
      ),
      const SizedBox(height: 8),
      Text(switch (d.origin) {
        'member_request' => 'Asked for in the app',
        'staff_request' => 'Asked for at the church office',
        _ => 'Re-applied after a restore',
      }),
      Text(d.hadAccount ? 'Had an app account' : 'No app account'),
      if (d.waitingReason != null)
        Text(
          _waiting(d.waitingReason!),
          key: Key('deletion-waiting-${d.deletionId}'),
        ),
      if (d.pendingObligations > 0)
        Text('${d.pendingObligations} handover(s) still pending'),
      _synthetic(d.isSynthetic),
      const SizedBox(height: 8),
      for (final step in d.steps)
        Row(
          key: Key('deletion-${d.deletionId}-step-${step.step}'),
          children: [
            Icon(
              step.done
                  ? Icons.check_circle_outline
                  : step.state == 'failed'
                  ? Icons.error_outline
                  : Icons.radio_button_unchecked,
              size: 18,
              semanticLabel: step.done ? 'done' : step.state,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                step.attempts > 1
                    ? '${step.label} (${step.attempts} attempts)'
                    : step.label,
              ),
            ),
          ],
        ),
    ]);
  }

  Widget _target(
    BuildContext context, {
    required String key,
    required String memberId,
    required String name,
    required int revision,
    required AccountStanding account,
    required bool own,
    required bool synthetic,
    required bool busy,
    String? note,
  }) {
    final check = _checks[memberId];
    final usesApp = account == AccountStanding.appAccount;
    final enabled = !busy && !own && !usesApp;
    return _card(context, Key('deletion-target-$key'), [
      _name(context, name),
      if (note != null) Text(note),
      Text(switch (account) {
        AccountStanding.noLogin => 'No app account',
        AccountStanding.accessReview => 'App sign-in closed or in review',
        AccountStanding.appAccount =>
          'Uses the app: they delete their account there',
      }),
      _synthetic(synthetic),
      if (own) ...[
        const SizedBox(height: 8),
        const Text('This is your own record: delete it in the app.'),
      ],
      const SizedBox(height: 12),
      RadioGroup<IdentityCheck>(
        groupValue: check,
        onChanged: (v) {
          if (!enabled || v == null) return;
          setState(() => _checks[memberId] = v);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Identity check', style: ChurchType.cardTitle),
            for (final k in IdentityCheck.values)
              RadioListTile<IdentityCheck>(
                key: Key('deletion-$memberId-check-${k.wire}'),
                value: k,
                enabled: enabled,
                contentPadding: EdgeInsets.zero,
                title: Text(k.label),
              ),
          ],
        ),
      ),
      const Text(
        'This cannot be undone: access ends at once and the member\'s data is '
        'erased.',
      ),
      const SizedBox(height: 12),
      FocusRing(
        child: FilledButton(
          key: Key('deletion-request-$memberId'),
          onPressed: !enabled || check == null
              ? null
              : () => _ctl.requestDeletion(
                  memberId: memberId,
                  revision: revision,
                  displayName: name,
                  check: check,
                ),
          child: const Text('Delete member'),
        ),
      ),
    ]);
  }

  List<Widget> _find(BuildContext context, MemberDeletionAdminState s) {
    final found = s.search;
    return [
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('deletion-search-field'),
              controller: _query,
              decoration: const InputDecoration(
                labelText: 'Find an approved member by name or contact number',
              ),
              onSubmitted: _ctl.searchMembers,
            ),
          ),
          const SizedBox(width: 12),
          FocusRing(
            child: OutlinedButton(
              key: const Key('deletion-search'),
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
          _target(
            context,
            key: 'found-${m.memberId}',
            memberId: m.memberId,
            name: m.displayName,
            revision: m.revision,
            account: m.account,
            own: false,
            synthetic: m.isSynthetic,
            busy: s.busy,
          ),
          const SizedBox(height: 12),
        ],
      if (found is AccessReadOk<List<MemberRecord>> && found.value.isEmpty)
        const Text('No member found.', key: Key('deletion-none-found')),
    ];
  }

  Widget _noticeBanner(DeletionAdminNotice notice, MemberDeletionAdminState s) {
    final who = s.subject ?? 'the member';
    final (tone, title, message) = switch (notice) {
      DeletionAdminNotice.requested => (
        StatusTone.success,
        'Deletion started',
        '$who can no longer sign in or be shown as a member. The data is now '
            'erased step by step; follow it below.',
      ),
      DeletionAdminNotice.lastAdmin => (
        StatusTone.danger,
        'Last Admin',
        '$who is the church\'s last usable Admin. Give another member the '
            'Admin role first.',
      ),
      DeletionAdminNotice.alreadyRequested => (
        StatusTone.info,
        'Already being deleted',
        '$who is already being deleted.',
      ),
      DeletionAdminNotice.canUseApp => (
        StatusTone.warning,
        'They can use the app',
        '$who can still sign in: they delete their account in the app. If '
            'they cannot, disable the login first (Membership status).',
      ),
      DeletionAdminNotice.selfAction => (
        StatusTone.warning,
        'Not for your own record',
        'Delete your own account in the app.',
      ),
      DeletionAdminNotice.changedElsewhere => (
        StatusTone.info,
        'Changed elsewhere',
        'The record changed since you loaded it. Search again before acting.',
      ),
      DeletionAdminNotice.noLongerAdmin => (
        StatusTone.danger,
        'Not allowed',
        'Your account no longer holds the Admin role.',
      ),
      DeletionAdminNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      DeletionAdminNotice.notAccepting => (
        StatusTone.neutral,
        'Not available here',
        'This can\'t be done right now. Nothing was changed.',
      ),
      DeletionAdminNotice.invalid => (
        StatusTone.danger,
        'Check the form',
        'Choose how you checked the member\'s identity.',
      ),
      DeletionAdminNotice.notFound => (
        StatusTone.info,
        'Not found',
        'The record no longer exists.',
      ),
      DeletionAdminNotice.refused => (
        StatusTone.danger,
        'Refused',
        'The server refused the request.',
      ),
      DeletionAdminNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed yet',
        'We couldn\'t confirm whether the request arrived. Check again; it '
            'is sent once.',
      ),
      DeletionAdminNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured.',
      ),
    };
    return RequestStateBanner(
      key: Key('deletion-notice-${notice.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (notice == DeletionAdminNotice.unconfirmed)
          BannerAction(
            'Check again',
            _ctl.checkAgain,
            key: const Key('deletion-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          _ctl.dismissNotice,
          key: const Key('deletion-dismiss'),
        ),
      ],
    );
  }
}
