import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/access_controllers.dart';
import '../application/providers.dart';
import '../domain/access_grants.dart';

/// Story 2.3: asks the server for the caller's grants again whenever the
/// shell shows a new destination (each navigation builds a new shell) and
/// when the app or tab returns to the foreground, so navigation reflects a
/// grant or revocation made elsewhere by the next protected request.
class AccessRefresher extends ConsumerStatefulWidget {
  const AccessRefresher({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AccessRefresher> createState() => _AccessRefresherState();
}

class _AccessRefresherState extends ConsumerState<AccessRefresher> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    // Every shell (navigation) asks again. A read already in flight is
    // followed by one more (the controller coalesces), so a navigation is
    // never answered by a read that started before it.
    Future.microtask(_refresh);
  }

  void _refresh() {
    if (!mounted || ref.read(accountProvider).accountId == null) return;
    ref.read(myAccessProvider.notifier).refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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

(String, String, StatusTone) _denialText(AccessDenial d, {String? area}) =>
    switch (d) {
      AccessDenial.signedOut => (
        'Not signed in',
        'Sign in with your phone number and password.',
        StatusTone.info,
      ),
      AccessDenial.untrustedSession => (
        'Please sign in again',
        'This sign-in is no longer valid.',
        StatusTone.warning,
      ),
      AccessDenial.notLinked => (
        'No member access yet',
        'This account is not yet linked to a church member record.',
        StatusTone.info,
      ),
      AccessDenial.reviewRequired => (
        'Access review required',
        'Your access needs a check by the church before it can continue. '
            'Please contact the church office for help.',
        StatusTone.warning,
      ),
      AccessDenial.notGranted => (
        'Not available to you',
        area == null
            ? 'Your account does not have this permission.'
            : '$area needs a permission your account does not have now. '
                  'Permissions are checked by the server each time.',
        StatusTone.neutral,
      ),
      AccessDenial.unavailable => (
        'Not available yet',
        'This is not available here yet.',
        StatusTone.neutral,
      ),
    };

Widget _readProblem<T>(AccessRead<T> r, String what, {String? area}) =>
    switch (r) {
      AccessReadOk() => const SizedBox.shrink(),
      AccessReadDenied(:final denial) => Builder(
        builder: (context) {
          final (title, message, tone) = _denialText(denial, area: area);
          return RequestStateBanner(
            key: Key('access-denied-${denial.name}'),
            tone: tone,
            icon: Icons.lock_outline,
            title: title,
            message: message,
          );
        },
      ),
      AccessReadFailed(:final unreachable) => RequestStateBanner(
        key: const Key('access-failed'),
        tone: StatusTone.danger,
        icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
        title: unreachable ? 'No connection' : 'Couldn\'t load $what',
        message: unreachable
            ? 'We couldn\'t reach the church server. Nothing is shown until it answers.'
            : 'The server answered in an unexpected way. Try again later.',
      ),
    };

/// "My access": the caller's current roles and scopes, as the server says.
class MyAccessScreen extends ConsumerWidget {
  const MyAccessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(myAccessProvider);
    final grants = s.grants;
    final children = <Widget>[];
    if (s.result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('access-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Checking your access…',
          message: 'The server checks your permissions every time.',
        ),
      );
    } else if (grants == null) {
      children.add(_readProblem(s.result!, 'your access'));
    } else {
      children.addAll([
        Semantics(
          header: true,
          child: Text(
            'Roles',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 8),
        if (grants.roles.isEmpty)
          const Text(
            'No staff roles. You have member access.',
            key: Key('no-roles'),
          )
        else
          Wrap(
            key: const Key('my-roles'),
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in grants.roles)
                StatusLabel(
                  key: Key('my-role-$r'),
                  label: ChurchRoles.label(r),
                  tone: StatusTone.info,
                ),
            ],
          ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        Semantics(
          header: true,
          child: Text(
            'Assigned scopes',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 8),
        if (grants.scopes.isEmpty)
          const Text('None.', key: Key('no-scopes'))
        else
          for (final sc in grants.scopes)
            Text(
              '${sc.scopeKind}: ${sc.scopeId}',
              key: Key('my-scope-${sc.scopeId}'),
            ),
        const SizedBox(height: 12),
        Text(
          'Menus follow these permissions, but the server checks them again '
          'on every request. A change made by an Admin applies at once.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ]);
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: OutlinedButton.icon(
            key: const Key('refresh-access'),
            onPressed: s.loading
                ? null
                : () => ref.read(myAccessProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),
        ),
      ),
    ]);
    return _page(context, 'My access', children);
  }
}

/// Staff web, Admin only: grant and remove roles (and remove scopes) with
/// audited server commands. Shown only when the server's current answer says
/// Admin; the server refuses every action otherwise.
class GrantAdminScreen extends ConsumerStatefulWidget {
  const GrantAdminScreen({super.key});

  @override
  ConsumerState<GrantAdminScreen> createState() => _GrantAdminScreenState();
}

class _GrantAdminScreenState extends ConsumerState<GrantAdminScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the screen asks the server again.
    if (ref.read(grantAdminProvider).result != null) Future.microtask(_reload);
  }

