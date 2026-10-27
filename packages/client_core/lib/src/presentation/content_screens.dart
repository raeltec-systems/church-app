import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/banner_controllers.dart'
    show
        BannerImageUpload,
        ImageUploadStatus,
        bannerPreviewProvider,
        staffRightsProvider;
import '../application/content_controllers.dart';
import '../application/providers.dart' show contentFilePickerProvider;
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/content_banners.dart';
import '../domain/content_events.dart';
import 'banner_screens.dart' show bannerReasonText;
import 'calendar_screens.dart'
    show churchLongWhen, churchShortWhen, eventSpanText;
import 'church_widgets.dart';
import 'home_banners.dart' show BannerPaths;

// Story 6.1, staff web: the editors (Media, Pastor, Admin) draft, publish,
// withdraw and archive church events. The screen answers "what is waiting to
// be published, and what is on the public calendar?" first: the finding line
// and the Waiting to publish section, then what is on the calendar, then the
// rest. One status mark per row; the versions, who saved and published them
// and every action are on the opened row. Every list comes from a
// server-checked read and every action is a server-checked command; an
// event shows as published only after the server confirmed it.

/// The staff routes of Content.
abstract final class ContentPaths {
  /// Staff web: the Events editor.
  static const events = '/content/events';
}

const _needs = 'Events are managed by Media, Pastors and Admins.';

(StatusTone, String, String) _noticeText(ContentNotice n, ContentAction? a) {
  final what = a?.subject ?? 'the event';
  return switch (n) {
    ContentNotice.created => (
      StatusTone.success,
      'Draft saved',
      '$what is saved as a draft. Only editors see it until you publish it.',
    ),
    ContentNotice.saved => (
      StatusTone.success,
      'Changes saved',
      'Your changes to $what are saved as a draft. The public calendar keeps '
          'showing the published version until you publish them.',
    ),
    ContentNotice.published => (
      StatusTone.success,
      'Published',
      '$what is on the public calendar. Phones show it on their next refresh.',
    ),
    ContentNotice.withdrawn => (
      StatusTone.success,
      'Withdrawn',
      '$what is off the public calendar. Phones drop it on their next '
          'refresh. You can publish it again.',
    ),
    ContentNotice.archived => (
      StatusTone.success,
      'Archived',
      '$what is archived. It is not public and can no longer change.',
    ),
    ContentNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      '$what was changed in another tab or by another editor. The list now '
          'shows the current version; check it and try again.',
    ),
    ContentNotice.nothingToPublish => (
      StatusTone.warning,
      'Nothing to publish',
      '$what has no saved changes to publish.',
    ),
    ContentNotice.notPublished => (
      StatusTone.warning,
      'Not on the calendar',
      '$what is not published, so there is nothing to withdraw.',
    ),
    ContentNotice.alreadyArchived => (
      StatusTone.warning,
      'Archived',
      '$what is archived and can no longer change.',
    ),
    ContentNotice.invalid => (
      StatusTone.warning,
      'Check the event',
      'Some details need changing; see the marked fields. Nothing was saved.',
    ),
    ContentNotice.notAllowed => (
      StatusTone.danger,
      'Not allowed',
      '$_needs Nothing was changed.',
    ),
    ContentNotice.signInAgain => (
      StatusTone.danger,
      'Please sign in again',
      'Your session is no longer trusted. Nothing was changed.',
    ),
    ContentNotice.notFound => (
      StatusTone.warning,
      'Not found',
      'That event no longer exists. The list now shows the current events.',
    ),
    ContentNotice.notAvailable => (
      StatusTone.warning,
      'Not available right now',
      'The church server could not do this now. Nothing was changed.',
    ),
    ContentNotice.refused => (
      StatusTone.danger,
      'Not done',
      'The church server refused this. Nothing was changed.',
    ),
    ContentNotice.unconfirmed => (
      StatusTone.warning,
      'Not confirmed',
      'We could not tell whether $what was changed. Check again sends the '
          'same request, so it cannot apply twice.',
    ),
    ContentNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
    ContentNotice.organisersSet => (
      StatusTone.success,
      'Organisers changed',
      'The organisers of $what are saved. They and Admins see who is coming; '
          'other editors see the numbers only.',
    ),
    ContentNotice.organisersNotAllowed => (
      StatusTone.danger,
      'Not allowed',
      'Only the event\'s organisers and Admins choose its organisers. Nothing '
          'was changed.',
    ),
    ContentNotice.organisersInvalid => (
      StatusTone.warning,
      'Check the organisers',
      'Organisers must be people who edit events now, at most '
          '$maxEventOrganisers. The list is reloaded; choose again. Nothing was '
          'changed.',
    ),
  };
}

/// A field error code as a sentence (null when there is none).
String? _fieldError(String wire, String? code) => switch (code) {
  null => null,
  'required' when wire == 'poster_asset_id' => 'Add a poster first',
  'required' when wire == 'poster_rights_id' => 'Choose a rights record',
  'required' when wire == 'poster_alt_text' =>
    'Describe the poster for someone who can\'t see it',
  'required' => 'Required',
  'too_long' when wire == 'ends_at' => 'An event can last at most 31 days',
  'too_long' => 'Too long',
  'before_start' => 'Must be after the start',
  'out_of_range' when wire == 'rsvp_capacity' =>
    'Use 1 to $maxEventPlaces places',
  'out_of_range' => 'Too far in the past or the future',
  'must_be_null' when wire == 'rsvp_capacity' =>
    'Places are only used when RSVP is on',
  'invalid' when wire == 'starts_at' || wire == 'ends_at' =>
    'Use a real date (YYYY-MM-DD) and time (HH:MM)',
  'invalid' when wire == 'rsvp_capacity' => 'Use a whole number',
  'not_ready' => 'The poster upload is not finished; choose it again',
  'retention_claimed' => 'This upload was removed; choose the poster again',
  'unknown' when wire == 'poster_asset_id' =>
    'This upload is not this event\'s; choose the poster again',
  'unknown' => 'Not found. Reload and choose again.',
  'not_in_force' => 'Verify this rights record first',
  'use_not_cleared' => 'This rights record does not clear display',
  'source_not_cleared' =>
    'This third-party source is not cleared by the owner (Q5)',
  _ => 'Check this',
};

