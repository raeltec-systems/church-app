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
import 'calendar_screens.dart' show publicReadProblem;
import 'sermon_screens.dart';

class StaffSermonsScreen extends ConsumerWidget {
  const StaffSermonsScreen({super.key, this.series = false, this.itemId});
  final bool series;
  final String? itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      series ? _SeriesCatalog(itemId: itemId) : _SermonCatalog(itemId: itemId);
}

class _SermonCatalog extends ConsumerWidget {
  const _SermonCatalog({this.itemId});
  final String? itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(staffSermonsProvider);
    final ctl = ref.read(staffSermonsProvider.notifier);
    final items = state.value?.sermons ?? [];
    final item = items.where((s) => s.id == itemId).firstOrNull;
    ref.listen(staffSermonsProvider.select((s) => s.notice), (previous, next) {
      if (itemId != null &&
          (next == BannerNotice.created || next == BannerNotice.saved)) {
        context.go(SermonPaths.staff);
      }
    });
    return _CatalogPage(
      title: 'Sermons',
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
                : const Text(
                    'This sermon was not found. Reload the catalog to check again.',
                  ))
          : _Rows(
              children: [
                for (final s in items)
                  _ItemRow(
                    item: s,
                    title: s.current.fields.title,
                    subtitle:
                        '${s.current.fields.speaker.isEmpty ? 'Speaker not added' : s.current.fields.speaker} · '
                        '${s.current.fields.sermonDate ?? 'Date not added'}',
                    liveRevision: s.live?.revisionNo,
                    draftRevision: s.draft?.revisionNo,
                    onEdit: () => context.push('${SermonPaths.staff}/${s.id}'),
                    onLifecycle: (command) => ctl.lifecycle(command, s),
                  ),
              ],
            ),
    );
  }
}

