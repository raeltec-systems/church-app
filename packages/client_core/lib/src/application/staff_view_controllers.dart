import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/cell_membership.dart';
import 'access_controllers.dart';
import 'providers.dart';

/// The three ways staff web is seen (design handoff: Admin, Cell leader,
/// Pastor). Presentation only: a view narrows the navigation and the
/// Overview, while every read and command is still checked by the server.
enum StaffRole {
  admin('Admin'),
  cellLeader('Cell leader'),
  pastor('Pastor');

  const StaffRole(this.label);
  final String label;
}

/// The staff roles [grants] hold, in the handoff's order.
List<StaffRole> staffRolesOf(MemberGrants? grants) => [
  if (grants?.isAdmin ?? false) StaffRole.admin,
  if (servesACell(grants)) StaffRole.cellLeader,
  if (grants?.hasRole(ChurchRoles.pastor) ?? false) StaffRole.pastor,
];

/// [grants] as seen in [view]: the other two staff roles are left out;
/// everything else (department scopes, other roles) stays. Used to choose
/// what to show, never to decide what is allowed.
MemberGrants grantsForView(MemberGrants grants, StaffRole view) {
  bool keepRole(String r) => switch (view) {
    StaffRole.admin => r != ChurchRoles.pastor,
    StaffRole.cellLeader => r != ChurchRoles.admin && r != ChurchRoles.pastor,
    StaffRole.pastor => r != ChurchRoles.admin,
  };
  return MemberGrants(
    memberId: grants.memberId,
    revision: grants.revision,
    roles: List.unmodifiable(grants.roles.where(keepRole)),
    scopes: List.unmodifiable(
      grants.scopes.where(
        (s) =>
            view == StaffRole.cellLeader ||
            !CellScopeKinds.isCellScope(s.scopeKind),
      ),
    ),
  );
}

/// The view chosen with the sidebar's role switch. Memory only; a new
/// account starts again with its first role.
class StaffViewController extends Notifier<StaffRole?> {
  @override
  StaffRole? build() {
    ref.watch(accountGenerationProvider);
    return null;
  }

  void choose(StaffRole role) => state = role;
}

final staffViewChoiceProvider =
    NotifierProvider<StaffViewController, StaffRole?>(StaffViewController.new);

/// What the caller's view is now: null with fewer than two staff roles (no
/// switch, nothing narrowed), otherwise the chosen role (or the first held).
final staffViewProvider = Provider<StaffRole?>((ref) {
  final roles = staffRolesOf(
    ref.watch(myAccessProvider.select((s) => s.grants)),
  );
  if (roles.length < 2) return null;
  final chosen = ref.watch(staffViewChoiceProvider);
  return chosen != null && roles.contains(chosen) ? chosen : roles.first;
});

/// The caller's grants narrowed to the current view (the grants themselves
/// when there is no view).
final staffViewGrantsProvider = Provider<MemberGrants?>((ref) {
  final grants = ref.watch(myAccessProvider.select((s) => s.grants));
  final view = ref.watch(staffViewProvider);
  if (grants == null || view == null) return grants;
  return grantsForView(grants, view);
});