  void _reload() {
    if (mounted) ref.read(grantAdminProvider.notifier).reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(grantAdminProvider);
    final ctl = ref.read(grantAdminProvider.notifier);
    // Rebuild when the caller's own member id is known (self-grant buttons).
    ref.watch(myAccessProvider.select((a) => a.grants?.memberId));
    final children = <Widget>[];
    final notice = s.notice;
    if (s.pending case final p?) {
      children.add(
        RequestStateBanner(
          key: const Key('grant-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              '${p.grant ? 'Granting' : 'Removing'} ${p.label} '
              '${p.grant ? 'to' : 'from'} ${p.memberName}.',
        ),
      );
    } else if (notice != null) {
      children.add(_noticeBanner(notice, s.noticeAction, ctl));
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    final result = s.result;
    if (result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('roster-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading members…',
          message: 'Only an Admin can see this list.',
        ),
      );
    } else if (result is! AccessReadOk<GrantRoster> && s.members.isEmpty) {
      children.add(_readProblem(result, 'the members', area: 'Roles & access'));
    } else {
      for (final m in s.members) {
        children
          ..add(_memberCard(context, m, s, ctl))
          ..add(const SizedBox(height: 12));
      }
      if (s.next != null) {
        children.add(
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: OutlinedButton(
                key: const Key('roster-more'),
                onPressed: s.loading ? null : ctl.loadMore,
                child: const Text('Show more members'),
              ),
            ),
          ),
        );
      }
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: OutlinedButton.icon(
            key: const Key('roster-reload'),
            onPressed: s.loading || s.busy ? null : ctl.reload,
            icon: const Icon(Icons.refresh),
            label: const Text('Reload'),
          ),
        ),
      ),
    ]);
    return _page(context, 'Roles & access', children);
  }

  Widget _noticeBanner(
    GrantNotice n,
    GrantAction? a,
    GrantAdminController ctl,
  ) {
    final who = a?.memberName ?? 'the member';
    final what = a?.label ?? 'the role';
    final (tone, title, message) = switch (n) {
      GrantNotice.granted => (
        StatusTone.success,
        'Granted',
        '$what was granted to $who. It applies at their next request.',
      ),
      GrantNotice.revoked => (
        StatusTone.success,
        'Removed',
        '$what was removed from $who. It stops at their next request.',
      ),
      GrantNotice.changedElsewhere => (
        StatusTone.warning,
        'Changed elsewhere',
        '$who\'s permissions changed in another tab or by another Admin. '
            'The list was reloaded; check it and try again.',
      ),
      GrantNotice.lastAdmin => (
        StatusTone.warning,
        'The last Admin can\'t be removed',
        'Grant Admin to another member with access first, so the church is '
            'never left without an Admin.',
      ),
      GrantNotice.selfGrant => (
        StatusTone.warning,
        'Not allowed',
        'Another Admin must grant you a role or scope. Nothing was changed.',
      ),
      GrantNotice.noLongerAdmin => (
        StatusTone.warning,
        'Not allowed',
        'Your account no longer has Admin access. Nothing was changed.',
      ),
      GrantNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid. Nothing was changed.',
      ),
      GrantNotice.roleUnavailable => (
        StatusTone.neutral,
        'Not available yet',
        '$what can\'t be granted here until the church approves the setting '
            'it needs.',
      ),
      GrantNotice.refused => (
        StatusTone.warning,
        'Not changed',
        'The server refused the change. The list was reloaded.',
      ),
      GrantNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed',
        'We don\'t know whether the change to $who was made. Check again: '
            'the same request is sent, so it can\'t apply twice.',
      ),
      GrantNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured, so nothing was sent.',
      ),
    };
    return RequestStateBanner(
      key: Key('grant-notice-${n.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (n == GrantNotice.unconfirmed)
          BannerAction(
            'Check again',
            ctl.checkAgain,
            key: const Key('grant-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          ctl.dismissNotice,
          key: const Key('grant-dismiss'),
        ),
      ],
    );
  }

  Widget _memberCard(
    BuildContext context,
    RosterMember m,
    GrantAdminState s,
    GrantAdminController ctl,
  ) {
    final c = ChurchColors.of(context);
    final (accountLabel, accountTone) = switch (m.account) {
      AccountStanding.appAccount => ('App account', StatusTone.success),
      AccountStanding.noLogin => ('No login', StatusTone.neutral),
      AccountStanding.accessReview => ('Access review', StatusTone.warning),
    };
    return Container(
      key: Key('member-${m.memberId}'),
      padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
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
                  m.displayName,
                  style: ChurchType.cardTitle.copyWith(color: c.ink),
                ),
              ),
              StatusLabel(label: accountLabel, tone: accountTone),
              if (m.adminViaFallback)
                const StatusLabel(
                  key: Key('admin-via-fallback'),
                  label: 'Admin by operator fallback',
                  tone: StatusTone.warning,
                ),
              if (m.isSynthetic)
                const StatusLabel(
                  label: 'Synthetic test record',
                  tone: StatusTone.neutral,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final r in s.roles) _roleButton(m, r, s, ctl)],
          ),
          if (m.grants.scopes.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final sc in m.grants.scopes)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${sc.scopeKind}: ${sc.scopeId}'),
                  FocusRing(
                    child: TextButton(
                      key: Key('remove-scope-${m.memberId}-${sc.scopeId}'),
                      onPressed: s.busy ? null : () => ctl.revokeScope(m, sc),
                      child: const Text('Remove'),
                    ),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _roleButton(
    RosterMember m,
    RoleOption r,
    GrantAdminState s,
    GrantAdminController ctl,
  ) {
    final held = m.grants.hasRole(r.role);
    final label = ChurchRoles.label(r.role);
    final key = Key('role-${m.memberId}-${r.role}');
    // Separation of duty: the server refuses a grant to the acting Admin.
    final self = ref.read(myAccessProvider).grants?.memberId == m.memberId;
    final enabled = !s.busy && (held || (r.available && !self));
    // Text says the state; colour is never the only signal.
    return FocusRing(
      child: held
          ? FilledButton.icon(
              key: key,
              onPressed: enabled
                  ? () => ctl.setRole(m, r.role, grant: false)
                  : null,
              icon: const Icon(Icons.check),
              label: Text('$label · Remove'),
            )
          : OutlinedButton(
              key: key,
              onPressed: enabled
                  ? () => ctl.setRole(m, r.role, grant: true)
                  : null,
              child: Text(
                !r.available
                    ? '$label (not granted here)'
                    : self
                    ? '$label (another Admin grants this)'
                    : 'Grant $label',
              ),
            ),
    );
  }
}
