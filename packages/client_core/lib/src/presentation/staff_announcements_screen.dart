import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/announcement_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/content_announcements.dart';
import '../domain/content_events.dart' show ContentState;
import 'announcement_screens.dart' show announcementExcerpt;
import 'calendar_screens.dart' show churchShortWhen;
import 'content_staff_widgets.dart';

// Story 6.13, staff web: the editors (Media, Pastor, Admin) draft, publish,
// withdraw and archive church announcements, and may notify members on
// publish. The screen answers "what is waiting to be published, and what do
// people see now?" first: the finding line and the Waiting to publish
// section, then what is pinned and published, then the rest. One status mark
// per row; the versions, who saved, published and notified, and every action
// are on the opened row. Every list comes from a server-checked read and
// every action is a server-checked command; an announcement shows as
// published, and members as notified, only after the server confirmed it.

/// The staff route of announcements.
abstract final class StaffAnnouncementPaths {
  /// Staff web: the Announcements editor.
  static const announcements = '/content/announcements';
}

const _needs = 'Announcements are managed by Media, Pastors and Admins.';

(StatusTone, String, String) _noticeText(
  AnnouncementNotice n,
  StaffAnnouncementsState s,
) {
  final what = s.noticeAction?.subject ?? 'the announcement';
  final count = s.notified;
  return switch (n) {
    AnnouncementNotice.created => (
      StatusTone.success,
      'Draft saved',
      '$what is saved as a draft. Only editors see it until you publish it.',
    ),
    AnnouncementNotice.saved => (
      StatusTone.success,
      'Changes saved',
      'Your changes to $what are saved as a draft. Everyone keeps seeing the '
          'published version until you publish them.',
    ),
    AnnouncementNotice.published => (
      StatusTone.success,
      'Published',
      '$what is published. Phones show it on their next refresh. No notice '
          'was sent.',
    ),
    AnnouncementNotice.publishedAndNotified => (
      StatusTone.success,
      'Published with a notice',
      count == null
          ? '$what is published, and a notice is queued for members.'
          : '$what is published, and a notice is queued for '
                '${_members(count)}. It reaches their Inbox over the next '
                'minutes, and phones that allow announcement notices show '
                'it.',
    ),
    AnnouncementNotice.withdrawn => (
      StatusTone.success,
      'Withdrawn',
      '$what is no longer published. Phones drop it on their next refresh, '
          'and notices not yet delivered are cancelled. You can publish it '
          'again.',
    ),
    AnnouncementNotice.archived => (
      StatusTone.success,
      'Archived',
      '$what is archived. It is not public and can no longer change.',
    ),
    AnnouncementNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      '$what was changed in another tab or by another editor. The list now '
          'shows the current version; check it and try again.',
    ),
    AnnouncementNotice.nothingToPublish => (
      StatusTone.warning,
      'Nothing to publish',
      '$what has no saved changes to publish.',
    ),
    AnnouncementNotice.notPublished => (
      StatusTone.warning,
      'Not published',
      '$what is not published, so there is nothing to withdraw.',
    ),
    AnnouncementNotice.alreadyArchived => (
      StatusTone.warning,
      'Archived',
      '$what is archived and can no longer change.',
    ),
    AnnouncementNotice.alreadyNotified => (
      StatusTone.warning,
      'Members were already notified',
      'Members already had a notice about this version of $what. Nothing was '
          'published; publish it without a notice.',
    ),
    AnnouncementNotice.tooManyRecipients => (
      StatusTone.warning,
      'Too many members for one notice',
      'More members can be reached than one notice may go to. Nothing was '
          'published; publish $what without a notice.',
    ),
    AnnouncementNotice.notifyUnavailable => (
      StatusTone.warning,
      'Notices are not available yet',
      'This server cannot send notices yet. Nothing was published; you can '
          'publish $what without a notice.',
    ),
    AnnouncementNotice.invalid => (
      StatusTone.warning,
      'Check the announcement',
      'Some details need changing; see the marked fields. Nothing was saved.',
    ),
    AnnouncementNotice.notAllowed => (
      StatusTone.danger,
      'Not allowed',
      '$_needs Nothing was changed.',
    ),
    AnnouncementNotice.signInAgain => (
      StatusTone.danger,
      'Please sign in again',
      'Your session is no longer trusted. Nothing was changed.',
    ),
    AnnouncementNotice.notFound => (
      StatusTone.warning,
      'Not found',
      'That announcement no longer exists. The list now shows the current '
          'announcements.',
    ),
    AnnouncementNotice.notAvailable => (
      StatusTone.warning,
      'Not available right now',
      'The church server could not do this now. Nothing was changed.',
    ),
    AnnouncementNotice.refused => (
      StatusTone.danger,
      'Not done',
      'The church server refused this. Nothing was changed.',
    ),
    AnnouncementNotice.unconfirmed => (
      StatusTone.warning,
      'Not confirmed',
      'We could not tell whether $what was changed. Check again sends the '
          'same request, so it cannot apply twice.',
    ),
    AnnouncementNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
  };
}

