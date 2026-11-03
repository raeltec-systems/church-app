import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/credential_review.dart';
import '../domain/membership_lifecycle.dart';
import '../domain/membership_review.dart';
import '../domain/user_management.dart';
import 'access_controllers.dart';
import 'providers.dart';

final userManagementRepositoryProvider = Provider<UserManagementRepository>(
  (ref) => const UnconfiguredUserManagementRepository(),
);

enum UserChangeNotice { saved, conflict, invalid, refused, unknown, notSent }

class UserChange {
  const UserChange(this.function, this.request, this.subject, this.label);
  final String function;
  final CommandRequest request;
  final String subject;
  final String label;
  String get memberId => request.payload['member_id']! as String;
}

const _keepUserValue = Object();

/// Protected data and any unresolved command live only in the current account generation.
class UserManagementState {
  const UserManagementState({
    this.filter = const UserFilter(),
    this.loading = false,
    this.directoryResult,
    this.members = const [],
    this.roles = const [],
    this.next,
    this.selectedId,
    this.detailResult,
    this.detailLoading = false,
    this.activityResult,
    this.events = const [],
    this.activityNext,
    this.activityLoading = false,
    this.pending,
    this.retry,
    this.notice,
    this.change,
    this.fieldErrors = const {},
  });
  final UserFilter filter;
  final bool loading;
  final AccessRead<UserDirectoryPage>? directoryResult;
  final List<ManagedMember> members;
  final List<RoleOption> roles;
  final MemberCursor? next;
  final String? selectedId;
  final AccessRead<UserDetail>? detailResult;
  final bool detailLoading;
  final AccessRead<UserActivityPage>? activityResult;
  final List<UserActivityEvent> events;
  final UserActivityCursor? activityNext;
  final bool activityLoading;
  final UserChange? pending;
  final UserChange? retry;
  final UserChangeNotice? notice;
  final UserChange? change;
  final Map<String, String> fieldErrors;
  bool get busy => pending != null;
  bool get unsettled => busy || retry != null;
  UserDetail? get detail => switch (detailResult) {
    AccessReadOk(:final value) => value,
    _ => null,
  };

