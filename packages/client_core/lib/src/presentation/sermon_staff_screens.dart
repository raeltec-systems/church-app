import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/banner_controllers.dart';
import '../application/sermon_controllers.dart';
import '../domain/content_banners.dart';
import '../domain/content_events.dart';
import '../domain/content_sermons.dart';
import 'banner_screens.dart' show bannerReasonText;
import 'calendar_screens.dart' show churchShortWhen, publicReadProblem;
import 'sermon_screens.dart';

// Story 6.9 (staff web; Media, Pastor and Admin): sermons and their series.
// The screen answers "what is waiting to publish?": drafts (including the
// ones later sent from teaching duties) come first, whoever created them.
// The published revision stays live until a replacement is published.

class StaffSermonsScreen extends ConsumerWidget {
  const StaffSermonsScreen({super.key, this.series = false, this.itemId});
  final bool series;
  final String? itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => series
      ? _SeriesCatalog(key: const Key('staff-sermon-series'), itemId: itemId)
      : _SermonCatalog(key: const Key('staff-sermons'), itemId: itemId);
}

/// The one mark a row carries.
typedef _Mark = (String, StatusTone);

_Mark _lifecycleMark(StaffSermonItem<Object?> item) => switch (item.state) {
  ContentState.draft => ('Draft', StatusTone.neutral),
  ContentState.published when item.hasChanges => (
    'Changes not published',
    StatusTone.warning,
  ),
  ContentState.published => ('Published', StatusTone.success),
  ContentState.withdrawn => ('Withdrawn', StatusTone.neutral),
  ContentState.archived => ('Archived', StatusTone.neutral),
};

/// A published sermon whose recorded video no longer clears display shows
/// its notes without the video.
_Mark _sermonMark(StaffSermon s) {
  final live = s.live;
  if (s.state == ContentState.published &&
      !s.hasChanges &&
      live != null &&
      live.fields.youtubeVideoId != null &&
      live.videoRights?.display != null) {
    return ('Published, video hidden', StatusTone.warning);
  }
  return _lifecycleMark(s);
}

_Mark _seriesMark(StaffSermonSeries s) {
  if (s.state == ContentState.published && !s.hasChanges) {
    switch (s.publicImage) {
      case PublicImageState.waiting:
        return ('Published, poster waiting', StatusTone.warning);
      case PublicImageState.blocked || PublicImageState.eventNotPublic:
        return ('Published, poster not shown', StatusTone.warning);
      case PublicImageState.shown || null:
        break;
    }
  }
  return _lifecycleMark(s);
}

/// The screen's finding: what waits to be published and what is public.
String _finding(List<StaffSermonItem<Object?>> items, String noun) {
  if (items.isEmpty) {
    return 'No $noun yet. A new draft stays private until you publish it.';
  }
  final waiting = items
      .where((i) => i.state == ContentState.draft || i.hasChanges)
      .length;
  final published = items
      .where((i) => i.state == ContentState.published)
      .length;
  return [
    waiting == 0 ? 'Nothing waiting to publish' : '$waiting waiting to publish',
    '$published published',
  ].join(' · ');
}

class _SermonCatalog extends ConsumerWidget {
  const _SermonCatalog({super.key, this.itemId});
  final String? itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(staffSermonsProvider);
    final ctl = ref.read(staffSermonsProvider.notifier);
    final items = state.value?.sermons ?? const <StaffSermon>[];
    final item = items.where((s) => s.id == itemId).firstOrNull;
    ref.listen(staffSermonsProvider.select((s) => s.notice), (previous, next) {
      if (itemId != null &&
          (next == BannerNotice.created || next == BannerNotice.saved)) {
        context.go(SermonPaths.staff);
      }
    });
    return _CatalogPage(
      title: 'Sermons',
      finding: state.value == null ? null : _finding(items, 'sermons'),
      path: SermonPaths.staff,
      state: state,
      controller: ctl,
      editing: itemId != null,
      child: itemId != null
          ? (itemId == 'new' || item != null
                ? _SermonForm(
                    key: ValueKey('sermon-form-${item?.id}-${item?.revision}'),
                    item: item,
                  )
                : const _NotFound(what: 'sermon'))
          : _Sections(
              noun: 'sermons',
              items: items,
              truncated: state.value?.truncated ?? false,
              row: (s) {
                final sermon = s as StaffSermon;
                final f = sermon.current.fields;
                return _ItemRow(
                  key: Key('sermon-${sermon.id}'),
                  item: sermon,
                  title: f.title,
                  subtitle: [
                    f.speaker.isEmpty ? 'Speaker not added' : f.speaker,
                    f.sermonDate ?? 'Date not added',
                    if (f.scriptureReference.isNotEmpty) f.scriptureReference,
                  ].join(' · '),
                  mark: _sermonMark(sermon),
                  busy: state.busy,
                  onEdit: () =>
                      context.push('${SermonPaths.staff}/${sermon.id}'),
                  onLifecycle: (command) => ctl.lifecycle(command, sermon),
                );
              },
            ),
    );
  }
}

