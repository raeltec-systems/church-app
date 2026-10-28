import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Mobile-only player. No YouTube bytes or thumbnails enter the public cache.
class YoutubeSermonPlayer extends StatefulWidget {
  const YoutubeSermonPlayer({super.key, required this.videoId});
  final String videoId;
  @override
  State<YoutubeSermonPlayer> createState() => _YoutubeSermonPlayerState();
}

class _YoutubeSermonPlayerState extends State<YoutubeSermonPlayer> {
  YoutubePlayerController? _controller;
  StreamSubscription<YoutubePlayerValue>? _subscription;
  Timer? _timeout;
  bool _failed = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(YoutubeSermonPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _close();
      _failed = false;
      _open();
    }
  }

  void _open() {
    final epoch = ++_epoch;
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      _failed = true;
      return;
    }
    try {
      final controller = YoutubePlayerController(
        key: widget.videoId,
        params: const YoutubePlayerParams(
          privacyEnhancedMode: true,
          showControls: true,
          showFullscreenButton: true,
          playsInline: true,
        ),
        onWebResourceError: (error) {
          if (error.isForMainFrame != false) _fail(epoch);
        },
      );
      _controller = controller;
      _subscription = controller.listen((value) {
        if (value.hasError) {
          _fail(epoch);
        } else if (value.playerState != PlayerState.unknown) {
          _timeout?.cancel();
        }
      }, onError: (_) => _fail(epoch));
      _timeout = Timer(const Duration(seconds: 25), () => _fail(epoch));
      // Cue loads a paused video; no autoplay or server polling.
      unawaited(
        controller
            .cueVideoById(videoId: widget.videoId)
            .catchError((Object _) => _fail(epoch)),
      );
    } catch (_) {
      _failed = true;
    }
  }

  void _fail(int epoch) {
    if (!mounted || epoch != _epoch || _failed) return;
    setState(() => _failed = true);
    _close();
  }

  void _close() {
    _epoch++;
    _timeout?.cancel();
    _timeout = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      unawaited(controller.close().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _failed || _controller == null
      ? const SermonVideoUnavailable()
      : YoutubePlayer(
          key: ValueKey(widget.videoId),
          controller: _controller!,
          aspectRatio: 16 / 9,
          autoFullScreen: false,
          enableFullScreenOnVerticalDrag: false,
        );
}

class UrlSermonLinkLauncher implements SermonLinkLauncher {
  const UrlSermonLinkLauncher();
  @override
  Future<bool> open(Uri uri) async {
    if (safeSermonLink(uri.toString()) == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
