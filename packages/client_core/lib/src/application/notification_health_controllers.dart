import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/notification_health.dart';
import 'providers.dart';

class NotificationHealthState {
  const NotificationHealthState({this.loading = false, this.result});
  final bool loading;
  final AccessRead<ReminderHealth>? result;
  ReminderHealth? get health => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };
}

class NotificationHealthController extends Notifier<NotificationHealthState> {
  @override
  NotificationHealthState build() {
    ref.watch(accountGenerationProvider);
    Future.microtask(refresh);
    return const NotificationHealthState(loading: true);
  }

  Future<void> refresh() async {
    final generation = ref.read(accountGenerationProvider);
    state = NotificationHealthState(loading: true, result: state.result);
    final result = await ref.read(notificationHealthRepositoryProvider).fetchHealth();
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) return;
    state = NotificationHealthState(result: result);
  }
}

final notificationHealthProvider = NotifierProvider.autoDispose<
    NotificationHealthController, NotificationHealthState>(
  NotificationHealthController.new,
);
