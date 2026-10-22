import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

typedef MobileDestination = ({String path, String label, IconData icon});

/// The bottom tabs (design handoff, owner decision 2026-10-21: Home, Bible &
/// Hymns, Sermons, Give, Calendar). Story 6.1 brings Home and Calendar and
/// story 6.3 Give; Bible & Hymns and Sermons join with epic 6 entries 6 and 9
/// (between Home and Give). My duties, My follow-ups and My cell are reached
/// from their Home cards and the Account menu. Inbox and the account live in
/// the top bar; the platform status, fixture and access screens are internal
/// and keep their routes but no tab.
const mobileDestinations = <MobileDestination>[
  (path: ClientPaths.home, label: 'Home', icon: Icons.home_outlined),
  (path: ClientPaths.give, label: 'Give', icon: Icons.favorite_border),
  (
    path: ClientPaths.calendar,
    label: 'Calendar',
    icon: Icons.calendar_today_outlined,
  ),
];

/// The tabs: the same public tabs for everyone, signed in or not, Pending or
/// member (story 6.1). [grants] decides only what each screen shows.
List<MobileDestination> mobileDestinationsFor(MemberGrants? grants) =>
    mobileDestinations;

/// Routes that show the top bar (logo, inbox, account or Sign in): the tab
/// roots for everyone, and every other screen of a caller without member
/// access except an event's or a giving method's detail (each has its own
/// back bar).
bool _showsTopBar(String location, bool member) =>
    location == ClientPaths.home ||
    location == ClientPaths.give ||
    location == ClientPaths.calendar ||
    (!member &&
        !location.startsWith('${ClientPaths.calendar}/') &&
        !location.startsWith('${ClientPaths.give}/'));

class MobileApp extends StatefulWidget {
  const MobileApp({
    super.key,
    this.initialLocation = ClientPaths.home,
    this.themeMode,
    this.launchCurtain = false,
  });

  final String initialLocation;

  /// Carry the launch screen into the app ([LaunchCurtain]); the real app
  /// turns it on, tests leave it off.
  final bool launchCurtain;

  /// Defaults to the system setting (full light/dark swap).
  final ThemeMode? themeMode;

  @override
  State<MobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<MobileApp> {
  late final GoRouter _router = buildClientRouter(
    initialLocation: widget.initialLocation,
    // Story 2.4: a new account continues to the membership request.
    membershipRequests: true,
    // Story 2.9: sign-in help links to staff-assisted recovery on this phone.
    assistedRecovery: true,
    // Story 4.5: the Home tab; story 6.1: and the public Calendar.
    memberHome: true,
    shell: (location, focusSelectedNav, child) => MobileShell(
      location: location,
      focusSelectedNav: focusSelectedNav,
      child: child,
    ),
  );

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Story 3.6: a tapped notification opens its inbox item, and the device
    // registers for push once member access is granted. The push SDK is off
    // (NoPushMessaging) until the owner's Firebase app is wired in.
    return PushBridge(
      router: _router,
      child: MaterialApp.router(
        title: 'BICC Kafue',
        theme: churchMobileTheme(Brightness.light),
        darkTheme: churchMobileTheme(Brightness.dark),
        themeMode: widget.themeMode ?? ThemeMode.system,
        routerConfig: _router,
        builder: (context, child) =>
            widget.launchCurtain ? LaunchCurtain(child: child!) : child!,
      ),
    );
  }
}

/// The church navy of the native launch screen (android/app/src/main/res/
/// values/colors.xml, splash_background), whatever the theme.
const _launchNavy = Color(0xFF14246B);

/// The launch screen carried into the app. The system splash (the white seal
/// on navy, navy system bars) ends at Flutter's first frame, which here draws
/// the same picture, so the hand-over is invisible. While the app loads
/// behind it the seal breathes; once the server has answered who this is (or
/// no one is signed in) it fades away as the seal grows slightly, and the
/// system bars return to the app's colours. It shows for at least [minHold]
/// (one breath) and never longer than [maxHold]. With reduced motion the seal
/// stays still and the screen simply goes.
class LaunchCurtain extends ConsumerStatefulWidget {
  const LaunchCurtain({
    super.key,
    required this.child,
    this.minHold = const Duration(milliseconds: 900),
    this.maxHold = const Duration(seconds: 4),
  });

