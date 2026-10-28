import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart' show myAccessProvider;
import '../application/account_controllers.dart'
    show memberSummaryControllerProvider;
import '../application/application_controllers.dart'
    show membershipApplicationProvider;
import '../application/providers.dart' show accountProvider;
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/member_access.dart' show MemberAccessGranted;
import '../domain/membership_application.dart';
import 'announcement_screens.dart' show HomeAnnouncementsSection;
import 'cell_screens.dart' show MyCellHomeCard;
import 'duties_screens.dart' show LeaderNeedsAttentionCard, MyDutiesHomeCard;
import 'followups_screens.dart' show MyFollowUpsHomeCard;
import 'home_banners.dart' show HomeBannersCarousel;
import 'home_coming_up.dart' show ComingUpSection;
import 'hymn_list_screens.dart' show HomeSundayHymnsSection;
import 'shell_routing.dart' show ClientPaths, goFromNav;

/// The mobile Home tab (stories 4.5, 6.1 and entry 14): everyone gets it,
/// signed in or not. It opens with the church's banners (the yearly theme
/// first). A member then sees a greeting and their cards (a department
/// leader's Needs attention, My duties, My follow-ups, My cell); a guest sees
/// the Join card; a Pending applicant sees their request with church approval
/// and their cell as two separate chips. Everyone then sees the pinned
/// announcements (story 6.13) with See all, Hymns for this Sunday (6.8) and
/// Coming up as poster cards. The shell's top bar carries the logo, search
/// and the way in, so Home has no app bar of its own.
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
    // Signed out: the Join card. Signed in without member access (a Pending
    // applicant, an account in review): their request's card. Not yet
    // answered: nothing until it is known.
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
    final greeting = hour < 12
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
                if (cards) ...[
                  Semantics(
                    header: true,
                    child: Text(
                      name == null ? greeting : '$greeting, $name',
                      key: const Key('home-greeting'),
                      style: ChurchType.mobileScreenTitle.copyWith(
                        color: c.ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                // Entry 14: the guest's way in and the applicant's request.
                if (guest) const _HomeGap(child: HomeJoinCard()),
                if (noMemberAccess) const _HomeGap(child: HomePendingCard()),
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
                // Story 6.13: the pinned announcements, for everyone.
                const _HomeGap(child: HomeAnnouncementsSection()),
                // Story 6.8: Hymns for this Sunday, Saturday and Sunday.
                const HomeSundayHymnsSection(gap: 16),
                // Story 6.1, entry 14: the next events and the current
                // sermon series as poster cards, for everyone.
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

/// Entry 14 (signed out): "Part of the church family?" with Join, which
/// opens the Account page's Sign in and Create account.
class HomeJoinCard extends StatelessWidget {
  const HomeJoinCard({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ChurchCard(
      key: const Key('home-join-card'),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    'Part of the church family?',
                    style: ChurchType.itemTitle.copyWith(color: c.ink),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sign in to see your duties and your cell, or ask to join.',
                  key: const Key('home-guest-line'),
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          FocusRing(
            child: FilledButton(
              key: const Key('home-join'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, ChurchGeometry.minTarget),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              onPressed: () => goFromNav(context, ClientPaths.account),
              child: const Text('Join'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Entry 14 (a Pending applicant): their membership request, with church
/// approval and the cell as two separate chips; it opens the request. While
/// the request is not known (loading, failed, none sent) a plain line says
/// where the status is.
class HomePendingCard extends ConsumerWidget {
  const HomePendingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(membershipApplicationProvider);
    final app = switch (s.result) {
      AccessReadOk(:final value) => value.application,
      _ => null,
    };
    if (app == null) {
      return Text(
        s.result is AccessReadOk<MyApplication>
            ? 'Sermons, events, the Bible, hymns and giving are open to '
                  'you. To become a member, send a membership request under '
                  'Account.'
            : 'What\'s on at church is on the Calendar. Your membership '
                  'status is under Account.',
        key: const Key('home-signed-in-line'),
        style: ChurchType.body.copyWith(color: c.muted),
      );
    }
    final (churchLabel, churchTone) = switch (app.churchStatus) {
      ChurchStatus.awaitingApproval => (
        'Awaiting church approval',
        StatusTone.warning,
      ),
      ChurchStatus.detailsRequested => (
        'The church asked for more details',
        StatusTone.warning,
      ),
      ChurchStatus.approved => ('Approved by the church', StatusTone.success),
      ChurchStatus.notApproved => ('Not approved', StatusTone.neutral),
      ChurchStatus.withdrawn => ('Withdrawn', StatusTone.neutral),
    };
    final options = switch (s.optionsResult) {
      AccessReadOk(:final value) => value,
      _ => const <CellOption>[],
    };
    final cellName = options
        .where((o) => o.cellId == app.cellChoice.cellId)
        .map((o) => o.label)
        .firstOrNull;
    final (cellLabel, cellTone) = switch (app.cellChoice.kind) {
      CellChoiceKind.cell => (
        cellName == null
            ? 'Cell awaiting confirmation'
            : '$cellName · Awaiting confirmation',
        StatusTone.warning,
      ),
      CellChoiceKind.notSure => (
        'Not sure · office will follow up',
        StatusTone.neutral,
      ),
      CellChoiceKind.notInCell => ('Not in a cell yet', StatusTone.neutral),
    };
    return Semantics(
      button: true,
      label:
          'Your membership request. Church approval: $churchLabel. Cell: '
          '$cellLabel. Open your request.',
      excludeSemantics: true,
      child: FocusRing(
        radius: ChurchGeometry.mobileCardRadius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const Key('home-pending-card'),
            borderRadius: BorderRadius.circular(
              ChurchGeometry.mobileCardRadius,
            ),
            onTap: () => context.push(ClientPaths.membership),
            child: Ink(
              padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(
                  ChurchGeometry.mobileCardRadius,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Your membership request',
                          style: ChurchType.itemTitle.copyWith(color: c.ink),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 20, color: c.muted),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusLabel(
                        key: const Key('home-pending-church'),
                        label: churchLabel,
                        tone: churchTone,
                      ),
                      StatusLabel(
                        key: const Key('home-pending-cell'),
                        label: cellLabel,
                        tone: cellTone,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sermons, events, the Bible, hymns and giving are open '
                    'to you now.',
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
