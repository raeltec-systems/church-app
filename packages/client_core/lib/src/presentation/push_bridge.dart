import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart';
import '../application/providers.dart';
import '../application/push_controllers.dart';
import '../domain/push_messaging.dart';
import 'shell_routing.dart';

/// Story 3.6 (mobile): connects the device push SDK to the app.
///
/// * A tapped notification (app running, in the background, or launched by
///   the tap) opens `/inbox/<item id>`. That screen asks the server every
///   time: signed out it offers sign-in and returns to the item, and a
///   superseded or foreign item shows nothing about the source.
/// * Once the server grants the caller member access, this device's push
///   token is registered (the operating system asks the person once). A
///   denial changes nothing else: every reminder is still in the inbox.
///
/// With the default [NoPushMessaging] it does nothing.
class PushBridge extends ConsumerStatefulWidget {
  const PushBridge({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<PushBridge> createState() => _PushBridgeState();
}

class _PushBridgeState extends ConsumerState<PushBridge> {
  StreamSubscription<String>? _taps;

  @override
  void initState() {
    super.initState();
    final push = ref.read(pushMessagingProvider);
    if (!push.isSupported) return;
    ref.listenManual<bool>(myAccessProvider.select((s) => s.grants != null), (
      previous,
      granted,
    ) {
      if (granted && previous != true) {
        unawaited(
          ref.read(pushRegistrationProvider.notifier).sync(prompt: true),
        );
      }
    }, fireImmediately: true);
    _taps = push.taps.listen(_open);
    unawaited(
      push.initialTap().then((id) {
        if (id != null && mounted) _open(id);
      }),
    );
  }

  void _open(String itemId) {
    if (pushItemId({'item_id': itemId}) == null) return;
    widget.router.go(ClientPaths.inboxItem(itemId));
  }

  @override
  void dispose() {
    _taps?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
