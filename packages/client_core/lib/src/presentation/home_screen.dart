import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/access_controllers.dart' show myAccessProvider;
import '../application/account_controllers.dart'
    show memberSummaryControllerProvider;
import '../application/providers.dart' show accountProvider;
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/member_access.dart' show MemberAccessGranted;
import 'calendar_screens.dart' show ComingUpSection;
import 'cell_screens.dart' show MyCellHomeCard;
import 'duties_screens.dart' show LeaderNeedsAttentionCard, MyDutiesHomeCard;
import 'followups_screens.dart' show MyFollowUpsHomeCard;
import 'home_banners.dart' show HomeBannersCarousel;

/// The mobile Home tab (stories 4.5 and 6.1): everyone gets it, signed in or
/// not. A member sees a greeting and their cards (a department leader's
/// Needs attention, My duties, My follow-ups, My cell); a guest or Pending
/// applicant sees no member card. Everyone then sees Coming up, the next
/// published events. The shell's top bar carries the logo and the way in, so
/// Home has no app bar of its own. Later entries add their own Home content
/// here (banners, Sunday hymns, announcements).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final access = ref.watch(myAccessProvider.select((s) => s.result));
    final signedIn =
        ref.watch(accountProvider.select((s) => s.accountId)) != null;
    final member = access is AccessReadOk<MemberGrants>;
    // A signed-in account whose access read failed (offline, a server
    // problem) keeps its member cards: each card reports its own failure
    // honestly, and none of them is treated as a guest's Home.
    final unknown = signedIn && access is AccessReadFailed<MemberGrants>;
    final cards = member || unknown;
    // Signed out: the guest line. Signed in without member access (a Pending
    // applicant, an account in review): a neutral line; their status is
    // under Account. Not yet answered: nothing until it is known.
    final guest = !signedIn;
    final noMemberAccess = signedIn && access is AccessReadDenied<MemberGrants>;
    final summary = ref.watch(memberSummaryControllerProvider).result;
    final name = member && summary is MemberAccessGranted
        ? summary.summary.displayName
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty && w != 'SYNTHETIC')
              .firstOrNull
        : null;
    final hour = ChurchTime.wall(DateTime.now()).hour;
    final greeting = !cards
        ? 'Welcome'
        : hour < 12
        ? 'Good morning'
        : hour < 17
        ? 'Good afternoon'
        : 'Good evening';
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Story 6.2: Home opens with the church's banners (the
                // yearly theme first), for everyone.
                const HomeBannersCarousel(),
                Semantics(
                  header: true,
                  child: Text(
                    name == null ? greeting : '$greeting, $name',
                    key: const Key('home-greeting'),
                    style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
                  ),
                ),
                if (guest) ...[
                  const SizedBox(height: 6),
                  Text(
                    'What\'s on at church is on the Calendar. Members sign in '
                    'to see their duties and their cell.',
                    key: const Key('home-guest-line'),
                    style: ChurchType.body.copyWith(color: c.muted),
                  ),
                ] else if (noMemberAccess) ...[
                  const SizedBox(height: 6),
                  Text(
                    'What\'s on at church is on the Calendar. Your membership '
                    'status is under Account.',
                    key: const Key('home-signed-in-line'),
                    style: ChurchType.body.copyWith(color: c.muted),
                  ),
                ],
                const SizedBox(height: 18),
                if (cards) ...[
                  // Story 4.9: a department leader's Needs attention card
                  // comes first (hidden for everyone else). Story 4.6: My
                  // follow-ups shows while the member owns open work. Story
                  // 5.5: My cell shows for a member with a confirmed cell.
                  const _HomeGap(child: LeaderNeedsAttentionCard()),
                  const _HomeGap(child: MyDutiesHomeCard()),
                  const _HomeGap(child: MyFollowUpsHomeCard()),
                  const _HomeGap(child: MyCellHomeCard()),
                ],
                // Story 6.1: the next published events, for everyone.
                const ComingUpSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The 16 px gap after a Home card.
class _HomeGap extends StatelessWidget {
  const _HomeGap({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 16), child: child);
}