  final Widget child;
  final Duration minHold;
  final Duration maxHold;

  @override
  ConsumerState<LaunchCurtain> createState() => _LaunchCurtainState();
}

class _LaunchCurtainState extends ConsumerState<LaunchCurtain>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  final _timers = <Timer>[];
  bool _minDone = false;
  bool _overdue = false;
  bool _leaving = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _timers
      ..add(Timer(widget.minHold, () => _mark(() => _minDone = true)))
      ..add(Timer(widget.maxHold, () => _mark(() => _overdue = true)));
  }

  void _mark(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _pulse.stop();
    } else if (!_pulse.isAnimating && !_leaving) {
      _pulse.repeat(reverse: true);
    }
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    _pulse.stop();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _finish();
      return;
    }
    _fade.forward().whenComplete(_finish);
  }

  /// The curtain is gone: the system bars take the app's colours again (the
  /// curtain painted them navy, and nothing else would put them back).
  void _finish() {
    if (!mounted) return;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final icons = dark ? Brightness.light : Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: icons,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: ChurchColors.of(context).surface,
        systemNavigationBarIconBrightness: icons,
      ),
    );
    setState(() => _gone = true);
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _pulse.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return widget.child;
    // Ready once the server has answered this account's access (or nobody
    // is signed in).
    final signedIn =
        ref.watch(accountProvider.select((s) => s.accountId)) != null;
    final answered =
        ref.watch(myAccessProvider.select((s) => s.result)) != null;
    if (_minDone && (!signedIn || answered || _overdue) && !_leaving) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _leave();
      });
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: Listenable.merge([_pulse, _fade]),
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(_fade.value);
            final breath = Curves.easeInOut.transform(_pulse.value);
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: const SystemUiOverlayStyle(
                statusBarColor: _launchNavy,
                statusBarIconBrightness: Brightness.light,
                statusBarBrightness: Brightness.dark,
                systemNavigationBarColor: _launchNavy,
                systemNavigationBarIconBrightness: Brightness.light,
              ),
              // Taps wait for the app; once it fades they reach it.
              child: AbsorbPointer(
                absorbing: !_leaving,
                child: Opacity(
                  opacity: 1 - t,
                  child: ColoredBox(
                    key: const Key('launch-curtain'),
                    color: _launchNavy,
                    child: Center(
                      // The white seal, 180 across, as the system splash
                      // draws it.
                      child: Transform.scale(
                        scale: 1 + 0.04 * breath + 0.06 * t,
                        child: Semantics(
                          label: 'BICC Kafue, loading',
                          child: const ChurchLogo(size: 182, onNavy: true),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The member app frame from the design handoff: a top bar on Home (logo,
/// inbox with its unread count, the member's initials), the bottom tabs on a
/// surface bar with a 1 px top line (active = link colour, 700), and pushed
/// screens with their own back title.
class MobileShell extends ConsumerWidget {
  const MobileShell({
    super.key,
    required this.location,
    required this.child,
    this.focusSelectedNav = false,
  });

  /// Put focus on the selected tab (the user navigated with the tabs).
  final bool focusSelectedNav;

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final grants = ref.watch(myAccessProvider.select((s) => s.grants));
    final destinations = mobileDestinationsFor(grants);
    final member = grants != null;
    // Story 2.3: every navigation (a new shell) and every resume asks the
    // server for the caller's grants again.
    return AccessRefresher(
      child: Scaffold(
        body: FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: Column(
            children: [
              if (_showsTopBar(location, member))
                _TopBar(member: member, location: location),
              // The tab bar below owns the bottom safe area; pages must not add
              // it again. This Scaffold also already shrinks for the on-screen
              // keyboard; the page's own Scaffold must not shrink for it a second
              // time, or the page body is left with no height while typing.
              Expanded(
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .removePadding(
                        removeBottom: destinations.isNotEmpty,
                        removeTop: _showsTopBar(location, member),
                      )
                      .removeViewInsets(removeBottom: true),
                  child: FocusTraversalGroup(child: child),
                ),
              ),
              if (destinations.isNotEmpty)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.surface,
                    border: Border(top: BorderSide(color: c.line)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: FocusTraversalGroup(
                      child: Semantics(
                        role: SemanticsRole.tabBar,
                        label: 'App sections',
                        explicitChildNodes: true,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
                          child: Row(
                            children: [
                              for (final d in destinations)
                                Expanded(
                                  child: NavItem(
                                    key: Key('nav-${d.path}'),
                                    label: d.label,
                                    icon: d.icon,
                                    vertical: true,
                                    selected: _selected(d.path),
                                    autofocus:
                                        focusSelectedNav && _selected(d.path),
                                    onTap: () => goFromNav(context, d.path),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A tab stays selected on its own detail screens (a duty, a plan).
  bool _selected(String path) =>
      location == path ||
      (path != ClientPaths.home && location.startsWith('$path/'));
}

/// The handoff's top bar: the emblem alone (it carries the church name), then
/// the inbox with its unread count and the member's initials; a caller
/// without member access sees a Sign in pill instead.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.member, required this.location});

  final bool member;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final signedIn =
        ref.watch(accountProvider.select((s) => s.accountId)) != null;
    return ColoredBox(
      color: c.bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
          child: Row(
            children: [
              const ChurchLogo(),
              const Spacer(),
              if (member) ...[
                _InboxButton(location: location),
                const SizedBox(width: 4),
                _AccountButton(location: location),
              ] else
                FocusRing(
                  child: FilledButton(
                    key: const Key('nav-/account'),
                    onPressed: () => goFromNav(context, ClientPaths.account),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: Text(signedIn ? 'Account' : 'Sign in'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InboxButton extends ConsumerWidget {
  const _InboxButton({required this.location});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final items = ref.watch(inboxProvider.select((s) => s.inbox?.items));
    final unread = items?.where((i) => i.opened == false).length ?? 0;
    final label = unread == 0 ? 'Inbox' : 'Inbox, $unread unread';
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: FocusRing(
        radius: 22,
        child: InkResponse(
          key: const Key('nav-/inbox'),
          radius: 22,
          onTap: () => context.push(ClientPaths.inbox),
          child: SizedBox.square(
            dimension: ChurchGeometry.minTarget,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.inbox_outlined, color: c.ink, size: 24),
                if (unread > 0)
                  Positioned(
                    top: 6,
                    right: 4,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      height: 18,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: c.accent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountButton extends ConsumerWidget {
  const _AccountButton({required this.location});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final summary = ref.watch(memberSummaryControllerProvider).result;
    final name = summary is MemberAccessGranted
        ? summary.summary.displayName
        : null;
    return Semantics(
      button: true,
      label: 'Account',
      excludeSemantics: true,
      child: FocusRing(
        radius: 22,
        child: InkResponse(
          key: const Key('nav-/account'),
          radius: 22,
          onTap: () => context.push(ClientPaths.account),
          child: SizedBox.square(
            dimension: ChurchGeometry.minTarget,
            child: Center(
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.primary,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: name == null
                    ? const Icon(
                        Icons.person_outline,
                        color: Colors.white,
                        size: 20,
                      )
                    : Text(
                        initialsOf(name),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two initials for an avatar: the first letters of the first and last
/// words, skipping a leading "SYNTHETIC" marker.
String initialsOf(String name) {
  final words = name
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty && w != 'SYNTHETIC')
      .toList();
  if (words.isEmpty) return '?';
  final first = words.first.characters.first;
  final last = words.length > 1 ? words.last.characters.first : '';
  return (first + last).toUpperCase();
}