class _SeriesCatalog extends ConsumerStatefulWidget {
  const _SeriesCatalog({super.key, this.itemId});
  final String? itemId;
  @override
  ConsumerState<_SeriesCatalog> createState() => _SeriesCatalogState();
}

class _SeriesCatalogState extends ConsumerState<_SeriesCatalog> {
  @override
  void initState() {
    super.initState();
    // Opening the series places or removes any poster file still waiting.
    Future.microtask(() {
      if (mounted) ref.read(staffSermonSeriesProvider.notifier).sync();
    });
  }

  @override
  Widget build(BuildContext context) {
    final itemId = widget.itemId;
    final state = ref.watch(staffSermonSeriesProvider);
    final ctl = ref.read(staffSermonSeriesProvider.notifier);
    final items = state.value?.series ?? const <StaffSermonSeries>[];
    final item = items.where((s) => s.id == itemId).firstOrNull;
    ref.listen(staffSermonSeriesProvider.select((s) => s.notice), (
      previous,
      next,
    ) {
      if (itemId != null &&
          (next == BannerNotice.created || next == BannerNotice.saved)) {
        context.go(SermonPaths.staffSeries);
      }
    });
    final removals = state.value?.removalsPending ?? 0;
    return _CatalogPage(
      title: 'Sermon series',
      finding: state.value == null ? null : _finding(items, 'series'),
      path: SermonPaths.staffSeries,
      state: state,
      controller: ctl,
      editing: itemId != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (removals > 0 && itemId == null) ...[
            RequestStateBanner(
              key: const Key('sermon-series-removals'),
              tone: StatusTone.warning,
              title:
                  '$removals public ${removals == 1 ? 'file' : 'files'} to '
                  'remove',
              message:
                  'Withdrawn or replaced posters are still in the public '
                  'bucket. Sync removes them.',
              actions: [
                BannerAction(
                  state.syncing ? 'Syncing…' : 'Sync',
                  state.syncing || state.busy ? null : ctl.sync,
                  key: const Key('sermon-series-sync'),
                  primary: true,
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          if (itemId != null)
            (itemId == 'new' || item != null
                ? _SeriesForm(
                    key: ValueKey('series-form-${item?.id}-${item?.revision}'),
                    item: item,
                  )
                : const _NotFound(what: 'series'))
          else
            _Sections(
              noun: 'series',
              items: items,
              truncated: state.value?.truncated ?? false,
              row: (s) {
                final series = s as StaffSermonSeries;
                return _ItemRow(
                  key: Key('sermon-series-${series.id}'),
                  item: series,
                  title: series.current.fields.title,
                  subtitle: series.current.fields.description,
                  mark: _seriesMark(series),
                  busy: state.busy,
                  series: true,
                  onEdit: () =>
                      context.push('${SermonPaths.staffSeries}/${series.id}'),
                  onLifecycle: (command) => ctl.lifecycle(command, series),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _NotFound extends StatelessWidget {
  const _NotFound({required this.what});
  final String what;
  @override
  Widget build(BuildContext context) => RequestStateBanner(
    key: const Key('sermon-item-not-found'),
    tone: StatusTone.neutral,
    title: 'Not in the catalog',
    message:
        'This $what was not found. Reload the catalog to check again; it '
        'may have been archived by another editor.',
  );
}

class _CatalogPage<T> extends StatelessWidget {
  const _CatalogPage({
    required this.title,
    required this.finding,
    required this.path,
    required this.state,
    required this.controller,
    required this.child,
    required this.editing,
  });
  final String title, path;
  final String? finding;
  final StaffCatalogState<T> state;
  final StaffCatalogController<T> controller;
  final Widget child;
  final bool editing;
  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final notice = state.notice;
    final reload = state.loading || state.busy ? null : controller.reload;
    return ChurchPageScaffold(
      title: title,
      subtitle: finding,
      actions: [
        if (state.value != null && !editing)
          FocusRing(
            child: FilledButton.icon(
              key: Key('$path-new'),
              onPressed: state.busy ? null : () => context.push('$path/new'),
              icon: const Icon(Icons.add),
              label: const Text('New draft'),
            ),
          ),
        staffReloadButton(Key('$path-reload'), reload),
      ],
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: DefaultTextStyle.merge(
                style: layout.body.copyWith(color: c.ink),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (editing)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FocusRing(
                          child: TextButton.icon(
                            key: const Key('sermon-back-to-catalog'),
                            onPressed: state.busy
                                ? null
                                : () => context.go(path),
                            icon: const Icon(Icons.arrow_back),
                            label: Text('Back to $title'),
                          ),
                        ),
                      ),
                    if (state.pending != null)
                      const RequestStateBanner(
                        tone: StatusTone.info,
                        busy: true,
                        title: 'Sending…',
                        message:
                            'Waiting for the church server to confirm the '
                            'change.',
                      ),
                    if (notice != null)
                      RequestStateBanner(
                        key: Key('sermon-notice-${notice.name}'),
                        tone: switch (notice) {
                          BannerNotice.created ||
                          BannerNotice.saved ||
                          BannerNotice.published ||
                          BannerNotice.withdrawn ||
                          BannerNotice.archived => StatusTone.success,
                          _ => StatusTone.warning,
                        },
                        title: _noticeTitle(notice),
                        message: _noticeMessage(notice, state.fieldErrors),
                        actions: [
                          if (notice == BannerNotice.unconfirmed)
                            BannerAction(
                              'Check again',
                              controller.checkAgain,
                              primary: true,
                            ),
                        ],
                      ),
                    if (state.sync is FileSyncFailed ||
                        state.sync is FileSyncNotAllowed ||
                        (state.sync is FileSyncDone &&
                            (state.sync as FileSyncDone).waiting > 0))
                      RequestStateBanner(
                        key: const Key('sermon-sync-waiting'),
                        tone: StatusTone.warning,
                        title: 'Public files still waiting',
                        message:
                            'Some posters could not be placed or removed. '
                            'Try the sync again.',
                        actions: [
                          BannerAction(
                            state.syncing ? 'Syncing…' : 'Sync again',
                            state.syncing || state.busy
                                ? null
                                : controller.sync,
                            primary: true,
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    if (state.result == null)
                      const RequestStateBanner(
                        tone: StatusTone.info,
                        busy: true,
                        title: 'Loading…',
                        message: 'Asking the church server.',
                      )
                    else if (state.value == null) ...[
                      publicReadProblem(state.result!, what: 'sermon editor'),
                      const SizedBox(height: 8),
                      Text(
                        'Sermon editing is for Media, Pastors and Admins. '
                        'Permissions are checked by the server each time.',
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    ] else
                      child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _noticeTitle(BannerNotice notice) => switch (notice) {
  BannerNotice.created => 'Draft saved',
  BannerNotice.saved => 'Changes saved',
  BannerNotice.published => 'Published',
  BannerNotice.withdrawn => 'Withdrawn',
  BannerNotice.archived => 'Archived',
  BannerNotice.changedElsewhere => 'Changed elsewhere',
  BannerNotice.invalid || BannerNotice.blocked => 'Check the marked details',
  BannerNotice.unconfirmed => 'Waiting for confirmation',
  BannerNotice.notSent => 'Not sent',
  BannerNotice.notAllowed || BannerNotice.signInAgain => 'Access required',
  _ => 'Change not completed',
};
String _noticeMessage(
  BannerNotice notice,
  Map<String, String> errors,
) => switch (notice) {
  BannerNotice.created || BannerNotice.saved =>
    'Your draft is saved. The published revision stays visible until a '
        'replacement is published.',
  BannerNotice.published => 'The church server confirmed publication.',
  BannerNotice.withdrawn => 'This item is no longer public.',
  BannerNotice.archived => 'This item is archived.',
  BannerNotice.changedElsewhere =>
    'Another editor changed this item. The catalog now shows the current '
        'revision; check it before trying again.',
  BannerNotice.invalid || BannerNotice.blocked =>
    errors.entries
        .map((e) => '${_fieldName(e.key)}: ${sermonReasonText(e.value, e.key)}')
        .join(' '),
  BannerNotice.unconfirmed =>
    'The reply did not arrive. Check again with the same request before '
        'starting another change.',
  BannerNotice.notSent => 'The request was not sent. Your input is still here.',
  BannerNotice.notAllowed || BannerNotice.signInAgain =>
    'Sign in with current Media, Pastor or Admin access.',
  _ => 'Reload the current catalog and check this item before trying again.',
};
String _fieldName(String field) => switch (field) {
  'youtube_video_id' => 'YouTube video',
  'video_rights_id' => 'Video rights',
  'poster_asset_id' => 'Poster',
  'poster_rights_id' => 'Poster rights',
  'alt_text' => 'Poster text alternative',
  'sermon_date' => 'Date',
  'scripture_reference' => 'Scripture',
  'series_id' => 'Series',
  'sermon_id' => 'Sermon',
  _ => '${field[0].toUpperCase()}${field.substring(1).replaceAll('_', ' ')}',
};
String sermonReasonText(String reason, String field) => switch (reason) {
  'unsupported_markdown' || 'unsafe_link' || 'invalid_markdown' || 'unsupported'
      when field == 'notes' =>
    'Use paragraphs, # headings, *emphasis*, lists and approved HTTPS '
        'links. HTML, images and other link forms are not supported.',
  'invalid' when field == 'notes' =>
    'Use supported Markdown and approved HTTPS links only.',
  'invalid' when field == 'youtube_video_id' =>
    'Paste an HTTPS YouTube watch, shorts, embed or youtu.be link, or the '
        '11-character video ID.',
  'too_long' when field == 'youtube_video_id' =>
    'Paste an HTTPS YouTube watch, shorts, embed or youtu.be link, or the '
        '11-character video ID.',
  'invalid' when field == 'sermon_date' => 'Choose a real date.',
  'not_published' when field == 'series_id' =>
    'Publish the series before publishing this sermon.',
  'unknown' when field == 'series_id' =>
    'This series is no longer available. Choose another or none.',
  'archived' => 'This item is archived and can no longer change.',
  'nothing_to_publish' => 'There are no saved changes to publish.',
  'not_published' => 'Only a published item can be withdrawn.',
  'too_long' => 'This text is too long.',
  'required' when field == 'alt_text' =>
    'Describe the poster before publishing.',
  'required' => 'Add this before publishing.',
  _ => bannerReasonText(reason, field: field),
};

/// Waiting to publish, published and withdrawn items, each group in one card;
/// archived items behind a toggle.
class _Sections extends StatefulWidget {
  const _Sections({
    required this.noun,
    required this.items,
    required this.truncated,
    required this.row,
  });
  final String noun;
  final List<StaffSermonItem<Object?>> items;
  final bool truncated;
  final Widget Function(StaffSermonItem<Object?> item) row;
  @override
  State<_Sections> createState() => _SectionsState();
}

class _SectionsState extends State<_Sections> {
  var _showArchived = false;
  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final all = widget.items;
    if (all.isEmpty) {
      return ChurchCard(
        child: Text(
          'No ${widget.noun} yet. Choose New draft to prepare one; it stays '
          'private until you publish it.',
          key: const Key('sermon-catalog-empty'),
          style: ChurchType.body.copyWith(color: c.muted),
        ),
      );
    }
    final waiting = all.where(
      (i) => i.state == ContentState.draft || i.hasChanges,
    );
    final published = all.where(
      (i) => i.state == ContentState.published && !i.hasChanges,
    );
    final withdrawn = all.where((i) => i.state == ContentState.withdrawn);
    final archived = all.where((i) => i.state == ContentState.archived);
    Widget section(
      String title,
      String key,
      Iterable<StaffSermonItem<Object?>> list,
    ) {
      final rows = [for (final i in list) widget.row(i)];
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.truncated)
          RequestStateBanner(
            key: const Key('sermon-catalog-truncated'),
            tone: StatusTone.warning,
            title: 'Not every item is listed',
            message: 'There are more ${widget.noun} than this list shows.',
          ),
        if (waiting.isNotEmpty)
          section('Waiting to publish', 'sermon-section-waiting', waiting),
        if (published.isNotEmpty)
          section('Published', 'sermon-section-published', published),
        if (withdrawn.isNotEmpty)
          section('Withdrawn', 'sermon-section-withdrawn', withdrawn),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: ChurchGeometry.sectionGap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('sermon-show-archived'),
                onPressed: () => setState(() => _showArchived = !_showArchived),
                child: Text(
                  _showArchived
                      ? 'Hide archived ${widget.noun}'
                      : 'Show archived ${widget.noun} (${archived.length})',
                ),
              ),
            ),
          ),
          if (_showArchived)
            section('Archived', 'sermon-section-archived', archived),
        ],
      ],
    );
  }
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
            key: const Key('sermon-confirm-no'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
        ),
        FocusRing(
          child: FilledButton(
            key: const Key('sermon-confirm-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(yes),
          ),
        ),
      ],
    ),
  );
  return ok == true && context.mounted;
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.title,
    required this.subtitle,
    required this.mark,
    required this.busy,
    required this.onEdit,
    required this.onLifecycle,
    this.series = false,
  });
  final StaffSermonItem<Object?> item;
  final String title, subtitle;
  final _Mark mark;
  final bool busy;
  final VoidCallback onEdit;
  final Future<void> Function(String command) onLifecycle;
  final bool series;
  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final id = item.id;
    final publishedLine = [
      if (item.publishedBy case final by?) 'Published by $by',
      if (item.publishedAt case final at?) churchShortWhen(at),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: ChurchType.cardTitle.copyWith(color: c.ink),
                ),
              ),
              const SizedBox(width: 12),
              StatusLabel(label: mark.$1, tone: mark.$2),
            ],
          ),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ChurchType.body.copyWith(color: c.ink),
              ),
            ),
          if (publishedLine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(publishedLine, style: muted),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (item.canEdit)
                FocusRing(
                  child: OutlinedButton(
                    key: Key('sermon-edit-$id'),
                    onPressed: busy ? null : onEdit,
                    child: Text(item.draft == null ? 'Edit' : 'Edit draft'),
                  ),
                ),
              if (item.canPublish)
                FocusRing(
                  child: FilledButton(
                    key: Key('sermon-publish-$id'),
                    onPressed: busy
                        ? null
                        : () => onLifecycle(
                            series
                                ? SermonCommands.publishSeries
                                : SermonCommands.publish,
                          ),
                    child: Text(
                      item.hasChanges
                          ? 'Publish changes'
                          : item.state == ContentState.withdrawn &&
                                item.draft == null
                          ? 'Publish again'
                          : 'Publish',
                    ),
                  ),
                ),
              if (item.canWithdraw)
                FocusRing(
                  child: OutlinedButton(
                    key: Key('sermon-withdraw-$id'),
                    onPressed: busy
                        ? null
                        : () async {
                            if (await _confirm(
                              context,
                              'Withdraw $title?',
                              series
                                  ? 'Its title and poster leave the app. Its '
                                        'published sermons stay readable '
                                        'without them. You can publish it '
                                        'again later.'
                                  : 'It leaves the Sermons tab at once. You '
                                        'can publish it again later.',
                              'Withdraw',
                            )) {
                              await onLifecycle(
                                series
                                    ? SermonCommands.withdrawSeries
                                    : SermonCommands.withdraw,
                              );
                            }
                          },
                    child: const Text('Withdraw'),
                  ),
                ),
              if (item.canEdit)
                FocusRing(
                  child: TextButton(
                    key: Key('sermon-archive-$id'),
                    onPressed: busy
                        ? null
                        : () async {
                            if (await _confirm(
                              context,
                              'Archive $title?',
                              'It leaves the app (if it is public) and can no '
                                  'longer be changed or published.',
                              'Archive',
                            )) {
                              await onLifecycle(
                                series
                                    ? SermonCommands.archiveSeries
                                    : SermonCommands.archive,
                              );
                            }
                          },
                    child: const Text('Archive'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SermonForm extends ConsumerStatefulWidget {
  const _SermonForm({super.key, this.item});
  final StaffSermon? item;
  @override
  ConsumerState<_SermonForm> createState() => _SermonFormState();
}

class _SermonFormState extends ConsumerState<_SermonForm> {
  late final _title = TextEditingController(
    text: widget.item?.current.fields.title,
  );
  late final _speaker = TextEditingController(
    text: widget.item?.current.fields.speaker,
  );
  late final _date = TextEditingController(
    text: widget.item?.current.fields.sermonDate,
  );
  late final _scripture = TextEditingController(
    text: widget.item?.current.fields.scriptureReference,
  );
  late final _notes = TextEditingController(
    text: widget.item?.current.fields.notes,
  );
  late final _video = TextEditingController(
    text: widget.item?.current.fields.youtubeVideoId,
  );
  late String? _series = widget.item?.current.fields.seriesId;
  late String? _rights = widget.item?.current.fields.videoRightsId;
  bool _videoInvalid = false;
  @override
  void dispose() {
    for (final c in [_title, _speaker, _date, _scripture, _notes, _video]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(staffSermonsProvider);
    final ctl = ref.read(staffSermonsProvider.notifier);
    final seriesState = ref.watch(staffSermonSeriesProvider);
    final selectable = [
      for (final s in seriesState.value?.series ?? const <StaffSermonSeries>[])
        if (s.state != ContentState.archived) s,
    ];
    final rights = ref.watch(staffRightsProvider).value;
    return StaffSection(
      title: widget.item == null ? 'New sermon' : 'Edit sermon draft',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'You can save an incomplete draft. Add the title, speaker, date and scripture before publishing. A video needs verified display rights.',
          ),
          const SizedBox(height: 16),
          for (final field in [
            (c: _title, key: 'title', label: 'Title', lines: 1, max: 160),
            (c: _speaker, key: 'speaker', label: 'Speaker', lines: 1, max: 160),
            (
              c: _date,
              key: 'sermon_date',
              label: 'Date (YYYY-MM-DD)',
              lines: 1,
              max: 10,
            ),
            (
              c: _scripture,
              key: 'scripture_reference',
              label: 'Scripture reference',
              lines: 1,
              max: 250,
            ),
            (
              c: _notes,
              key: 'notes',
              label: 'Church-authored notes',
              lines: 10,
              max: 20000,
            ),
            (
              c: _video,
              key: 'youtube_video_id',
              label: 'YouTube link or video ID (optional)',
              lines: 1,
              max: 2000,
            ),
          ])
            if (field.key == 'sermon_date')
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  key: const Key('sermon-field-sermon_date'),
                  controller: _date,
                  readOnly: true,
                  enabled: !state.busy,
                  decoration: InputDecoration(
                    labelText: 'Sermon date',
                    suffixIcon: const Icon(Icons.calendar_today_outlined),
                    errorText: _error(state.fieldErrors, 'sermon_date'),
                  ),
                  onTap: () async {
                    final chosen = await showDatePicker(
                      context: context,
                      initialDate:
                          DateTime.tryParse(_date.text) ?? DateTime.now(),
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2200),
                    );
                    if (chosen != null && mounted) {
                      _date.text =
                          '${chosen.year.toString().padLeft(4, '0')}-${chosen.month.toString().padLeft(2, '0')}-${chosen.day.toString().padLeft(2, '0')}';
                      ctl.clearFieldErrors();
                    }
                  },
                ),
              )
            else
              _Field(
                controller: field.c,
                field: field.key,
                label: field.label,
                maxLines: field.lines,
                maxLength: field.max,
                busy: state.busy,
                errors: {
                  ...state.fieldErrors,
                  if (_videoInvalid) 'youtube_video_id': 'invalid',
                },
                onChanged: () {
                  ctl.clearFieldErrors();
                  if (_videoInvalid) setState(() => _videoInvalid = false);
                },
              ),
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Notes support paragraphs, # headings, *emphasis*, **bold**, lists and [label](https://host/path). '
              'Approved hosts: ebible.org, biblegateway.com, www.biblegateway.com, youtube.com, www.youtube.com, youtu.be. '
              'HTML, images, automatic links, reference links and code are not supported.',
            ),
          ),
          DropdownButtonFormField<String>(
            key: const Key('sermon-field-series_id'),
            initialValue: _series,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Series (optional)',
              errorText: _error(state.fieldErrors, 'series_id'),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('No series')),
              // An archived series can no longer take sermons.
              for (final s in selectable)
                DropdownMenuItem(
                  value: s.id,
                  child: Text(
                    '${s.current.fields.title} · ${switch (s.state) {
                      ContentState.published => 'published',
                      ContentState.withdrawn => 'withdrawn',
                      _ => 'draft, publish it first',
                    }}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (_series != null && selectable.every((s) => s.id != _series))
                DropdownMenuItem(
                  value: _series,
                  child: const Text('Previously chosen series'),
                ),
            ],
            onChanged: state.busy
                ? null
                : (value) => setState(() => _series = value),
          ),
          // Only an answered read that failed says so; loading is not failure.
          if (seriesState.result != null && seriesState.value == null)
            const Text(
              'The series catalog could not be loaded. Your current choice is retained.',
              key: Key('sermon-series-unavailable'),
            ),
          const SizedBox(height: 16),
          _RightsPicker(
            selected: _rights,
            records: rights?.rights ?? [],
            busy: state.busy,
            label: 'Video rights record',
            error: _error(state.fieldErrors, 'video_rights_id'),
            onChanged: (value) => setState(() => _rights = value),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('sermon-save-draft'),
            onPressed: state.busy
                ? null
                : () {
                    final video = _nullable(_video.text);
                    final videoId = video == null
                        ? null
                        : normalizeSermonVideoId(video);
                    if (video != null && videoId == null) {
                      setState(() => _videoInvalid = true);
                      return;
                    }
                    final input = SermonInput(
                      title: _title.text,
                      speaker: _speaker.text,
                      sermonDate: _nullable(_date.text),
                      scriptureReference: _scripture.text,
                      notes: _notes.text,
                      youtubeVideoId: videoId,
                      seriesId: _series,
                      videoRightsId: _rights,
                    );
                    widget.item == null
                        ? ctl.create(input)
                        : ctl.save(widget.item!, input);
                  },
            child: const Text('Save draft'),
          ),
        ],
      ),
    );
  }
}

