import 'dart:async';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/commands.dart';
import '../domain/push_messaging.dart';
import 'providers.dart';

/// Where this device's push registration stands for the CURRENT account
/// generation.
enum PushRegistrationStatus {
  /// Nothing tried yet for this account (or signed out).
  idle,

  /// This build or platform has no push: the inbox carries every reminder.
  unsupported,

  /// The person declined notifications (or has not been asked): no token is
  /// registered and the inbox still holds every reminder.
  permissionDenied,

  /// A registration is in flight.
  registering,

  /// The server holds this device's token for the signed-in account.
  registered,

  /// No token, a refusal or an unknown outcome: push may be off for this
  /// device; [PushRegistrationController.sync] tries again.
  failed,
}

class PushRegistrationState {
  const PushRegistrationState(this.status, {this.deviceId, this.revision});

  final PushRegistrationStatus status;

  /// The server's device id and revision (to retire it at sign-out). Memory
  /// only; never the token.
  final String? deviceId;
  final int? revision;
}

/// Story 3.6: registers this device's push token for the signed-in member
/// (`notifications.register_device`) when push is supported and allowed, keeps
/// it current when the provider issues a new token, and retires it before the
/// person signs out (`notifications.retire_device`). Nothing is stored on the
/// device beyond what the push SDK itself keeps; turning push off or denying
/// permission never removes in-app work (the inbox).
class PushRegistrationController extends Notifier<PushRegistrationState> {
  static const _retireTimeout = Duration(seconds: 5);

  @override
  PushRegistrationState build() {
    ref.watch(accountGenerationProvider);
    final push = ref.watch(pushMessagingProvider);
    if (!push.isSupported) {
      return const PushRegistrationState(PushRegistrationStatus.unsupported);
    }
    final sub = push.tokenRefreshes.listen((token) {
      if (state.status == PushRegistrationStatus.registered) {
        unawaited(_register(token));
      }
    });
    ref.onDispose(sub.cancel);
    return const PushRegistrationState(PushRegistrationStatus.idle);
  }

  /// Registers this device for the signed-in account. [prompt] lets the
  /// operating system ask the person when they have not answered yet.
  Future<void> sync({bool prompt = false}) async {
    final push = ref.read(pushMessagingProvider);
    if (!push.isSupported || push.platform == null) return;
    if (ref.read(accountProvider).accountId == null) return;
    if (state.status == PushRegistrationStatus.registering) return;
    final generation = ref.read(accountGenerationProvider);
    state = const PushRegistrationState(PushRegistrationStatus.registering);
    var permission = await push.permission();
    if (permission == PushPermission.notDetermined && prompt) {
      permission = await push.requestPermission();
    }
    if (!_current(generation)) return;
    if (permission != PushPermission.granted) {
      state = const PushRegistrationState(
        PushRegistrationStatus.permissionDenied,
      );
      return;
    }
    final token = await push.token();
    if (!_current(generation)) return;
    if (token == null || !isPushToken(token)) {
      state = const PushRegistrationState(PushRegistrationStatus.failed);
      return;
    }
    await _register(token, generation: generation);
  }

  Future<void> _register(String token, {int? generation}) async {
    final push = ref.read(pushMessagingProvider);
    final int gen = generation ?? ref.read(accountGenerationProvider);
    if (!isPushToken(token) || push.platform == null) return;
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(
          'notifications_command',
          CommandRequest(
            command: 'notifications.register_device',
            requestId: ref.read(requestIdsProvider).next(),
            payload: {'token': token, 'platform': push.platform!.name},
          ),
        );
    if (!_current(gen)) return;
    state = switch (outcome) {
      CommandConfirmed(:final success) => switch (success.data) {
        {'device_id': final String id} => PushRegistrationState(
          PushRegistrationStatus.registered,
          deviceId: id,
          revision: success.revision,
        ),
        _ => const PushRegistrationState(PushRegistrationStatus.failed),
      },
      _ => const PushRegistrationState(PushRegistrationStatus.failed),
    };
  }

  /// Before the person signs out: retires this device's registration so the
  /// next person on this phone never receives the previous account's
  /// reminders, then forgets the token at the provider. Best effort and
  /// bounded: sign-out never waits more than a few seconds for it.
  Future<void> retireBeforeSignOut() async {
    final push = ref.read(pushMessagingProvider);
    final current = state;
    if (current.status == PushRegistrationStatus.registered &&
        current.deviceId != null &&
        current.revision != null) {
      try {
        await ref
            .read(commandGatewayProvider)
            .send(
              'notifications_command',
              CommandRequest(
                command: 'notifications.retire_device',
                requestId: ref.read(requestIdsProvider).next(),
                expectedRevision: Optional<int>.of(current.revision!),
                payload: {'device_id': current.deviceId},
              ),
            )
            .timeout(_retireTimeout);
      } on TimeoutException {
        // The server keeps the row until the next lifecycle event; pushes
        // stay generic and every open re-checks the session.
      }
    }
    if (push.isSupported) {
      try {
        await push.deleteToken().timeout(_retireTimeout);
      } on TimeoutException {
        // Nothing more to do.
      }
    }
    if (ref.mounted) {
      state = PushRegistrationState(
        push.isSupported
            ? PushRegistrationStatus.idle
            : PushRegistrationStatus.unsupported,
      );
    }
  }

  bool _current(int generation) =>
      ref.mounted && ref.read(accountGenerationProvider) == generation;
}

final pushRegistrationProvider =
    NotifierProvider<PushRegistrationController, PushRegistrationState>(
      PushRegistrationController.new,
    );