/// A field error code as a sentence (null when there is none).
String? _fieldError(String? code) => switch (code) {
  null => null,
  'required' => 'Required',
  'too_long' => 'Too long',
  _ => 'Check this',
};

/// The one mark an announcement's row carries.
(String, StatusTone) _mark(StaffAnnouncement a) => switch (a.state) {
  ContentState.draft => ('Draft', StatusTone.neutral),
  ContentState.published when a.hasChanges => (
    'Changes not published',
    StatusTone.warning,
  ),
  ContentState.published when a.pinnedLive => ('Pinned', StatusTone.success),
  ContentState.published => ('Published', StatusTone.success),
  ContentState.withdrawn => ('Withdrawn', StatusTone.neutral),
  ContentState.archived => ('Archived', StatusTone.neutral),
};

/// "12 members" / "1 member".
String _members(int n) => '$n ${n == 1 ? 'member' : 'members'}';

/// `/content/announcements` (staff web; Media, Pastor and Admin).
class StaffAnnouncementsScreen extends ConsumerStatefulWidget {
  const StaffAnnouncementsScreen({super.key});

  @override
  ConsumerState<StaffAnnouncementsScreen> createState() =>
      _StaffAnnouncementsScreenState();
}

class _StaffAnnouncementsScreenState
    extends ConsumerState<StaffAnnouncementsScreen> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'announcements notice');

  /// The new-announcement form is open (the header's main action toggles it).
  var _creating = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    if (ref.read(staffAnnouncementsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    final s = ref.read(staffAnnouncementsProvider);
    if (mounted && !s.busy && !s.loading) {
      ref.read(staffAnnouncementsProvider.notifier).reload();
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
    final s = ref.watch(staffAnnouncementsProvider);
    final ctl = ref.read(staffAnnouncementsProvider.notifier);
    ref.listen(staffAnnouncementsProvider.select((x) => x.notice), (
      prev,
      next,
    ) {
      if (next == null || next == prev) return;
      final (_, title, message) = _noticeText(
        next,
        ref.read(staffAnnouncementsProvider),
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
          key: const Key('announcements-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the church server about ${p.subject}. Nothing is '
              'shown as done until it answers.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(n, s);
      children.add(
        RequestStateBanner(
          key: Key('announcements-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == AnnouncementNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('announcements-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('announcements-dismiss'),
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
            key: Key('announcements-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading announcements…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        children.add(
          _AnnouncementsBody(
            value: value,
            state: s,
            creating: _creating,
            onCreatingChanged: (v) => setState(() => _creating = v),
          ),
        );
      case AccessReadDenied(:final denial):
        children.add(
          RequestStateBanner(
            key: Key('announcements-denied-${denial.name}'),
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
            key: const Key('announcements-failed'),
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
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final value = s.value;
    final create = value == null
        ? null
        : FocusRing(
            child: FilledButton.icon(
              key: const Key('announcements-new'),
              onPressed: s.busy
                  ? null
                  : () => setState(() => _creating = !_creating),
              icon: Icon(_creating ? Icons.close : Icons.add),
              label: Text(_creating ? 'Close the form' : 'New announcement'),
            ),
          );
    return ChurchPageScaffold(
      title: 'Announcements',
      subtitle: value == null ? null : _finding(value),
      actions: phone
          ? [
              ?create,
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('announcements-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [
              ?create,
              staffReloadButton(const Key('announcements-reload'), reload),
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
/// published and what people see now.
String _finding(StaffAnnouncements value) {
  final list = value.announcements;
  if (list.isEmpty) {
    return 'No announcements yet. A new announcement stays a private draft '
        'until you publish it.';
  }
  final waiting = list
      .where((a) => a.state == ContentState.draft || a.hasChanges)
      .length;
  // Every published announcement is public, unpublished changes or not (the
  // published version is what people see).
  final published = list.where((a) => a.state == ContentState.published);
  final pinned = published.where((a) => a.live!.pinned).length;
  return [
    waiting == 0 ? 'Nothing waiting to publish' : '$waiting waiting to publish',
    '${published.length} published ($pinned pinned)',
  ].join(' · ');
}

class _AnnouncementsBody extends ConsumerStatefulWidget {
  const _AnnouncementsBody({
    required this.value,
    required this.state,
    required this.creating,
    required this.onCreatingChanged,
  });
  final StaffAnnouncements value;
  final StaffAnnouncementsState state;
  final bool creating;
  final ValueChanged<bool> onCreatingChanged;

  @override
  ConsumerState<_AnnouncementsBody> createState() => _AnnouncementsBodyState();
}

class _AnnouncementsBodyState extends ConsumerState<_AnnouncementsBody> {
  String? _open;
  var _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final busy = widget.state.busy;
    // A confirmed create closes the new-announcement form.
    ref.listen(staffAnnouncementsProvider.select((x) => x.notice), (
      prev,
      next,
    ) {
      if (next == AnnouncementNotice.created && mounted) {
        widget.onCreatingChanged(false);
      }
    });
    final list = widget.value.announcements;
    bool settled(StaffAnnouncement a) =>
        a.state == ContentState.published && !a.hasChanges;
    final waiting = [
      for (final a in list)
        if (a.state == ContentState.draft || a.hasChanges) a,
    ];
    final pinned = [
      for (final a in list)
        if (settled(a) && a.live!.pinned) a,
    ];
    final published = [
      for (final a in list)
        if (settled(a) && !a.live!.pinned) a,
    ];
    final withdrawn = [
      for (final a in list)
        if (a.state == ContentState.withdrawn) a,
    ];
    final archived = [
      for (final a in list)
        if (a.state == ContentState.archived) a,
    ];
    Widget section(String title, List<StaffAnnouncement> rows, String key) =>
        Column(
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
                  for (final (i, a) in rows.indexed) ...[
                    if (i > 0) Divider(height: 1, color: c.line),
                    _AnnouncementRow(
                      key: Key('announcement-${a.announcementId}'),
                      announcement: a,
                      audience: widget.value,
                      open: _open == a.announcementId,
                      busy: busy,
                      state: widget.state,
                      onToggle: () => setState(
                        () => _open = _open == a.announcementId
                            ? null
                            : a.announcementId,
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
        if (widget.creating)
          ChurchCard(
            radius: 12,
            child: _AnnouncementForm(
              key: const Key('announcement-form-new'),
              announcement: null,
              busy: busy,
              state: widget.state,
              onCancel: () => widget.onCreatingChanged(false),
            ),
          ),
        if (widget.value.truncated) ...[
          const SizedBox(height: 12),
          const RequestStateBanner(
            key: Key('announcements-truncated'),
            tone: StatusTone.warning,
            title: 'Not every announcement is listed',
            message:
                'There are more announcements than this list shows; the most '
                'recently changed are listed first.',
          ),
        ],
        if (waiting.isNotEmpty)
          section('Waiting to publish', waiting, 'announcements-waiting'),
        if (pinned.isNotEmpty)
          section('Pinned', pinned, 'announcements-pinned'),
        if (published.isNotEmpty)
          section('Published', published, 'announcements-published'),
        if (withdrawn.isNotEmpty)
          section('Withdrawn', withdrawn, 'announcements-withdrawn'),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: ChurchGeometry.sectionGap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('announcements-show-archived'),
                onPressed: () => setState(() => _showArchived = !_showArchived),
                child: Text(
                  _showArchived
                      ? 'Hide archived announcements'
                      : 'Show archived announcements (${archived.length})',
                ),
              ),
            ),
          ),
          if (_showArchived)
            section('Archived', archived, 'announcements-archived'),
        ],
        const SizedBox(height: 16),
        Text(
          'Times are church time (Kafue). A draft and unpublished changes are '
          'seen by editors only; everyone else sees the published version, '
          'pinned ones first. A notice to members\' phones is optional when '
          'you publish and never shows the announcement\'s text.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ],
    );
  }
}

/// One announcement: the row (title, when · the start of the text, one
/// mark), and when opened its published and draft versions with who saved,
/// published and notified, and its actions.
class _AnnouncementRow extends ConsumerStatefulWidget {
  const _AnnouncementRow({
    super.key,
    required this.announcement,
    required this.audience,
    required this.open,
    required this.busy,
    required this.state,
    required this.onToggle,
  });

  final StaffAnnouncement announcement;
  final StaffAnnouncements audience;
  final bool open;
  final bool busy;
  final StaffAnnouncementsState state;
  final VoidCallback onToggle;

  @override
  ConsumerState<_AnnouncementRow> createState() => _AnnouncementRowState();
}

class _AnnouncementRowState extends ConsumerState<_AnnouncementRow> {
  var _editing = false;

  Future<bool> _confirm(String title, String body, String yes) =>
      confirmContentChange(
        context,
        keyPrefix: 'announcement',
        title: title,
        body: body,
        yes: yes,
      );

  /// The publish dialog: whether to also notify members. Null: cancelled.
  Future<bool?> _askPublish(StaffAnnouncement a) async {
    final target = a.publishTarget ?? a.current;
    final audience = widget.audience;
    // Publishing a change stops the earlier version's notices that have not
    // reached members yet (the server cancels them).
    final earlierNoticeStops =
        a.draft != null &&
        (a.live?.notified ?? false) &&
        a.state != ContentState.archived;
    final minutes = (audience.audienceMembers / audience.audiencePerMinute)
        .ceil();
    final String? notifyBlocked = a.notifyDone
        ? 'Members already had a notice about this version.'
        : audience.audienceTooLarge
        ? 'More than ${audience.audienceLimit} members can be reached; one '
              'notice may go to at most ${audience.audienceLimit}.'
        : null;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) {
        var notify = false;
        return StatefulBuilder(
          builder: (context, setDialog) {
            final c = ChurchColors.of(context);
            final muted = ChurchType.secondary.copyWith(color: c.muted);
            return ChurchDialog(
              title: 'Publish ${target.title}?',
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    target.pinned
                        ? 'Everyone sees it in the app, signed in or not. It '
                              'is pinned, so Home shows it first.'
                        : 'Everyone sees it in the app, signed in or not.',
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    key: const Key('announcement-notify'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: notify,
                    onChanged: notifyBlocked != null
                        ? null
                        : (v) => setDialog(() => notify = v ?? false),
                    title: const Text('Also send a notice to members\' phones'),
                    subtitle: Text(
                      notifyBlocked ??
                          'About ${_members(audience.audienceMembers)} can '
                              'get it now'
                              '${minutes > 1 ? ', within about $minutes minutes' : ''}.',
                      key: const Key('announcement-notify-reason'),
                      style: muted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const CardLabel('What phones show'),
                  const SizedBox(height: 6),
                  Container(
                    key: const Key('announcement-notice-preview'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.line),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          audience.noticeTitle,
                          key: const Key('announcement-notice-title'),
                          style: ChurchType.itemTitle.copyWith(color: c.ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          audience.noticeBody,
                          key: const Key('announcement-notice-body'),
                          style: ChurchType.secondary.copyWith(color: c.ink),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The notice never shows the announcement\'s text; it '
                    'opens the announcement in the app. Members who turned '
                    'announcement notices off still find it in their Inbox.',
                    style: muted,
                  ),
                  if (earlierNoticeStops) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Publishing this change stops the notices about the '
                      'earlier version that have not reached members yet.',
                      key: const Key('announcement-earlier-notice-stops'),
                      style: muted,
                    ),
                  ],
                ],
              ),
              actions: [
                FocusRing(
                  child: TextButton(
                    key: const Key('announcement-publish-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                FocusRing(
                  child: FilledButton(
                    key: const Key('announcement-publish-confirm'),
                    onPressed: () => Navigator.of(context).pop(notify),
                    child: Text(notify ? 'Publish and notify' : 'Publish'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    return mounted ? answer : null;
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final a = widget.announcement;
    final id = a.announcementId;
    final busy = widget.busy;
    final cur = a.current;
    final (mark, tone) = _mark(a);
    final ctl = ref.read(staffAnnouncementsProvider.notifier);
    // A confirmed save closes this announcement's form.
    ref.listen(staffAnnouncementsProvider.select((x) => x.notice), (
      prev,
      next,
    ) {
      final act = ref.read(staffAnnouncementsProvider).noticeAction;
      if (next == AnnouncementNotice.saved &&
          act?.request.payload['announcement_id'] == id &&
          mounted) {
        setState(() => _editing = false);
      }
    });
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final when = switch (a.publishedAt) {
      final at? when a.state != ContentState.draft =>
        'Published ${churchShortWhen(at)}',
      _ => 'Saved ${churchShortWhen(cur.savedAt)}',
    };
    final summary = InkWell(
      key: Key('announcement-open-$id'),
      onTap: widget.onToggle,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cur.title,
                    style: ChurchType.itemTitle.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$when · ${announcementExcerpt(cur.body)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            StatusLabel(
              key: Key('announcement-mark-$id'),
              label: mark,
              tone: tone,
            ),
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

    Widget version(
      String label,
      StaffAnnouncementRevision r,
      List<String> lines,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CardLabel(label),
        const SizedBox(height: 6),
        DetailTable(
          rows: [
            (label: 'Title', value: r.title),
            (label: 'Pinned', value: r.pinned ? 'Yes, shown first' : 'No'),
            (label: 'Text', value: r.body),
          ],
        ),
        for (final l in lines) ...[
          const SizedBox(height: 6),
          Text(l, style: muted),
        ],
      ],
    );

    String? noticeLine(StaffAnnouncementRevision r) => switch (r) {
      StaffAnnouncementRevision(
        :final notifiedAt?,
        :final notifiedCount?,
        :final notifiedBy,
      ) =>
        'Notice queued ${churchShortWhen(notifiedAt)} for '
            '${_members(notifiedCount)}'
            '${notifiedBy == null ? '' : ' · by $notifiedBy'}',
      _ => null,
    };

    final live = a.live;
    final draft = a.draft;
    final publishLabel = switch (a) {
      _ when a.hasChanges => 'Publish changes',
      _ when a.state == ContentState.withdrawn && draft == null =>
        'Publish again',
      _ => 'Publish',
    };
    final actions = <Widget>[
      if (a.canEdit)
        FocusRing(
          child: OutlinedButton(
            key: Key('announcement-edit-$id'),
            onPressed: busy ? null : () => setState(() => _editing = !_editing),
            child: Text(_editing ? 'Close the form' : 'Edit'),
          ),
        ),
      if (a.canPublish)
        FocusRing(
          child: FilledButton(
            key: Key('announcement-publish-$id'),
            onPressed: busy
                ? null
                : () async {
                    final notify = await _askPublish(a);
                    if (notify != null) await ctl.publish(a, notify: notify);
                  },
            child: Text(publishLabel),
          ),
        ),
      if (a.canWithdraw)
        FocusRing(
          child: OutlinedButton(
            key: Key('announcement-withdraw-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      'Withdraw ${cur.title}?',
                      'It disappears from the app the next time a phone '
                          'refreshes, and notices not yet delivered are '
                          'cancelled. You can publish it again later.',
                      'Withdraw',
                    )) {
                      await ctl.withdraw(a);
                    }
                  },
            child: const Text('Withdraw'),
          ),
        ),
      if (a.canArchive)
        FocusRing(
          child: TextButton(
            key: Key('announcement-archive-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      'Archive ${cur.title}?',
                      'It leaves the app (if it is published) and can no '
                          'longer be changed or published.',
                      'Archive',
                    )) {
                      await ctl.archive(a);
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
          key: Key('announcement-details-$id'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (live != null) ...[
                version(
                  switch (a.state) {
                    ContentState.published => 'What everyone sees',
                    _ => 'Last published version (not public)',
                  },
                  live,
                  [
                    [
                      if (a.publishedBy case final by?) 'Published by $by',
                      if (a.publishedAt case final at?) churchShortWhen(at),
                    ].join(' · '),
                    ?noticeLine(live),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (draft != null) ...[
                version(
                  live == null
                      ? 'Draft (editors only)'
                      : 'Changes not published yet (editors only)',
                  draft,
                  [
                    'Saved by ${draft.savedBy} · '
                        '${churchShortWhen(draft.savedAt)}',
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (a.withdrawnAt case final at?
                  when a.state == ContentState.withdrawn)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Withdrawn ${churchShortWhen(at)}', style: muted),
                ),
              if (a.archivedAt case final at?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Archived ${churchShortWhen(at)}', style: muted),
                ),
              Text(
                'Created by ${a.createdBy} · ${churchShortWhen(a.createdAt)}',
                style: muted,
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
              if (_editing) ...[
                const SizedBox(height: 14),
                _AnnouncementForm(
                  key: Key('announcement-form-$id'),
                  announcement: a,
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

/// A new announcement ([announcement] null) or an edit of one: every field,
/// saved as a draft.
class _AnnouncementForm extends ConsumerStatefulWidget {
  const _AnnouncementForm({
    super.key,
    required this.announcement,
    required this.busy,
    required this.state,
    required this.onCancel,
  });

  final StaffAnnouncement? announcement;
  final bool busy;
  final StaffAnnouncementsState state;
  final VoidCallback onCancel;

  @override
  ConsumerState<_AnnouncementForm> createState() => _AnnouncementFormState();
}

class _AnnouncementFormState extends ConsumerState<_AnnouncementForm> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  var _pinned = false;

  @override
  void initState() {
    super.initState();
    // An edit starts from the draft, otherwise from the published version.
    if (widget.announcement?.current case final r?) {
      _title.text = r.title;
      _body.text = r.body;
      _pinned = r.pinned;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  /// What is typed, or null while something required is missing.
  AnnouncementInput? _input() {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) return null;
    return AnnouncementInput(
      title: _title.text,
      body: _body.text,
      pinned: _pinned,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final a = widget.announcement;
    final tag = a?.announcementId ?? 'new';
    final st = widget.state;
    // Only a refusal of this form's own command names its fields.
    final act = st.noticeAction;
    final mine = a == null
        ? act?.command == AnnouncementCommands.create
        : act?.command == AnnouncementCommands.save &&
              act?.request.payload['announcement_id'] == a.announcementId;
    final errors = mine ? st.fieldErrors : const <String, String>{};
    void edited() =>
        ref.read(staffAnnouncementsProvider.notifier).clearFieldErrors();
    Widget field(
      String key,
      TextEditingController ctl,
      String label,
      String wire, {
      required int maxLength,
      int maxLines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$tag'),
        controller: ctl,
        enabled: !widget.busy,
        maxLength: maxLength,
        maxLines: maxLines,
        onChanged: (_) => edited(),
        decoration: InputDecoration(
          labelText: label,
          errorText: _fieldError(errors[wire]),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            a == null ? 'New announcement' : 'Edit ${a.current.title}',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          a != null && a.state == ContentState.published
              ? 'Saving keeps the published version in the app until you '
                    'publish the changes.'
              : 'Saved as a draft: only editors see it until you publish it.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 12),
        field('announcement-title', _title, 'Title', 'title', maxLength: 100),
        field(
          'announcement-body',
          _body,
          'Text',
          'body',
          maxLength: 1500,
          maxLines: 6,
        ),
        CheckboxListTile(
          key: Key('announcement-pinned-$tag'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _pinned,
          onChanged: widget.busy
              ? null
              : (v) {
                  setState(() => _pinned = v ?? false);
                  edited();
                },
          title: const Text('Pin it'),
          subtitle: Text(
            errors['pinned'] != null
                ? 'Check this'
                : 'Pinned announcements are shown first, and on Home.',
            style: ChurchType.secondary.copyWith(
              color: errors['pinned'] != null ? c.redFg : c.muted,
            ),
          ),
        ),
        if (errors['announcement_id'] != null || errors.keys.any(_unknownKey))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'The server could not read this announcement. Reload and try '
              'again.',
              style: TextStyle(color: c.redFg),
            ),
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ListenableBuilder(
              listenable: Listenable.merge([_title, _body]),
              builder: (context, _) {
                final input = _input();
                return FocusRing(
                  child: FilledButton(
                    key: Key('announcement-save-$tag'),
                    onPressed: widget.busy || input == null
                        ? null
                        : () {
                            final ctl = ref.read(
                              staffAnnouncementsProvider.notifier,
                            );
                            if (a == null) {
                              ctl.create(input);
                            } else {
                              ctl.save(a, input);
                            }
                          },
                    child: const Text('Save draft'),
                  ),
                );
              },
            ),
            FocusRing(
              child: TextButton(
                key: Key('announcement-cancel-$tag'),
                onPressed: widget.busy ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static bool _unknownKey(String k) =>
      !const {'title', 'body', 'pinned', 'announcement_id'}.contains(k);
}