class _SeriesForm extends ConsumerStatefulWidget {
  const _SeriesForm({super.key, this.item});
  final StaffSermonSeries? item;
  @override
  ConsumerState<_SeriesForm> createState() => _SeriesFormState();
}

class _SeriesFormState extends ConsumerState<_SeriesForm> {
  late final _title = TextEditingController(
    text: widget.item?.current.fields.title,
  );
  late final _description = TextEditingController(
    text: widget.item?.current.fields.description,
  );
  late final _alt = TextEditingController(
    text: widget.item?.current.fields.altText,
  );
  late String? _rights = widget.item?.current.fields.posterRightsId;
  bool _removePoster = false;
  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _alt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final state = ref.watch(staffSermonSeriesProvider);
    final ctl = ref.read(staffSermonSeriesProvider.notifier);
    final upload = item == null
        ? null
        : ref.watch(sermonPosterUploadProvider(item.id));
    final records = ref.watch(staffRightsProvider).value?.rights ?? [];
    final oldAsset = _removePoster ? null : item?.current.poster?.assetId;
    final preview = oldAsset == null
        ? null
        : ref.watch(bannerPreviewProvider(oldAsset)).value;
    final bytes = upload?.bytes ?? preview;
    return StaffSection(
      title: item == null ? 'New series' : 'Edit series draft',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final field in [
            (c: _title, key: 'title', label: 'Title', max: 120, lines: 1),
            (
              c: _description,
              key: 'description',
              label: 'Description',
              max: 2000,
              lines: 3,
            ),
            (
              c: _alt,
              key: 'alt_text',
              label: 'Poster text alternative',
              max: 250,
              lines: 2,
            ),
          ])
            _Field(
              controller: field.c,
              field: field.key,
              label: field.label,
              maxLength: field.max,
              maxLines: field.lines,
              busy: state.busy,
              errors: state.fieldErrors,
              onChanged: ctl.clearFieldErrors,
            ),
          if (item == null)
            const Text(
              'Save the draft first, then add its poster and verified rights.',
            )
          else ...[
            if (bytes != null)
              SizedBox(
                height: 180,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) =>
                      const Text('The poster preview could not be loaded.'),
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('sermon-series-poster-pick'),
                  onPressed: state.busy || upload!.busy
                      ? null
                      : () {
                          setState(() => _removePoster = false);
                          ref
                              .read(
                                sermonPosterUploadProvider(item.id).notifier,
                              )
                              .pickAndUpload();
                        },
                  icon: const Icon(Icons.image_outlined),
                  label: Text(upload!.busy ? 'Uploading…' : 'Choose poster'),
                ),
                if (oldAsset != null || upload.image != null)
                  TextButton(
                    onPressed: state.busy
                        ? null
                        : () {
                            setState(() {
                              _removePoster = true;
                              _rights = null;
                            });
                            ref
                                .read(
                                  sermonPosterUploadProvider(item.id).notifier,
                                )
                                .clear();
                          },
                    child: const Text('Remove poster'),
                  ),
              ],
            ),
            const Text(
              'PNG, JPEG or WebP; landscape close to 16:9, at least 960 × 540, up to 5 MB.',
            ),
            if (upload.status == ImageUploadStatus.uploaded)
              const Text(
                'Poster uploaded privately. Save the draft to attach it.',
              ),
            if (upload.outcome case ImageUploadRefused(:final fieldErrors))
              Text(
                fieldErrors.entries
                    .map((e) => bannerReasonText(e.value, field: e.key))
                    .join(' '),
              ),
            if (upload.status == ImageUploadStatus.failed)
              const Text('The poster could not be uploaded. Try again.'),
            if (_error(state.fieldErrors, 'poster_asset_id') case final error?)
              Text(error),
            const SizedBox(height: 16),
            _RightsPicker(
              selected: _rights,
              records: records,
              busy: state.busy,
              label: 'Poster rights record',
              error: _error(state.fieldErrors, 'poster_rights_id'),
              onChanged: (value) => setState(() => _rights = value),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('sermon-series-save-draft'),
            onPressed: state.busy || (upload?.busy ?? false)
                ? null
                : () {
                    final input = SermonSeriesInput(
                      title: _title.text,
                      description: _description.text,
                      altText: _alt.text,
                      posterAssetId: upload?.image?.assetId ?? oldAsset,
                      posterRightsId: _rights,
                    );
                    item == null ? ctl.create(input) : ctl.save(item, input);
                  },
            child: const Text('Save draft'),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.field,
    required this.label,
    required this.maxLength,
    required this.maxLines,
    required this.busy,
    required this.errors,
    required this.onChanged,
  });
  final TextEditingController controller;
  final String field, label;
  final int maxLength, maxLines;
  final bool busy;
  final Map<String, String> errors;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key('sermon-field-$field'),
      controller: controller,
      enabled: !busy,
      minLines: maxLines,
      maxLines: maxLines,
      maxLength: maxLength,
      decoration: InputDecoration(
        labelText: label,
        alignLabelWithHint: maxLines > 1,
        errorText: _error(errors, field),
      ),
      onChanged: (_) => onChanged(),
    ),
  );
}

