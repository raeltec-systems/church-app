import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/admin_onboarding.dart';
import 'providers.dart';

final adminOnboardingRepositoryProvider = Provider<AdminOnboardingRepository>(
  (ref) => const UnconfiguredAdminOnboardingRepository(),
);

enum AdminSetupPhase {
  invitation,
  checking,
  details,
  submitting,
  resolving,
  complete,
}

/// Only presentation-safe status is observable. No invitation, phone or password.
final class AdminSetupState {
  const AdminSetupState({
    this.phase = AdminSetupPhase.invitation,
    this.invitationDetails,
    this.outcome,
    this.validationMessage,
  });
  final AdminSetupPhase phase;
  final AdminOnboardingReply? invitationDetails;
  final AdminOnboardingOutcome? outcome;
  final String? validationMessage;
  bool get busy => const {
    AdminSetupPhase.checking,
    AdminSetupPhase.submitting,
  }.contains(phase);
}

/// One in-memory setup journey. Unknown mutations are reconciled by status;
/// the controller never automatically resends a password or creates a new account.
class AdminOnboardingController extends Notifier<AdminSetupState> {
  AdminInvitation? _invitation;
  String? _phone;
  String? _requestId;
  int _epoch = 0;

  @override
  AdminSetupState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    _invitation = null;
    _phone = null;
    _requestId = null;
    ref.onDispose(() {
      _invitation = null;
      _phone = null;
      _requestId = null;
    });
    return const AdminSetupState();
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;
  AdminOnboardingRepository get _repo =>
      ref.read(adminOnboardingRepositoryProvider);

  void reset() {
    _epoch++;
    _invitation = null;
    _phone = null;
    _requestId = null;
    state = const AdminSetupState();
  }