class _SeriesCatalog extends ConsumerWidget {
  const _SeriesCatalog({this.itemId});
  final String? itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(staffSermonSeriesProvider);
    final ctl = ref.read(staffSermonSeriesProvider.notifier);
    final items = state.value?.series ?? [];
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
    return _CatalogPage(
      title: 'Sermon series',
      path: SermonPaths.staffSeries,
      state: state,
      controller: ctl,
      editing: itemId != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if ((state.value?.removalsPending ?? 0) > 0)
            const Text(
              'Some public poster files are waiting to be removed. Sync files to finish.',
            ),
          if (itemId != null)
            (itemId == 'new' || item != null
                ? _SeriesForm(
                    key: ValueKey('series-form-${item?.id}-${item?.revision}'),
                    item: item,
                  )
                : const Text(
                    'This series was not found. Reload the catalog to check again.',
                  ))
          else
            _Rows(
              children: [
                for (final s in items)
                  _ItemRow(
                    item: s,
                    title: s.current.fields.title,
                    subtitle: s.current.fields.description,
                    liveRevision: s.live?.revisionNo,
                    draftRevision: s.draft?.revisionNo,
                    onEdit: () =>
                        context.push('${SermonPaths.staffSeries}/${s.id}'),
                    series: true,
                    onLifecycle: (command) => ctl.lifecycle(command, s),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CatalogPage<T> extends StatelessWidget {
  const _CatalogPage({
    required this.title,
    required this.path,
    required this.state,
    required this.controller,
    required this.child,
    required this.editing,
  });
  final String title, path;
  final StaffCatalogState<T> state;
  final StaffCatalogController<T> controller;
  final Widget child;
  final bool editing;
  @override
  Widget build(BuildContext context) {
    final notice = state.notice;
    return ChurchPageScaffold(
      title: title,
      subtitle: 'Drafts and published teaching',
      actions: [
        if (state.value != null && !editing)
          FilledButton(
            key: Key('$path-new'),
            onPressed: state.busy ? null : () => context.push('$path/new'),
            child: const Text('New draft'),
          ),
        if (path == SermonPaths.staffSeries)
          TextButton(
            onPressed: state.syncing || state.busy ? null : controller.sync,
            child: Text(state.syncing ? 'Syncing…' : 'Sync files'),
          ),
        IconButton(
          key: Key('$path-reload'),
          tooltip: 'Reload',
          onPressed: state.loading || state.busy ? null : controller.reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: SingleChildScrollView(
        padding: ChurchLayout.of(context).pagePadding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ChurchLayout.of(context).contentMaxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (editing)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: state.busy ? null : () => context.go(path),
                      icon: const Icon(Icons.arrow_back),
                      label: Text('Back to $title'),
                    ),
                  ),
                if (state.pending != null)
                  const RequestStateBanner(
                    tone: StatusTone.info,
                    busy: true,
                    title: 'Sending…',
                    message:
                        'Waiting for the church server to confirm the change.',
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
                  const RequestStateBanner(
                    tone: StatusTone.warning,
                    title: 'Public files still waiting',
                    message: 'Some posters could not be placed or removed. Try Sync files again.',
                  ),
                const SizedBox(height: 16),
                if (state.result == null)
                  const Center(child: CircularProgressIndicator())
                else if (state.value == null) ...[
                  const Text(
                    'Sermon editing is available to Media, Pastors and Admins.',
                  ),
                  publicReadProblem(state.result!, what: 'sermon editor'),
                ] else
                  child,
              ],
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
  BannerNotice.created || BannerNotice.saved => 'Your draft is saved. The published revision stays visible until a replacement is published.',
  BannerNotice.published => 'The church server confirmed publication.',
  BannerNotice.withdrawn => 'This item is no longer public.',
  BannerNotice.archived => 'This item is archived.',
  BannerNotice.changedElsewhere => 'Another editor changed this item. The catalog now shows the current revision; check it before trying again.',
  BannerNotice.invalid || BannerNotice.blocked =>
    errors.entries
        .map((e) => '${_fieldName(e.key)}: ${sermonReasonText(e.value, e.key)}')
        .join(' '),
  BannerNotice.unconfirmed => 'The reply did not arrive. Check again with the same request before starting another change.',
  BannerNotice.notSent => 'The request was not sent. Your input is still here.',
  BannerNotice.notAllowed || BannerNotice.signInAgain =>
    'Sign in with current Media, Pastor or Admin access.',
  _ => 'Reload the current catalog and check this item before trying again.',
};
String _fieldName(String field) => switch (field) {
  'youtube_video_id' => 'YouTube video ID',
  'video_rights_id' => 'Video rights',
  'poster_asset_id' => 'Poster',
  'poster_rights_id' => 'Poster rights',
  'sermon_date' => 'Date',
  'scripture_reference' => 'Scripture',
  'series_id' => 'Series',
  _ => field.replaceAll('_', ' '),
};
String sermonReasonText(String reason, String field) => switch (reason) {
  'unsupported_markdown' ||
  'unsafe_link' ||
  'invalid_markdown' ||
  'unsupported' when field == 'notes' => 'Use paragraphs, # headings, *emphasis*, lists and approved HTTPS links. HTML, images and other link forms are not supported.',
  'invalid' when field == 'notes' =>
    'Use supported Markdown and approved HTTPS links only.',
  'invalid' when field == 'youtube_video_id' => 'Paste an HTTPS YouTube watch, shorts, embed or youtu.be link, or the 11-character video ID.',
  'invalid' when field == 'sermon_date' =>
    'Use a real date in YYYY-MM-DD format.',
  'not_published' when field == 'series_id' =>
    'Publish the series before publishing this sermon.',
  'too_long' => 'This text is too long.',
  'required' => 'Add this before publishing.',
  _ => bannerReasonText(reason, field: field),
};

class _Rows extends StatelessWidget {
  const _Rows({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => children.isEmpty
      ? const ChurchCard(
          child: Text(
            'No drafts yet. Choose New draft to prepare teaching for the church.',
          ),
        )
      : ChurchCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0)
                  Divider(height: 1, color: ChurchColors.of(context).line),
                child,
              ],
            ],
          ),
        );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.title,
    required this.subtitle,
    required this.liveRevision,
    required this.draftRevision,
    required this.onEdit,
    required this.onLifecycle,
    this.series = false,
  });
  final StaffSermonItem<Object?> item;
  final String title, subtitle;
  final int? liveRevision, draftRevision;
  final VoidCallback onEdit;
  final Future<void> Function(String command) onLifecycle;
  final bool series;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: ChurchType.cardTitle)),
            const SizedBox(width: 8),
            StatusLabel(
              label: item.hasChanges
                  ? 'Published · draft changes'
                  : switch (item.state) {
                      ContentState.draft => 'Draft',
                      ContentState.published => 'Published',
                      ContentState.withdrawn => 'Withdrawn',
                      ContentState.archived => 'Archived',
                    },
              tone: item.state == ContentState.published
                  ? StatusTone.success
                  : StatusTone.neutral,
            ),
          ],
        ),
        if (subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(subtitle),
          ),
        const SizedBox(height: 6),
        Text(
          [
            if (liveRevision != null) 'Live revision $liveRevision',
            if (draftRevision != null) 'Draft revision $draftRevision',
          ].join(' · '),
          style: ChurchType.secondary,
        ),
        if (item.publishedBy != null)
          Text('Published by ${item.publishedBy}', style: ChurchType.secondary),
        Wrap(
          spacing: 8,
          children: [
            if (item.canEdit)
              TextButton(
                key: Key('sermon-edit-${item.id}'),
                onPressed: onEdit,
                child: const Text('Edit draft'),
              ),
            if (item.canPublish)
              TextButton(
                key: Key('sermon-publish-${item.id}'),
                onPressed: () => onLifecycle(
                  series
                      ? SermonCommands.publishSeries
                      : SermonCommands.publish,
                ),
                child: const Text('Publish'),
              ),
            if (item.canWithdraw)
              TextButton(
                key: Key('sermon-withdraw-${item.id}'),
                onPressed: () => onLifecycle(
                  series
                      ? SermonCommands.withdrawSeries
                      : SermonCommands.withdraw,
                ),
                child: const Text('Withdraw'),
              ),
            if (item.canEdit)
              TextButton(
                key: Key('sermon-archive-${item.id}'),
                onPressed: () => onLifecycle(
                  series
                      ? SermonCommands.archiveSeries
                      : SermonCommands.archive,
                ),
                child: const Text('Archive'),
              ),
          ],
        ),
      ],
    ),
  );
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
    final allSeries = seriesState.value?.series ?? [];
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
            initialValue: _series,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Series (optional)',
              errorText: _error(state.fieldErrors, 'series_id'),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('No series')),
              for (final s in allSeries)
                DropdownMenuItem(
                  value: s.id,
                  child: Text('${s.current.fields.title} · ${s.state.name}'),
                ),
              if (_series != null && allSeries.every((s) => s.id != _series))
                DropdownMenuItem(
                  value: _series,
                  child: const Text('Previously chosen series'),
                ),
            ],
            onChanged: state.busy
                ? null
                : (value) => setState(() => _series = value),
          ),
          if (seriesState.value == null)
            const Text(
              'The series catalog could not be loaded. Your current choice is retained.',
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