String? _nullable(String text) => text.trim().isEmpty ? null : text.trim();
String? _error(Map<String, String> errors, String key) =>
    errors[key] == null ? null : sermonReasonText(errors[key]!, key);

class _RightsPicker extends StatelessWidget {
  const _RightsPicker({
    required this.selected,
    required this.records,
    required this.busy,
    required this.label,
    required this.error,
    required this.onChanged,
  });
  final String? selected, error;
  final List<RightsRecord> records;
  final bool busy;
  final String label;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) {
    final verified = records
        .where((r) => r.state == ContentState.published && r.live != null)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('$label-$selected-${verified.length}'),
          initialValue: selected,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, errorText: error),
          items: [
            const DropdownMenuItem(
              value: null,
              child: Text('No rights record chosen'),
            ),
            for (final r in verified)
              DropdownMenuItem(
                value: r.rightsId,
                child: Text(
                  '${r.live!.fields.label} · ${r.live!.fields.basis.label} · ${r.live!.fields.clearedLabels.join(', ')}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (selected != null &&
                verified.every((r) => r.rightsId != selected))
              DropdownMenuItem(
                value: selected,
                child: const Text(
                  'Previously chosen record · check its clearance',
                ),
              ),
          ],
          onChanged: busy ? null : onChanged,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => context.go('/content/rights'),
            child: const Text('Add or verify rights records'),
          ),
        ),
      ],
    );
  }
}
