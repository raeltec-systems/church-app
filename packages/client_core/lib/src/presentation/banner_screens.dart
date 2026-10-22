import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/banner_controllers.dart';
import '../application/content_controllers.dart'
    show ContentAction, staffEventsProvider;
import '../application/providers.dart' show contentFilePickerProvider;
import '../domain/access_grants.dart';
import '../domain/content_banners.dart';
import '../domain/content_events.dart' show ContentState, StaffEvent;
import 'calendar_screens.dart' show churchShortWhen;
import 'home_banners.dart' show BannerPaths;

// Story 6.2, staff web: the editors (Media, Pastor, Admin) keep Home's
// banners and the rights records their images cite. Banners answers "what is
// on Home now, and what waits to be published?" first; Rights answers "which
// sources may we publish, and for what?". Every list comes from a
// server-checked read, every action is a server-checked command, and an image
// is measured and stored by the server (the browser's file type is never
// trusted). After a lifecycle change the screen asks the server to place or
// remove public files and shows what is still waiting.

const _needs = 'Banners and rights are managed by Media, Pastors and Admins.';

/// A server reason code as a sentence for the editor.
String bannerReasonText(String code, {String? field}) => switch (code) {
  'too_large' when field == 'width' || field == 'height' =>
    'This image is larger than 6000 x 6000.',
  'too_large' => 'This image is larger than 5 MB.',
  'unsupported_type' => 'Only PNG, JPEG or WebP images can be used.',
  'type_mismatch' => 'This file is not the image type it claims to be.',
  'invalid_image' => 'This image file is damaged.',
  'too_small' => 'This image is smaller than 960 x 540.',
  'bad_ratio' => 'Use a landscape image close to 16:9.',
  'source_not_cleared' =>
    'This third-party source is not cleared by the owner (Q5).',
  'use_not_cleared' => 'This rights record does not clear display.',
  'not_in_force' => 'Verify this rights record first.',
  'not_published' when field == 'event_id' =>
    'The linked event is not published.',
  'required' when field == 'image_asset_id' => 'Add an image first.',
  'required' when field == 'image_rights_id' => 'Choose a rights record first.',
  'required' => 'Required',
  'too_long' => 'Too long',
  'out_of_range' when field == 'theme_year' => 'Use a year from 2000 to 2100',
  'must_be_null' => 'Not used for this kind of banner',
  'unknown' => 'Not found. Reload and choose again.',
  'none_cleared' => 'Choose at least one use',
  'invalid' when field == 'source_key' =>
    'Lower case letters, digits and dashes (for example kjv)',
  _ => 'Check this',
};

(StatusTone, String, String) _noticeText(
  BannerNotice n,
  ContentAction? a,
  Map<String, String> fieldErrors, {
  required bool rights,
}) {
  final what = a?.subject ?? (rights ? 'the rights record' : 'the banner');
  final where = rights ? '' : ' Home shows it once its image is placed.';
  return switch (n) {
    BannerNotice.created => (
      StatusTone.success,
      'Draft saved',
      rights
          ? '$what is saved as a draft. Verify it to put it in force.'
          : '$what is saved as a draft. Add its image, then publish it.',
    ),
    BannerNotice.saved => (
      StatusTone.success,
      'Changes saved',
      rights
          ? 'Your changes to $what are a draft until you verify them.'
          : 'Your changes to $what are a draft. Home keeps the published '
                'version until you publish them.',
    ),
    BannerNotice.published => (
      StatusTone.success,
      'Published',
      '$what is published.$where',
    ),
    BannerNotice.verified => (
      StatusTone.success,
      'Verified',
      '$what is in force from now, with you as its verifier.',
    ),
    BannerNotice.withdrawn => (
      StatusTone.success,
      'Withdrawn',
      rights
          ? '$what is no longer in force. Images citing it leave Home.'
          : '$what is off Home and its public file is removed.',
    ),
    BannerNotice.archived => (
      StatusTone.success,
      'Archived',
      '$what is archived and can no longer change.',
    ),
    BannerNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      '$what was changed in another tab or by another editor. The list now '
          'shows the current version; check it and try again.',
    ),
    BannerNotice.nothingToPublish => (
      StatusTone.warning,
      rights ? 'Nothing to verify' : 'Nothing to publish',
      '$what has no saved changes.',
    ),
    BannerNotice.notPublished => (
      StatusTone.warning,
      rights ? 'Not in force' : 'Not published',
      '$what is not published, so there is nothing to withdraw.',
    ),
    BannerNotice.alreadyArchived => (
      StatusTone.warning,
      'Archived',
      '$what is archived and can no longer change.',
    ),
    BannerNotice.invalid => (
      StatusTone.warning,
      rights ? 'Check the rights record' : 'Check the banner',
      'Some details need changing; see the marked fields. Nothing was saved.',
    ),
    BannerNotice.blocked => (
      StatusTone.warning,
      rights ? 'Not verified' : 'Not published',
      [
        for (final e in fieldErrors.entries)
          bannerReasonText(e.value, field: e.key),
      ].join(' '),
    ),
    BannerNotice.notAllowed => (
      StatusTone.danger,
      'Not allowed',
      '$_needs Nothing was changed.',
    ),
    BannerNotice.signInAgain => (
      StatusTone.danger,
      'Please sign in again',
      'Your session is no longer trusted. Nothing was changed.',
    ),
    BannerNotice.notFound => (
      StatusTone.warning,
      'Not found',
      'That no longer exists. The list now shows the current state.',
    ),
    BannerNotice.notAvailable => (
      StatusTone.warning,
      'Not available right now',
      'The church server could not do this now. Nothing was changed.',
    ),
    BannerNotice.refused => (
      StatusTone.danger,
      'Not done',
      'The church server refused this. Nothing was changed.',
    ),
    BannerNotice.unconfirmed => (
      StatusTone.warning,
      'Not confirmed',
      'We could not tell whether $what was changed. Check again sends the '
          'same request, so it cannot apply twice.',
    ),
    BannerNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
  };
}

/// The notices, request state and read state of an editors' list; [body]
/// draws the list once it has loaded.
class _CatalogFrame<T> extends ConsumerStatefulWidget {
  const _CatalogFrame({
    required this.prefix,
    required this.provider,
    required this.rights,
    required this.body,
  });

  final String prefix;
  final NotifierProvider<StaffCatalogController<T>, StaffCatalogState<T>>
  provider;
  final bool rights;
  final Widget Function(T value, StaffCatalogState<T> state) body;

  @override
  ConsumerState<_CatalogFrame<T>> createState() => _CatalogFrameState<T>();
}