  Future<void> inspect(String invitation, String phoneUsername) async {
    if (state.busy || state.phase == AdminSetupPhase.resolving) return;
    reset();
    if (invitation.trim().isEmpty ||
        invitation.length > 512 ||
        !RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phoneUsername)) {
      state = const AdminSetupState(
        validationMessage:
            'Enter your invitation and an international phone number.',
      );
      return;
    }
    _invitation = AdminInvitation(invitation.trim());
    _phone = phoneUsername;
    final epoch = _epoch;
    state = const AdminSetupState(phase: AdminSetupPhase.checking);
    AdminOnboardingReply reply;
    try {
      reply = await _repo.inspect(
        invitation: _invitation!,
        phoneUsername: _phone!,
      );
    } catch (_) {
      reply = const AdminOnboardingReply(AdminOnboardingOutcome.unavailable);
    }
    if (!_current(epoch)) return;
    if (reply.outcome == AdminOnboardingOutcome.completed ||
        reply.outcome == AdminOnboardingOutcome.activationPending) {
      // A returning holder can learn their own completed status after a
      // reload. This does not create a session or grant client authority.
      _applyCompletion(reply);
      return;
    }
    if (reply.outcome == AdminOnboardingOutcome.pending &&
        reply.requestId != null) {
      _requestId = reply.requestId;
      state = AdminSetupState(
        phase: AdminSetupPhase.resolving,
        outcome: reply.outcome,
      );
      return;
    }
    if (reply.outcome == AdminOnboardingOutcome.ready &&
        reply.mode != null &&
        reply.privacyVersion != null &&
        reply.privacyText != null &&
        reply.expiresAt != null &&
        reply.expiresAt!.isAfter(DateTime.now().toUtc())) {
      _requestId = ref.read(requestIdsProvider).next();
      state = AdminSetupState(
        phase: AdminSetupPhase.details,
        invitationDetails: reply,
      );
    } else {
      // A ready response without its notice is not permission to submit.
      _invitation = null;
      _phone = null;
      state = AdminSetupState(
        outcome: switch (reply.outcome) {
          AdminOnboardingOutcome.refused ||
          AdminOnboardingOutcome.rateLimited ||
          AdminOnboardingOutcome.unavailable => reply.outcome,
          _ => AdminOnboardingOutcome.refused,
        },
      );
    }
  }

  Future<void> complete({
    required String fullName,
    required String password,
    required bool privacyAccepted,
  }) async {
    final ready = state.invitationDetails;
    if (state.phase != AdminSetupPhase.details ||
        ready == null ||
        _invitation == null ||
        _phone == null ||
        _requestId == null) {
      return;
    }
    final name = fullName.trim();
    final bytes = utf8.encode(password).length;
    if (name.isEmpty ||
        name.length > 120 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        password.runes.length < 8 ||
        bytes < 8 ||
        bytes > 72 ||
        !privacyAccepted) {
      state = AdminSetupState(
        phase: AdminSetupPhase.details,
        invitationDetails: ready,
        validationMessage: 'Enter your name, a password of 8–72 bytes, and acknowledge the privacy notice.',
      );
      return;
    }
    if (!ready.expiresAt!.isAfter(DateTime.now().toUtc())) {
      reset();
      state = const AdminSetupState(outcome: AdminOnboardingOutcome.refused);
      return;
    }
    final epoch = _epoch;
    state = AdminSetupState(
      phase: AdminSetupPhase.submitting,
      invitationDetails: ready,
    );
    AdminOnboardingReply reply;
    try {
      reply = await _repo.complete(
        invitation: _invitation!,
        phoneUsername: _phone!,
        fullName: name,
        password: password,
        privacyVersion: ready.privacyVersion!,
        requestId: _requestId!,
      );
    } catch (_) {
      reply = const AdminOnboardingReply(AdminOnboardingOutcome.uncertain);
    }
    if (!_current(epoch)) return;
    _applyCompletion(reply, ready: ready);
  }

  void _applyCompletion(
    AdminOnboardingReply reply, {
    AdminOnboardingReply? ready,
  }) {
    if (reply.outcome == AdminOnboardingOutcome.completed ||
        reply.outcome == AdminOnboardingOutcome.activationPending) {
      _invitation = null;
      _phone = null;
      _requestId = null;
      state = AdminSetupState(
        phase: AdminSetupPhase.complete,
        outcome: reply.outcome,
      );
    } else if (reply.outcome == AdminOnboardingOutcome.ready &&
        reply.mode != null &&
        reply.privacyVersion != null &&
        reply.privacyText != null &&
        reply.expiresAt != null &&
        reply.expiresAt!.isAfter(DateTime.now().toUtc())) {
      // Status has positively established that no provisioning is in flight.
      // Reopen the form, but never resend the password automatically.
      state = AdminSetupState(
        phase: AdminSetupPhase.details,
        invitationDetails: reply,
      );
    } else if (reply.outcome == AdminOnboardingOutcome.passwordRejected &&
        ready != null) {
      state = AdminSetupState(
        phase: AdminSetupPhase.details,
        invitationDetails: ready,
        outcome: reply.outcome,
      );
    } else if (reply.outcome == AdminOnboardingOutcome.refused) {
      reset();
      state = AdminSetupState(outcome: reply.outcome);
    } else {
      // Even an unavailable or rate-limited response cannot prove that a
      // prior provisioning call did not commit. Only status can resolve it.
      state = AdminSetupState(
        phase: AdminSetupPhase.resolving,
        outcome: reply.outcome,
      );
    }
  }

  Future<void> checkStatus() async {
    if (state.phase != AdminSetupPhase.resolving ||
        _invitation == null ||
        _phone == null ||
        _requestId == null) {
      return;
    }
    final epoch = _epoch;
    state = const AdminSetupState(phase: AdminSetupPhase.checking);
    AdminOnboardingReply reply;
    try {
      reply = await _repo.status(
        invitation: _invitation!,
        phoneUsername: _phone!,
        requestId: _requestId!,
      );
    } catch (_) {
      reply = const AdminOnboardingReply(AdminOnboardingOutcome.unavailable);
    }
    if (!_current(epoch)) return;
    _applyCompletion(reply);
  }
}

final adminOnboardingProvider =
    NotifierProvider.autoDispose<AdminOnboardingController, AdminSetupState>(
      AdminOnboardingController.new,
    );