  UserManagementState copyWith({
    UserFilter? filter,
    bool? loading,
    AccessRead<UserDirectoryPage>? directoryResult,
    List<ManagedMember>? members,
    List<RoleOption>? roles,
    Object? next = _keepUserValue,
    Object? selectedId = _keepUserValue,
    Object? detailResult = _keepUserValue,
    bool? detailLoading,
    Object? activityResult = _keepUserValue,
    List<UserActivityEvent>? events,
    Object? activityNext = _keepUserValue,
    bool? activityLoading,
    Object? pending = _keepUserValue,
    Object? retry = _keepUserValue,
    Object? notice = _keepUserValue,
    Object? change = _keepUserValue,
    Map<String, String>? fieldErrors,
  }) => UserManagementState(
    filter: filter ?? this.filter,
    loading: loading ?? this.loading,
    directoryResult: directoryResult ?? this.directoryResult,
    members: members ?? this.members,
    roles: roles ?? this.roles,
    next: identical(next, _keepUserValue) ? this.next : next as MemberCursor?,
    selectedId: identical(selectedId, _keepUserValue)
        ? this.selectedId
        : selectedId as String?,
    detailResult: identical(detailResult, _keepUserValue)
        ? this.detailResult
        : detailResult as AccessRead<UserDetail>?,
    detailLoading: detailLoading ?? this.detailLoading,
    activityResult: identical(activityResult, _keepUserValue)
        ? this.activityResult
        : activityResult as AccessRead<UserActivityPage>?,
    events: events ?? this.events,
    activityNext: identical(activityNext, _keepUserValue)
        ? this.activityNext
        : activityNext as UserActivityCursor?,
    activityLoading: activityLoading ?? this.activityLoading,
    pending: identical(pending, _keepUserValue)
        ? this.pending
        : pending as UserChange?,
    retry: identical(retry, _keepUserValue) ? this.retry : retry as UserChange?,
    notice: identical(notice, _keepUserValue)
        ? this.notice
        : notice as UserChangeNotice?,
    change: identical(change, _keepUserValue)
        ? this.change
        : change as UserChange?,
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

class UserManagementController extends Notifier<UserManagementState> {
  int _epoch = 0, _search = 0, _selection = 0, _activity = 0;
  @override
  UserManagementState build() {
    ref.watch(accountGenerationProvider);
    final allowed = ref.watch(
      myAccessProvider.select((s) => s.grants?.isAdmin == true),
    );
    final epoch = ++_epoch;
    _search++;
    _selection++;
    _activity++;
    if (!allowed) {
      return const UserManagementState(
        directoryResult: AccessReadDenied(AccessDenial.notGranted),
      );
    }
    Future.microtask(() {
      if (_current(epoch)) search(const UserFilter(), preserveSelection: true);
    });
    return const UserManagementState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;
  UserManagementRepository get _repo =>
      ref.read(userManagementRepositoryProvider);

  void _denied(AccessDenial denial) {
    _search++;
    _selection++;
    _activity++;
    state = UserManagementState(directoryResult: AccessReadDenied(denial));
    noteProtectedDenial(ref);
  }

  Future<void> search(
    UserFilter filter, {
    bool preserveSelection = false,
  }) async {
    if (state.unsettled) return;
    final epoch = _epoch, serial = ++_search;
    _selection++;
    _activity++;
    state = state.copyWith(
      filter: filter,
      loading: true,
      members: const [],
      next: null,
      selectedId: preserveSelection ? state.selectedId : null,
      detailResult: null,
      detailLoading: false,
      activityResult: null,
      events: const [],
      activityNext: null,
      activityLoading: false,
    );
    final answer = await _repo.directory(filter);
    if (!_current(epoch) || serial != _search) return;
    if (answer is AccessReadDenied<UserDirectoryPage>) {
      _denied(answer.denial);
      return;
    }
    state = state.copyWith(
      loading: false,
      directoryResult: answer,
      members: answer is AccessReadOk<UserDirectoryPage>
          ? answer.value.members
          : const [],
      roles: answer is AccessReadOk<UserDirectoryPage>
          ? answer.value.roles
          : const [],
      next: answer is AccessReadOk<UserDirectoryPage>
          ? answer.value.next
          : null,
    );
    if (preserveSelection && state.selectedId != null) {
      await select(state.selectedId);
    }
  }

  Future<void> reload() => search(state.filter, preserveSelection: true);

  Future<void> loadMore() async {
    final after = state.next;
    if (after == null || state.loading || state.unsettled) return;
    final epoch = _epoch, serial = _search;
    state = state.copyWith(loading: true);
    final answer = await _repo.directory(state.filter, after: after);
    if (!_current(epoch) || serial != _search) return;
    if (answer is AccessReadDenied<UserDirectoryPage>) {
      _denied(answer.denial);
      return;
    }
    if (answer is AccessReadOk<UserDirectoryPage>) {
      final seen = state.members.map((m) => m.id).toSet();
      state = state.copyWith(
        loading: false,
        directoryResult: answer,
        members: [
          ...state.members,
          ...answer.value.members.where((m) => !seen.contains(m.id)),
        ],
        next: answer.value.next,
      );
    } else {
      state = state.copyWith(
        loading: false,
        directoryResult: answer,
        members: const [],
        next: null,
        selectedId: null,
        detailResult: null,
        events: const [],
        activityResult: null,
      );
      _selection++;
      _activity++;
    }
  }

  Future<void> select(String? id) async {
    if (state.unsettled) return;
    final epoch = _epoch, serial = ++_selection;
    _activity++;
    state = state.copyWith(
      selectedId: id,
      detailResult: null,
      detailLoading: id != null,
      activityResult: null,
      activityNext: null,
      events: const [],
      activityLoading: false,
    );
    if (id == null) return;
    final answer = await _repo.detail(id);
    if (!_current(epoch) || serial != _selection || state.selectedId != id) {
      return;
    }
    if (answer is AccessReadDenied<UserDetail>) {
      _denied(answer.denial);
      return;
    }
    state = state.copyWith(detailLoading: false, detailResult: answer);
  }

  Future<void> loadActivity({bool more = false}) async {
    final id = state.selectedId, after = more ? state.activityNext : null;
    if (id == null ||
        state.detail == null ||
        state.activityLoading ||
        (more && after == null)) {
      return;
    }
    final epoch = _epoch, serial = ++_activity, selection = _selection;
    state = state.copyWith(
      activityLoading: true,
      events: more ? state.events : const [],
    );
    final answer = await _repo.activity(id, after: after);
    if (!_current(epoch) || serial != _activity || selection != _selection) {
      return;
    }
    if (answer is AccessReadDenied<UserActivityPage>) {
      _denied(answer.denial);
      return;
    }
    final items = answer is AccessReadOk<UserActivityPage>
        ? answer.value.events
        : <UserActivityEvent>[];
    state = state.copyWith(
      activityLoading: false,
      activityResult: answer,
      events: answer is AccessReadOk<UserActivityPage>
          ? [...(more ? state.events : <UserActivityEvent>[]), ...items]
          : const [],
      activityNext: answer is AccessReadOk<UserActivityPage>
          ? answer.value.next
          : null,
    );
  }

  Future<void> updateProfile(
    ManagedMember member,
    String name,
    List<Map<String, Object?>> contacts,
    ConsentBasis consent,
  ) => _send(
    UserManagementCommands.function,
    UserManagementCommands.updateProfile,
    member,
    member.record.revision,
    {
      'full_name': name.trim(),
      'contact_routes': contacts,
      'consent_basis': consent.wire,
    },
    'Profile updated',
  );
  Future<void> setRole(ManagedMember member, String role, bool grant) => _send(
    GrantCommands.function,
    grant ? GrantCommands.grantRole : GrantCommands.revokeRole,
    member,
    member.grants.revision,
    {'role': role},
    '${ChurchRoles.label(role)} ${grant ? 'granted' : 'removed'}',
  );
  Future<void> revokeScope(ManagedMember member, ScopeGrant scope) => _send(
    GrantCommands.function,
    GrantCommands.revokeScope,
    member,
    member.grants.revision,
    {'scope_kind': scope.scopeKind, 'scope_id': scope.scopeId},
    'Scoped access removed',
  );
  Future<void> hold(ManagedMember member, HoldReason reason) => _send(
    CredentialCommands.function,
    CredentialCommands.placeHold,
    member,
    member.record.revision,
    {'reason_code': reason.wire},
    'Access review hold placed',
  );
  Future<void> unlink(ManagedMember member, UnlinkReason reason) => _send(
    ReviewCommands.function,
    ReviewCommands.unlink,
    member,
    member.record.revision,
    {'reason': reason.wire},
    'App account unlinked',
  );
  Future<void> deactivate(ManagedMember member, DeactivationReason reason) =>
      _send(
        LifecycleCommands.function,
        LifecycleCommands.deactivate,
        member,
        member.record.revision,
        {'reason_code': reason.wire},
        'Membership deactivated',
      );
  Future<void> restore(ManagedMember member, IdentityCheck check) => _send(
    LifecycleCommands.function,
    LifecycleCommands.restore,
    member,
    member.record.revision,
    {'identity_check': check.wire},
    'Membership restored without roles',
  );

  Future<void> _send(
    String function,
    String command,
    ManagedMember member,
    int revision,
    Map<String, Object?> payload,
    String label,
  ) async {
    if (state.unsettled ||
        state.detailLoading ||
        state.detail?.member.id != member.id) {
      return;
    }
    final request = CommandRequest(
      command: command,
      requestId: ref.read(requestIdsProvider).next(),
      expectedRevision: Optional.of(revision),
      payload: Map<String, Object?>.from(
        jsonDecode(jsonEncode({'member_id': member.id, ...payload})) as Map,
      ),
    );
    await _dispatch(
      UserChange(function, request, member.record.displayName, label),
    );
  }

  Future<void> checkAgain() async {
    final action = state.retry;
    if (action != null && !state.busy) await _dispatch(action);
  }

  void dismissNotice() {
    if (!state.unsettled) {
      state = state.copyWith(notice: null, change: null, fieldErrors: const {});
    }
  }

  Future<void> _dispatch(UserChange action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      change: action,
      notice: null,
      fieldErrors: const {},
    );
    final answer = await ref
        .read(commandGatewayProvider)
        .send(action.function, action.request);
    if (!_current(epoch)) return;
    switch (answer) {
      case CommandConfirmed():
        state = state.copyWith(
          pending: null,
          retry: null,
          notice: UserChangeNotice.saved,
        );
        await reload();
        if (_current(epoch)) noteProtectedDenial(ref);
      case CommandRefused(:final error):
        if (error.code == ErrorCode.unauthenticated ||
            (error.code == ErrorCode.forbidden && error.fieldErrors.isEmpty)) {
          _denied(AccessDenial.notGranted);
          return;
        }
        state = state.copyWith(
          pending: null,
          retry: null,
          fieldErrors: error.fieldErrors,
          notice: switch (error.code) {
            ErrorCode.conflict => UserChangeNotice.conflict,
            ErrorCode.validationFailed => UserChangeNotice.invalid,
            _ => UserChangeNotice.refused,
          },
        );
        if (error.code != ErrorCode.validationFailed) await reload();
      case CommandUnknownOutcome():
        state = state.copyWith(
          pending: null,
          retry: action,
          notice: UserChangeNotice.unknown,
        );
      case CommandNotSent():
        state = state.copyWith(
          pending: null,
          retry: action,
          notice: UserChangeNotice.notSent,
        );
    }
  }
}

final userManagementProvider =
    NotifierProvider<UserManagementController, UserManagementState>(
      UserManagementController.new,
    );