class _CatalogFrameState<T> extends ConsumerState<_CatalogFrame<T>> {
  final _noticeFocus = FocusNode(debugLabel: 'content notice');

  @override
  void dispose() {
    _noticeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prefix;
    final s = ref.watch(widget.provider);
    final ctl = ref.read(widget.provider.notifier);
    ref.listen(widget.provider.select((x) => x.notice), (prev, next) {
      if (next == null || next == prev) return;
      final st = ref.read(widget.provider);
      final (_, title, message) = _noticeText(
        next,
        st.noticeAction,
        st.fieldErrors,
        rights: widget.rights,
      );
      announce(context, '$title. $message');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      });
    });
    final children = <Widget>[];
    if (s.pending case final a?) {
      children.add(
        RequestStateBanner(
          key: Key('$p-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the church server about ${a.subject}. Nothing is '
              'shown as done until it answers.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(
        n,
        s.noticeAction,
        s.fieldErrors,
        rights: widget.rights,
      );
      children.add(
        RequestStateBanner(
          key: Key('$p-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == BannerNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: Key('$p-check-again'),
                primary: true,
              ),
            BannerAction('Dismiss', ctl.dismissNotice, key: Key('$p-dismiss')),
          ],
        ),
      );
    }
    if (_syncBanner(s, ctl) case final b?) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.add(b);
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    switch (s.result) {
      case null:
        children.add(
          RequestStateBanner(
            key: Key('$p-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        children.add(widget.body(value, s));
      case AccessReadDenied(:final denial):
        children.add(
          RequestStateBanner(
            key: Key('$p-denied-${denial.name}'),
            tone: StatusTone.warning,
            icon: Icons.lock_outline,
            title: switch (denial) {
              AccessDenial.signedOut => 'Not signed in',
              AccessDenial.untrustedSession => 'Please sign in again',
              AccessDenial.notGranted => 'Not available to you',
              AccessDenial.notLinked => 'No member access yet',
              AccessDenial.unavailable => 'Not available yet',
              _ => 'Access review required',
            },
            message: denial == AccessDenial.notGranted
                ? '$_needs Permissions are checked by the server each time.'
                : 'Nothing is shown until the server allows it.',
          ),
        );
      case AccessReadFailed(:final unreachable):
        children.add(
          RequestStateBanner(
            key: Key('$p-failed'),
            tone: StatusTone.danger,
            icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
            title: unreachable ? 'No connection' : 'Couldn\'t load',
            message: unreachable
                ? 'We couldn\'t reach the church server. This is not an empty '
                      'list: nothing is shown until it answers.'
                : 'The server answered in an unexpected way. Try again later.',
          ),
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// What the last public-file sync left undone, with a way to sync again.
  Widget? _syncBanner(StaffCatalogState<T> s, StaffCatalogController<T> ctl) {
    final p = widget.prefix;
    final again = BannerAction(
      s.syncing ? 'Syncing…' : 'Sync again',
      s.syncing || s.busy ? null : ctl.sync,
      key: Key('$p-sync-again'),
      primary: true,
    );
    return switch (s.sync) {
      FileSyncFailed(:final unreachable) => RequestStateBanner(
        key: Key('$p-sync-failed'),
        tone: StatusTone.warning,
        icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
        title: 'Public files not updated',
        message: unreachable
            ? 'We couldn\'t reach the church server to place or remove public '
                  'files. Home may still show an old image until a sync works.'
            : 'The server could not place or remove public files now. Home '
                  'may still show an old image until a sync works.',
        actions: [again],
      ),
      FileSyncNotAllowed() => RequestStateBanner(
        key: Key('$p-sync-not-allowed'),
        tone: StatusTone.warning,
        title: 'Public files not updated',
        message: 'The server did not accept this session for a sync.',
        actions: [again],
      ),
      FileSyncDone(:final waiting) when waiting > 0 => RequestStateBanner(
        key: Key('$p-sync-waiting'),
        tone: StatusTone.warning,
        title: 'Images still waiting',
        message:
            '$waiting published ${waiting == 1 ? 'image is' : 'images are'} '
            'not placed yet, so Home does not show '
            '${waiting == 1 ? 'it' : 'them'}.',
        actions: [again],
      ),
      _ => null,
    };
  }
}

/// A list section with its count and rows in one card.
Widget _section(
  BuildContext context,
  String title,
  String key,
  List<Widget> rows,
) {
  final c = ChurchColors.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: ChurchGeometry.sectionGap),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          header: true,
          child: Text(
            '$title (${rows.length})',
            key: Key(key),
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
      ),
      ChurchCard(
        padding: EdgeInsets.zero,
        radius: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) Divider(height: 1, color: c.line),
              r,
            ],
          ],
        ),
      ),
    ],
  );
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String body,
  String yes,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => ChurchDialog(
      title: title,
      content: Text(body),
      actions: [
        FocusRing(
          child: TextButton(
            key: const Key('content-confirm-no'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
        ),
        FocusRing(
          child: FilledButton(
            key: const Key('content-confirm-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(yes),
          ),
        ),
      ],
    ),
  );
  return ok == true && context.mounted;
}

// ---------------------------------------------------------------------------
// Banners
// ---------------------------------------------------------------------------

/// The one mark a banner's row carries.
(String, StatusTone) _bannerMark(StaffBanner b) => switch (b.state) {
  ContentState.draft => ('Draft', StatusTone.neutral),
  ContentState.published when b.hasChanges => (
    'Changes not published',
    StatusTone.warning,
  ),
  ContentState.published when b.publicImage == PublicImageState.shown => (
    'On Home',
    StatusTone.success,
  ),
  ContentState.published => ('Published, not shown', StatusTone.warning),
  ContentState.withdrawn => ('Withdrawn', StatusTone.neutral),
  ContentState.archived => ('Archived', StatusTone.neutral),
};

String _kindText(BannerFields f) => switch (f.kind) {
  BannerKind.theme => 'Theme ${f.themeYear}',
  BannerKind.campaign => 'Campaign',
};

/// The screen's finding: what waits to be published, what Home shows and
/// what public files are still to remove.
String _bannersFinding(StaffBanners v) {
  if (v.banners.isEmpty && v.removalsPending == 0) {
    return 'No banners yet. A new banner stays a private draft until you '
        'publish it.';
  }
  final waiting = v.banners
      .where((b) => b.state == ContentState.draft || b.hasChanges)
      .length;
  final onHome = v.banners
      .where(
        (b) =>
            b.state == ContentState.published &&
            b.publicImage == PublicImageState.shown,
      )
      .length;
  return [
    waiting == 0 ? 'Nothing waiting to publish' : '$waiting waiting to publish',
    '$onHome on Home',
    if (v.removalsPending > 0)
      '${v.removalsPending} public '
          '${v.removalsPending == 1 ? 'file' : 'files'} to remove',
  ].join(' · ');
}

/// `/content/banners` (staff web; Media, Pastor and Admin).
class StaffBannersScreen extends ConsumerStatefulWidget {
  const StaffBannersScreen({super.key});

  @override
  ConsumerState<StaffBannersScreen> createState() => _StaffBannersState();
}

class _StaffBannersState extends ConsumerState<StaffBannersScreen> {
  var _creating = false;

  @override
  void initState() {
    super.initState();
    // Opening Banners places or removes any public file still waiting.
    Future.microtask(() {
      if (mounted) ref.read(staffBannersProvider.notifier).sync();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(staffBannersProvider);
    final ctl = ref.read(staffBannersProvider.notifier);
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final value = s.value;
    final newBanner = value == null
        ? null
        : FocusRing(
            child: FilledButton.icon(
              key: const Key('banners-new'),
              onPressed: s.busy
                  ? null
                  : () => setState(() => _creating = !_creating),
              icon: Icon(_creating ? Icons.close : Icons.add),
              label: Text(_creating ? 'Close the form' : 'New banner'),
            ),
          );
    return ChurchPageScaffold(
      title: 'Banners',
      subtitle: value == null ? null : _bannersFinding(value),
      actions: phone
          ? [
              ?newBanner,
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('banners-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [
              ?newBanner,
              staffReloadButton(const Key('banners-reload'), reload),
            ],
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: DefaultTextStyle.merge(
                style: layout.body.copyWith(color: c.ink),
                child: _CatalogFrame<StaffBanners>(
                  prefix: 'banners',
                  provider: staffBannersProvider,
                  rights: false,
                  body: (v, st) => _BannersBody(
                    value: v,
                    state: st,
                    creating: _creating,
                    onCreatingChanged: (x) => setState(() => _creating = x),
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

class _BannersBody extends ConsumerStatefulWidget {
  const _BannersBody({
    required this.value,
    required this.state,
    required this.creating,
    required this.onCreatingChanged,
  });

  final StaffBanners value;
  final StaffCatalogState<StaffBanners> state;
  final bool creating;
  final ValueChanged<bool> onCreatingChanged;

  @override
  ConsumerState<_BannersBody> createState() => _BannersBodyState();
}

class _BannersBodyState extends ConsumerState<_BannersBody> {
  String? _open;
  var _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    ref.listen(staffBannersProvider.select((x) => x.notice), (prev, next) {
      if (next == BannerNotice.created && mounted) {
        widget.onCreatingChanged(false);
      }
    });
    final s = widget.state;
    final ctl = ref.read(staffBannersProvider.notifier);
    final all = widget.value.banners;
    List<Widget> rows(Iterable<StaffBanner> list) => [
      for (final b in list)
        _BannerRow(
          key: Key('banner-${b.bannerId}'),
          banner: b,
          open: _open == b.bannerId,
          state: s,
          onToggle: () =>
              setState(() => _open = _open == b.bannerId ? null : b.bannerId),
        ),
    ];
    final waiting = all.where(
      (b) => b.state == ContentState.draft || b.hasChanges,
    );
    final onHome = all.where(
      (b) => b.state == ContentState.published && !b.hasChanges,
    );
    final withdrawn = all.where((b) => b.state == ContentState.withdrawn);
    final archived = all.where((b) => b.state == ContentState.archived);
    final removals = widget.value.removalsPending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (removals > 0) ...[
          RequestStateBanner(
            key: const Key('banners-removals'),
            tone: StatusTone.warning,
            title:
                '$removals public ${removals == 1 ? 'file' : 'files'} to '
                'remove',
            message:
                'Withdrawn or replaced images are still in the public '
                'bucket. Sync removes them.',
            actions: [
              BannerAction(
                s.syncing ? 'Syncing…' : 'Sync',
                s.syncing || s.busy ? null : ctl.sync,
                key: const Key('banners-sync'),
                primary: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (widget.creating)
          ChurchCard(
            radius: 12,
            child: _BannerForm(
              key: const Key('banner-form-new'),
              banner: null,
              state: s,
              onCancel: () => widget.onCreatingChanged(false),
            ),
          ),
        if (widget.value.truncated) ...[
          const SizedBox(height: 12),
          const RequestStateBanner(
            key: Key('banners-truncated'),
            tone: StatusTone.warning,
            title: 'Not every banner is listed',
            message: 'There are more banners than this list shows.',
          ),
        ],
        if (waiting.isNotEmpty)
          _section(
            context,
            'Waiting to publish',
            'banners-waiting',
            rows(waiting),
          ),
        if (onHome.isNotEmpty)
          _section(context, 'On Home', 'banners-on-home', rows(onHome)),
        if (withdrawn.isNotEmpty)
          _section(context, 'Withdrawn', 'banners-withdrawn', rows(withdrawn)),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: ChurchGeometry.sectionGap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('banners-show-archived'),
                onPressed: () => setState(() => _showArchived = !_showArchived),
                child: Text(
                  _showArchived
                      ? 'Hide archived banners'
                      : 'Show archived banners (${archived.length})',
                ),
              ),
            ),
          ),
          if (_showArchived)
            _section(context, 'Archived', 'banners-archived', rows(archived)),
        ],
        const SizedBox(height: 16),
        Text(
          'Home shows the theme first, then campaigns. A banner reaches Home '
          'once it is published, its rights record clears display and its '
          'image is placed in the public bucket. A campaign linked to an event '
          'shows only while that event is published.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ],
    );
  }
}

/// A 16:9 thumbnail of an uploaded image, read through the access-checked
/// preview route (in memory only).
class _Thumbnail extends ConsumerWidget {
  const _Thumbnail({required this.assetId, this.width = 112});
  final String? assetId;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final id = assetId;
    final Widget inner;
    if (id == null) {
      inner = Center(
        child: Text(
          'No image',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      );
    } else {
      final bytes = ref.watch(bannerPreviewProvider(id));
      inner = switch (bytes) {
        AsyncData(value: final b?) => Image.memory(
          b,
          key: Key('banner-thumb-$id'),
          fit: BoxFit.cover,
          excludeFromSemantics: true,
        ),
        AsyncLoading() => const SizedBox.shrink(),
        _ => Center(
          child: Text(
            'Preview unavailable',
            textAlign: TextAlign.center,
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        ),
      };
    }
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: c.surface2,
          child: SizedBox(width: width, height: width * 9 / 16, child: inner),
        ),
      ),
    );
  }
}

class _BannerRow extends ConsumerStatefulWidget {
  const _BannerRow({
    super.key,
    required this.banner,
    required this.open,
    required this.state,
    required this.onToggle,
  });

  final StaffBanner banner;
  final bool open;
  final StaffCatalogState<StaffBanners> state;
  final VoidCallback onToggle;

  @override
  ConsumerState<_BannerRow> createState() => _BannerRowState();
}

class _BannerRowState extends ConsumerState<_BannerRow> {
  var _editing = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final b = widget.banner;
    final id = b.bannerId;
    final busy = widget.state.busy;
    final cur = b.current;
    final (mark, tone) = _bannerMark(b);
    final ctl = ref.read(staffBannersProvider.notifier);
    ref.listen(staffBannersProvider.select((x) => x.notice), (prev, next) {
      final a = ref.read(staffBannersProvider).noticeAction;
      if (next == BannerNotice.saved &&
          a?.request.payload['banner_id'] == id &&
          mounted) {
        setState(() => _editing = false);
      }
    });
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final shownImage = b.state == ContentState.published
        ? b.live?.image
        : cur.image;
    final note = switch (b.publicImage) {
      PublicImageState.waiting => 'Image waiting to be placed',
      PublicImageState.blocked => 'Rights no longer clear: not shown',
      PublicImageState.eventNotPublic =>
        'Its event is not public now: not shown',
      _ => null,
    };
    final summary = InkWell(
      key: Key('banner-open-$id'),
      onTap: widget.onToggle,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Thumbnail(assetId: shownImage?.assetId),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cur.fields.title,
                    style: ChurchType.itemTitle.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [_kindText(cur.fields), ?cur.fields.subtitle].join(' · '),
                    style: muted,
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      note,
                      key: Key('banner-note-$id'),
                      style: ChurchType.secondary.copyWith(color: c.amberFg),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            StatusLabel(key: Key('banner-mark-$id'), label: mark, tone: tone),
            const SizedBox(width: 6),
            ExcludeSemantics(
              child: Icon(
                widget.open ? Icons.expand_less : Icons.expand_more,
                color: c.muted,
              ),
            ),
          ],
        ),
      ),
    );
    if (!widget.open) return FocusRing(radius: 4, child: summary);

    Widget version(String label, StaffBannerRevision r, String attribution) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardLabel(label),
            const SizedBox(height: 6),
            DetailTable(
              rows: [
                (label: 'Kind', value: _kindText(r.fields)),
                (label: 'Title', value: r.fields.title),
                (label: 'Line', value: r.fields.subtitle ?? '—'),
                (label: 'Image text', value: r.fields.altText),
                (
                  label: 'Image',
                  value: r.image == null
                      ? 'None yet'
                      : '${r.image!.width} x ${r.image!.height}',
                ),
                (
                  label: 'Rights',
                  value: switch (r.rights) {
                    null => 'None chosen',
                    final x when x.display == null => '${x.label} (clears)',
                    final x => '${x.label}: ${bannerReasonText(x.display!)}',
                  },
                ),
                if (r.fields.kind == BannerKind.campaign)
                  (label: 'Event', value: r.eventTitle ?? '—'),
              ],
            ),
            const SizedBox(height: 6),
            Text(attribution, style: muted),
          ],
        );

    final actions = <Widget>[
      if (b.canEdit)
        FocusRing(
          child: OutlinedButton(
            key: Key('banner-edit-$id'),
            onPressed: busy ? null : () => setState(() => _editing = !_editing),
            child: Text(_editing ? 'Close the form' : 'Edit'),
          ),
        ),
      if (b.canPublish)
        FocusRing(
          child: FilledButton(
            key: Key('banner-publish-$id'),
            onPressed: busy ? null : () => ctl.publish(b),
            child: Text(
              b.hasChanges
                  ? 'Publish changes'
                  : b.state == ContentState.withdrawn && b.draft == null
                  ? 'Publish again'
                  : 'Publish',
            ),
          ),
        ),
      if (b.canWithdraw)
        FocusRing(
          child: OutlinedButton(
            key: Key('banner-withdraw-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      context,
                      'Withdraw ${cur.fields.title}?',
                      'It leaves Home and its public image is removed. You '
                          'can publish it again later.',
                      'Withdraw',
                    )) {
                      await ctl.withdraw(b);
                    }
                  },
            child: const Text('Withdraw'),
          ),
        ),
      if (b.canArchive)
        FocusRing(
          child: TextButton(
            key: Key('banner-archive-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      context,
                      'Archive ${cur.fields.title}?',
                      'It leaves Home (if it is on it) and can no longer be '
                          'changed or published.',
                      'Archive',
                    )) {
                      await ctl.archive(b);
                    }
                  },
            child: const Text('Archive'),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusRing(radius: 4, child: summary),
        Padding(
          key: Key('banner-details-$id'),
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (b.live case final live?) ...[
                version(
                  b.state == ContentState.published
                      ? 'Published version'
                      : 'Last published version (not public)',
                  live,
                  [
                    if (b.publishedBy case final by?) 'Published by $by',
                    if (b.publishedAt case final at?) churchShortWhen(at),
                  ].join(' · '),
                ),
                const SizedBox(height: 14),
              ],
              if (b.draft case final draft?) ...[
                version(
                  b.live == null
                      ? 'Draft (editors only)'
                      : 'Changes not published yet (editors only)',
                  draft,
                  'Saved by ${draft.savedBy} · ${churchShortWhen(draft.savedAt)}',
                ),
                const SizedBox(height: 14),
              ],
              Text(
                'Created by ${b.createdBy} · ${churchShortWhen(b.createdAt)}',
                style: muted,
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
              if (_editing) ...[
                const SizedBox(height: 14),
                _BannerForm(
                  key: Key('banner-form-$id'),
                  banner: b,
                  state: widget.state,
                  onCancel: () => setState(() => _editing = false),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A new banner ([banner] null: text only, the image comes after the first
/// save) or an edit of one: every field, saved as a draft.
class _BannerForm extends ConsumerStatefulWidget {
  const _BannerForm({
    super.key,
    required this.banner,
    required this.state,
    required this.onCancel,
  });

  final StaffBanner? banner;
  final StaffCatalogState<StaffBanners> state;
  final VoidCallback onCancel;

  @override
  ConsumerState<_BannerForm> createState() => _BannerFormState();
}

class _BannerFormState extends ConsumerState<_BannerForm> {
  final _year = TextEditingController();
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _alt = TextEditingController();
  var _kind = BannerKind.campaign;
  String? _eventId;
  String? _rightsId;

  @override
  void initState() {
    super.initState();
    if (widget.banner?.current case final r?) {
      final f = r.fields;
      _kind = f.kind;
      _year.text = f.themeYear?.toString() ?? '';
      _title.text = f.title;
      _subtitle.text = f.subtitle ?? '';
      _alt.text = f.altText;
      _eventId = f.eventId;
      _rightsId = r.rights?.rightsId;
    } else {
      _year.text = '${DateTime.now().year}';
    }
  }

  List<TextEditingController> get _all => [_year, _title, _subtitle, _alt];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  /// What is typed, or null while something required is missing.
  BannerInput? _input(String? assetId) {
    final year = int.tryParse(_year.text.trim());
    if (_title.text.trim().isEmpty ||
        _alt.text.trim().isEmpty ||
        (_kind == BannerKind.theme && year == null)) {
      return null;
    }
    return BannerInput(
      kind: _kind,
      themeYear: _kind == BannerKind.theme ? year : null,
      title: _title.text,
      subtitle: _subtitle.text,
      altText: _alt.text,
      eventId: _kind == BannerKind.campaign ? _eventId : null,
      imageAssetId: assetId,
      imageRightsId: _rightsId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final b = widget.banner;
    final tag = b?.bannerId ?? 'new';
    final st = widget.state;
    final busy = st.busy;
    final a = st.noticeAction;
    final mine = b == null
        ? a?.command == BannerCommands.createBanner
        : a?.command == BannerCommands.saveBanner &&
              a?.request.payload['banner_id'] == b.bannerId;
    final errors = mine ? st.fieldErrors : const <String, String>{};
    String? err(String wire) => errors[wire] == null
        ? null
        : bannerReasonText(errors[wire]!, field: wire);
    final ctl = ref.read(staffBannersProvider.notifier);
    Widget field(
      String key,
      TextEditingController controller,
      String label, {
      required String wire,
      String? helper,
      int maxLength = 80,
      List<TextInputFormatter>? formatters,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$tag'),
        controller: controller,
        enabled: !busy,
        maxLength: maxLength,
        inputFormatters: formatters,
        onChanged: (_) => ctl.clearFieldErrors(),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          errorText: err(wire),
        ),
      ),
    );

    // The image: the one just uploaded, else the revision's own.
    final upload = b == null
        ? null
        : ref.watch(bannerImageUploadProvider(b.bannerId));
    final assetId = upload?.image?.assetId ?? b?.current.image?.assetId;

    // A confirmed save of this banner uses the uploaded image: forget it.
    ref.listen(staffBannersProvider.select((x) => x.notice), (prev, next) {
      final act = ref.read(staffBannersProvider).noticeAction;
      if (b != null &&
          next == BannerNotice.saved &&
          act?.request.payload['banner_id'] == b.bannerId) {
        ref.read(bannerImageUploadProvider(b.bannerId).notifier).clear();
      }
    });

    final events = [
      for (final e
          in ref.watch(staffEventsProvider).value?.events ?? <StaffEvent>[])
        if (e.state != ContentState.archived) e,
    ];
    final rights = [
      for (final r
          in ref.watch(staffRightsProvider).value?.rights ?? <RightsRecord>[])
        if (r.inForce) r,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            b == null ? 'New banner' : 'Edit ${b.current.fields.title}',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          b != null && b.state == ContentState.published
              ? 'Saving keeps the published version on Home until you '
                    'publish the changes.'
              : 'Saved as a draft: only editors see it until you publish it.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 12),
        RadioSegments<BannerKind>(
          label: 'Kind of banner',
          options: const [
            SegmentOption(BannerKind.theme, 'Theme'),
            SegmentOption(BannerKind.campaign, 'Campaign'),
          ],
          selected: _kind,
          onChanged: busy ? null : (k) => setState(() => _kind = k),
        ),
        const SizedBox(height: 12),
        if (_kind == BannerKind.theme)
          field(
            'banner-year',
            _year,
            'Theme year',
            wire: 'theme_year',
            maxLength: 4,
            formatters: [FilteringTextInputFormatter.digitsOnly],
          ),
        field('banner-title', _title, 'Title', wire: 'title'),
        field(
          'banner-subtitle',
          _subtitle,
          _kind == BannerKind.theme ? 'Scripture reference' : 'Short line',
          wire: 'subtitle',
          maxLength: 120,
        ),
        field(
          'banner-alt',
          _alt,
          'Image text',
          wire: 'alt_text',
          helper: 'Describe the image for someone who can\'t see it',
          maxLength: 250,
        ),
        if (_kind == BannerKind.campaign)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<String?>(
              key: Key('banner-event-$tag'),
              initialValue: _eventId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Linked event (optional)',
                errorText: err('event_id'),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('No event'),
                ),
                for (final e in events)
                  DropdownMenuItem<String?>(
                    value: e.eventId,
                    child: Text(
                      e.current.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (_eventId != null &&
                    events.every((e) => e.eventId != _eventId))
                  DropdownMenuItem<String?>(
                    value: _eventId,
                    child: Text(b?.current.eventTitle ?? 'Linked event'),
                  ),
              ],
              onChanged: busy ? null : (v) => setState(() => _eventId = v),
            ),
          ),
        if (b == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Save the draft first; then add its image and rights record.',
              key: const Key('banner-image-after-save'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          )
        else ...[
          _ImageSection(banner: b, upload: upload!, busy: busy),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: Key('banner-rights-$tag'),
            initialValue: _rightsId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Rights record',
              errorText: err('image_rights_id'),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('None chosen yet'),
              ),
              for (final r in rights)
                DropdownMenuItem<String?>(
                  value: r.rightsId,
                  child: Text(
                    '${r.live!.fields.label} · '
                    '${r.live!.fields.basis == RightsBasis.churchOwned
                        ? 'Q5 approval is not required'
                        : r.clearsDisplayNow
                        ? 'On the Q5 list for display'
                        : 'Not on the Q5 list'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (_rightsId != null &&
                  rights.every((r) => r.rightsId != _rightsId))
                DropdownMenuItem<String?>(
                  value: _rightsId,
                  child: Text(
                    b.current.rights?.label ?? 'Chosen rights record',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: busy ? null : (v) => setState(() => _rightsId = v),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: Key('banner-manage-rights-$tag'),
                onPressed: () => context.go(BannerPaths.rights),
                child: const Text('Add or verify rights records'),
              ),
            ),
          ),
        ],
        if (errors.keys.any(_unknownKey))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              [
                for (final e in errors.entries)
                  if (_unknownKey(e.key))
                    bannerReasonText(e.value, field: e.key),
              ].join(' '),
              key: Key('banner-form-errors-$tag'),
              style: TextStyle(color: c.redFg),
            ),
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ListenableBuilder(
              listenable: Listenable.merge(_all),
              builder: (context, _) {
                final input = _input(assetId);
                return FocusRing(
                  child: FilledButton(
                    key: Key('banner-save-$tag'),
                    onPressed: busy || input == null || (upload?.busy ?? false)
                        ? null
                        : () {
                            if (b == null) {
                              ctl.create(input);
                            } else {
                              ctl.save(b, input);
                            }
                          },
                    child: const Text('Save draft'),
                  ),
                );
              },
            ),
            FocusRing(
              child: TextButton(
                key: Key('banner-cancel-$tag'),
                onPressed: busy ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static bool _unknownKey(String k) => !const {
    'banner_kind',
    'theme_year',
    'title',
    'subtitle',
    'alt_text',
    'event_id',
    'image_rights_id',
  }.contains(k);
}

/// A saved banner's image: its preview, Choose image (uploads at once) and
/// what the server said about the file.
class _ImageSection extends ConsumerWidget {
  const _ImageSection({
    required this.banner,
    required this.upload,
    required this.busy,
  });

  final StaffBanner banner;
  final BannerImageUpload upload;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final id = banner.bannerId;
    final picker = ref.watch(contentFilePickerProvider);
    final ctl = ref.read(bannerImageUploadProvider(id).notifier);
    final current = banner.current.image;
    final Widget preview = switch (upload) {
      BannerImageUpload(:final bytes?) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 160,
          height: 90,
          child: Image.memory(
            bytes,
            key: Key('banner-upload-preview-$id'),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
          ),
        ),
      ),
      _ => _Thumbnail(assetId: current?.assetId, width: 160),
    };
    final status = switch (upload.status) {
      ImageUploadStatus.idle when current != null =>
        '${current.width} x ${current.height}, '
            '${(current.byteSize / 1024).ceil()} KB',
      ImageUploadStatus.idle =>
        'No image yet. PNG, JPEG or WebP, at least '
            '960 x 540, landscape close to 16:9, up to 5 MB.',
      ImageUploadStatus.picking => 'Choosing a file…',
      ImageUploadStatus.uploading => 'Uploading; the server checks the file…',
      ImageUploadStatus.uploaded =>
        'Uploaded (${upload.image!.width} x ${upload.image!.height}). Save '
            'the draft to use this image.',
      ImageUploadStatus.refused => switch (upload.outcome) {
        ImageUploadRefused(:final reason?, :final fieldErrors) =>
          'Not uploaded. ${bannerReasonText(reason, field: fieldErrors.entries.firstWhere((e) => e.value == reason).key)}',
        _ => 'Not uploaded. The server refused this file.',
      },
      ImageUploadStatus.failed => switch (upload.outcome) {
        ImageUploadSignedOut() => 'Not uploaded. Please sign in again.',
        ImageUploadNotAllowed() => 'Not uploaded. $_needs',
        ImageUploadFailed(unreachable: true) =>
          'Not uploaded. We couldn\'t reach the church server.',
        ImageUploadNotSent() =>
          'Not uploaded. This build has no server configured.',
        _ => 'Not uploaded. The church server could not take it now.',
      },
    };
    final problem =
        upload.status == ImageUploadStatus.refused ||
        upload.status == ImageUploadStatus.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CardLabel('Image'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            preview,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      status,
                      key: Key('banner-upload-status-$id'),
                      style: ChurchType.secondary.copyWith(
                        color: problem ? c.redFg : c.muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FocusRing(
                    child: OutlinedButton.icon(
                      key: Key('banner-choose-image-$id'),
                      onPressed: busy || upload.busy || !picker.supported
                          ? null
                          : ctl.pickAndUpload,
                      icon: const Icon(Icons.upload_outlined, size: 18),
                      label: Text(
                        current == null && upload.image == null
                            ? 'Choose image'
                            : 'Choose another image',
                      ),
                    ),
                  ),
                  if (!picker.supported)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Images are added on staff web in a browser.',
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Rights
// ---------------------------------------------------------------------------

(String, StatusTone) _rightsMark(RightsRecord r) => switch (r.state) {
  ContentState.draft => ('Draft', StatusTone.neutral),
  ContentState.published when r.hasChanges => (
    'Changes not verified',
    StatusTone.warning,
  ),
  ContentState.published => ('In force', StatusTone.success),
  ContentState.withdrawn => ('Withdrawn', StatusTone.neutral),
  ContentState.archived => ('Archived', StatusTone.neutral),
};

String _q5Text(RightsRecord r) {
  final basis = (r.live ?? r.draft)!.fields.basis;
  if (basis == RightsBasis.churchOwned) {
    return 'Q5 approval is not required for church-owned images';
  }
  if (r.q5Uses.contains(RightsUses.display)) {
    return 'On the Q5 list for display';
  }
  return r.q5Uses.isEmpty
      ? 'Not on the Q5 list'
      : 'On the Q5 list for ${r.q5Uses.join(', ')}';
}

String _rightsFinding(StaffRights v) {
  if (v.rights.isEmpty) {
    return 'No rights records yet. An image needs one before it is '
        'published.';
  }
  final inForce = v.rights.where((r) => r.inForce).length;
  final waiting = v.rights
      .where((r) => r.state == ContentState.draft || r.hasChanges)
      .length;
  return [
    '$inForce in force',
    waiting == 0 ? 'nothing waiting to verify' : '$waiting waiting to verify',
  ].join(' · ');
}

/// `/content/rights` (staff web; Media, Pastor and Admin).
class StaffRightsScreen extends ConsumerStatefulWidget {
  const StaffRightsScreen({super.key});

  @override
  ConsumerState<StaffRightsScreen> createState() => _StaffRightsState();
}

class _StaffRightsState extends ConsumerState<StaffRightsScreen> {
  var _creating = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(staffRightsProvider);
    final ctl = ref.read(staffRightsProvider.notifier);
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final value = s.value;
    final newRecord = value == null
        ? null
        : FocusRing(
            child: FilledButton.icon(
              key: const Key('rights-new'),
              onPressed: s.busy
                  ? null
                  : () => setState(() => _creating = !_creating),
              icon: Icon(_creating ? Icons.close : Icons.add),
              label: Text(_creating ? 'Close the form' : 'New rights record'),
            ),
          );
    return ChurchPageScaffold(
      title: 'Rights',
      subtitle: value == null ? null : _rightsFinding(value),
      actions: phone
          ? [
              ?newRecord,
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('rights-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [?newRecord, staffReloadButton(const Key('rights-reload'), reload)],
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: DefaultTextStyle.merge(
                style: layout.body.copyWith(color: c.ink),
                child: _CatalogFrame<StaffRights>(
                  prefix: 'rights',
                  provider: staffRightsProvider,
                  rights: true,
                  body: (v, st) => _RightsBody(
                    value: v,
                    state: st,
                    creating: _creating,
                    onCreatingChanged: (x) => setState(() => _creating = x),
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

class _RightsBody extends ConsumerStatefulWidget {
  const _RightsBody({
    required this.value,
    required this.state,
    required this.creating,
    required this.onCreatingChanged,
  });

  final StaffRights value;
  final StaffCatalogState<StaffRights> state;
  final bool creating;
  final ValueChanged<bool> onCreatingChanged;

  @override
  ConsumerState<_RightsBody> createState() => _RightsBodyState();
}

class _RightsBodyState extends ConsumerState<_RightsBody> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    ref.listen(staffRightsProvider.select((x) => x.notice), (prev, next) {
      if (next == BannerNotice.created && mounted) {
        widget.onCreatingChanged(false);
      }
    });
    final all = widget.value.rights;
    List<Widget> rows(Iterable<RightsRecord> list) => [
      for (final r in list)
        _RightsRow(
          key: Key('rights-${r.rightsId}'),
          record: r,
          open: _open == r.rightsId,
          state: widget.state,
          onToggle: () =>
              setState(() => _open = _open == r.rightsId ? null : r.rightsId),
        ),
    ];
    final waiting = all.where(
      (r) => r.state == ContentState.draft || r.hasChanges,
    );
    final inForce = all.where((r) => r.inForce && !r.hasChanges);
    final other = all.where(
      (r) =>
          r.state == ContentState.withdrawn || r.state == ContentState.archived,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.creating)
          ChurchCard(
            radius: 12,
            child: _RightsForm(
              key: const Key('rights-form-new'),
              record: null,
              state: widget.state,
              onCancel: () => widget.onCreatingChanged(false),
            ),
          ),
        if (waiting.isNotEmpty)
          _section(
            context,
            'Waiting to verify',
            'rights-waiting',
            rows(waiting),
          ),
        if (inForce.isNotEmpty)
          _section(context, 'In force', 'rights-in-force', rows(inForce)),
        if (other.isNotEmpty)
          _section(
            context,
            'Withdrawn and archived',
            'rights-other',
            rows(other),
          ),
        const SizedBox(height: 16),
        Text(
          'An image is published only with a verified rights record that '
          'clears display. Church-owned images do not need Q5 source approval; '
          'third-party sources must be on the owner\'s Q5 list for display.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ],
    );
  }
}

class _RightsRow extends ConsumerStatefulWidget {
  const _RightsRow({
    super.key,
    required this.record,
    required this.open,
    required this.state,
    required this.onToggle,
  });

  final RightsRecord record;
  final bool open;
  final StaffCatalogState<StaffRights> state;
  final VoidCallback onToggle;

  @override
  ConsumerState<_RightsRow> createState() => _RightsRowState();
}

class _RightsRowState extends ConsumerState<_RightsRow> {
  var _editing = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final r = widget.record;
    final id = r.rightsId;
    final busy = widget.state.busy;
    final f = r.current.fields;
    final (mark, tone) = _rightsMark(r);
    final ctl = ref.read(staffRightsProvider.notifier);
    ref.listen(staffRightsProvider.select((x) => x.notice), (prev, next) {
      final a = ref.read(staffRightsProvider).noticeAction;
      if (next == BannerNotice.saved &&
          a?.request.payload['rights_id'] == id &&
          mounted) {
        setState(() => _editing = false);
      }
    });
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final summary = InkWell(
      key: Key('rights-open-$id'),
      onTap: widget.onToggle,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.label,
                    style: ChurchType.itemTitle.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      f.sourceKey,
                      f.basis.label,
                      f.clearedLabels.join(' · '),
                    ].join(' · '),
                    style: muted,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      _q5Text(r),
                      if (r.verifiedBy case final by?)
                        'verified by $by'
                            '${r.verifiedAt == null ? '' : ' ${churchShortWhen(r.verifiedAt!)}'}',
                    ].join(' · '),
                    key: Key('rights-q5-$id'),
                    style: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            StatusLabel(key: Key('rights-mark-$id'), label: mark, tone: tone),
            const SizedBox(width: 6),
            ExcludeSemantics(
              child: Icon(
                widget.open ? Icons.expand_less : Icons.expand_more,
                color: c.muted,
              ),
            ),
          ],
        ),
      ),
    );
    if (!widget.open) return FocusRing(radius: 4, child: summary);

    Widget version(String label, RightsRevision v, String attribution) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardLabel(label),
            const SizedBox(height: 6),
            DetailTable(
              rows: [
                (label: 'Covers', value: v.fields.label),
                (label: 'Source', value: v.fields.sourceKey),
                (label: 'Holder', value: v.fields.holder),
                (label: 'Basis', value: v.fields.basis.label),
                (label: 'Clears', value: v.fields.clearedLabels.join(' · ')),
                (label: 'Evidence', value: v.fields.evidence),
              ],
            ),
            const SizedBox(height: 6),
            Text(attribution, style: muted),
          ],
        );

    final actions = <Widget>[
      if (r.canEdit)
        FocusRing(
          child: OutlinedButton(
            key: Key('rights-edit-$id'),
            onPressed: busy ? null : () => setState(() => _editing = !_editing),
            child: Text(_editing ? 'Close the form' : 'Edit'),
          ),
        ),
      if (r.canVerify)
        FocusRing(
          child: FilledButton(
            key: Key('rights-verify-$id'),
            onPressed: busy ? null : () => ctl.verify(r),
            child: Text(r.hasChanges ? 'Verify changes' : 'Verify'),
          ),
        ),
      if (r.canWithdraw)
        FocusRing(
          child: OutlinedButton(
            key: Key('rights-withdraw-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      context,
                      'Withdraw ${f.label}?',
                      'It is no longer in force: images citing it leave Home '
                          'and cannot be published until it is verified '
                          'again.',
                      'Withdraw',
                    )) {
                      await ctl.withdraw(r);
                    }
                  },
            child: const Text('Withdraw'),
          ),
        ),
      if (r.canArchive)
        FocusRing(
          child: TextButton(
            key: Key('rights-archive-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      context,
                      'Archive ${f.label}?',
                      'It is retired: nothing can cite it any more and it can '
                          'no longer change.',
                      'Archive',
                    )) {
                      await ctl.archive(r);
                    }
                  },
            child: const Text('Archive'),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusRing(radius: 4, child: summary),
        Padding(
          key: Key('rights-details-$id'),
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (r.live case final live?) ...[
                version(
                  r.inForce
                      ? 'In force'
                      : 'Last verified version (not in force)',
                  live,
                  [
                    if (r.verifiedBy case final by?) 'Verified by $by',
                    if (r.verifiedAt case final at?) churchShortWhen(at),
                  ].join(' · '),
                ),
                const SizedBox(height: 14),
              ],
              if (r.draft case final draft?) ...[
                version(
                  r.live == null
                      ? 'Draft (not in force)'
                      : 'Changes not verified yet',
                  draft,
                  'Saved by ${draft.savedBy} · ${churchShortWhen(draft.savedAt)}',
                ),
                const SizedBox(height: 14),
              ],
              Wrap(spacing: 8, runSpacing: 8, children: actions),
              if (_editing) ...[
                const SizedBox(height: 14),
                _RightsForm(
                  key: Key('rights-form-$id'),
                  record: r,
                  state: widget.state,
                  onCancel: () => setState(() => _editing = false),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RightsForm extends ConsumerStatefulWidget {
  const _RightsForm({
    super.key,
    required this.record,
    required this.state,
    required this.onCancel,
  });

  final RightsRecord? record;
  final StaffCatalogState<StaffRights> state;
  final VoidCallback onCancel;

  @override
  ConsumerState<_RightsForm> createState() => _RightsFormState();
}

class _RightsFormState extends ConsumerState<_RightsForm> {
  final _label = TextEditingController();
  final _source = TextEditingController();
  final _holder = TextEditingController();
  final _evidence = TextEditingController();
  var _basis = RightsBasis.churchOwned;
  var _display = true;
  var _offline = false;
  var _audio = false;

  @override
  void initState() {
    super.initState();
    if (widget.record?.current.fields case final f?) {
      _label.text = f.label;
      _source.text = f.sourceKey;
      _holder.text = f.holder;
      _evidence.text = f.evidence;
      _basis = f.basis;
      _display = f.clearsDisplay;
      _offline = f.clearsOffline;
      _audio = f.clearsAudio;
    }
  }

  List<TextEditingController> get _all => [_label, _source, _holder, _evidence];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  RightsInput? _input() {
    if (_all.any((c) => c.text.trim().isEmpty)) return null;
    return RightsInput(
      label: _label.text,
      sourceKey: _source.text,
      holder: _holder.text,
      basis: _basis,
      clearsDisplay: _display,
      clearsOffline: _offline,
      clearsAudio: _audio,
      evidence: _evidence.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final r = widget.record;
    final tag = r?.rightsId ?? 'new';
    final st = widget.state;
    final busy = st.busy;
    final a = st.noticeAction;
    final mine = r == null
        ? a?.command == BannerCommands.createRights
        : a?.command == BannerCommands.saveRights &&
              a?.request.payload['rights_id'] == r.rightsId;
    final errors = mine ? st.fieldErrors : const <String, String>{};
    String? err(String wire) => errors[wire] == null
        ? null
        : bannerReasonText(errors[wire]!, field: wire);
    final ctl = ref.read(staffRightsProvider.notifier);
    Widget field(
      String key,
      TextEditingController controller,
      String label, {
      required String wire,
      String? helper,
      int maxLength = 120,
      int maxLines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$tag'),
        controller: controller,
        enabled: !busy,
        maxLength: maxLength,
        maxLines: maxLines,
        onChanged: (_) => ctl.clearFieldErrors(),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          errorText: err(wire),
        ),
      ),
    );
    Widget use(String key, String label, bool value, ValueChanged<bool> set) =>
        CheckboxListTile(
          key: Key('$key-$tag'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: value,
          title: Text(label),
          onChanged: busy ? null : (v) => setState(() => set(v ?? false)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            r == null ? 'New rights record' : 'Edit ${r.current.fields.label}',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Saved as a draft. It comes into force when an editor verifies it.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 12),
        field(
          'rights-label',
          _label,
          'What it covers',
          wire: 'label',
          helper: 'For example SYNTHETIC Theme 2026 artwork',
        ),
        field(
          'rights-source',
          _source,
          'Source key',
          wire: 'source_key',
          helper: 'The source named on the owner\'s Q5 list, e.g. synthetic',
          maxLength: 41,
        ),
        field(
          'rights-holder',
          _holder,
          'Holder',
          wire: 'holder',
          maxLength: 160,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: DropdownButtonFormField<RightsBasis>(
            key: Key('rights-basis-$tag'),
            initialValue: _basis,
            decoration: InputDecoration(
              labelText: 'Basis',
              errorText: err('basis'),
            ),
            items: [
              for (final b in RightsBasis.values)
                DropdownMenuItem(value: b, child: Text(b.label)),
            ],
            onChanged: busy ? null : (v) => setState(() => _basis = v!),
          ),
        ),
        const CardLabel('Cleared uses'),
        use(
          'rights-display',
          'Display in the app',
          _display,
          (v) => _display = v,
        ),
        use(
          'rights-offline',
          'Offline download',
          _offline,
          (v) => _offline = v,
        ),
        use('rights-audio', 'Audio', _audio, (v) => _audio = v),
        if (err('clears_display') case final e?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(e, style: TextStyle(color: c.redFg)),
          ),
        field(
          'rights-evidence',
          _evidence,
          'Evidence',
          wire: 'evidence',
          helper: 'Where the permission or licence is recorded',
          maxLength: 1000,
          maxLines: 4,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ListenableBuilder(
              listenable: Listenable.merge(_all),
              builder: (context, _) {
                final input = _input();
                return FocusRing(
                  child: FilledButton(
                    key: Key('rights-save-$tag'),
                    onPressed: busy || input == null
                        ? null
                        : () {
                            if (r == null) {
                              ctl.create(input);
                            } else {
                              ctl.save(r, input);
                            }
                          },
                    child: const Text('Save draft'),
                  ),
                );
              },
            ),
            FocusRing(
              child: TextButton(
                key: Key('rights-cancel-$tag'),
                onPressed: busy ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
