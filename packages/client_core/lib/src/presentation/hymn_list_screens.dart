import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart' show myAccessProvider;
import '../application/hymn_controllers.dart';
import '../application/hymn_list_controllers.dart';
import '../application/providers.dart' show accountProvider;
import '../domain/access_grants.dart';
import '../domain/hymn_book.dart';
import '../domain/hymn_lists.dart';
import 'hymn_screens.dart' show HymnRow;
import 'shell_routing.dart' show ClientPaths;

// Story 6.8 (mobile): the Save pill on a hymn, the member's saved hymns in
// the hymn book and on their own screen, and Hymns for this Sunday on Home.
// The book itself is built into the app (story 6.7); only item ids travel.

/// The item ids of this Sunday's list the hymn book marks with a Sunday chip
/// (any day of that Sunday's week), or none while the list is unknown.
Set<String> sundayHymnIds(WidgetRef ref) {
  final value = ref.watch(publicSundayHymnsProvider).value;
  if (value == null) return const {};
  return value.idsFor(ref.watch(hymnClockProvider)());
}

/// What the hymn's Save pill says after an answer: the sentence and whether
/// "Check again" applies.
String favouriteNoticeText(FavouriteNotice n) => switch (n) {
  FavouriteNotice.saved => 'Saved. It is under Saved in the hymn book.',
  FavouriteNotice.removed => 'Removed from your saved hymns.',
  FavouriteNotice.membersOnly => 'Saving hymns is for approved church members.',
  FavouriteNotice.signInAgain => 'Please sign in again.',
  FavouriteNotice.notAvailable =>
    'The church server could not do this now. Try again later.',
  FavouriteNotice.refused => 'The church server refused this.',
  FavouriteNotice.unconfirmed =>
    'We couldn\'t tell whether that reached the church server. Check again '
        'sends the same request, so nothing is saved twice.',
  FavouriteNotice.notSent =>
    'This build has no server configured, so nothing was sent.',
};

/// Story 6.8: the Save / Saved pill in a hymn's bar (design handoff screen
/// 5). A member saves or removes the hymn; it shows as saved only once the
/// server confirmed it. A guest is asked to sign in, and a signed-in account
/// without member access (Pending, on hold) is told that saving is for
/// approved members; nothing is sent for either.
class HymnFavouriteAction extends ConsumerWidget {
  const HymnFavouriteAction({
    super.key,
    required this.hymn,
    required this.edition,
  });

  final Hymn hymn;

