import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/content_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/content_events.dart';
import 'calendar_screens.dart'
    show churchLongWhen, churchShortWhen, eventSpanText;
import 'church_widgets.dart';

// Story 6.1, staff web: the editors (Media, Pastor, Admin) draft, publish,
// withdraw and archive church events. The screen answers "what is waiting to
// be published, and what is on the public calendar?" first: the finding line
// and the Not published yet section, then what is on the calendar, then the
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
  };
}

/// A field error code as a sentence (null when there is none).
String? _fieldError(String wire, String? code) => switch (code) {
  null => null,
  'required' => 'Required',
  'too_long' when wire == 'ends_at' => 'An event can last at most 31 days',
  'too_long' => 'Too long',
  'before_start' => 'Must be after the start',
  'out_of_range' => 'Too far in the past or the future',
  'invalid' when wire == 'starts_at' || wire == 'ends_at' =>
    'Use a real date (YYYY-MM-DD) and time (HH:MM)',
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
  final onCalendar = events
      .where(
        (e) =>
            e.state == ContentState.published &&
            !e.hasChanges &&
            !e.endedAt(now),
      )
      .length;
  return [
    waiting == 0 ? 'Nothing waiting to publish' : '$waiting not published yet',
    '$onCalendar on the calendar',
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
          section('Not published yet', waiting, 'events-waiting'),
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
  }

  List<TextEditingController> get _all => [
    _title,
    _description,
    _startDate,
    _startTime,
    _endDate,
    _endTime,
    _location,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  /// What is typed, or null while something required is missing or unread.
  EventInput? _input() {
    final starts = ChurchTime.parse(_startDate.text, _startTime.text);
    final ends = ChurchTime.parse(_endDate.text, _endTime.text);
    if (_title.text.trim().isEmpty ||
        _description.text.trim().isEmpty ||
        _location.text.trim().isEmpty ||
        starts == null ||
        ends == null) {
      return null;
    }
    return EventInput(
      title: _title.text,
      description: _description.text,
      startsAt: starts,
      endsAt: ends,
      location: _location.text,
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
      int maxLength = 120,
      int maxLines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$tag'),
        controller: ctl,
        enabled: !widget.busy,
        maxLength: maxLength,
        maxLines: maxLines,
        onChanged: (_) =>
            ref.read(staffEventsProvider.notifier).clearFieldErrors(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: wire == null ? null : _fieldError(wire, errors[wire]),
        ),
      ),
    );
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
        ),
        field(
          'event-start-time',
          _startTime,
          'Starts: time',
          hint: 'HH:MM',
          maxLength: 5,
        ),
        field(
          'event-end-date',
          _endDate,
          'Ends: date',
          hint: 'YYYY-MM-DD',
          wire: 'ends_at',
          maxLength: 10,
        ),
        field(
          'event-end-time',
          _endTime,
          'Ends: time',
          hint: 'HH:MM',
          maxLength: 5,
        ),
        field(
          'event-location',
          _location,
          'Where',
          wire: 'location',
          maxLength: 160,
        ),
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
                final input = _input();
                return FocusRing(
                  child: FilledButton(
                    key: Key('event-save-$tag'),
                    onPressed: widget.busy || input == null
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
  }.contains(k);
}
