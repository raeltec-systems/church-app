import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Story 6.10, mobile only: a sermon's public Facebook video or live broadcast
/// in Facebook's embedded player, pinned inside a web view. Nothing plays
/// until the viewer taps play, the web view never leaves the player page (so
/// it never shows a Facebook sign-in), and no Facebook media enters the
/// public cache. A removed, private or sign-in-only video shows the same
/// unavailable state as YouTube, with the notes readable below it.
class FacebookSermonPlayer extends StatefulWidget {
  const FacebookSermonPlayer({super.key, required this.videoUrl});
  final String videoUrl;
  @override
  State<FacebookSermonPlayer> createState() => _FacebookSermonPlayerState();
}

/// What the player page shows, read by [_probeScript].
enum _Probe { playable, gone, waiting }

/// Reads the player page without changing it: a video element or a play
/// control means the video can play; otherwise Facebook's own unavailable or
/// sign-in text means it cannot. Anything else is still loading.
const _probeScript = '''
(function () {
  if (document.querySelector('video') || document.querySelector('[aria-label*="Play" i]')) return 'playable';
  var text = (document.body && document.body.innerText || '').toLowerCase();
  if (/unavailable|isn.t available|not available|no longer available|log in|log into/.test(text)
      || document.querySelector('form[action*="login"]')) return 'gone';
  return 'waiting';
})();
''';

/// The player page itself (and the same page after Facebook's redirects),
/// the only top-level page the web view may show.
bool isFacebookPlayerPage(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'www.facebook.com' &&
    !uri.hasPort &&
    uri.userInfo.isEmpty &&
    uri.path == '/plugins/video.php';

class _FacebookSermonPlayerState extends State<FacebookSermonPlayer> {
  WebViewController? _controller;
  Timer? _timeout, _poll;
  bool _failed = false, _confirmed = false;
  int _epoch = 0;
  bool _loaded = false;
  Route<void>? _fullScreen;

  /// The player page is asked for at the width it will show at, so
  /// Facebook lays the player out to fit the phone.
  void _load(double width) {
    final controller = _controller;
    if (_loaded || controller == null) return;
    _loaded = true;
    final epoch = _epoch;
    try {
      final embed = facebookSermonEmbedUri(
        widget.videoUrl,
        width: width.isFinite ? width.round() : null,
      );
      unawaited(
        controller.loadRequest(embed).catchError((Object _) => _fail(epoch)),
      );
    } catch (_) {
      _fail(epoch);
    }
  }

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(FacebookSermonPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _close();
      _failed = false;
      _confirmed = false;
      _open();
    }
  }

  void _open() {
    final epoch = ++_epoch;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      _failed = true;
      return;
    }
    try {
      final controller = WebViewController.fromPlatformCreationParams(
        defaultTargetPlatform == TargetPlatform.iOS
            ? WebKitWebViewControllerCreationParams(
                allowsInlineMediaPlayback: true,
                // No autoplay: audio and video wait for the viewer's tap.
                mediaTypesRequiringUserAction: const {
                  PlaybackMediaTypes.audio,
                  PlaybackMediaTypes.video,
                },
              )
            : const PlatformWebViewControllerCreationParams(),
      );
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        unawaited(platform.setMediaPlaybackRequiresUserGesture(true));
        unawaited(
          platform.setCustomWidgetCallbacks(
            onShowCustomWidget: _showFullScreen,
            onHideCustomWidget: _hideFullScreen,
          ),
        );
      } else if (platform is WebKitWebViewController) {
        unawaited(platform.setAllowsBackForwardNavigationGestures(false));
      }
      unawaited(controller.setJavaScriptMode(JavaScriptMode.unrestricted));
      unawaited(controller.setBackgroundColor(Colors.black));
      unawaited(
        controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              if (!request.isMainFrame) {
                // The player's own frames load over HTTPS only.
                return Uri.tryParse(request.url)?.scheme == 'https'
                    ? NavigationDecision.navigate
                    : NavigationDecision.prevent;
              }
              final uri = Uri.tryParse(request.url);
              if (uri != null && isFacebookPlayerPage(uri)) {
                return NavigationDecision.navigate;
              }
              // Facebook sends a private or sign-in-only video to its login
              // page: the app never shows it, and the video is unavailable.
              if (uri != null &&
                  RegExp(r'(^|/)(login|checkpoint)').hasMatch(uri.path)) {
                _fail(epoch);
              }
              return NavigationDecision.prevent;
            },
            onWebResourceError: (error) {
              if (error.isForMainFrame != false) _fail(epoch);
            },
            onHttpError: (error) {
              final uri = error.request?.uri;
              if (uri != null && isFacebookPlayerPage(uri)) _fail(epoch);
            },
            onPageFinished: (_) => _startProbe(epoch),
          ),
        ),
      );
      _controller = controller;
      _loaded = false;
      _timeout = Timer(const Duration(seconds: 25), () {
        if (!_confirmed) _fail(epoch);
      });
    } catch (_) {
      _failed = true;
    }
  }

  void _startProbe(int epoch) {
    if (epoch != _epoch || _confirmed || _failed) return;
    _poll?.cancel();
    var tries = 0;
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      final controller = _controller;
      if (epoch != _epoch || controller == null || tries++ > 12) {
        timer.cancel();
        return;
      }
      try {
        final raw = await controller.runJavaScriptReturningResult(_probeScript);
        final probe = switch ('$raw'.replaceAll('"', '')) {
          'playable' => _Probe.playable,
          'gone' => _Probe.gone,
          _ => _Probe.waiting,
        };
        if (epoch != _epoch) return;
        if (probe == _Probe.playable) {
          _confirmed = true;
          _timeout?.cancel();
          timer.cancel();
        } else if (probe == _Probe.gone) {
          timer.cancel();
          _fail(epoch);
        }
      } catch (_) {
        // A page between loads cannot answer yet; the timeout decides.
      }
    });
  }

  void _showFullScreen(Widget view, void Function() onHidden) {
    if (!mounted || _fullScreen != null) return;
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: view),
      ),
    );
    _fullScreen = route;
    unawaited(
      Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
        if (_fullScreen == route) {
          _fullScreen = null;
          onHidden();
        }
      }),
    );
  }

  void _hideFullScreen() {
    final route = _fullScreen;
    _fullScreen = null;
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route);
    }
  }

  void _fail(int epoch) {
    if (!mounted || epoch != _epoch || _failed) return;
    _hideFullScreen();
    setState(() => _failed = true);
    _close();
  }

  void _close() {
    _epoch++;
    _timeout?.cancel();
    _timeout = null;
    _poll?.cancel();
    _poll = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      // Stop any sound before the web view goes.
      unawaited(
        controller.loadHtmlString('<html></html>').catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    _hideFullScreen();
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _failed || _controller == null
      ? const SermonVideoUnavailable()
      : AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (!_loaded) _load(constraints.maxWidth);
                return WebViewWidget(
                  key: ValueKey(widget.videoUrl),
                  controller: _controller!,
                );
              },
            ),
          ),
        );
}