  /// The built-in book's edition, sent with the item id.
  final String edition;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final signedIn =
        ref.watch(accountProvider.select((s) => s.accountId)) != null;
    final access = ref.watch(myAccessProvider.select((s) => s.result));
    final favourites = ref.watch(hymnFavouritesProvider);
    final ctl = ref.read(hymnFavouritesProvider.notifier);
    ref.listen(hymnFavouritesProvider.select((s) => s.notice), (prev, next) {
      final s = ref.read(hymnFavouritesProvider);
      if (next == null || next == prev || s.noticeAction?.itemId != hymn.id) {
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: Key('hymn-favourite-notice-${next.name}'),
            content: Text(favouriteNoticeText(next)),
            action: next == FavouriteNotice.unconfirmed
                ? SnackBarAction(
                    key: const Key('hymn-favourite-check-again'),
                    label: 'Check again',
                    onPressed: ctl.checkAgain,
                  )
                : null,
          ),
        );
    });
    final saved = favourites.isSaved(hymn.id);
    final sending = favourites.isSending(hymn.id);
    final label = sending
        ? (favourites.pending!.saves ? 'Saving…' : 'Removing…')
        : saved
        ? 'Saved'
        : 'Save';
    void onPressed() {
      if (!signedIn) {
        _askToSignIn(context);
      } else if (access is AccessReadDenied<MemberGrants>) {
        _membersOnly(context);
      } else if (saved) {
        ctl.remove(hymn.id, edition);
      } else {
        ctl.save(hymn.id, edition);
      }
    }

    final on = saved && !sending;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12),
      child: Semantics(
        button: true,
        toggled: signedIn ? saved : null,
        label: saved
            ? 'Saved. Remove from saved hymns'
            : 'Save this ${hymn.kind == HymnKind.chorus ? 'chorus' : 'hymn'}',
        excludeSemantics: true,
        onTap: favourites.busy ? null : onPressed,
        child: FocusRing(
          radius: 19,
          child: TextButton(
            key: const Key('hymn-favourite'),
            onPressed: favourites.busy ? null : onPressed,
            style: TextButton.styleFrom(
              minimumSize: const Size(64, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: StadiumBorder(
                side: on
                    ? BorderSide(color: c.primary, width: 1.5)
                    : BorderSide(color: c.line),
              ),
              backgroundColor: on ? c.primary : c.surface,
              foregroundColor: on ? c.onPrimary : c.ink,
              textStyle: ChurchType.chip.copyWith(fontSize: 14),
            ),
            child: Text(label, softWrap: false),
          ),
        ),
      ),
    );
  }

  static Future<void> _askToSignIn(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialog) => ChurchDialog(
      key: const Key('hymn-favourite-sign-in-prompt'),
      title: 'Save this hymn',
      content: const Text(
        'Church members sign in to keep their favourite hymns in one place.',
      ),
      actions: [
        TextButton(
          key: const Key('hymn-favourite-not-now'),
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const Key('hymn-favourite-sign-in'),
          onPressed: () {
            Navigator.of(dialog).pop();
            context.push(ClientPaths.signIn);
          },
          child: const Text('Sign in'),
        ),
      ],
    ),
  );

  static Future<void> _membersOnly(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialog) => ChurchDialog(
      key: const Key('hymn-favourite-members-only'),
      title: 'Saving hymns',
      content: const Text(
        'Saving hymns is for approved church members. Your membership status '
        'is under Account.',
      ),
      actions: [
        FilledButton(
          key: const Key('hymn-favourite-members-only-ok'),
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// The member's saved items that are in [book], newest first (an item a
/// later book no longer has is left out).
List<Hymn> savedHymnsIn(HymnBook book, MyHymnFavourites favourites) => [
  for (final f in favourites.favourites) ?book.byId(f.itemId),
];

/// Story 6.8: the Saved group at the top of the hymn book (no search): up to
/// [shown] saved items, newest first, and "See all" to the full list. Shown
/// only to a signed-in member with saved hymns; a failed read says so here
/// and never looks like no saved hymns.
class SavedHymnsSliver extends ConsumerWidget {
  const SavedHymnsSliver({
    super.key,
    required this.book,
    required this.sundayIds,
  });

  static const shown = 5;

  final HymnBook book;
  final Set<String> sundayIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(hymnFavouritesProvider);
    final access = ref.watch(myAccessProvider.select((x) => x.result));
    if (!s.signedIn || access is AccessReadDenied<MemberGrants>) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final Widget? body;
    final value = s.value;
    if (value != null) {
      final saved = savedHymnsIn(book, value);
      if (saved.isEmpty) {
        return const SliverToBoxAdapter(child: SizedBox.shrink());
      }
      return SliverMainAxisGroup(
        key: const Key('hymn-saved'),
        slivers: [
          _header(
            context,
            more: saved.length > shown
                ? TextButton(
                    key: const Key('hymn-saved-see-all'),
                    onPressed: () => context.push(ClientPaths.savedHymns),
                    child: Text('See all ${saved.length}'),
                  )
                : null,
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: DecoratedSliver(
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(
                  ChurchGeometry.mobileCardRadius,
                ),
              ),
              sliver: SliverList.list(
                children: [
                  for (final (i, hymn) in saved.take(shown).indexed)
                    HymnRow(
                      key: Key('hymn-saved-row-${hymn.id}'),
                      hymn: hymn,
                      first: i == 0,
                      last:
                          i ==
                          (saved.length > shown ? shown : saved.length) - 1,
                      showKind: true,
                      sunday: sundayIds.contains(hymn.id),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    if (s.result case AccessReadFailed()) {
      body = Text(
        'Your saved hymns could not be loaded. The hymn book below works as '
        'usual.',
        key: const Key('hymn-saved-failed'),
        style: ChurchType.secondary.copyWith(color: c.muted),
      );
    } else {
      body = null;
    }
    if (body == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverMainAxisGroup(
      slivers: [
        _header(
          context,
          more: TextButton(
            key: const Key('hymn-saved-retry'),
            onPressed: ref.read(hymnFavouritesProvider.notifier).reload,
            child: const Text('Try again'),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverToBoxAdapter(child: body),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, {Widget? more}) {
    final c = ChurchColors.of(context);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
      sliver: SliverToBoxAdapter(
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Saved',
                  key: const Key('hymn-saved-header'),
                  style: ChurchType.label.copyWith(color: c.muted),
                ),
              ),
            ),
            ?more,
          ],
        ),
      ),
    );
  }
}

/// Story 6.8 (mobile, members): every saved hymn, newest first, pushed from
/// the hymn book's Saved group with its back bar. A guest is asked to sign
/// in; a failed read says so with Try again.
class SavedHymnsScreen extends ConsumerStatefulWidget {
  const SavedHymnsScreen({super.key});

  @override
  ConsumerState<SavedHymnsScreen> createState() => _SavedHymnsScreenState();
}

class _SavedHymnsScreenState extends ConsumerState<SavedHymnsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final s = ref.read(hymnFavouritesProvider);
      if (!s.loading) ref.read(hymnFavouritesProvider.notifier).reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final book = ref.watch(hymnBookProvider);
    final s = ref.watch(hymnFavouritesProvider);
    final access = ref.watch(myAccessProvider.select((x) => x.result));
    final sundayIds = sundayHymnIds(ref);
    final Widget body;
    if (!s.signedIn) {
      body = RequestStateBanner(
        key: const Key('hymn-saved-signed-out'),
        tone: StatusTone.neutral,
        title: 'Sign in to see your saved hymns',
        message: 'Church members sign in to keep their favourite hymns here.',
        actions: [
          BannerAction(
            'Sign in',
            () => context.push(ClientPaths.signIn),
            key: const Key('hymn-saved-sign-in'),
            primary: true,
          ),
        ],
      );
    } else if (access is AccessReadDenied<MemberGrants> ||
        s.result is AccessReadDenied<MyHymnFavourites>) {
      body = const RequestStateBanner(
        key: Key('hymn-saved-members-only'),
        tone: StatusTone.neutral,
        title: 'For approved church members',
        message:
            'Saving hymns is for approved church members. Your membership '
            'status is under Account.',
      );
    } else if (s.value != null && book.hasValue) {
      final saved = savedHymnsIn(book.requireValue, s.value!);
      body = saved.isEmpty
          ? DecoratedBox(
              key: const Key('hymn-saved-empty'),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(
                  ChurchGeometry.mobileCardRadius,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No saved hymns yet. Open a hymn and tap Save to keep it '
                  'here.',
                  textAlign: TextAlign.center,
                  style: ChurchType.body.copyWith(color: c.muted),
                ),
              ),
            )
          : DecoratedBox(
              key: const Key('hymn-saved-list'),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(
                  ChurchGeometry.mobileCardRadius,
                ),
              ),
              child: Column(
                children: [
                  for (final (i, hymn) in saved.indexed)
                    HymnRow(
                      hymn: hymn,
                      first: i == 0,
                      last: i == saved.length - 1,
                      showKind: true,
                      sunday: sundayIds.contains(hymn.id),
                    ),
                ],
              ),
            );
    } else if (s.result is AccessReadFailed<MyHymnFavourites> ||
        (book.hasError && !book.isLoading)) {
      body = RequestStateBanner(
        key: const Key('hymn-saved-error'),
        tone: StatusTone.warning,
        icon: Icons.error_outline,
        title: 'Your saved hymns could not be loaded',
        message: 'This is not an empty list. Try again.',
        actions: [
          BannerAction(
            'Try again',
            () {
              ref.read(hymnFavouritesProvider.notifier).reload();
              if (book.hasError) ref.invalidate(hymnBookProvider);
            },
            key: const Key('hymn-saved-error-retry'),
            primary: true,
          ),
        ],
      );
    } else {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: CircularProgressIndicator(key: Key('hymn-saved-loading')),
        ),
      );
    }
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(title: const Text('Saved hymns')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// Story 6.8 (mobile, everyone): Hymns for this Sunday on Home, from Saturday
/// 00:00 to Sunday 23:59 church time (the device's clock, Africa/Lusaka),
/// when this Sunday has a list: a chip per item (its number and title from
/// the built-in book) that opens it, and a link to the hymn book. Hidden on
/// other days and while nothing is set; a failed read says so.
class HomeSundayHymnsSection extends ConsumerWidget {
  const HomeSundayHymnsSection({super.key, this.gap = 0});

  /// The space after the section while it shows (none while it is hidden).
  final double gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final now = ref.watch(hymnClockProvider)();
    if (!SundayHymnsWindow.onHome(now)) return const SizedBox.shrink();
    final s = ref.watch(publicSundayHymnsProvider);
    final book = ref.watch(hymnBookProvider).value;
    final value = s.value;
    final Widget body;
    if (value != null) {
      if (value.sunday != SundayHymnsWindow.thisSunday(now) ||
          value.items.isEmpty) {
        return const SizedBox.shrink();
      }
      body = SingleChildScrollView(
        key: const Key('home-sunday-hymns-chips'),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (i, id) in value.items.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              _SundayHymnChip(id: id, hymn: book?.byId(id)),
            ],
          ],
        ),
      );
    } else if (s.result case AccessReadFailed() || AccessReadDenied()) {
      body = Row(
        children: [
          Expanded(
            child: Text(
              'This Sunday\'s hymns could not be loaded.',
              key: const Key('home-sunday-hymns-failed'),
              style: ChurchType.body.copyWith(color: c.muted),
            ),
          ),
          TextButton(
            key: const Key('home-sunday-hymns-retry'),
            onPressed: ref.read(publicSundayHymnsProvider.notifier).reload,
            child: const Text('Try again'),
          ),
        ],
      );
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: Column(
        key: const Key('home-sunday-hymns'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Hymns for this Sunday',
            action: TextButton(
              key: const Key('home-sunday-hymns-book'),
              onPressed: () => context.go(ClientPaths.hymnBook),
              child: const Text('Hymn book'),
            ),
          ),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }
}

/// One Home chip: the item's number in a pale blue badge and its title.
class _SundayHymnChip extends StatelessWidget {
  const _SundayHymnChip({required this.id, required this.hymn});

  final String id;

  /// Null while the book is loading or when this build's book lacks it.
  final Hymn? hymn;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final (badgeBg, badgeFg) = toneColors(c, StatusTone.info);
    final chorus = id.startsWith('chorus-');
    final number = id.substring(id.indexOf('-') + 1);
    final kind = chorus ? 'Chorus' : 'Hymn';
    final title = hymn?.title ?? '$kind $number';
    return Semantics(
      button: true,
      label: '$kind $number${hymn == null ? '' : ', ${hymn!.title}'}',
      excludeSemantics: true,
      onTap: () => context.push(ClientPaths.hymn(id)),
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.line),
        ),
        child: InkWell(
          key: Key('home-sunday-hymn-$id'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push(ClientPaths.hymn(id)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    number,
                    softWrap: false,
                    style: ChurchType.figures.copyWith(
                      color: badgeFg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ChurchType.itemTitle.copyWith(
                      color: c.ink,
                      fontSize: 15,
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
