import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/user_management_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/credential_review.dart';
import '../domain/membership_lifecycle.dart';
import '../domain/membership_review.dart';
import '../domain/user_management.dart';
import 'user_profile_editor.dart';
import 'user_change_banner.dart';

class UserDirectoryScreen extends ConsumerStatefulWidget {
  const UserDirectoryScreen({
    super.key,
    this.memberId,
    required this.openArea,
    required this.selectLocation,
  });
  final String? memberId;
  final void Function(String area, String? memberId) openArea;
  final void Function(String? memberId) selectLocation;
  @override
  ConsumerState<UserDirectoryScreen> createState() =>
      _UserDirectoryScreenState();
}

class _UserDirectoryScreenState extends ConsumerState<UserDirectoryScreen> {
  final _query = TextEditingController();
  late final AppLifecycleListener _lifecycle;
  String? _scheduledMember;
  UserManagementController get ctl => ref.read(userManagementProvider.notifier);
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted) ctl.reload();
      },
    );
    Future.microtask(() {
      if (!mounted) return;
      final s = ref.read(userManagementProvider);
      _query.text = s.filter.query;
      if (s.directoryResult is AccessReadOk<UserDirectoryPage>) ctl.reload();
    });
  }

  @override
  void didUpdateWidget(UserDirectoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.memberId != widget.memberId) {
      _scheduledMember = null;
      if (widget.memberId == null) {
        Future.microtask(() {
          if (mounted) ctl.select(null);
        });
      }
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _query.dispose();
    super.dispose();
  }

  void _search({
    String? membership,
    String? account,
    String? role,
    bool clearRole = false,
  }) {
    final f = ref.read(userManagementProvider).filter;
    widget.selectLocation(null);
    ctl.search(
      UserFilter(
        query: _query.text,
        membership: membership ?? f.membership,
        account: account ?? f.account,
        role: clearRole ? null : (role ?? f.role),
      ),
    );
  }

  void _select(String id) {
    ctl.select(id);
    widget.selectLocation(id);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(userManagementProvider), c = ChurchColors.of(context);
    final id = widget.memberId;
    if (id != null &&
        id != s.selectedId &&
        id != _scheduledMember &&
        s.directoryResult is AccessReadOk<UserDirectoryPage> &&
        !s.unsettled) {
      _scheduledMember = id;
      Future.microtask(() {
        if (mounted) ctl.select(id);
      });
    }
    ref.listen(userManagementProvider.select((s) => s.notice), (
      previous,
      next,
    ) {
      if (next != null && previous != next) {
        announce(context, userChangeMessage(ref.read(userManagementProvider)));
      }
    });
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s.loading && s.members.isEmpty)
          const RequestStateBanner(
            tone: StatusTone.info,
            busy: true,
            title: 'Loading people…',
            message: 'Checking current member records.',
          )
        else if (s.directoryResult is AccessReadDenied<UserDirectoryPage>)
          RequestStateBanner(
            tone: StatusTone.warning,
            title: 'Access could not be confirmed',
            message: 'No member records are shown. Sign in again or check your current Admin access.',
            actions: [BannerAction('Try again', ctl.reload)],
          )
        else if (s.directoryResult is AccessReadFailed<UserDirectoryPage>)
          RequestStateBanner(
            key: const Key('users-directory-failed'),
            tone: StatusTone.warning,
            title: 'Could not load people',
            message: 'This is not an empty directory. Check your connection and try again.',
            actions: [BannerAction('Try again', ctl.reload)],
          )
        else if (s.directoryResult is AccessReadOk<UserDirectoryPage> &&
            s.members.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No people match these filters.',
              key: Key('users-empty'),
            ),
          )
        else
          _table(context, s),
        if (s.next != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              key: const Key('users-more'),
              onPressed: s.loading || s.unsettled ? null : ctl.loadMore,
              child: Text(s.loading ? 'Loading…' : 'Load more people'),
            ),
          ),
      ],
    );
    return ChurchPageScaffold(
      title: 'Members',
      subtitle: 'Membership, account access and administrative activity',
      actions: [
        FilledButton.icon(
          key: const Key('add-member-record'),
          onPressed: s.unsettled
              ? null
              : () => widget.openArea('add-member', null),
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: const Text('Add member record'),
        ),
        staffReloadButton(
          const Key('users-reload'),
          s.loading || s.unsettled ? null : ctl.reload,
        ),
      ],
      body: SingleChildScrollView(
        padding: ChurchLayout.of(context).pagePadding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ChurchLayout.of(context).contentMaxWidth,
            ),
            child: DefaultTextStyle.merge(
              style: ChurchType.staffBody.copyWith(color: c.ink),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.busy || s.notice != null) ...[
                    UserChangeBanner(state: s),
                    const SizedBox(height: 16),
                  ],
                  LayoutBuilder(
                    builder: (context, box) => Wrap(
                      spacing: 12,
                      runSpacing: 16,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: box.maxWidth < 440 ? box.maxWidth : 300,
                          child: TextField(
                            key: const Key('member-query'),
                            controller: _query,
                            maxLength: 120,
                            enabled: !s.unsettled,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => _search(),
                            decoration: const InputDecoration(
                              labelText: 'Search name or contact number',
                              counterText: '',
                              prefixIcon: Icon(Icons.search),
                            ),
                          ),
                        ),
                        OutlinedButton(
                          key: const Key('users-search'),
                          onPressed: s.unsettled ? null : () => _search(),
                          child: const Text('Search'),
                        ),
                        _filter(
                          'Membership',
                          'users-membership-filter',
                          s.filter.membership,
                          const {
                            'all': 'All memberships',
                            'approved': 'Approved',
                            'deactivated': 'Deactivated',
                            'pending': 'Pending',
                            'rejected': 'Not approved',
                          },
                          s.unsettled ? null : (v) => _search(membership: v),
                          box.maxWidth,
                        ),
                        _filter(
                          'Account',
                          'users-account-filter',
                          s.filter.account,
                          const {
                            'all': 'All account states',
                            'app_account': 'App account',
                            'no_login': 'No login',
                            'access_review': 'Access review',
                          },
                          s.unsettled ? null : (v) => _search(account: v),
                          box.maxWidth,
                        ),
                        _filter(
                          'Role',
                          'users-role-filter',
                          s.filter.role ?? 'all',
                          {
                            'all': 'All roles',
                            for (final r in s.roles)
                              r.role: ChurchRoles.label(r.role),
                          },
                          s.unsettled
                              ? null
                              : (v) => _search(
                                  role: v == 'all' ? null : v,
                                  clearRole: v == 'all',
                                ),
                          box.maxWidth,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, box) {
                      if (s.selectedId == null) return list;
                      final detail = _detail(context, s);
                      if (box.maxWidth >= 1000 &&
                          MediaQuery.textScalerOf(context).scale(15) <= 21) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: list),
                            const SizedBox(width: 20),
                            SizedBox(width: 360, child: detail),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [detail, const SizedBox(height: 20), list],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _filter(
    String label,
    String key,
    String value,
    Map<String, String> choices,
    ValueChanged<String>? change,
    double maxWidth,
  ) => SizedBox(
    width: maxWidth < 240 ? maxWidth : 220,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$key-$value'),
      initialValue: choices.containsKey(value) ? value : 'all',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final e in choices.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: change == null
          ? null
          : (v) {
              if (v != null) change(v);
            },
    ),
  );

  static const _columns = [
    StaffColumn('Name', flex: 4),
    StaffColumn('Membership', flex: 2),
    StaffColumn('Roles', flex: 2),
    StaffColumn('Account', flex: 2),
  ];
  Widget _table(BuildContext context, UserManagementState s) => LayoutBuilder(
    builder: (context, box) {
      final wide =
          box.maxWidth >= 700 &&
          MediaQuery.textScalerOf(context).scale(15) < 23;
      return StaffTableFrame(
        key: const Key('users-table'),
        children: [
          if (wide) const StaffTableHeader(columns: _columns),
          for (final (index, m) in s.members.indexed)
            StaffTableRow(
              key: Key('user-row-${m.id}'),
              divider: index > 0,
              selected: s.selectedId == m.id,
              onTap: s.unsettled ? null : () => _select(m.id),
              semanticLabel:
                  '${m.record.displayName}, ${m.membershipLabel}, ${m.accountLabel}, open details',
              child: wide
                  ? StaffColumnsRow(
                      columns: _columns,
                      cells: [
                        _name(context, m),
                        Text(m.membershipLabel),
                        Text(
                          m.grants.roles.isEmpty
                              ? 'Member'
                              : m.grants.roles
                                    .map(ChurchRoles.label)
                                    .join(', '),
                        ),
                        Text(m.accountLabel),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _name(context, m),
                        const SizedBox(height: 6),
                        Text(
                          '${m.membershipLabel} · ${m.accountLabel}',
                          style: ChurchType.secondary,
                        ),
                        if (m.grants.roles.isNotEmpty)
                          Text(
                            m.grants.roles.map(ChurchRoles.label).join(', '),
                            style: ChurchType.secondary,
                          ),
                      ],
                    ),
            ),
        ],
      );
    },
  );
  Widget _name(BuildContext context, ManagedMember m) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        m.record.displayName,
        style: ChurchType.staffBody.copyWith(fontWeight: FontWeight.w600),
      ),
      if (m.record.contactRoutes.isNotEmpty)
        Text(
          m.record.contactRoutes.first.phone,
          style: ChurchType.secondary.copyWith(
            color: ChurchColors.of(context).muted,
          ),
        ),
      if (m.deletionPending)
        const Text('Deletion requested', style: ChurchType.secondary),
    ],
  );

  Widget _detail(BuildContext context, UserManagementState s) {
    if (s.detailLoading || s.detailResult == null) {
      return const RequestStateBanner(
        tone: StatusTone.info,
        busy: true,
        title: 'Loading person…',
        message: 'Checking current access and record details.',
      );
    }
    final detail = s.detail;
    if (detail == null) {
      return RequestStateBanner(
        tone: StatusTone.warning,
        title: 'Could not read this person',
        message: 'The record may have changed or become unavailable. No old details are shown.',
        actions: [
          BannerAction('Try again', () => ctl.select(s.selectedId)),
          BannerAction('Close', () {
            ctl.select(null);
            widget.selectLocation(null);
          }),
        ],
      );
    }
    final m = detail.member, own = detail.ownRecord;
    final disabled = s.unsettled || m.deletionPending;
    Widget button(String key, String label, VoidCallback? action) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton(
        key: Key(key),
        onPressed: action,
        child: Text(label),
      ),
    );
    return StaffSection(
      title: m.record.displayName,
      trailing: IconButton(
        tooltip: 'Close person details',
        onPressed: s.unsettled
            ? null
            : () {
                ctl.select(null);
                widget.selectLocation(null);
              },
        icon: const Icon(Icons.close),
      ),
      child: Column(
        key: Key('user-detail-${m.id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Membership: ${m.membershipLabel}'),
          const SizedBox(height: 8),
          Text('Account: ${m.accountLabel}'),
          if (m.commissionedAdmin)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'First Admin by owner invitation',
                style: ChurchType.secondary,
              ),
            ),
          if (m.deletionPending)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: RequestStateBanner(
                tone: StatusTone.warning,
                title: 'Deletion requested',
                message: 'Profile and access changes are unavailable while deletion is processed.',
              ),
            ),
          const SizedBox(height: 16),
          Text('Agreed contact routes', style: ChurchType.label),
          if (m.record.contactRoutes.isEmpty)
            const Text('No contact number recorded.'),
          for (final route in m.record.contactRoutes)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${route.phone}\n${route.owner.label}${route.holderLabel == null ? '' : ': ${route.holderLabel}'} · not a login',
              ),
            ),
          button(
            'user-edit-profile',
            'Edit name & contacts',
            disabled || own || !m.editable
                ? null
                : () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => UserProfileEditor(member: m),
                  ),
          ),
          const SizedBox(height: 16),
          const Divider(),
          Text('Roles & permissions', style: ChurchType.label),
          const SizedBox(height: 8),
          if (m.membership == 'approved')
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final option in s.roles)
                  FilterChip(
                    key: Key('user-role-${option.role}'),
                    label: Text(ChurchRoles.label(option.role)),
                    selected: m.grants.hasRole(option.role),
                    onSelected:
                        disabled ||
                            (!m.grants.hasRole(option.role) &&
                                (own || !option.available))
                        ? null
                        : (grant) async {
                            final ok = await confirmStaffAction(
                              context,
                              title:
                                  '${grant ? 'Grant' : 'Remove'} ${ChurchRoles.label(option.role)} ${grant ? 'for' : 'from'} ${m.record.displayName}?',
                              message: 'This changes the person\'s current access. It does not grant unrelated private care or finance permissions.',
                              confirmLabel: grant
                                  ? 'Grant role'
                                  : 'Remove role',
                              destructive: !grant,
                            );
                            if (ok && mounted) {
                              await ctl.setRole(m, option.role, grant);
                            }
                          },
                  ),
              ],
            )
          else
            const Text('Restore membership before granting roles.'),
          const SizedBox(height: 8),
          const Text(
            'Admin does not include private care, finance or prayer access.',
            style: ChurchType.secondary,
          ),
          if (m.grants.scopes.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Scoped assignments', style: ChurchType.label),
            for (final scope in m.grants.scopes)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(scope.scopeKind.replaceAll('_', ' ')),
                    SelectableText(scope.scopeId, style: ChurchType.secondary),
                    TextButton(
                      onPressed: disabled || own
                          ? null
                          : () async {
                              final ok = await confirmStaffAction(
                                context,
                                title:
                                    'Remove scoped access for ${m.record.displayName}?',
                                message: 'This removes only the selected assignment. Required handovers may prevent removal.',
                                confirmLabel: 'Remove assignment',
                              );
                              if (ok && mounted) {
                                await ctl.revokeScope(m, scope);
                              }
                            },
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ),
            const Text(
              'New scoped assignments are made in the responsible ministry or cell workflow.',
              style: ChurchType.secondary,
            ),
          ],
          const SizedBox(height: 16),
          const Divider(),
          if (own)
            const Text(
              'Another Admin must edit your record or change your account access.',
              style: ChurchType.secondary,
            ),
          if (m.membership == 'approved' &&
              m.record.account != AccountStanding.noLogin) ...[
            button(
              'user-hold',
              'Place access review hold',
              disabled || own
                  ? null
                  : () => _reason<HoldReason>(
                      m,
                      'Place access review hold',
                      'All existing sessions will end. Membership and roles are kept.',
                      HoldReason.values,
                      (x) => x.label,
                      (x) => ctl.hold(m, x),
                    ),
            ),
            button(
              'user-unlink',
              'Unlink app account',
              disabled || own
                  ? null
                  : () => _reason<UnlinkReason>(
                      m,
                      'Unlink app account',
                      'This account loses member access. The member record and history are kept.',
                      UnlinkReason.values,
                      (x) => x.label,
                      (x) => ctl.unlink(m, x),
                    ),
            ),
          ],
          if (m.membership == 'approved')
            button(
              'user-deactivate',
              'Deactivate membership',
              disabled || own
                  ? null
                  : () => _reason<DeactivationReason>(
                      m,
                      'Deactivate membership',
                      'Sessions and roles end. Records and history remain. Required handovers must be completed first.',
                      DeactivationReason.values,
                      (x) => x.label,
                      (x) => ctl.deactivate(m, x),
                    ),
            ),
          if (m.membership == 'deactivated')
            button(
              'user-restore',
              'Restore membership',
              disabled || own
                  ? null
                  : () => _reason<IdentityCheck>(
                      m,
                      'Restore membership',
                      'The member must sign in again. No previous role or scope is restored.',
                      IdentityCheck.values,
                      (x) => x.label,
                      (x) => ctl.restore(m, x),
                      destructive: false,
                    ),
            ),
          button(
            'user-access-review',
            'Review access & holds',
            s.unsettled ? null : () => widget.openArea('access-reviews', m.id),
          ),
          button(
            'user-recovery',
            'Account recovery',
            s.unsettled ? null : () => widget.openArea('recovery', m.id),
          ),
          button(
            'user-membership',
            'Membership & handovers',
            s.unsettled ? null : () => widget.openArea('membership', m.id),
          ),
          button(
            'user-deletions',
            'Deletion request & progress',
            s.unsettled ? null : () => widget.openArea('deletions', m.id),
          ),
          const SizedBox(height: 16),
          const Divider(),
          Text('Administrative activity', style: ChurchType.label),
          const Text(
            'Changes to membership and access only. No private care or financial content.',
            style: ChurchType.secondary,
          ),
          button(
            'user-activity',
            s.activityResult == null ? 'Load activity' : 'Refresh activity',
            s.activityLoading ? null : () => ctl.loadActivity(),
          ),
          if (s.activityLoading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            ),
          if (s.activityResult is AccessReadFailed<UserActivityPage>)
            const Text('Activity could not be loaded. Try again.'),
          if (s.activityResult is AccessReadOk<UserActivityPage> &&
              s.events.isEmpty)
            const Text('No administrative activity recorded.'),
          for (final event in s.events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${event.action.replaceAll('_', ' ')}${event.role == null ? '' : ' · ${ChurchRoles.label(event.role!)}'}',
                  ),
                  Text(event.actor, style: ChurchType.secondary),
                  Text(
                    '${event.at.replaceFirst('T', ' ').replaceFirst(RegExp(r'\.\d+Z$'), '')} UTC',
                    style: ChurchType.secondary,
                  ),
                  if (event.changedFields.isNotEmpty)
                    Text(
                      event.changedFields
                          .map(
                            (f) => f == 'full_name' ? 'Name' : 'Contact routes',
                          )
                          .join(', '),
                      style: ChurchType.secondary,
                    ),
                ],
              ),
            ),
          if (s.activityNext != null)
            button(
              'user-activity-more',
              'Load earlier activity',
              s.activityLoading ? null : () => ctl.loadActivity(more: true),
            ),
        ],
      ),
    );
  }

  Future<void> _reason<T>(
    ManagedMember m,
    String title,
    String message,
    List<T> choices,
    String Function(T) label,
    Future<void> Function(T) send, {
    bool destructive = true,
  }) async {
    T? selected;
    final ok = await confirmStaffAction(
      context,
      title: '$title for ${m.record.displayName}?',
      message: message,
      confirmLabel: title,
      destructive: destructive,
      canConfirm: () => selected != null,
      extra: (context, set) => RadioGroup<T>(
        groupValue: selected,
        onChanged: (v) => set(() => selected = v),
        child: Column(
          children: [
            for (final choice in choices)
              RadioListTile<T>(value: choice, title: Text(label(choice))),
          ],
        ),
      ),
    );
    if (ok && mounted && selected != null) await send(selected as T);
  }
}