/// The one mark an event's row carries.
(String, StatusTone) _mark(StaffEvent e, DateTime now) => switch (e.state) {
  ContentState.draft => ('Draft', StatusTone.neutral),
  ContentState.published when e.hasChanges => (
    'Changes not published',
    StatusTone.warning,
  ),
  ContentState.published when e.endedAt(now) => ('Ended', StatusTone.neutral),
  ContentState.published => ('Published', StatusTone.success),
  ContentState.withdrawn => ('Withdrawn', StatusTone.neutral),
  ContentState.archived => ('Archived', StatusTone.neutral),
};

/// `/content/events` (staff web; Media, Pastor and Admin).
class StaffEventsScreen extends ConsumerStatefulWidget {
  const StaffEventsScreen({super.key});

  @override
  ConsumerState<StaffEventsScreen> createState() => _StaffEventsScreenState();
}

class _StaffEventsScreenState extends ConsumerState<StaffEventsScreen> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'events notice');

  /// The new-event form is open (the header's main action toggles it).
  var _creating = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    if (ref.read(staffEventsProvider).result != null) {
      Future.microtask(_reload);
    }
    // Story 6.11: opening Events places published posters and removes those
    // of withdrawn or ended events (the list is read again only if it did).
    Future.microtask(() {
      if (mounted) ref.read(staffEventsProvider.notifier).sync();
    });
  }

  void _reload() {
    final s = ref.read(staffEventsProvider);
    if (mounted && !s.busy && !s.loading) {
      ref.read(staffEventsProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(staffEventsProvider);
    final ctl = ref.read(staffEventsProvider.notifier);
    ref.listen(staffEventsProvider.select((x) => x.notice), (prev, next) {
      if (next == null || next == prev) return;
      final (_, title, message) = _noticeText(
        next,
        ref.read(staffEventsProvider).noticeAction,
      );
      announce(context, '$title. $message');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      });
    });
    final children = <Widget>[];
    if (s.pending case final p?) {
      children.add(
        RequestStateBanner(
          key: const Key('events-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the church server about ${p.subject}. Nothing is '
              'shown as done until it answers.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(n, s.noticeAction);
      children.add(
        RequestStateBanner(
          key: Key('events-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == ContentNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('events-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('events-dismiss'),
            ),
          ],
        ),
      );
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('events-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading events…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        children.add(
          _EventsBody(
            value: value,
            state: s,
            creating: _creating,
            onCreatingChanged: (v) => setState(() => _creating = v),
          ),
        );
      case AccessReadDenied(:final denial):
        children.add(
          RequestStateBanner(
            key: Key('events-denied-${denial.name}'),
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
            key: const Key('events-failed'),
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
    // Staff web: the page header carries the finding, the main action (New
    // event) and Reload; on a phone the bar keeps its Reload button.
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final value = s.value;
    final newEvent = value == null
        ? null
        : FocusRing(
            child: FilledButton.icon(
              key: const Key('events-new'),
              onPressed: s.busy
                  ? null
                  : () => setState(() => _creating = !_creating),
              icon: Icon(_creating ? Icons.close : Icons.add),
              label: Text(_creating ? 'Close the form' : 'New event'),
            ),
          );
    return ChurchPageScaffold(
      title: 'Events',
      subtitle: value == null ? null : _eventsFinding(value, DateTime.now()),
      actions: phone
          ? [
              ?newEvent,
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('events-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [?newEvent, staffReloadButton(const Key('events-reload'), reload)],
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
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The screen's finding, in one line under the title: what waits to be
/// published and what is on the public calendar.
String _eventsFinding(StaffEvents value, DateTime now) {
  final events = value.events;
  if (events.isEmpty) {
    return 'No events yet. A new event stays a private draft until you '
        'publish it.';
  }
  final waiting = events
      .where((e) => e.state == ContentState.draft || e.hasChanges)
      .length;
  // Every published event that has not ended is public, unpublished
  // changes or not (the published version is what the calendar shows).
  final onCalendar = events
      .where((e) => e.state == ContentState.published && !e.endedAt(now))
      .length;
  return [
    waiting == 0 ? 'Nothing waiting to publish' : '$waiting waiting to publish',
    '$onCalendar on the public calendar',
  ].join(' · ');
}

class _EventsBody extends ConsumerStatefulWidget {
  const _EventsBody({
    required this.value,
    required this.state,
    required this.creating,
    required this.onCreatingChanged,
  });
  final StaffEvents value;
  final StaffEventsState state;
  final bool creating;
  final ValueChanged<bool> onCreatingChanged;

  @override
  ConsumerState<_EventsBody> createState() => _EventsBodyState();
}

class _EventsBodyState extends ConsumerState<_EventsBody> {
  String? _open;
  var _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final busy = widget.state.busy;
    // A confirmed create closes the new-event form.
    ref.listen(staffEventsProvider.select((x) => x.notice), (prev, next) {
      if (next == ContentNotice.created && mounted) {
        widget.onCreatingChanged(false);
      }
    });
    final now = DateTime.now();
    final events = widget.value.events;
    final waiting = [
      for (final e in events)
        if (e.state == ContentState.draft || e.hasChanges) e,
    ];
    final onCalendar = [
      for (final e in events)
        if (e.state == ContentState.published &&
            !e.hasChanges &&
            !e.endedAt(now))
          e,
    ];
    final withdrawn = [
      for (final e in events)
        if (e.state == ContentState.withdrawn) e,
    ];
    final past = [
      for (final e in events)
        if (e.state == ContentState.published &&
            !e.hasChanges &&
            e.endedAt(now))
          e,
    ];
    final archived = [
      for (final e in events)
        if (e.state == ContentState.archived) e,
    ];
    Widget section(String title, List<StaffEvent> rows, String key) => Column(
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
              for (final (i, e) in rows.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 78, color: c.line),
                _EventRow(
                  key: Key('event-${e.eventId}'),
                  event: e,
                  open: _open == e.eventId,
                  busy: busy,
                  state: widget.state,
                  now: now,
                  onToggle: () => setState(
                    () => _open = _open == e.eventId ? null : e.eventId,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.creating) ...[
          ChurchCard(
            radius: 12,
            child: _EventForm(
              key: const Key('event-form-new'),
              event: null,
              busy: busy,
              state: widget.state,
              onCancel: () => widget.onCreatingChanged(false),
            ),
          ),
        ],
        if (widget.value.truncated) ...[
          const SizedBox(height: 12),
          const RequestStateBanner(
            key: Key('events-truncated'),
            tone: StatusTone.warning,
            title: 'Not every event is listed',
            message:
                'There are more events than this list shows; the most '
                'relevant are listed first.',
          ),
        ],
        if (waiting.isNotEmpty)
          section('Waiting to publish', waiting, 'events-waiting'),
        if (onCalendar.isNotEmpty)
          section('On the calendar', onCalendar, 'events-on-calendar'),
        if (withdrawn.isNotEmpty)
          section('Withdrawn', withdrawn, 'events-withdrawn'),
        if (past.isNotEmpty) section('Past', past, 'events-past'),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: ChurchGeometry.sectionGap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('events-show-archived'),
                onPressed: () => setState(() => _showArchived = !_showArchived),
                child: Text(
                  _showArchived
                      ? 'Hide archived events'
                      : 'Show archived events (${archived.length})',
                ),
              ),
            ),
          ),
          if (_showArchived) section('Archived', archived, 'events-archived'),
        ],
        const SizedBox(height: 16),
        Text(
          'Times are church time (Kafue), whatever this computer\'s clock is '
          'set to. A draft and unpublished changes are seen by editors only; '
          'the public calendar shows the published version.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ],
    );
  }
}

/// One event: the row (date, title, when · where, one mark), and when opened
/// its published and draft versions with who saved them, and its actions.
class _EventRow extends ConsumerStatefulWidget {
  const _EventRow({
    super.key,
    required this.event,
    required this.open,
    required this.busy,
    required this.state,
    required this.now,
    required this.onToggle,
  });

  final StaffEvent event;
  final bool open;
  final bool busy;
  final StaffEventsState state;
  final DateTime now;
  final VoidCallback onToggle;

  @override
  ConsumerState<_EventRow> createState() => _EventRowState();
}

class _EventRowState extends ConsumerState<_EventRow> {
  var _editing = false;

  Future<bool> _confirm(String title, String body, String yes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ChurchDialog(
        title: title,
        content: Text(body),
        actions: [
          FocusRing(
            child: TextButton(
              key: const Key('event-confirm-no'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep it'),
            ),
          ),
          FocusRing(
            child: FilledButton(
              key: const Key('event-confirm-yes'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(yes),
            ),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final e = widget.event;
    final id = e.eventId;
    final busy = widget.busy;
    final f = e.current;
    final (mark, tone) = _mark(e, widget.now);
    final ctl = ref.read(staffEventsProvider.notifier);
    // A confirmed save closes this event's form.
    ref.listen(staffEventsProvider.select((x) => x.notice), (prev, next) {
      final a = ref.read(staffEventsProvider).noticeAction;
      if (next == ContentNotice.saved &&
          a?.request.payload['event_id'] == id &&
          mounted) {
        setState(() => _editing = false);
      }
    });
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final summary = InkWell(
      key: Key('event-open-$id'),
      onTap: widget.onToggle,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ChurchDateBadge(at: f.startsAt),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.title,
                    style: ChurchType.itemTitle.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${eventSpanText(f.startsAt, f.endsAt)} · ${f.location}',
                    style: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            StatusLabel(key: Key('event-mark-$id'), label: mark, tone: tone),
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

    Widget version(String label, StaffEventRevision r, String attribution) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardLabel(label),
            const SizedBox(height: 6),
            DetailTable(
              rows: [
                (label: 'Title', value: r.fields.title),
                (label: 'Starts', value: churchLongWhen(r.fields.startsAt)),
                (label: 'Ends', value: churchLongWhen(r.fields.endsAt)),
                (label: 'Where', value: r.fields.location),
                (label: 'About', value: r.fields.description),
                (label: 'Poster', value: _posterText(r)),
                (label: 'RSVP', value: _rsvpSettingText(r)),
              ],
            ),
            const SizedBox(height: 6),
            Text(attribution, style: muted),
          ],
        );

    final live = e.live;
    final draft = e.draft;
    final publishLabel = switch (e) {
      _ when e.hasChanges => 'Publish changes',
      _ when e.state == ContentState.withdrawn && draft == null =>
        'Publish again',
      _ => 'Publish',
    };
    final actions = <Widget>[
      if (e.canEdit)
        FocusRing(
          child: OutlinedButton(
            key: Key('event-edit-$id'),
            onPressed: busy ? null : () => setState(() => _editing = !_editing),
            child: Text(_editing ? 'Close the form' : 'Edit'),
          ),
        ),
      if (e.canPublish)
        FocusRing(
          child: FilledButton(
            key: Key('event-publish-$id'),
            onPressed: busy ? null : () => ctl.publish(e),
            child: Text(publishLabel),
          ),
        ),
      if (e.canWithdraw)
        FocusRing(
          child: OutlinedButton(
            key: Key('event-withdraw-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      'Withdraw ${f.title}?',
                      'It disappears from the public calendar the next time '
                          'a phone refreshes. You can publish it again later.',
                      'Withdraw',
                    )) {
                      await ctl.withdraw(e);
                    }
                  },
            child: const Text('Withdraw'),
          ),
        ),
      if (e.canArchive)
        FocusRing(
          child: TextButton(
            key: Key('event-archive-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      'Archive ${f.title}?',
                      'It leaves the public calendar (if it is on it) and can '
                          'no longer be changed or published.',
                      'Archive',
                    )) {
                      await ctl.archive(e);
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
          key: Key('event-details-$id'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (live != null) ...[
                version(
                  switch (e.state) {
                    ContentState.published => 'On the public calendar',
                    _ => 'Last published version (not public)',
                  },
                  live,
                  [
                    if (e.publishedBy case final by?) 'Published by $by',
                    if (e.publishedAt case final at?) churchShortWhen(at),
                  ].join(' · '),
                ),
                const SizedBox(height: 14),
              ],
              if (draft != null) ...[
                version(
                  live == null
                      ? 'Draft (editors only)'
                      : 'Changes not '
                            'published yet (editors only)',
                  draft,
                  'Saved by ${draft.savedBy} · ${churchShortWhen(draft.savedAt)}',
                ),
                const SizedBox(height: 14),
              ],
              if (e.withdrawnAt case final at?
                  when e.state == ContentState.withdrawn)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Withdrawn ${churchShortWhen(at)}', style: muted),
                ),
              if (e.archivedAt case final at?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Archived ${churchShortWhen(at)}', style: muted),
                ),
              Text(
                'Created by ${e.createdBy} · ${churchShortWhen(e.createdAt)}',
                style: muted,
              ),
              const SizedBox(height: 14),
              _EventPeople(event: e, busy: busy),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
              if (_editing) ...[
                const SizedBox(height: 14),
                _EventForm(
                  key: Key('event-form-$id'),
                  event: e,
                  busy: busy,
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

/// Story 6.11: a revision's poster in one line.
String _posterText(StaffEventRevision r) => switch (r.poster) {
  null => 'None',
  _ => 'Added · ${r.posterAltText ?? 'no description'}',
};

/// Story 6.11: a revision's RSVP setting in one line.
String _rsvpSettingText(StaffEventRevision r) => switch (r) {
  StaffEventRevision(rsvpEnabled: false) => 'Off',
  StaffEventRevision(rsvpCapacity: null) => 'On · no limit',
  StaffEventRevision(rsvpCapacity: final c?) => 'On · $c places',
};

/// Story 6.11: how many are going, as every editor reads it.
String _goingText(StaffEvent e) {
  final capacity = (e.live ?? e.draft)?.rsvpCapacity;
  final going = e.rsvpGoing == 1 ? '1 going' : '${e.rsvpGoing} going';
  if (capacity == null) return going;
  final left = capacity - e.rsvpGoing;
  return left <= 0
      ? '$going · full ($capacity places)'
      : '$going · $left of $capacity places left';
}

/// Story 6.11: an opened event's RSVP, poster place, organisers and (for an
/// Admin or one of its organisers) who is coming. Every editor reads the
/// numbers; the names are a separate, server-checked read.
class _EventPeople extends ConsumerStatefulWidget {
  const _EventPeople({required this.event, required this.busy});

  final StaffEvent event;
  final bool busy;

  @override
  ConsumerState<_EventPeople> createState() => _EventPeopleState();
}

class _EventPeopleState extends ConsumerState<_EventPeople> {
  var _showNames = false;

  Future<void> _changeOrganisers(StaffEvent e) async {
    final options = ref.read(staffEventsProvider).value?.organiserOptions ?? [];
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (context) => _OrganisersDialog(event: e, options: options),
    );
    if (chosen == null || !mounted) return;
    await ref.read(staffEventsProvider.notifier).setOrganisers(e, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final e = widget.event;
    final id = e.eventId;
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final takesRsvp =
        (e.live?.rsvpEnabled ?? false) ||
        (e.draft?.rsvpEnabled ?? false) ||
        e.rsvpGoing > 0;
    final posterNote = switch (e.publicPoster) {
      EventPosterState.waiting =>
        'The poster goes on the public calendar at the next file sync.',
      EventPosterState.blocked =>
        'The poster can\'t be shown: check its upload and rights record.',
      EventPosterState.ended =>
        'The event has ended; its poster leaves the public calendar.',
      _ => null,
    };
    final organisers = e.organisers.isEmpty
        ? 'No organisers yet'
        : e.organisers.map((o) => o.name).join(', ');
    return Column(
      key: Key('event-people-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (posterNote != null) ...[
          Text(posterNote, key: Key('event-poster-note-$id'), style: muted),
          const SizedBox(height: 10),
        ],
        const CardLabel('RSVP'),
        const SizedBox(height: 6),
        Text(
          takesRsvp ? _goingText(e) : 'This event takes no RSVPs.',
          key: Key('event-going-$id'),
          style: ChurchType.body.copyWith(color: c.ink),
        ),
        const SizedBox(height: 6),
        Text(
          'Organisers: $organisers',
          key: Key('event-organisers-$id'),
          style: muted,
        ),
        if (!e.seesNames)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Only this event\'s organisers and Admins see who is coming.',
              key: Key('event-names-hidden-$id'),
              style: muted,
            ),
          )
        else ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (takesRsvp)
                FocusRing(
                  child: OutlinedButton(
                    key: Key('event-who-$id'),
                    onPressed: () => setState(() => _showNames = !_showNames),
                    child: Text(
                      _showNames ? 'Hide who\'s coming' : 'Who\'s coming',
                    ),
                  ),
                ),
              if (e.canEdit)
                FocusRing(
                  child: TextButton(
                    key: Key('event-organisers-change-$id'),
                    onPressed: widget.busy ? null : () => _changeOrganisers(e),
                    child: const Text('Change organisers'),
                  ),
                ),
            ],
          ),
          if (_showNames) ...[
            const SizedBox(height: 8),
            _WhoIsComing(eventId: id),
          ],
        ],
      ],
    );
  }
}

/// Story 6.11: the names of the members going (earliest first), read only
/// when an Admin or an organiser asks for them.
class _WhoIsComing extends ConsumerWidget {
  const _WhoIsComing({required this.eventId});

  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final read = ref.watch(staffEventRsvpsProvider(eventId));
    Widget line(String text, String key) =>
        Text(text, key: Key('$key-$eventId'), style: muted);
    return switch (read) {
      AsyncData(value: AccessReadOk(value: StaffEventRsvpsRead(:final rsvps?)))
          when rsvps.attendees.isEmpty =>
        line('Nobody is going yet.', 'event-names-empty'),
      AsyncData(
        value: AccessReadOk(value: StaffEventRsvpsRead(:final rsvps?)),
      ) =>
        Column(
          key: Key('event-names-$eventId'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChurchCard(
              padding: EdgeInsets.zero,
              radius: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, a) in rsvps.attendees.indexed) ...[
                    if (i > 0) Divider(height: 1, color: c.line),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              a.name,
                              style: ChurchType.body.copyWith(color: c.ink),
                            ),
                          ),
                          Text(churchShortWhen(a.rsvpAt), style: muted),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (rsvps.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: line(
                  'More are going than this list shows.',
                  'event-names-truncated',
                ),
              ),
          ],
        ),
      AsyncData(value: AccessReadOk()) => line(
        'This event is no longer listed. Reload the events.',
        'event-names-gone',
      ),
      AsyncData(value: AccessReadDenied()) => line(
        'Only this event\'s organisers and Admins see who is coming.',
        'event-names-denied',
      ),
      AsyncData(value: AccessReadFailed(:final unreachable)) => line(
        unreachable
            ? 'No connection: the names could not be loaded.'
            : 'The names could not be loaded. Try again later.',
        'event-names-failed',
      ),
      _ => line('Loading who\'s coming…', 'event-names-loading'),
    };
  }
}

/// Story 6.11: choose up to [maxEventOrganisers] organisers among the people
/// who edit events. Pops the chosen member ids, or null when cancelled.
class _OrganisersDialog extends StatefulWidget {
  const _OrganisersDialog({required this.event, required this.options});

  final StaffEvent event;
  final List<EventOrganiser> options;

  @override
  State<_OrganisersDialog> createState() => _OrganisersDialogState();
}

class _OrganisersDialogState extends State<_OrganisersDialog> {
  // Only people who edit events now can be organisers: an organiser who no
  // longer does is listed unticked (saving removes them), never sent.
  late final Set<String> _chosen = {
    for (final o in widget.event.organisers)
      if (widget.options.any((x) => x.memberId == o.memberId)) o.memberId,
  };

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final options = widget.options;
    final stale = [
      for (final o in widget.event.organisers)
        if (options.every((x) => x.memberId != o.memberId)) o,
    ];
    final full = _chosen.length >= maxEventOrganisers;
    return ChurchDialog(
      title: 'Organisers of ${widget.event.current.title}',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Organisers and Admins see who is coming. Choose up to '
            '$maxEventOrganisers people who edit events.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final o in options)
                    CheckboxListTile(
                      key: Key('organiser-option-${o.memberId}'),
                      value: _chosen.contains(o.memberId),
                      title: Text(o.name),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: !_chosen.contains(o.memberId) && full
                          ? null
                          : (v) => setState(() {
                              if (v ?? false) {
                                _chosen.add(o.memberId);
                              } else {
                                _chosen.remove(o.memberId);
                              }
                            }),
                    ),
                  for (final o in stale)
                    CheckboxListTile(
                      key: Key('organiser-stale-${o.memberId}'),
                      value: false,
                      title: Text(o.name),
                      subtitle: const Text(
                        'No longer edits events; saving removes them',
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: null,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        FocusRing(
          child: TextButton(
            key: const Key('organisers-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ),
        FocusRing(
          child: FilledButton(
            key: const Key('organisers-save'),
            onPressed: () => Navigator.of(context).pop([
              for (final o in options)
                if (_chosen.contains(o.memberId)) o.memberId,
            ]),
            child: const Text('Save organisers'),
          ),
        ),
      ],
    );
  }
}

/// A new event ([event] null) or an edit of one: every field, saved as a
/// draft. Times are church time.
class _EventForm extends ConsumerStatefulWidget {
  const _EventForm({
    super.key,
    required this.event,
    required this.busy,
    required this.state,
    required this.onCancel,
  });

  final StaffEvent? event;
  final bool busy;
  final StaffEventsState state;
  final VoidCallback onCancel;

  @override
  ConsumerState<_EventForm> createState() => _EventFormState();
}

class _EventFormState extends ConsumerState<_EventForm> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _startDate = TextEditingController();
  final _startTime = TextEditingController();
  final _endDate = TextEditingController();
  final _endTime = TextEditingController();
  final _location = TextEditingController();

  // Story 6.11: RSVP and the poster.
  final _places = TextEditingController();
  final _posterAlt = TextEditingController();
  var _rsvp = false;
  String? _posterRightsId;

  /// The editor removed the revision's poster (saved with the next save).
  var _posterRemoved = false;

  @override
  void initState() {
    super.initState();
    // An edit starts from the draft, otherwise from the published version.
    if (widget.event?.current case final f?) {
      _title.text = f.title;
      _description.text = f.description;
      _startDate.text = ChurchTime.dateText(f.startsAt);
      _startTime.text = ChurchTime.timeText(f.startsAt);
      _endDate.text = ChurchTime.dateText(f.endsAt);
      _endTime.text = ChurchTime.timeText(f.endsAt);
      _location.text = f.location;
    }
    if (widget.event?.currentRevision case final r?) {
      _rsvp = r.rsvpEnabled;
      _places.text = r.rsvpCapacity?.toString() ?? '';
      _posterRightsId = r.posterRights?.rightsId;
      _posterAlt.text = r.posterAltText ?? '';
    }
  }

  List<TextEditingController> get _all => [
    _title,
    _description,
    _startDate,
    _startTime,
    _endDate,
    _endTime,
    _location,
    _places,
    _posterAlt,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseDate(
    TextEditingController controller, {
    required String label,
  }) async {
    final firstDate = DateTime(1900);
    final lastDate = DateTime(2100, 12, 31);
    final current = DateTime.tryParse(controller.text) ?? DateTime.now();
    final initialDate = current.isBefore(firstDate)
        ? firstDate
        : current.isAfter(lastDate)
        ? lastDate
        : current;
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: label,
    );
    if (!mounted || selected == null) return;
    controller.text = ChurchTime.dateText(selected);
    ref.read(staffEventsProvider.notifier).clearFieldErrors();
  }

  Future<void> _chooseTime(
    TextEditingController controller, {
    required String label,
    required TimeOfDay fallback,
  }) async {
    final parts = controller.text.split(':');
    final parsed = parts.length == 2
        ? (int.tryParse(parts[0]), int.tryParse(parts[1]))
        : (null, null);
    final initial =
        parsed.$1 != null &&
            parsed.$2 != null &&
            parsed.$1! >= 0 &&
            parsed.$1! <= 23 &&
            parsed.$2! >= 0 &&
            parsed.$2! <= 59
        ? TimeOfDay(hour: parsed.$1!, minute: parsed.$2!)
        : fallback;
    final selected = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: label,
    );
    if (!mounted || selected == null) return;
    controller.text = MaterialLocalizations.of(context)
        .formatTimeOfDay(selected, alwaysUse24HourFormat: true);
    ref.read(staffEventsProvider.notifier).clearFieldErrors();
  }

  /// What is typed, or null while something required is missing or unread.
  /// [posterAssetId] is the poster the draft keeps (the new upload, else the
  /// revision's own unless removed).
  EventInput? _input(String? posterAssetId) {
    final starts = ChurchTime.parse(_startDate.text, _startTime.text);
    final ends = ChurchTime.parse(_endDate.text, _endTime.text);
    final placesText = _places.text.trim();
    final places = placesText.isEmpty ? null : int.tryParse(placesText);
    if (_title.text.trim().isEmpty ||
        _description.text.trim().isEmpty ||
        _location.text.trim().isEmpty ||
        starts == null ||
        ends == null ||
        (_rsvp && placesText.isNotEmpty && places == null)) {
      return null;
    }
    return EventInput(
      title: _title.text,
      description: _description.text,
      startsAt: starts,
      endsAt: ends,
      location: _location.text,
      rsvpEnabled: _rsvp,
      rsvpCapacity: _rsvp ? places : null,
      posterAssetId: posterAssetId,
      posterRightsId: posterAssetId == null ? null : _posterRightsId,
      posterAltText: posterAssetId == null ? null : _posterAlt.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final e = widget.event;
    final tag = e?.eventId ?? 'new';
    final st = widget.state;
    // Only a refusal of this form's own command names its fields.
    final a = st.noticeAction;
    final mine = e == null
        ? a?.command == ContentCommands.createEvent
        : a?.command == ContentCommands.saveEvent &&
              a?.request.payload['event_id'] == e.eventId;
    final errors = mine ? st.fieldErrors : const <String, String>{};
    Widget field(
      String key,
      TextEditingController ctl,
      String label, {
      String? wire,
      String? hint,
      String? helper,
      int maxLength = 120,
      int maxLines = 1,
      Widget? suffixIcon,
      List<TextInputFormatter>? formatters,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$tag'),
        controller: ctl,
        enabled: !widget.busy,
        maxLength: maxLength,
        maxLines: maxLines,
        inputFormatters: formatters,
        onChanged: (_) =>
            ref.read(staffEventsProvider.notifier).clearFieldErrors(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          suffixIcon: suffixIcon,
          errorText: wire == null ? null : _fieldError(wire, errors[wire]),
        ),
      ),
    );

    // Story 6.11: the poster the draft keeps: the one just uploaded, else the
    // revision's own unless the editor removed it.
    final upload = e == null
        ? null
        : ref.watch(eventPosterUploadProvider(e.eventId));
    final currentPoster = _posterRemoved ? null : e?.currentRevision.poster;
    final posterAssetId = upload?.image?.assetId ?? currentPoster?.assetId;
    // A confirmed save of this event uses the uploaded poster: forget it.
    ref.listen(staffEventsProvider.select((x) => x.notice), (prev, next) {
      final act = ref.read(staffEventsProvider).noticeAction;
      if (e != null &&
          next == ContentNotice.saved &&
          act?.request.payload['event_id'] == e.eventId) {
        ref.read(eventPosterUploadProvider(e.eventId).notifier).clear();
      }
    });
    final rights = e == null
        ? const <RightsRecord>[]
        : [
            for (final r
                in ref.watch(staffRightsProvider).value?.rights ??
                    <RightsRecord>[])
              if (r.inForce) r,
          ];
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            e == null ? 'New event' : 'Edit ${e.current.title}',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          e != null && e.state == ContentState.published
              ? 'Saving keeps the published version on the public calendar '
                    'until you publish the changes.'
              : 'Saved as a draft: only editors see it until you publish it.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 12),
        field('event-title', _title, 'Title', wire: 'title'),
        field(
          'event-description',
          _description,
          'Description',
          wire: 'description',
          maxLength: 2000,
          maxLines: 4,
        ),
        field(
          'event-start-date',
          _startDate,
          'Starts: date',
          hint: 'YYYY-MM-DD',
          wire: 'starts_at',
          maxLength: 10,
          suffixIcon: IconButton(
            tooltip: 'Choose start date',
            onPressed: widget.busy
                ? null
                : () => _chooseDate(_startDate, label: 'Choose start date'),
            icon: const Icon(Icons.calendar_today_outlined),
          ),
        ),
        field(
          'event-start-time',
          _startTime,
          'Starts: time',
          hint: 'HH:MM',
          maxLength: 5,
          suffixIcon: IconButton(
            tooltip: 'Choose start time',
            onPressed: widget.busy
                ? null
                : () => _chooseTime(
                    _startTime,
                    label: 'Choose start time',
                    fallback: const TimeOfDay(hour: 9, minute: 0),
                  ),
            icon: const Icon(Icons.schedule_outlined),
          ),
        ),
        field(
          'event-end-date',
          _endDate,
          'Ends: date',
          hint: 'YYYY-MM-DD',
          wire: 'ends_at',
          maxLength: 10,
          suffixIcon: IconButton(
            tooltip: 'Choose end date',
            onPressed: widget.busy
                ? null
                : () => _chooseDate(_endDate, label: 'Choose end date'),
            icon: const Icon(Icons.calendar_today_outlined),
          ),
        ),
        field(
          'event-end-time',
          _endTime,
          'Ends: time',
          hint: 'HH:MM',
          maxLength: 5,
          suffixIcon: IconButton(
            tooltip: 'Choose end time',
            onPressed: widget.busy
                ? null
                : () => _chooseTime(
                    _endTime,
                    label: 'Choose end time',
                    fallback: const TimeOfDay(hour: 12, minute: 0),
                  ),
            icon: const Icon(Icons.schedule_outlined),
          ),
        ),
        field(
          'event-location',
          _location,
          'Where',
          wire: 'location',
          maxLength: 160,
        ),
        // Story 6.11: RSVP within an optional number of places.
        SwitchListTile(
          key: Key('event-rsvp-$tag'),
          contentPadding: EdgeInsets.zero,
          value: _rsvp,
          title: const Text('Members can RSVP'),
          subtitle: Text(
            'Approved members say they are coming. The event\'s organisers '
            'and Admins see who; everyone else sees the numbers.',
            style: muted,
          ),
          onChanged: widget.busy
              ? null
              : (v) {
                  setState(() => _rsvp = v);
                  ref.read(staffEventsProvider.notifier).clearFieldErrors();
                },
        ),
        if (_rsvp)
          field(
            'event-places',
            _places,
            'Places (optional)',
            wire: 'rsvp_capacity',
            helper: 'Leave empty for no limit',
            maxLength: 5,
            formatters: [FilteringTextInputFormatter.digitsOnly],
          ),
        const SizedBox(height: 8),
        if (e == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Save the draft first; then add its poster (optional).',
              key: const Key('event-poster-after-save'),
              style: muted,
            ),
          )
        else ...[
          _PosterSection(
            event: e,
            upload: upload!,
            current: currentPoster,
            busy: widget.busy,
            onRemove: () {
              setState(() => _posterRemoved = true);
              ref.read(eventPosterUploadProvider(e.eventId).notifier).clear();
              ref.read(staffEventsProvider.notifier).clearFieldErrors();
            },
          ),
          if (_fieldError('poster_asset_id', errors['poster_asset_id'])
              case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                message,
                key: Key('event-poster-error-$tag'),
                style: TextStyle(color: c.redFg),
              ),
            ),
          if (posterAssetId != null) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: Key('event-poster-rights-$tag'),
              initialValue: _posterRightsId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Poster rights record',
                errorText: _fieldError(
                  'poster_rights_id',
                  errors['poster_rights_id'],
                ),
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
                if (_posterRightsId != null &&
                    rights.every((r) => r.rightsId != _posterRightsId))
                  DropdownMenuItem<String?>(
                    value: _posterRightsId,
                    child: Text(
                      e.currentRevision.posterRights?.label ??
                          'Chosen rights record',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: widget.busy
                  ? null
                  : (v) {
                      setState(() => _posterRightsId = v);
                      ref.read(staffEventsProvider.notifier).clearFieldErrors();
                    },
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FocusRing(
                child: TextButton(
                  key: Key('event-manage-rights-$tag'),
                  onPressed: () => context.go(BannerPaths.rights),
                  child: const Text('Add or verify rights records'),
                ),
              ),
            ),
            field(
              'event-poster-alt',
              _posterAlt,
              'Poster description',
              wire: 'poster_alt_text',
              helper: 'Describe the poster for someone who can\'t see it',
              maxLength: 250,
            ),
          ],
          const SizedBox(height: 4),
        ],
        if (errors['event_id'] != null || errors.keys.any(_unknownKey))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'The server could not read this event. Reload and try again.',
              style: TextStyle(color: c.redFg),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ListenableBuilder(
              listenable: Listenable.merge(_all),
              builder: (context, _) {
                final input = _input(posterAssetId);
                return FocusRing(
                  child: FilledButton(
                    key: Key('event-save-$tag'),
                    onPressed:
                        widget.busy || input == null || (upload?.busy ?? false)
                        ? null
                        : () {
                            final ctl = ref.read(staffEventsProvider.notifier);
                            if (e == null) {
                              ctl.create(input);
                            } else {
                              ctl.save(e, input);
                            }
                          },
                    child: const Text('Save draft'),
                  ),
                );
              },
            ),
            FocusRing(
              child: TextButton(
                key: Key('event-cancel-$tag'),
                onPressed: widget.busy ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static bool _unknownKey(String k) => !const {
    'title',
    'description',
    'starts_at',
    'ends_at',
    'location',
    'event_id',
    'rsvp_enabled',
    'rsvp_capacity',
    'poster_asset_id',
    'poster_rights_id',
    'poster_alt_text',
  }.contains(k);
}

/// Story 6.11: an upload refusal for a poster as a sentence.
String _posterUploadText(String code, String field) => switch (code) {
  'too_small' => 'This image is smaller than 540 x 540.',
  'bad_ratio' =>
    'Use a poster between tall portrait (1:2) and wide landscape (2.4:1).',
  _ => bannerReasonText(code, field: field),
};

/// Story 6.11: a saved event's poster: its preview, Choose poster (uploads at
/// once), Remove poster, and what the server said about the file.
class _PosterSection extends ConsumerWidget {
  const _PosterSection({
    required this.event,
    required this.upload,
    required this.current,
    required this.busy,
    required this.onRemove,
  });

  final StaffEvent event;
  final BannerImageUpload upload;

  /// The revision's poster the draft keeps (null: none, or removed).
  final StaffImage? current;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final id = event.eventId;
    final picker = ref.watch(contentFilePickerProvider);
    final ctl = ref.read(eventPosterUploadProvider(id).notifier);
    final shown = upload.image != null || current != null;
    final Widget preview = switch (upload) {
      BannerImageUpload(:final bytes?) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 128,
          height: 72,
          child: Image.memory(
            bytes,
            key: Key('event-poster-upload-preview-$id'),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
          ),
        ),
      ),
      _ when current != null => _PosterThumb(assetId: current!.assetId),
      _ => const SizedBox.shrink(),
    };
    final status = switch (upload.status) {
      ImageUploadStatus.idle when current != null =>
        '${current!.width} x ${current!.height}, '
            '${(current!.byteSize / 1024).ceil()} KB',
      ImageUploadStatus.idle =>
        'No poster. PNG, JPEG or WebP, at least 540 x 540, up to 5 MB. The '
            'Calendar shows it as a 16:9 thumbnail and in full on the event.',
      ImageUploadStatus.picking => 'Choosing a file…',
      ImageUploadStatus.uploading => 'Uploading; the server checks the file…',
      ImageUploadStatus.uploaded =>
        'Uploaded (${upload.image!.width} x ${upload.image!.height}). Save '
            'the draft to use this poster.',
      ImageUploadStatus.refused => switch (upload.outcome) {
        ImageUploadRefused(:final reason?, :final fieldErrors) =>
          'Not uploaded. ${_posterUploadText(reason, fieldErrors.entries.firstWhere((e) => e.value == reason).key)}',
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
        const CardLabel('Poster (optional)'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            preview,
            if (shown || upload.bytes != null) const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      status,
                      key: Key('event-poster-status-$id'),
                      style: ChurchType.secondary.copyWith(
                        color: problem ? c.redFg : c.muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FocusRing(
                        child: OutlinedButton.icon(
                          key: Key('event-choose-poster-$id'),
                          onPressed: busy || upload.busy || !picker.supported
                              ? null
                              : ctl.pickAndUpload,
                          icon: const Icon(Icons.upload_outlined, size: 18),
                          label: Text(
                            shown ? 'Choose another poster' : 'Choose poster',
                          ),
                        ),
                      ),
                      if (shown)
                        FocusRing(
                          child: TextButton(
                            key: Key('event-remove-poster-$id'),
                            onPressed: busy || upload.busy ? null : onRemove,
                            child: const Text('Remove poster'),
                          ),
                        ),
                    ],
                  ),
                  if (!picker.supported)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Posters are added on staff web in a browser.',
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

/// An uploaded (private) poster's preview through the access-checked route.
class _PosterThumb extends ConsumerWidget {
  const _PosterThumb({required this.assetId});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final bytes = ref.watch(bannerPreviewProvider(assetId)).value;
    return ClipRRect(
      key: Key('event-poster-thumb-$assetId'),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 128,
        height: 72,
        child: bytes == null
            ? ColoredBox(color: c.surface2)
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (context, _, _) => ColoredBox(color: c.surface2),
              ),
      ),
    );
  }
}
