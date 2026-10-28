import 'dart:async';

import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart' show myAccessProvider;
import '../application/content_controllers.dart'
    show linkableEventsProvider, linkedEventProvider;
import '../application/duties_controllers.dart';
import '../application/providers.dart' show contactLauncherProvider;
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/content_events.dart' show PublicEvent, PublicEventRead;
import '../domain/duties.dart';
import '../domain/duty_calendar.dart';
import 'calendar_screens.dart' show CalendarPaths, churchShortWhen;
import 'church_widgets.dart';
import 'followups_screens.dart' show FollowUpPaths;

part 'duties_coverage_screens.dart';
part 'duties_outcome_screens.dart';
part 'duties_reminder_widgets.dart';
part 'duties_rota_screens.dart';
part 'duties_special_screens.dart';

/// Story 6.12: the published event a duty is linked to, as the public
/// calendar shows it; it opens the event. Once the event is no longer public
/// the duty says so, and a failed read never looks like no event.
class _DutyLinkedEvent extends ConsumerWidget {
  const _DutyLinkedEvent({required this.assignmentId, required this.eventId});

  final String assignmentId;
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final read = ref.watch(linkedEventProvider(eventId));
    Widget note(String text, String key) => Text(
      text,
      key: Key('$key-$assignmentId'),
      style: ChurchType.secondary.copyWith(color: c.muted),
    );
    final body = switch (read) {
      AsyncData(value: AccessReadOk(value: PublicEventRead(:final event?))) =>
        FocusRing(
          radius: 4,
          child: InkWell(
            key: Key('duty-event-$assignmentId'),
            onTap: () => context.push(CalendarPaths.event(event.eventId)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.title,
                          style: ChurchType.body.copyWith(
                            fontWeight: FontWeight.w500,
                            color: c.ink,
                          ),
                        ),
                        Text(
                          '${churchShortWhen(event.startsAt)} · '
                          '${event.location}',
                          style: ChurchType.secondary.copyWith(color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  ExcludeSemantics(
                    child: Icon(Icons.chevron_right, size: 20, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      AsyncData(value: AccessReadOk()) => note(
        'This event is no longer on the church calendar.',
        'duty-event-gone',
      ),
      AsyncData(value: AccessReadDenied()) || AsyncError() => note(
        'The event could not be loaded. Check your connection and try again.',
        'duty-event-failed',
      ),
      _ => const SizedBox.shrink(),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const CardLabel('Event'),
        const SizedBox(height: 6),
        body,
      ],
    );
  }
}

// Story 4.1: departments (Admin) and publishing with responses (leaders) on
// staff web, and the member's duties with Accept / Can't make it on mobile.
// Story 4.2: leaders change a published duty (a material change asks the
// member again and keeps the earlier answer in history; an instructions-only
// change keeps the answer), and an answer to an old version is refused with
// what changed.
// Story 4.3: the rota grid (duties_rota_screens.dart): repeating multi-position
// rotas as drafts, Publish N draft slots, this-date and this-and-later edits
// and cancellation.
// Every list comes from a server-checked read and every action is a
// server-checked command; hiding a button is never the control. An answer
// shows as Accepted only after the server confirmed it.

/// The member-facing duty routes (shared by both shells' router).
abstract final class DutyPaths {
  /// Mobile: the member's own duties.
  static const mine = '/duties';

  /// One assignment (the reminder contract's link `/duties/assignments/{id}`).
  static String assignment(String assignmentId) =>
      '/duties/assignments/$assignmentId';

  /// Staff web: leaders, deputies, Admin (and Pastor, read only).
  static const leader = '/duties/leader';

  /// Story 4.16 (both apps): the leader board showing only the duties with
  /// an open review (the `duty_review_flagged` notice's link).
  static const leaderReviews = '/duties/leader/reviews';

  /// Story 4.3, staff web: the rota grid (leaders, deputies, Admin; Pastor
  /// read only).
  static const rota = '/duties/rota';

  /// Staff web, Admin only: departments, leaders, deputies and members.
  static const adminDepartments = '/admin/departments';

  /// Story 4.5 (mobile): the member Home with the My duties card.
  static const home = '/home';

  /// Story 4.9 (staff web and mobile): the coverage queue (leaders and
  /// deputies; Admin and Pastor oversight). The leaders' decline alert
  /// opens it.
  static const coverage = '/duties/coverage';

  /// Story 4.10 (staff web and mobile): record and correct the outcomes of
  /// started duties (the department's leaders and deputies).
  static const outcomes = '/duties/outcomes';

  /// Story 4.10: the reader's own assignment history.
  static const history = '/duties/history';

  /// Story 4.10: a member's history, for their department's leaders.
  static String memberHistory(String memberId) =>
      Uri(path: history, queryParameters: {'member': memberId}).toString();

  /// Special assignments (staff web): the Pastors give, change and cancel
  /// them and record their outcomes.
  static const special = '/duties/special';
}

(StatusTone, String, String) _noticeText(
  DutyNotice n,
  DutyAction? a, [
  Map<String, String> fieldErrors = const {},
]) {
  final what = a?.subject ?? 'this';
  final changed = DutyFields.changedIn(fieldErrors);
  // Story 4.11 (review S3): a cell programme part's answer is seen by the
  // cell's leaders in the programme; no department leader is told.
  final whoSees = switch (a?.ownerKind) {
    DutyOwnerKind.cell =>
      'Your answer is saved. Your cell leader sees it in '
          'the programme',
    DutyOwnerKind.department => 'Your leader now sees it',
    // Special assignments: the Pastors see the answer.
    DutyOwnerKind.special => 'The Pastor now sees it',
    _ => 'Your answer is saved. Whoever manages it sees it',
  };
  final special = a?.ownerKind == DutyOwnerKind.special;
  return switch (n) {
    DutyNotice.departmentCreated => (
      StatusTone.success,
      'Department added',
      '$what is set up. Give it a leader and add its members next.',
    ),
    DutyNotice.memberAdded => (
      StatusTone.success,
      'Member added',
      '$what now serves in this department.',
    ),
    DutyNotice.staffAssigned => (
      StatusTone.success,
      'Role given',
      '$what can now act for this department. The change applies on their '
          'next step.',
    ),
    DutyNotice.staffRemoved => (
      StatusTone.success,
      'Role removed',
      '$what no longer manages this department.',
    ),
    DutyNotice.published => (
      StatusTone.success,
      'Duty published',
      '$what was sent. The member is asked to accept or say they can\'t make '
          'it.',
    ),
    DutyNotice.accepted => (
      StatusTone.success,
      'Accepted',
      a?.ownerKind == DutyOwnerKind.cell || special
          ? 'You accepted $what. $whoSees.'
          : 'Your leader now sees that you accepted $what.',
    ),
    DutyNotice.declined => (
      StatusTone.success,
      'Answer sent',
      a?.ownerKind == DutyOwnerKind.cell || special
          ? 'You can\'t make $what. $whoSees.'
          : 'Your leader now sees that you can\'t make $what.',
    ),
    DutyNotice.specialGiven => (
      StatusTone.success,
      'Special assignment given',
      '$what was sent. They are asked to accept or say they can\'t make it; '
          'their answer shows here.',
    ),
    DutyNotice.specialCancelled => (
      StatusTone.success,
      'Cancelled',
      '$what is cancelled. If they had not declined, they get a notice.',
    ),
    DutyNotice.specialOwn => (
      StatusTone.neutral,
      'Not to yourself',
      'A special assignment goes to someone else: another Pastor would have '
          'to record its outcome. Nothing was sent.',
    ),
    DutyNotice.revised => (
      StatusTone.success,
      'Duty changed',
      '$what was changed. The member is asked to answer again by the new '
          'deadline; their earlier answer is kept in the history.',
    ),
    DutyNotice.notesUpdated => (
      StatusTone.success,
      'Details updated',
      'The instructions for $what were updated. The member\'s answer stands; '
          'they get a notice to read the new details.',
    ),
    DutyNotice.superseded when changed.contains(DutyFields.memberId) => (
      StatusTone.warning,
      'This duty changed',
      'Your answer was not recorded: this duty is no longer assigned to you. '
          'Your current duties are listed here.',
    ),
    DutyNotice.superseded when changed.isEmpty => (
      StatusTone.warning,
      'This duty changed',
      'Your answer was not recorded: this duty changed since you opened it. '
          'The current version is shown; please answer it again.',
    ),
    DutyNotice.superseded => (
      StatusTone.warning,
      'This duty changed',
      'Your answer was not recorded: the ${DutyFields.describe(changed)} '
          'changed since you opened it. The current version is shown; please '
          'answer it again.',
    ),
    DutyNotice.dutyStarted => (
      StatusTone.neutral,
      'Already started',
      'This duty has started, so it can no longer be changed. Nothing was '
          'changed.',
    ),
    DutyNotice.dutyCancelled => (
      StatusTone.neutral,
      'Cancelled',
      'This duty was cancelled, so it can no longer be answered.',
    ),
    DutyNotice.unchanged => (
      StatusTone.neutral,
      'Nothing changed',
      'The duty already has these details.',
    ),
    DutyNotice.seriesCreated => (
      StatusTone.success,
      'Rota created',
      '$what was made as draft dates. Members see nothing until you '
          'publish.',
    ),
    DutyNotice.draftAssigned => (
      StatusTone.success,
      'Plan saved',
      'The plan for $what was saved. Nobody is told until you publish.',
    ),
    DutyNotice.draftUpdated => (
      StatusTone.success,
      'Draft updated',
      'The draft $what was changed. Nobody is told until you publish.',
    ),
    DutyNotice.referenceUpdated => (
      StatusTone.success,
      'Link updated',
      'The linked event of $what was updated. Answers stand and nobody is '
          'sent a notice.',
    ),
    DutyNotice.positionGiven => (
      StatusTone.success,
      'Position given',
      '$what was sent. The member is asked to accept or say they can\'t '
          'make it.',
    ),
    DutyNotice.draftsPublished => (
      StatusTone.success,
      'Drafts published',
      '$what was published. Each planned person is asked to answer; '
          'positions without anyone show as unfilled.',
    ),
    DutyNotice.seriesRevised => (
      StatusTone.success,
      'Rota changed',
      'This and the later dates of $what were changed; earlier and started '
          'dates were not. Anyone asked again keeps their earlier answer in '
          'the history.',
    ),
    DutyNotice.occurrenceCancelled => (
      StatusTone.success,
      'Cancelled',
      '$what was cancelled for the chosen dates. People who were waiting to '
          'answer or had accepted get a notice (not those who declined, and '
          'not for drafts); '
          'their earlier answers are kept.',
    ),
    DutyNotice.overlapNeedsReason => (
      StatusTone.warning,
      'Overlaps another duty',
      'This person has another duty at that time. Say why they are assigned '
          'anyway, or choose someone else. They still choose whether to '
          'accept.',
    ),
    DutyNotice.draftCountChanged => (
      StatusTone.warning,
      'Drafts changed',
      'The number of draft slots changed since you looked. The rota was '
          'reloaded; check it and publish again.',
    ),
    DutyNotice.leadPassed => (
      StatusTone.warning,
      'Answer-by already passed',
      'For at least one date that answer-by time has already passed. Choose '
          'a shorter time before the duty.',
    ),
    DutyNotice.plannedUnavailable => (
      StatusTone.warning,
      'Someone can\'t serve',
      'A planned person can no longer serve in this department (marked '
          '"can\'t serve now"). Plan someone else first.',
    ),
    DutyNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      'This was changed in another tab or by someone else. The list was '
          'reloaded; check it and try again.',
    ),
    DutyNotice.alreadyAnswered => (
      StatusTone.neutral,
      'Already answered',
      'This duty already has an answer. The list was reloaded.',
    ),
    DutyNotice.reviewCleared => (
      StatusTone.success,
      'Marked reviewed',
      'The change to what $what is linked to is marked reviewed. The duty '
          'itself was not changed: change it here if it should follow.',
    ),
    DutyNotice.reviewAlreadyCleared => (
      StatusTone.neutral,
      'Already reviewed',
      'Someone else marked this change reviewed first. The list was '
          'reloaded.',
    ),
    DutyNotice.withdrawn => (
      StatusTone.success,
      'Answer sent',
      a?.ownerKind == DutyOwnerKind.cell || special
          ? 'You can\'t make $what anymore. $whoSees.'
          : 'Your leader now sees that you can\'t make $what anymore.',
    ),
    DutyNotice.remindersSet => (
      StatusTone.success,
      'Reminders saved',
      'The reminders of $what are set. Nobody is asked to answer again.',
    ),
    DutyNotice.contactRecorded => (
      StatusTone.success,
      'Contact attempt recorded',
      'Your contact attempt with $what is recorded with the next follow-up '
          'date. It is on your follow-up task (My follow-ups), which closes '
          'when the position is answered, confirmed or given to someone else.',
    ),
    DutyNotice.leaderConfirmed => (
      StatusTone.success,
      special ? 'Confirmed by the Pastor' : 'Confirmed by leader',
      '$what is recorded as ${special ? 'Confirmed by the Pastor' : 'Confirmed by leader'}, '
          'with you, the time, how they confirmed and your reason. It is kept '
          'apart from an answer in the app; their answer reminders stop.',
    ),
    DutyNotice.positionCancelled => (
      StatusTone.success,
      'Position cancelled',
      '$what is cancelled and no longer counts as required. Anyone who was '
          'asked or had accepted gets a cancellation notice.',
    ),
    DutyNotice.confirmDeclined => (
      StatusTone.warning,
      'They declined',
      'A decline is not overwritten: give the position to someone (Reassign). '
          'Nothing was recorded.',
    ),
    DutyNotice.outcomeRecorded => (
      StatusTone.success,
      'Outcome recorded',
      'The outcome for $what is recorded with you and the time. It is seen '
          'only by them and ${special ? 'the Pastors' : 'this department\'s leaders and deputies'}.',
    ),
    DutyNotice.outcomeCorrected => (
      StatusTone.success,
      'Outcome corrected',
      'The outcome for $what is corrected. The earlier value, who recorded it '
          'and when are kept, with your reason.',
    ),
    DutyNotice.outcomeAlreadyRecorded => (
      StatusTone.warning,
      'Already recorded',
      'Someone recorded an outcome for $what first, so nothing was recorded. '
          'The list was reloaded: correct it if it is wrong.',
    ),
    DutyNotice.outcomeNotAccepted => (
      StatusTone.warning,
      'Not a No-show',
      '$what never accepted this duty, so it cannot be a No-show. Choose '
          'Completed or Excused. Nothing was recorded.',
    ),
    DutyNotice.outcomeNotStarted => (
      StatusTone.neutral,
      'Not started yet',
      'An outcome is recorded after the duty starts. Nothing was recorded.',
    ),
    DutyNotice.outcomeMemberGone => (
      StatusTone.neutral,
      'No longer a member',
      'This member was removed or is leaving the church, so no outcome is '
          'recorded about them. Nothing was recorded.',
    ),
    DutyNotice.ownOutcome => (
      StatusTone.neutral,
      'Your own duty',
      special
          ? 'Another Pastor records the outcome of your own special '
                'assignment. Nothing was recorded.'
          : 'Another leader or deputy of the department records the outcome '
                'of your own duty. Nothing was recorded.',
    ),
    DutyNotice.ownAssignment => (
      StatusTone.neutral,
      'Your own duty',
      'This duty is yours: answer it yourself in My duties. Nothing was '
          'recorded.',
    ),
    DutyNotice.alreadyConfirmed => (
      StatusTone.neutral,
      'Already confirmed',
      'This position is already confirmed, so nothing was recorded. The list '
          'was reloaded.',
    ),
    DutyNotice.bulkAccepted => (
      StatusTone.success,
      'Accepted',
      a?.ownerKind == DutyOwnerKind.department
          ? 'Your leader now sees that you accepted $what.'
          : 'You accepted $what. $whoSees.',
    ),
    DutyNotice.bulkChanged => (
      StatusTone.warning,
      'Nothing accepted',
      'Some of the dates you chose changed or were already answered, so none '
          'were accepted. The list was reloaded; check it and choose again.',
    ),
    DutyNotice.started => (
      StatusTone.neutral,
      'Already started',
      special
          ? 'Its time or due date has passed, so it can no longer be answered '
                'here. Speak to the Pastor.'
          : 'This duty has started, so it can no longer be answered here. '
                'Speak to your leader.',
    ),
    DutyNotice.nameTaken => (
      StatusTone.warning,
      'Name in use',
      'A department with that name already exists.',
    ),
    DutyNotice.memberRemoved => (
      StatusTone.success,
      'Removed from the department',
      '$what no longer serves in this department. Their future duties here '
          'ended: each position shows Needs a new person and its leaders and '
          'the member are being told. Past duties are kept.',
    ),
    DutyNotice.memberRemovedNoNotices => (
      StatusTone.warning,
      'Removed, but nobody was told',
      '$what no longer serves in this department and their future duties '
          'here ended (each position shows Needs a new person). Notices could '
          'not be sent right now: tell its leaders and the member directly.',
    ),
    DutyNotice.handoverResolved => (
      StatusTone.success,
      'Handover done',
      '$what has a responsible leader again; the handover is marked done.',
    ),
    DutyNotice.staffHandoverRequired => (
      StatusTone.warning,
      'Hand over first',
      'This department has no other leader or deputy who can use the app. '
          'Give the leader or deputy role to someone else first, then remove '
          'it from $what. Nothing was changed.',
    ),
    DutyNotice.leaderRequired => (
      StatusTone.warning,
      'Give it a leader first',
      '$what has no leader or deputy who can use the app. Give one the role '
          'above, then mark the handover done.',
    ),
    DutyNotice.notInDepartment => (
      StatusTone.warning,
      'Not in this department',
      'Only the department\'s members can be given its duties. Ask an Admin '
          'to add them first.',
    ),
    DutyNotice.invalid => (
      StatusTone.danger,
      'Check the form',
      'Some answers need fixing before this can be sent.',
    ),
    DutyNotice.notAllowed => (
      StatusTone.warning,
      'Not allowed',
      'Your account cannot do this now. Nothing was changed.',
    ),
    DutyNotice.signInAgain => (
      StatusTone.warning,
      'Please sign in again',
      'This sign-in is no longer valid. Nothing was changed.',
    ),
    DutyNotice.notFound => (
      StatusTone.neutral,
      'Not found',
      'That duty, department or person is not available to you. The list '
          'was reloaded.',
    ),
    DutyNotice.notAvailable => (
      StatusTone.neutral,
      'Not available yet',
      'Duties cannot be changed here right now. Nothing was changed.',
    ),
    DutyNotice.refused => (
      StatusTone.warning,
      'Not changed',
      'The server refused the change. The list was reloaded.',
    ),
    DutyNotice.unconfirmed => (
      StatusTone.warning,
      'Not sent yet',
      'We don\'t know whether the change for $what reached the church '
          'server, so nothing is shown as done. Check again: the same request '
          'is sent, so it can\'t apply twice.',
    ),
    DutyNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
  };
}

Widget _readProblem<T>(AccessRead<T> r, String needs) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('duties-denied-${denial.name}'),
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
        ? '$needs Permissions are checked by the server each time.'
        : 'Nothing is shown until the server allows it.',
  ),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: const Key('duties-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load',
    message: unreachable
        ? 'We couldn\'t reach the church server. This is not an empty rota: '
              'nothing is shown until it answers.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
};

/// The page frame shared by the duties screens: notice, read problem,
/// content and a reload button.
class _DutiesPage<T> extends ConsumerStatefulWidget {
  const _DutiesPage({
    required this.title,
    required this.provider,
    required this.needs,
    required this.loading,
    required this.body,
    this.tabRoot = false,
    this.footer,
    this.subtitle,
    this.headerAction,
  });

  final String title;

  /// Staff web: one line about the data under the page title.
  final String? subtitle;

  /// Staff web: the screen's main action in the page header (null when it
  /// has none, or before the read answers).
  final Widget? Function(BuildContext context, T value, DutiesState<T> state)?
  headerAction;
  final NotifierProvider<DutiesController<T>, DutiesState<T>> provider;
  final String needs;
  final String loading;

  /// A member tab (My duties, My cell): the handoff's in-page title with a
  /// refresh button and pull to refresh instead of an app bar and Reload.
  final bool tabRoot;
  final Widget Function(BuildContext context, T value, DutiesState<T> state)
  body;

  /// Story 4.5: a sticky footer below the scrolling content (the duty
  /// detail's answer buttons); null when there is none.
  final Widget? Function(BuildContext context, T value, DutiesState<T> state)?
  footer;

  @override
  ConsumerState<_DutiesPage<T>> createState() => _DutiesPageState<T>();
}

class _DutiesPageState<T> extends ConsumerState<_DutiesPage<T>> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'duties notice');

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the screen asks the server again.
    if (ref.read(widget.provider).result != null) Future.microtask(_reload);
  }

  // Resume and revisit reloads wait while a command is in flight (its own
  // answer reloads the list). Story 4.5: and while a read is already under
  // way, so screens mounted together (the Home card, a list under a pushed
  // detail) read once on resume.
  void _reload() {
    final s = ref.read(widget.provider);
    if (mounted && !s.busy && !s.loading) {
      ref.read(widget.provider.notifier).reload();
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
    final s = ref.watch(widget.provider);
    final ctl = ref.read(widget.provider.notifier);
    ref.listen(widget.provider.select((x) => x.notice), (prev, next) {
      if (next == null || next == prev) return;
      final now = ref.read(widget.provider);
      final (_, title, message) = _noticeText(
        next,
        now.noticeAction,
        now.fieldErrors,
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
          key: const Key('duties-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the church server about ${p.subject}. Nothing is '
              'shown as done until it answers.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(
        n,
        s.noticeAction,
        s.fieldErrors,
      );
      children.add(
        RequestStateBanner(
          key: Key('duties-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == DutyNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('duties-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('duties-dismiss'),
            ),
          ],
        ),
      );
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    final result = s.result;
    if (result == null) {
      children.add(
        RequestStateBanner(
          key: const Key('duties-loading'),
          tone: StatusTone.info,
          busy: true,
          title: widget.loading,
          message: 'Asking the church server.',
        ),
      );
    } else if (result case AccessReadOk(:final value)) {
      children.add(widget.body(context, value, s));
    } else {
      children.add(_readProblem(result, widget.needs));
    }
    if (widget.tabRoot) {
      return MemberTabPage(
        title: widget.title,
        reloadKey: const Key('duties-reload'),
        onReload: s.loading || s.busy ? null : ctl.reload,
        children: children,
      );
    }
    // On the phone a pushed screen refreshes from its bar (and by pulling);
    // staff web has Reload in the page header, after the main action.
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final footer = switch ((widget.footer, result)) {
      (final f?, AccessReadOk(:final value)) => f(context, value, s),
      _ => null,
    };
    final main = switch ((widget.headerAction, result)) {
      (final f?, AccessReadOk(:final value)) when !phone => f(
        context,
        value,
        s,
      ),
      _ => null,
    };
    return ChurchPageScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      actions: phone
          ? [
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('duties-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [?main, staffReloadButton(const Key('duties-reload'), reload)],
      bottomNavigationBar: footer,
      body: SafeArea(
        child: RefreshIndicator(
          notificationPredicate: (n) => phone && n.depth == 0,
          onRefresh: () async => reload?.call(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
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
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ChurchCard(
    radius: identical(ChurchLayout.of(context), ChurchLayout.staff)
        ? 12
        : ChurchGeometry.mobileCardRadius,
    child: child,
  );
}

Widget _heading(BuildContext context, String text, {Key? key}) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Semantics(
    header: true,
    child: Text(
      text,
      key: key,
      style: ChurchType.cardTitle.copyWith(color: ChurchColors.of(context).ink),
    ),
  ),
);

Widget _muted(BuildContext context, String text) => Text(
  text,
  style: ChurchType.secondary.copyWith(color: ChurchColors.of(context).muted),
);

// Every duty time is shown in church time (Africa/Lusaka), whatever zone the
// device is set to.
String _clock(BuildContext context, DateTime at) {
  final w = ChurchTime.wall(at);
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay(hour: w.hour, minute: w.minute),
    alwaysUse24HourFormat: true,
  );
}

String _when(BuildContext context, DateTime at) =>
    '${MaterialLocalizations.of(context).formatMediumDate(ChurchTime.wall(at))} '
    '${_clock(context, at)}';

String _timesText(BuildContext context, DutyTimes t) {
  bool sameDay(DateTime a, DateTime b) {
    final x = ChurchTime.wall(a), y = ChurchTime.wall(b);
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  return [
    _when(context, t.startsAt),
    if (t.endsAt case final e?)
      sameDay(t.startsAt, e)
          ? 'until ${_clock(context, e)}'
          : 'until ${_when(context, e)}',
    if (t.reportingAt case final r?) '(report at ${_clock(context, r)})',
    '(church time)',
  ].join(' ');
}

(String, StatusTone) _responseLabel(DutyResponse r) => switch (r) {
  DutyResponse.accepted => ('Accepted', StatusTone.success),
  DutyResponse.declined => ('Can\'t make it', StatusTone.warning),
  DutyResponse.pending => ('Awaiting response', StatusTone.warning),
};

String _accountLabel(AccountStanding a) => switch (a) {
  AccountStanding.appAccount => 'App account',
  AccountStanding.noLogin => 'No login',
  AccountStanding.accessReview => 'Access review',
};

// ---------------------------------------------------------------------------
// Staff web, Admin: departments
// ---------------------------------------------------------------------------

/// Story 4.1, staff web, Admin only: create departments, give the leader
/// and deputy scopes (through the audited 2.3 grant command) and add
/// approved members, including members without a login.
class DutyAdminScreen extends StatelessWidget {
  const DutyAdminScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyAdminOverview>(
    title: 'Departments',
    subtitle: 'Departments with their leaders, deputies and members',
    provider: dutyAdminProvider,
    needs: 'Departments needs the Admin role.',
    loading: 'Loading departments…',
    body: (context, o, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context, 'Departments (${o.departments.length})'),
        if (o.membersTruncated)
          _muted(
            context,
            'Only the first 500 members (by name) can be chosen here.',
          ),
        if (o.departments.isEmpty)
          const Text('No departments yet.', key: Key('no-departments')),
        for (final d in o.departments) ...[
          _DepartmentCard(
            key: Key('department-${d.departmentId}-r${d.revision}'),
            department: d,
            overview: o,
            busy: s.busy,
          ),
          const SizedBox(height: 12),
        ],
        _CreateDepartmentForm(busy: s.busy),
      ],
    ),
  );
}

class _DepartmentCard extends ConsumerStatefulWidget {
  const _DepartmentCard({
    super.key,
    required this.department,
    required this.overview,
    required this.busy,
  });
  final AdminDepartment department;
  final DutyAdminOverview overview;
  final bool busy;

  @override
  ConsumerState<_DepartmentCard> createState() => _DepartmentCardState();
}

class _DepartmentCardState extends ConsumerState<_DepartmentCard> {
  String? _staffId;
  String _kind = DutyScopeKinds.leader;
  String? _memberId;

  /// Story 4.12: removing a member ends their future duties in the
  /// department, so it is confirmed first.
  Future<void> _confirmRemove(AdminDepartment d, DepartmentMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ChurchDialog(
        title: 'Remove ${m.displayName} from ${d.name}?',
        // Review N4: the notices are promised only as far as they can go.
        content: const Text(
          'Their future duties in this department end now and each position '
          'shows Needs a new person. The department\'s leaders and the member '
          'are told when notices can be sent; a member the app cannot reach '
          'is listed for the leaders to tell directly. Past duties and '
          'answers are kept.',
          key: Key('remove-member-explain'),
        ),
        actions: [
          FocusRing(
            child: TextButton(
              key: const Key('remove-member-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          FocusRing(
            child: FilledButton(
              key: const Key('remove-member-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove from department'),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(dutyAdminProvider.notifier).removeMember(d, m);
    }
  }

  DutyCandidate? _candidate(String? id) {
    for (final m in widget.overview.members) {
      if (m.memberId == id) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.department;
    final ctl = ref.read(dutyAdminProvider.notifier);
    final id = d.departmentId;
    final busy = widget.busy;
    final staff = _candidate(_staffId);
    final member = _candidate(_memberId);
    final addable = widget.overview.members
        .where((m) => !d.hasMember(m.memberId))
        .toList();
    Widget staffRow(DepartmentStaff st, String kind) => Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(st.displayName),
        StatusLabel(
          label: kind == DutyScopeKinds.leader ? 'Leader' : 'Deputy',
          tone: StatusTone.neutral,
        ),
        FocusRing(
          child: TextButton(
            key: Key('remove-$kind-$id-${st.memberId}'),
            onPressed: busy ? null : () => ctl.removeStaff(d, st, kind),
            child: const Text('Remove'),
          ),
        ),
      ],
    );
    return _Card(
      key: Key('department-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, d.name),
              if (d.isSynthetic)
                const StatusLabel(
                  label: 'Synthetic test record',
                  tone: StatusTone.neutral,
                ),
            ],
          ),
          if (d.leaders.isEmpty)
            _muted(context, 'No leader yet: only an Admin can publish duties.'),
          for (final st in d.leaders) staffRow(st, DutyScopeKinds.leader),
          for (final st in d.deputies) staffRow(st, DutyScopeKinds.deputy),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: Key('staff-member-$id'),
                hint: const Text('Choose a member'),
                value: staff?.memberId,
                items: [
                  for (final m in widget.overview.members)
                    DropdownMenuItem(
                      value: m.memberId,
                      child: Text(m.displayName),
                    ),
                ],
                onChanged: busy ? null : (v) => setState(() => _staffId = v),
              ),
              DropdownButton<String>(
                key: Key('staff-kind-$id'),
                value: _kind,
                items: const [
                  DropdownMenuItem(
                    value: DutyScopeKinds.leader,
                    child: Text('Leader'),
                  ),
                  DropdownMenuItem(
                    value: DutyScopeKinds.deputy,
                    child: Text('Deputy'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() => _kind = v ?? _kind),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('assign-staff-$id'),
                  onPressed: busy || staff == null
                      ? null
                      : () => ctl.assignStaff(d, staff, _kind),
                  child: const Text('Give this role'),
                ),
              ),
            ],
          ),
          // Story 4.12: the last leader left (a member deletion): give the
          // department a leader, then mark the handover done.
          if (d.handovers.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              key: Key('department-handover-$id'),
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const StatusLabel(
                  label: 'Handover pending',
                  tone: StatusTone.warning,
                ),
                Text(
                  d.needsLeader
                      ? 'Its last leader left. Give it a leader or deputy, '
                            'then mark the handover done.'
                      : 'It has a leader again: mark the handover done.',
                ),
                FocusRing(
                  child: OutlinedButton(
                    key: Key('resolve-handover-$id'),
                    onPressed: busy || d.needsLeader
                        ? null
                        : () => ctl.resolveHandover(d),
                    child: const Text('Mark handover done'),
                  ),
                ),
              ],
            ),
          ] else if (d.needsLeader)
            // Review S4: shown whenever no leader or deputy the app can reach
            // is in place (also before any is given the role).
            Padding(
              key: Key('department-needs-leader-$id'),
              padding: const EdgeInsets.only(top: 8),
              child: const StatusLabel(
                label:
                    'No leader or deputy can use the app: alerts reach nobody',
                tone: StatusTone.warning,
              ),
            ),
          const SizedBox(height: 12),
          _heading(context, 'Members (${d.members.length})'),
          if (d.members.isEmpty) const Text('No members yet.'),
          for (final m in d.members)
            Wrap(
              key: Key('department-member-$id-${m.memberId}'),
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(m.displayName),
                if (m.account != AccountStanding.appAccount)
                  StatusLabel(
                    label: _accountLabel(m.account),
                    tone: StatusTone.neutral,
                  ),
                FocusRing(
                  child: TextButton(
                    key: Key('remove-member-$id-${m.memberId}'),
                    onPressed: busy ? null : () => _confirmRemove(d, m),
                    child: Text(
                      'Remove from department',
                      semanticsLabel: 'Remove ${m.displayName} from ${d.name}',
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: Key('add-member-$id'),
                hint: const Text('Add a member'),
                value: member?.memberId,
                items: [
                  for (final m in addable)
                    DropdownMenuItem(
                      value: m.memberId,
                      child: Text(
                        m.account == AccountStanding.noLogin
                            ? '${m.displayName} (no login)'
                            : m.displayName,
                      ),
                    ),
                ],
                onChanged: busy ? null : (v) => setState(() => _memberId = v),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('add-member-save-$id'),
                  onPressed:
                      busy || member == null || d.hasMember(member.memberId)
                      ? null
                      : () => ctl.addMember(d, member),
                  child: const Text('Add to department'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CreateDepartmentForm extends ConsumerStatefulWidget {
  const _CreateDepartmentForm({required this.busy});
  final bool busy;

  @override
  ConsumerState<_CreateDepartmentForm> createState() =>
      _CreateDepartmentFormState();
}

class _CreateDepartmentFormState extends ConsumerState<_CreateDepartmentForm> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errors = ref.watch(dutyAdminProvider.select((s) => s.fieldErrors));
    final err = switch (errors['name']) {
      null => null,
      'required' => 'Required',
      _ =>
        'Check this (while personal data is not approved, start with '
            '"SYNTHETIC ")',
    };
    return _Card(
      key: const Key('create-department'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Add a department'),
          _muted(
            context,
            'For example ushering, cleaning or the preaching rota. Leaders and '
            'members are added on the department afterwards.',
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('create-department-name'),
            controller: _name,
            enabled: !widget.busy,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: 'Department name',
              errorText: err,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ListenableBuilder(
              listenable: _name,
              builder: (context, _) => FocusRing(
                child: FilledButton(
                  key: const Key('create-department-save'),
                  onPressed: widget.busy || _name.text.trim().isEmpty
                      ? null
                      : () => ref
                            .read(dutyAdminProvider.notifier)
                            .createDepartment(_name.text),
                  child: const Text('Add department'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Staff web, leaders: publish and see responses
// ---------------------------------------------------------------------------

/// Story 4.1, staff web: the departments the caller leads or deputises (an
/// Admin sees all; a Pastor sees all, read only). A leader publishes a duty
/// to one department member with a response deadline and sees each
/// position's answer.
///
/// The board answers one question first: which duties are short of
/// confirmed people. Each department is a table (duty, when, where, how many
/// are confirmed, and Change), each duty's positions and answers in a quiet
/// well under its row; on a phone each duty is a two-line row.
class DutyLeaderScreen extends StatelessWidget {
  const DutyLeaderScreen({super.key, this.reviewsOnly = false});

  /// Story 4.16: opened from the "Duty needs review" notice: only the duties
  /// with an open review are listed, with a way back to every duty. The
  /// board is read again either way (the link is a pointer, not a grant).
  final bool reviewsOnly;

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyLeaderBoard>(
    title: reviewsOnly ? 'Duties to review' : 'Duties',
    subtitle: 'Duties your departments publish, and the answers',
    provider: dutyLeaderProvider,
    needs: 'This page is for department leaders and deputies.',
    loading: 'Loading duties…',
    body: (context, b, s) {
      final c = ChurchColors.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (reviewsOnly)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Wrap(
                key: const Key('leader-reviews-only'),
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Showing the duties whose linked meeting or event changed.',
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
                  FocusRing(
                    child: TextButton(
                      key: const Key('leader-show-all'),
                      onPressed: () => context.go(DutyPaths.leader),
                      child: const Text('Show all duties'),
                    ),
                  ),
                ],
              ),
            ),
          if (b.departments.isEmpty)
            ChurchCard(
              radius: churchCardRadiusOf(context),
              child: Text(
                'No departments yet.',
                key: const Key('leader-no-departments'),
                style: ChurchType.staffBody.copyWith(color: c.muted),
              ),
            ),
          for (final (i, d) in b.departments.indexed) ...[
            if (i > 0) const SizedBox(height: 36),
            _LeaderDepartmentCard(
              department: d,
              busy: s.busy,
              reviewsOnly: reviewsOnly,
            ),
          ],
        ],
      );
    },
  );
}

/// One department: its name and the caller's capacity, who needs direct
/// contact, the duties as a table, then the form to publish one more.
class _LeaderDepartmentCard extends StatefulWidget {
  const _LeaderDepartmentCard({
    required this.department,
    required this.busy,
    this.reviewsOnly = false,
  });
  final LeaderDepartment department;
  final bool busy;
  final bool reviewsOnly;

  @override
  State<_LeaderDepartmentCard> createState() => _LeaderDepartmentCardState();
}

class _LeaderDepartmentCardState extends State<_LeaderDepartmentCard> {
  final _publishSection = GlobalKey();
  final _publishName = FocusNode(debugLabel: 'publish a duty: name');

  @override
  void dispose() {
    _publishName.dispose();
    super.dispose();
  }

  /// The department's most frequent job, one click from its heading: the
  /// form below the table comes into view with the cursor in its first
  /// field.
  void _goToPublish() {
    final target = _publishSection.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        alignment: 0.05,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
      );
    }
    _publishName.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final d = widget.department;
    final reviewsOnly = widget.reviewsOnly;
    // Story 4.16: the reviews view lists only duties with an open review.
    final duties = reviewsOnly
        ? [
            for (final duty in d.duties)
              if (duty.reviews.isNotEmpty) duty,
          ]
        : d.duties;
    final publish = d.canPublish && !reviewsOnly;
    // Story 4.8: who needs direct contact comes before the duties; when
    // nobody does, one quiet line says so.
    final contact =
        d.contactNotices.isNotEmpty ||
        d.duties.any(
          (duty) =>
              duty.positions.any((p) => p.assignment?.needsContact != null),
        );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            d.name,
            style: ChurchType.sectionTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          d.capacityLabel,
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        if (!reviewsOnly && !contact)
          Text(
            'Nobody needs direct contact right now.',
            key: Key('board-no-contact-${d.departmentId}'),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
      ],
    );
    return Column(
      key: Key('leader-department-${d.departmentId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final jump = publish
                ? FocusRing(
                    child: OutlinedButton.icon(
                      key: Key('board-publish-jump-${d.departmentId}'),
                      onPressed: _goToPublish,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Publish a duty'),
                    ),
                  )
                : null;
            // A phone: the button under the heading, so neither is squeezed.
            if (box.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading,
                  if (jump != null) ...[const SizedBox(height: 8), jump],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: heading),
                if (jump != null) ...[const SizedBox(width: 12), jump],
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        if (!reviewsOnly && contact) ...[
          ChurchCard(
            radius: churchCardRadiusOf(context),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            child: _NeedsContactList(department: d),
          ),
          const SizedBox(height: 16),
        ],
        _BoardDutyTable(
          department: d,
          duties: duties,
          busy: widget.busy,
          reviewsOnly: reviewsOnly,
        ),
        if (publish) ...[
          const SizedBox(height: 20),
          // A form reads best at about 680 px, not across the page.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: KeyedSubtree(
                key: _publishSection,
                child: StaffSection(
                  title: 'Publish a duty',
                  subtitle: 'To ${d.name}',
                  child: _PublishForm(
                    key: Key('publish-${d.departmentId}'),
                    department: d,
                    busy: widget.busy,
                    nameFocus: _publishName,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The table's columns on a wide screen; null on a narrow one (two-line
/// rows instead).
List<StaffColumn> _boardColumns(LeaderDepartment d) => [
  const StaffColumn('Duty', flex: 4),
  const StaffColumn('When (church time)', flex: 4),
  const StaffColumn('Where', flex: 3),
  const StaffColumn('Confirmed', width: 132, numeric: true),
  if (d.canPublish) const StaffColumn('', width: 92),
];

/// A department's duties as a table: its title row ("Duties (3)" and how
/// many are short of people), the 12 px grey header, one row group per duty.
class _BoardDutyTable extends StatelessWidget {
  const _BoardDutyTable({
    required this.department,
    required this.duties,
    required this.busy,
    required this.reviewsOnly,
  });

  final LeaderDepartment department;
  final List<LeaderDuty> duties;
  final bool busy;
  final bool reviewsOnly;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final d = department;
    final short = duties.where((x) => x.accepted < x.required).length;
    final (shortText, shortColor) = short == 0
        ? ('Every duty has its people', c.greenFg)
        : (
            '$short ${short == 1 ? 'duty' : 'duties'} short of people',
            c.amberFg,
          );
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 760;
        final columns = wide ? _boardColumns(d) : null;
        return StaffTableFrame(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        reviewsOnly
                            ? 'Needs review (${duties.length})'
                            : 'Duties (${d.duties.length})',
                        style: ChurchType.cardTitle.copyWith(
                          color: c.ink,
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ),
                  if (duties.isNotEmpty)
                    Text(
                      shortText,
                      key: Key('board-short-${d.departmentId}'),
                      style: ChurchType.secondary.copyWith(
                        color: shortColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            // Story 4.16 (review N5): every duty needing review is listed
            // even past the first 200, so the reviews view is complete.
            if (d.dutiesTruncated && !reviewsOnly)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _muted(
                  context,
                  'Only the first 200 duties (and every duty that needs '
                  'review) are shown.',
                ),
              ),
            if (duties.isEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.line)),
                ),
                child: Text(
                  reviewsOnly ? 'Nothing needs review here.' : 'No duties yet.',
                  key: Key('no-duties-${d.departmentId}'),
                  style: ChurchType.staffBody.copyWith(color: c.muted),
                ),
              )
            else ...[
              if (columns != null)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: c.line)),
                  ),
                  child: StaffTableHeader(columns: columns),
                ),
              for (final (i, duty) in duties.indexed)
                _LeaderDutyRow(
                  key: Key('leader-duty-row-${duty.occurrenceId}'),
                  duty: duty,
                  department: d,
                  busy: busy,
                  columns: columns,
                  divider: columns == null || i > 0,
                ),
            ],
          ],
        );
      },
    );
  }
}

/// When a duty is, as the table shows it: the start (and its end) on the
/// first line, the reporting time on a second.
(String, String?) _boardWhen(BuildContext context, DutyTimes t) {
  final s = ChurchTime.wall(t.startsAt);
  final first = StringBuffer(_when(context, t.startsAt));
  if (t.endsAt case final e?) {
    final w = ChurchTime.wall(e);
    final sameDay = w.year == s.year && w.month == s.month && w.day == s.day;
    first.write(
      sameDay ? '–${_clock(context, e)}' : ' until ${_when(context, e)}',
    );
  }
  return (
    first.toString(),
    switch (t.reportingAt) {
      final r? => 'Report at ${_clock(context, r)}',
      null => null,
    },
  );
}

class _LeaderDutyRow extends StatefulWidget {
  const _LeaderDutyRow({
    super.key,
    required this.duty,
    required this.department,
    required this.busy,
    this.columns,
    this.divider = true,
  });
  final LeaderDuty duty;
  final LeaderDepartment department;
  final bool busy;

  /// The table's columns on a wide screen; null for a two-line row.
  final List<StaffColumn>? columns;
  final bool divider;

  @override
  State<_LeaderDutyRow> createState() => _LeaderDutyRowState();
}

class _LeaderDutyRowState extends State<_LeaderDutyRow> {
  bool _editing = false;

  @override
  void didUpdateWidget(_LeaderDutyRow old) {
    super.didUpdateWidget(old);
    // A new revision from the server closes the form (it was saved, or
    // someone else changed the duty: the form would edit stale values).
    if (old.duty.revision != widget.duty.revision) _editing = false;
  }

  @override
  Widget build(BuildContext context) {
    final duty = widget.duty;
    final id = duty.occurrenceId;
    final started = !duty.times.arriveBy.isAfter(DateTime.now());
    final c = ChurchColors.of(context);
    final meta = ChurchType.secondary.copyWith(color: c.muted);
    final canChange = widget.department.canPublish && !started;
    final columns = widget.columns;
    // How many are confirmed: the one coloured figure on the row (amber
    // while short, green when full, grey when nothing is required).
    final figureColor = duty.required == 0
        ? c.muted
        : duty.accepted < duty.required
        ? c.amberFg
        : c.greenFg;
    final confirmed = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${duty.accepted} of ${duty.required}',
            style: ChurchType.figures.copyWith(
              color: figureColor,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          TextSpan(
            text: ' confirmed',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        ],
      ),
      key: Key('coverage-$id'),
      textAlign: TextAlign.end,
    );
    final name = Text(
      duty.dutyName,
      style: ChurchType.staffBody.copyWith(
        color: c.ink,
        fontWeight: FontWeight.w600,
      ),
    );
    final change = canChange && !_editing
        ? Semantics(
            button: true,
            label: 'Change this duty: ${duty.dutyName}',
            excludeSemantics: true,
            child: FocusRing(
              child: TextButton(
                key: Key('edit-$id'),
                onPressed: widget.busy
                    ? null
                    : () => setState(() => _editing = true),
                child: const Text('Change'),
              ),
            ),
          )
        : null;
    final Widget main;
    if (columns != null) {
      final (whenText, report) = _boardWhen(context, duty.times);
      main = Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
        alignment: AlignmentDirectional.centerStart,
        child: StaffColumnsRow(
          columns: columns,
          cells: [
            name,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  whenText,
                  style: ChurchType.staffBody.copyWith(
                    color: c.ink,
                    fontSize: 14,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (report != null) Text(report, style: meta),
              ],
            ),
            Text(
              duty.location ?? '—',
              style: ChurchType.staffBody.copyWith(
                color: duty.location == null ? c.muted : c.ink,
                fontSize: 14,
              ),
            ),
            confirmed,
            if (widget.department.canPublish) change ?? const SizedBox.shrink(),
          ],
        ),
      );
    } else {
      // A phone or a narrow window: the name and the figure on one line,
      // when and where in grey under them.
      main = Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: name),
                const SizedBox(width: 12),
                confirmed,
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [_timesText(context, duty.times), ?duty.location].join(' · '),
              style: meta,
            ),
          ],
        ),
      );
    }
    final pad = columns == null
        ? const EdgeInsets.fromLTRB(16, 0, 16, 14)
        : const EdgeInsets.fromLTRB(20, 0, 20, 16);
    final detail = Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (duty.instructions case final i?)
            Text('Instructions: $i', style: meta),
          if (duty.topic case final t?) Text('Topic: $t', style: meta),
          if (duty.scripture case final sc?)
            Text('Scripture: $sc', style: meta),
          // Story 4.11: linked programme parts and owner-review mismatches.
          Consumer(
            builder: (context, ref, _) => _OwnerReviews(
              occurrenceId: id,
              dutyName: duty.dutyName,
              reviews: duty.reviews,
              linkedParts: duty.linkedParts,
              canClear: widget.department.canPublish,
              busy: widget.busy,
              onClear: (r) =>
                  ref.read(dutyLeaderProvider.notifier).clearReview(duty, r),
            ),
          ),
          if (duty.positions.isNotEmpty) ...[
            const SizedBox(height: 8),
            _BoardPositions(positions: duty.positions),
          ],
          // Story 4.8: the member reminders, changed without asking anyone
          // again.
          if (duty.reminders case final r?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DefaultTextStyle.merge(
                style: meta,
                child: Consumer(
                  builder: (context, ref, _) {
                    final st = ref.watch(dutyLeaderProvider);
                    final mine =
                        st.noticeAction?.command == DutyCommands.setReminders &&
                        st.noticeAction?.request.payload['occurrence_id'] == id;
                    return _RemindersEditor(
                      key: Key('leader-reminders-$id-r${duty.revision}'),
                      keyPrefix: 'leader-$id',
                      reminders: r,
                      reporting: duty.times.reportingAt != null,
                      canChange: widget.department.canPublish && !started,
                      busy: widget.busy,
                      error: mine ? st.fieldErrors['reminders'] : null,
                      onSave: (specs) => ref
                          .read(dutyLeaderProvider.notifier)
                          .setReminders(duty, specs),
                    );
                  },
                ),
              ),
            ),
          // On a phone Change sits under the details.
          if (columns == null && change != null)
            Align(alignment: AlignmentDirectional.centerStart, child: change),
          if (canChange && _editing) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _EditDutyForm(
                  key: Key('edit-form-$id-r${duty.revision}'),
                  duty: duty,
                  department: widget.department,
                  busy: widget.busy,
                  onClose: () => setState(() => _editing = false),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return DecoratedBox(
      key: Key('leader-duty-$id'),
      decoration: BoxDecoration(
        border: widget.divider ? Border(top: BorderSide(color: c.line)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [main, detail],
      ),
    );
  }
}

/// A duty's positions in a quiet well under its row: each position's person
/// and their answer (the position's one status mark), then what the leader
/// needs to know about it in grey.
class _BoardPositions extends StatelessWidget {
  const _BoardPositions({required this.positions});

  final List<DutyPosition> positions;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, p) in positions.indexed)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                border: i == 0 ? null : Border(top: BorderSide(color: c.line)),
              ),
              child: _BoardPosition(position: p),
            ),
        ],
      ),
    );
  }
}

class _BoardPosition extends StatelessWidget {
  const _BoardPosition({required this.position});

  final DutyPosition position;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final p = position;
    final label = p.positionName ?? 'Position ${p.positionNo}';
    final ink = ChurchType.staffBody.copyWith(color: c.ink, fontSize: 14);
    final gap = ChurchType.staffBody.copyWith(
      color: c.redFg,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    final lines = <Widget>[];
    // Story 4.9: a cancelled position is no longer required.
    if (p.cancelled) {
      lines.add(
        Text(
          '$label: Cancelled',
          key: Key('position-cancelled-${p.slotId}'),
          style: ink.copyWith(color: c.muted),
        ),
      );
    }
    // Story 4.12: the person given it can no longer serve; story 4.16: with
    // the coarse reason for the department's leaders and deputies (the
    // server sends it to nobody else).
    else if (p.vacated) {
      lines.add(
        Wrap(
          key: Key('position-vacated-${p.slotId}'),
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$label: ', style: ink),
                  TextSpan(text: 'Unfilled', style: gap),
                ],
              ),
            ),
            const StatusLabel(
              label: 'Needs a new person',
              tone: StatusTone.warning,
            ),
            if (p.vacancyReason case final r?)
              Text(
                'Reason: ${DutyVacancyReasons.label(r)}',
                key: Key('position-vacancy-reason-${p.slotId}'),
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
          ],
        ),
      );
    } else if (p.assignment == null && p.positionName != null) {
      lines.add(
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '${p.positionName}: ', style: ink),
              TextSpan(text: 'Unfilled', style: gap),
            ],
          ),
        ),
      );
    }
    if (p.assignment case final a?) {
      final (answer, tone) = _answerLabel(a.response, a.priorAcceptedAt);
      lines.add(
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              p.positionName == null
                  ? (a.displayName ?? 'Removed member')
                  : '${p.positionName}: '
                        '${a.displayName ?? 'Removed member'}',
              style: ink.copyWith(fontWeight: FontWeight.w500),
            ),
            StatusLabel(
              key: Key('response-${a.assignmentId}'),
              // Story 4.9: kept apart from the member's own answer.
              label: a.confirmation != null ? 'Confirmed by leader' : answer,
              tone: tone,
            ),
            // Story 4.8: Short notice and Needs contact.
            ..._contactFlags(
              context,
              assignmentId: a.assignmentId,
              shortNotice: a.shortNotice,
              response: a.response,
              needsContact: a.needsContact,
            ),
          ],
        ),
      );
      final quiet = ChurchType.secondary.copyWith(color: c.muted, fontSize: 13);
      final details = <Widget>[
        if (a.confirmation case final cf?)
          Text(
            '${cf.by ?? 'A leader'} recorded it ${_when(context, cf.at)} '
            '(${cf.channel.label.toLowerCase()})'
            '${cf.reason == null ? '' : ': "${cf.reason}"'}',
            style: quiet,
          ),
        if (a.priorAcceptedAt case final t?)
          Text('Had accepted ${_when(context, t)}; needs cover', style: quiet),
        if (a.changes case final ch?)
          Text(
            'Changed: ${DutyFields.describe(ch)}',
            key: Key('changed-${a.assignmentId}'),
            style: quiet,
          ),
        if (a.response == DutyResponse.pending)
          Text(
            a.shortNotice
                ? 'Given at short notice: answer requested now'
                : 'Answer by ${_when(context, a.responseDeadline)}'
                      '${a.deadlineSource == DutyDeadlineSource.churchDefault ? ' (church default)' : ''}',
            style: quiet,
          ),
        if (a.notesUpdatedAt case final u?)
          Text('Details updated ${_when(context, u)}', style: quiet),
        if (a.note case final n?)
          Text(
            'Note: $n',
            key: Key('note-${a.assignmentId}'),
            style: quiet.copyWith(color: c.ink),
          ),
        if (a.overlaps > 0)
          Text(
            'Overlaps ${a.overlaps} other '
            '${a.overlaps == 1 ? 'duty' : 'duties'}',
            key: Key('overlaps-${a.assignmentId}'),
            style: quiet.copyWith(
              color: c.amberFg,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (a.override case final o?)
          Text(
            _overrideText(context, o),
            key: Key('override-${a.assignmentId}'),
            style: quiet,
          ),
      ];
      if (details.isNotEmpty) {
        lines.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: details,
            ),
          ),
        );
      }
    }
    if (p.history.isNotEmpty) lines.add(_History(position: p));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: lines,
    );
  }
}

/// Story 4.11: the cell programme parts that show a department duty (display
/// links; the department keeps sole authority) and its open owner-review
/// mismatches: a linked cell meeting or event changed, the duty did not. Its
/// leaders and deputies (and an Admin) mark a mismatch reviewed after
/// deciding whether to change the duty.
class _OwnerReviews extends StatelessWidget {
  const _OwnerReviews({
    required this.occurrenceId,
    required this.dutyName,
    required this.reviews,
    required this.linkedParts,
    required this.canClear,
    required this.busy,
    required this.onClear,
  });
  final String occurrenceId;

  /// The duty's name, for the button's accessible label (review N6).
  final String dutyName;
  final List<DutyReview> reviews;
  final int linkedParts;
  final bool canClear;
  final bool busy;
  final void Function(DutyReview review) onClear;

  @override
  Widget build(BuildContext context) {
    if (linkedParts == 0 && reviews.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (linkedParts > 0)
          Padding(
            key: Key('linked-parts-$occurrenceId'),
            padding: const EdgeInsets.only(top: 4),
            child: _muted(
              context,
              'Shown on $linkedParts cell programme '
              '${linkedParts == 1 ? 'part' : 'parts'}. Only this department '
              'changes it.',
            ),
          ),
        for (final r in reviews)
          Padding(
            key: Key('review-${r.flagId}'),
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const StatusLabel(
                  label: 'Needs review',
                  tone: StatusTone.warning,
                ),
                Text(
                  '${r.summary}. This duty was not changed; change it here if '
                  'it should follow.',
                  style: ChurchType.secondary.copyWith(
                    color: ChurchColors.of(context).ink,
                  ),
                ),
                if (canClear)
                  Semantics(
                    button: true,
                    label: 'Mark reviewed: $dutyName',
                    excludeSemantics: true,
                    child: FocusRing(
                      child: TextButton(
                        key: Key('clear-review-${r.flagId}'),
                        onPressed: busy ? null : () => onClear(r),
                        child: const Text('Mark reviewed'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Story 4.2: the earlier assignments of a position with the answers they
/// had (kept, never reset), newest first.
class _History extends StatelessWidget {
  const _History({required this.position});
  final DutyPosition position;

  @override
  Widget build(BuildContext context) {
    final quiet = ChurchType.secondary.copyWith(
      color: ChurchColors.of(context).muted,
      fontSize: 13,
    );
    return Padding(
      key: Key('history-${position.slotId}'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Earlier versions (${position.history.length})', style: quiet),
          for (final h in position.history)
            Padding(
              key: Key('history-${h.assignmentId}'),
              padding: const EdgeInsetsDirectional.only(start: 12),
              child: Text(
                [
                  '${h.displayName ?? 'Removed member'}: '
                      '${_answerLabel(h.response, h.priorAcceptedAt).$1}',
                  if (h.respondedAt case final r?)
                    'answered ${_when(context, r)}',
                  if (h.provenance == 'member') 'by the member',
                  h.state == 'cancelled'
                      ? 'cancelled ${_when(context, h.endedAt)}'
                      : 'replaced by a change ${_when(context, h.endedAt)}',
                  if (h.note case final n?) 'note: $n',
                ].join(', '),
                style: quiet,
              ),
            ),
        ],
      ),
    );
  }
}

/// Lays a duty form's short fields out two to a row when there is room
/// (date beside start time, and so on), one under another on a phone.
class _BoardFieldPairs extends StatelessWidget {
  const _BoardFieldPairs({required this.pairs});

  /// Each entry is one row: one field, or two side by side.
  final List<List<Widget>> pairs;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final two = box.maxWidth >= 520;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in pairs)
            if (two && row.length == 2)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: row[0]),
                  const SizedBox(width: 12),
                  Expanded(child: row[1]),
                ],
              )
            else
              ...row,
        ],
      );
    },
  );
}

/// Story 4.2, staff web: change a published duty. Changing the duty, date,
/// times, place or person asks the member to answer again by a new answer-by
/// time (their earlier answer is kept); changing only the instructions keeps
/// the answer. The server decides; this form only explains it.
class _EditDutyForm extends ConsumerStatefulWidget {
  const _EditDutyForm({
    super.key,
    required this.duty,
    required this.department,
    required this.busy,
    required this.onClose,
  });
  final LeaderDuty duty;
  final LeaderDepartment department;
  final bool busy;
  final VoidCallback onClose;

  @override
  ConsumerState<_EditDutyForm> createState() => _EditDutyFormState();
}

class _EditDutyFormState extends ConsumerState<_EditDutyForm> {
  late final _name = TextEditingController(text: widget.duty.dutyName);
  late final _date = TextEditingController(
    text: ChurchTime.dateText(widget.duty.times.startsAt),
  );
  late final _start = TextEditingController(
    text: ChurchTime.timeText(widget.duty.times.startsAt),
  );
  late final _end = TextEditingController(
    text: switch (widget.duty.times.endsAt) {
      final e? => ChurchTime.timeText(e),
      null => '',
    },
  );
  late final _endDate = TextEditingController(
    text: switch (widget.duty.times.endsAt) {
      final e?
          when ChurchTime.dateText(e) !=
              ChurchTime.dateText(widget.duty.times.startsAt) =>
        ChurchTime.dateText(e),
      _ => '',
    },
  );
  late final _reporting = TextEditingController(
    text: switch (widget.duty.times.reportingAt) {
      final r? => ChurchTime.timeText(r),
      null => '',
    },
  );
  late final _location = TextEditingController(
    text: widget.duty.location ?? '',
  );
  late final _instructions = TextEditingController(
    text: widget.duty.instructions ?? '',
  );
  final _deadlineDate = TextEditingController();
  final _deadlineTime = TextEditingController();
  final _reason = TextEditingController();
  late String? _memberId = widget.duty.memberId;

  List<TextEditingController> get _all => [
    _name,
    _date,
    _start,
    _end,
    _endDate,
    _reporting,
    _location,
    _instructions,
    _deadlineDate,
    _deadlineTime,
    _reason,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  /// The edit, or null while a field cannot be read.
  DutyEdit? _edit() {
    final starts = ChurchTime.parse(_date.text, _start.text);
    final endDate = _endDate.text.trim().isEmpty ? _date.text : _endDate.text;
    final ends = _end.text.trim().isEmpty
        ? null
        : ChurchTime.parse(endDate, _end.text);
    final reporting = _reporting.text.trim().isEmpty
        ? null
        : ChurchTime.parse(_date.text, _reporting.text);
    final deadlineGiven =
        _deadlineDate.text.trim().isNotEmpty ||
        _deadlineTime.text.trim().isNotEmpty;
    final deadline = deadlineGiven
        ? ChurchTime.parse(_deadlineDate.text, _deadlineTime.text)
        : null;
    if (_name.text.trim().isEmpty ||
        starts == null ||
        (_end.text.trim().isNotEmpty && ends == null) ||
        (_endDate.text.trim().isNotEmpty && _end.text.trim().isEmpty) ||
        (_reporting.text.trim().isNotEmpty && reporting == null) ||
        (deadlineGiven && deadline == null)) {
      return null;
    }
    return DutyEdit(
      duty: widget.duty,
      dutyName: _name.text,
      startsAt: starts,
      endsAt: ends,
      reportingAt: reporting,
      location: _location.text,
      instructions: _instructions.text,
      memberId: _memberId,
      responseDeadline: deadline,
      overrideReason: _reason.text,
    );
  }

  /// Story 4.4: the one position at the times entered (its own assignment
  /// is never its own conflict).
  CandidateQuery _query() {
    final slot = widget.duty.positions.first.slotId;
    final e = _edit();
    if (e == null) return CandidateQuery.slot(slot);
    return CandidateQuery.slot(
      slot,
      startsAt: e.startsAt,
      endsAt: e.endsAt,
      reportingAt: e.reportingAt,
    );
  }

  String _memberName(String? id) {
    for (final m in widget.department.members) {
      if (m.memberId == id) return m.displayName;
    }
    return 'the member';
  }

  @override
  Widget build(BuildContext context) {
    final duty = widget.duty;
    final id = duty.occurrenceId;
    final c = ChurchColors.of(context);
    final s = ref.watch(dutyLeaderProvider);
    // Only this form's own refusal names its fields.
    final mine =
        s.noticeAction?.command == DutyCommands.revise &&
        s.noticeAction?.request.payload['occurrence_id'] == id;
    final errors = mine ? s.fieldErrors : const <String, String>{};
    String? err(String wire) => switch (errors[wire]) {
      null => null,
      'required' => 'Required',
      'past' => 'This is in the past',
      'after_start' => 'Must be before the duty starts',
      'before_start' => 'Must be after the start',
      'not_in_department' => 'Not a member of this department',
      'not_material' =>
        'Only needed when the duty, time, place or person '
            'changes',
      'required_reassign' =>
        'The current person can no longer serve: choose who takes this duty',
      'overlap' => 'Has another duty at that time',
      _ => 'Check this',
    };
    Widget field(
      String key,
      TextEditingController c,
      String label, {
      String? wire,
      String? hint,
      int maxLength = 80,
      int maxLines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key('$key-$id'),
        controller: c,
        enabled: !widget.busy,
        maxLength: maxLength,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: wire == null ? null : err(wire),
          // The limit still holds; only the long text shows its count.
          counterText: maxLength > 120 ? null : '',
        ),
      ),
    );
    final inRoster = widget.department.members.any(
      (m) => m.memberId == _memberId,
    );
    return Container(
      key: Key('edit-card-$id'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Change this duty',
              style: ChurchType.cardTitle.copyWith(color: c.ink, fontSize: 17),
            ),
          ),
          const SizedBox(height: 4),
          _muted(
            context,
            'Changing the duty, date, times, place or person asks the member '
            'to answer again by a new answer-by time; their earlier answer is '
            'kept. Changing only the instructions keeps their answer. Times '
            'are church time (Lusaka).${duty.positions.length == 1 ? '' : ' '
                      'Every position of this date changes together; give a '
                      'position to someone on the Rota page.'}',
          ),
          const SizedBox(height: 14),
          field('edit-name', _name, 'Duty', wire: 'duty_name'),
          _BoardFieldPairs(
            pairs: [
              [
                field(
                  'edit-date',
                  _date,
                  'Date',
                  hint: 'YYYY-MM-DD',
                  wire: 'starts_at',
                  maxLength: 10,
                ),
                field(
                  'edit-start',
                  _start,
                  'Start time',
                  hint: 'HH:MM',
                  maxLength: 5,
                ),
              ],
              [
                field(
                  'edit-end',
                  _end,
                  'End time (optional)',
                  hint: 'HH:MM',
                  wire: 'ends_at',
                  maxLength: 5,
                ),
                field(
                  'edit-end-date',
                  _endDate,
                  'End date, if a later day (optional)',
                  hint: 'YYYY-MM-DD',
                  maxLength: 10,
                ),
              ],
              [
                field(
                  'edit-reporting',
                  _reporting,
                  'Reporting time, if earlier (optional)',
                  hint: 'HH:MM',
                  wire: 'reporting_at',
                  maxLength: 5,
                ),
                field(
                  'edit-location',
                  _location,
                  'Location (optional)',
                  wire: 'location',
                  maxLength: 120,
                ),
              ],
            ],
          ),
          field(
            'edit-instructions',
            _instructions,
            'Instructions (optional)',
            wire: 'instructions',
            maxLength: 1000,
            maxLines: 3,
          ),
          if (duty.positions.length == 1)
            ListenableBuilder(
              listenable: Listenable.merge([
                _date,
                _start,
                _end,
                _endDate,
                _reporting,
              ]),
              builder: (context, _) => _CandidatePicker(
                pickerKey: 'edit-member-$id',
                members: widget.department.members,
                value: inRoster ? _memberId : null,
                query: _query(),
                reason: _reason,
                busy: widget.busy,
                reasonError: errors['override_reason'],
                onChanged: (v) => setState(() => _memberId = v),
              ),
            )
          else if (errors['override_reason'] != null)
            TextField(
              key: Key('edit-reason-$id'),
              controller: _reason,
              enabled: !widget.busy,
              maxLength: DutyOverride.maxLength,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText:
                    'Someone has another duty at the new time. Why keep them? '
                    '(required)',
                errorText: 'Give a reason, or change the time',
              ),
            ),
          if (err('member_id') case final e?)
            Text(e, style: TextStyle(color: c.redFg)),
          const SizedBox(height: 12),
          _BoardFieldPairs(
            pairs: [
              [
                field(
                  'edit-deadline-date',
                  _deadlineDate,
                  'New answer by: date (optional)',
                  hint: 'YYYY-MM-DD',
                  wire: 'response_deadline',
                  maxLength: 10,
                ),
                field(
                  'edit-deadline-time',
                  _deadlineTime,
                  'New answer by: time',
                  hint: 'HH:MM',
                  maxLength: 5,
                ),
              ],
            ],
          ),
          _muted(context, 'An empty answer-by date means the church default.'),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: Listenable.merge(_all),
            builder: (context, _) {
              final edit = _edit();
              final changed = edit?.changed ?? const <String>[];
              final material = edit?.material ?? false;
              // Story 4.8: without a new answer-by time the church default
              // applies (Short notice when it has already passed).
              final ready = edit != null && changed.isNotEmpty;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (changed.isNotEmpty)
                    Text(
                      material
                          ? '${_memberName(edit!.memberId)} will be asked to '
                                'answer again (changed: '
                                '${DutyFields.describe(changed)}).'
                          : 'Only the instructions change: the answer '
                                'stands.',
                      key: Key('edit-summary-$id'),
                    ),
                  if (material && edit?.responseDeadline == null)
                    _muted(
                      context,
                      'No new answer-by time: the church default applies. '
                      '$_defaultDeadlineHelp',
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FocusRing(
                        child: FilledButton(
                          key: Key('edit-save-$id'),
                          onPressed: widget.busy || !ready
                              ? null
                              : () => ref
                                    .read(dutyLeaderProvider.notifier)
                                    .revise(edit, edit.duty.dutyName),
                          child: const Text('Save the change'),
                        ),
                      ),
                      FocusRing(
                        child: TextButton(
                          key: Key('edit-cancel-$id'),
                          onPressed: widget.busy ? null : widget.onClose,
                          child: const Text('Close without saving'),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PublishForm extends ConsumerStatefulWidget {
  const _PublishForm({
    super.key,
    required this.department,
    required this.busy,
    this.nameFocus,
  });
  final LeaderDepartment department;
  final bool busy;

  /// The first field, focused by the department's "Publish a duty" button.
  final FocusNode? nameFocus;

  @override
  ConsumerState<_PublishForm> createState() => _PublishFormState();
}

class _PublishFormState extends ConsumerState<_PublishForm> {
  final _name = TextEditingController();
  final _date = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _endDate = TextEditingController();
  final _reporting = TextEditingController();
  final _location = TextEditingController();
  final _instructions = TextEditingController();
  final _deadlineDate = TextEditingController();
  final _deadlineTime = TextEditingController();
  final _reason = TextEditingController();
  String? _memberId;

  /// Story 4.8: the creator's member reminders (off = the defaults).
  bool _customReminders = false;
  final Set<DutyReminderSpec> _reminders = {};

  List<TextEditingController> get _all => [
    _name,
    _date,
    _start,
    _end,
    _endDate,
    _reporting,
    _location,
    _instructions,
    _deadlineDate,
    _deadlineTime,
    _reason,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  /// Story 4.4: the busy time entered so far (null until it can be read).
  CandidateQuery? _query() {
    final starts = ChurchTime.parse(_date.text, _start.text);
    if (starts == null) return null;
    final endDate = _endDate.text.trim().isEmpty ? _date.text : _endDate.text;
    final ends = _end.text.trim().isEmpty
        ? null
        : ChurchTime.parse(endDate, _end.text);
    final reporting = _reporting.text.trim().isEmpty
        ? null
        : ChurchTime.parse(_date.text, _reporting.text);
    if ((_end.text.trim().isNotEmpty &&
            (ends == null || !ends.isAfter(starts))) ||
        (_reporting.text.trim().isNotEmpty &&
            (reporting == null || reporting.isAfter(starts)))) {
      return null;
    }
    return CandidateQuery.window(
      departmentId: widget.department.departmentId,
      startsAt: starts,
      endsAt: ends,
      reportingAt: reporting,
    );
  }

  DutyDraft? _draft() {
    final member = _memberId;
    // Church time (Africa/Lusaka), whatever zone this computer uses.
    final starts = ChurchTime.parse(_date.text, _start.text);
    // Story 4.8: an empty answer-by time is the church default.
    final noDeadline =
        _deadlineDate.text.trim().isEmpty && _deadlineTime.text.trim().isEmpty;
    final deadline = noDeadline
        ? null
        : ChurchTime.parse(_deadlineDate.text, _deadlineTime.text);
    final endDate = _endDate.text.trim().isEmpty ? _date.text : _endDate.text;
    final ends = _end.text.trim().isEmpty
        ? null
        : ChurchTime.parse(endDate, _end.text);
    final reporting = _reporting.text.trim().isEmpty
        ? null
        : ChurchTime.parse(_date.text, _reporting.text);
    if (member == null ||
        _name.text.trim().isEmpty ||
        starts == null ||
        (!noDeadline && deadline == null) ||
        (_end.text.trim().isNotEmpty && ends == null) ||
        (_endDate.text.trim().isNotEmpty && _end.text.trim().isEmpty) ||
        (_reporting.text.trim().isNotEmpty && reporting == null)) {
      return null;
    }
    return DutyDraft(
      departmentId: widget.department.departmentId,
      dutyName: _name.text,
      startsAt: starts,
      endsAt: ends,
      reportingAt: reporting,
      location: _location.text,
      instructions: _instructions.text,
      memberId: member,
      responseDeadline: deadline,
      overrideReason: _reason.text,
      reminders: _chosenReminders(_customReminders, _reminders),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.department;
    final id = d.departmentId;
    final st = ref.watch(dutyLeaderProvider);
    // Only a publish refusal names this form's fields (not an edit's).
    final errors = st.noticeAction?.command == DutyCommands.publish
        ? st.fieldErrors
        : const <String, String>{};
    String? err(String wire) => switch (errors[wire]) {
      null => null,
      'required' => 'Required',
      'past' => 'This is in the past',
      'after_start' => 'Must be before the duty starts',
      'before_start' => 'Must be after the start',
      'not_in_department' => 'Not a member of this department',
      'overlap' => 'Has another duty at that time',
      _ => 'Check this',
    };
    Widget field(
      String key,
      TextEditingController c,
      String label, {
      String? wire,
      String? hint,
      int maxLength = 80,
      int maxLines = 1,
      FocusNode? focusNode,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key('$key-$id'),
        controller: c,
        focusNode: focusNode,
        enabled: !widget.busy,
        maxLength: maxLength,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: wire == null ? null : err(wire),
          // The limit still holds; only the long text shows its count.
          counterText: maxLength > 120 ? null : '',
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          'One person, one position. They are asked to accept or say they '
          'can\'t make it by the answer-by time. Times are church time '
          '(Lusaka), whatever this computer\'s clock is set to.',
        ),
        const SizedBox(height: 14),
        field(
          'publish-name',
          _name,
          'Duty',
          wire: 'duty_name',
          focusNode: widget.nameFocus,
        ),
        _BoardFieldPairs(
          pairs: [
            [
              field(
                'publish-date',
                _date,
                'Date',
                hint: 'YYYY-MM-DD',
                wire: 'starts_at',
                maxLength: 10,
              ),
              field(
                'publish-start',
                _start,
                'Start time',
                hint: 'HH:MM',
                maxLength: 5,
              ),
            ],
            [
              field(
                'publish-end',
                _end,
                'End time (optional)',
                hint: 'HH:MM',
                wire: 'ends_at',
                maxLength: 5,
              ),
              field(
                'publish-end-date',
                _endDate,
                'End date, if a later day (optional)',
                hint: 'YYYY-MM-DD',
                maxLength: 10,
              ),
            ],
            [
              field(
                'publish-reporting',
                _reporting,
                'Reporting time, if earlier (optional)',
                hint: 'HH:MM',
                wire: 'reporting_at',
                maxLength: 5,
              ),
              field(
                'publish-location',
                _location,
                'Location (optional)',
                wire: 'location',
                maxLength: 120,
              ),
            ],
          ],
        ),
        field(
          'publish-instructions',
          _instructions,
          'Instructions (optional)',
          wire: 'instructions',
          maxLength: 1000,
          maxLines: 3,
        ),
        ListenableBuilder(
          listenable: Listenable.merge([
            _date,
            _start,
            _end,
            _endDate,
            _reporting,
          ]),
          builder: (context, _) => _CandidatePicker(
            pickerKey: 'publish-member-$id',
            members: d.members,
            value: _memberId,
            query: _query(),
            reason: _reason,
            busy: widget.busy,
            reasonError: errors['override_reason'],
            onChanged: (v) => setState(() => _memberId = v),
          ),
        ),
        if (err('member_id') case final e?)
          Text(e, style: TextStyle(color: ChurchColors.of(context).redFg)),
        if (d.members.isEmpty)
          _muted(context, 'This department has no members yet.'),
        const SizedBox(height: 12),
        _BoardFieldPairs(
          pairs: [
            [
              field(
                'publish-deadline-date',
                _deadlineDate,
                'Answer by: date (optional)',
                hint: 'YYYY-MM-DD',
                wire: 'response_deadline',
                maxLength: 10,
              ),
              field(
                'publish-deadline-time',
                _deadlineTime,
                'Answer by: time (optional)',
                hint: 'HH:MM',
                maxLength: 5,
              ),
            ],
          ],
        ),
        _muted(context, _defaultDeadlineHelp),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: _reporting,
          builder: (context, _) => _ReminderChoice(
            keyPrefix: 'publish-$id',
            custom: _customReminders,
            selected: _reminders,
            enabled: !widget.busy,
            error: errors['reminders'],
            reporting: _reporting.text.trim().isNotEmpty,
            onCustom: (v) => setState(() => _customReminders = v),
            onToggle: (c, on) =>
                setState(() => on ? _reminders.add(c) : _reminders.remove(c)),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ListenableBuilder(
            listenable: Listenable.merge(_all),
            builder: (context, _) {
              final draft = _draft();
              return FocusRing(
                child: FilledButton(
                  key: Key('publish-save-$id'),
                  onPressed: widget.busy || draft == null
                      ? null
                      : () => ref
                            .read(dutyLeaderProvider.notifier)
                            .publish(draft, draft.dutyName.trim()),
                  child: const Text('Publish'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile: the member's duties
// ---------------------------------------------------------------------------

/// Story 4.5: the member's answer as they and their leader read it ("Can't
/// make it anymore" after an earlier acceptance).
(String, StatusTone) _answerLabel(DutyResponse r, DateTime? priorAcceptedAt) =>
    r == DutyResponse.declined && priorAcceptedAt != null
    ? ('Can\'t make it anymore', StatusTone.warning)
    : _responseLabel(r);

/// When a member's duty is, in one phrase: "Due 30 Nov" for a special
/// assignment with a due date (never a time), otherwise the date and time.
String _dutyWhen(BuildContext context, MyDuty a) => switch (a.times.dueOn) {
  final d? => DutySpecial.dueText(d),
  null => _when(context, a.times.arriveBy),
};

/// A My duties row's subline: who gave it and when to be there ("Ushering ·
/// Report 08:30", "Special assignment · 10:00", "Special assignment · Due 30
/// Nov").
String _dutySubline(BuildContext context, MyDuty a) => [
  a.ownerLabel,
  if (a.times.dueOn case final d?)
    DutySpecial.dueText(d)
  else if (a.times.reportingAt case final r?)
    'Report ${_clock(context, r)}'
  else
    _clock(context, a.times.startsAt),
].join(' · ');

/// The handoff's date badge (weekday, day, month) in church time.
class _DateBadge extends StatelessWidget {
  const _DateBadge({required this.at});
  final DateTime at;

  @override
  Widget build(BuildContext context) => ChurchDateBadge(at: at);
}

/// Story 4.1, mobile: the member's duties across departments. Story 4.5:
/// segments (Needs a response, Upcoming, Past), a detail screen with a
/// sticky answer footer, Can't make it (anymore) through a sheet with an
/// optional practical note, accepting several listed dates together after a
/// confirmation, and Add to calendar. Answers show as done only after the
/// server confirmed them.
class MyDutiesScreen extends StatelessWidget {
  const MyDutiesScreen({super.key, this.assignmentId});

  /// Set when opened from a reminder or the list (`/duties/assignments/<id>`):
  /// only that duty is shown, in full.
  final String? assignmentId;

  @override
  Widget build(BuildContext context) => _DutiesPage<MyDuties>(
    title: assignmentId == null ? 'My duties' : 'Duty',
    provider: myDutiesProvider,
    needs: 'Your duties are shown once you have member access.',
    loading: 'Loading your duties…',
    body: (context, v, s) => assignmentId == null
        ? _MyDutiesList(
            key: const ValueKey('my-duties-list'),
            duties: v,
            busy: s.busy,
          )
        : _OneDuty(
            key: const ValueKey('my-duty-detail'),
            duties: v,
            assignmentId: assignmentId!,
            busy: s.busy,
          ),
    footer: assignmentId == null
        ? null
        : (context, v, s) => switch (v.findCurrent(assignmentId)) {
            final d? => _DutyFooter(duty: d, busy: s.busy),
            null => null,
          },
  );
}

enum _Segment { needs, upcoming, past }

class _MyDutiesList extends ConsumerStatefulWidget {
  const _MyDutiesList({super.key, required this.duties, required this.busy});
  final MyDuties duties;
  final bool busy;

  @override
  ConsumerState<_MyDutiesList> createState() => _MyDutiesListState();
}

class _MyDutiesListState extends ConsumerState<_MyDutiesList> {
  _Segment? _chosen;
  final _selected = <String>{};

  // Only dates that still need an answer stay selected: an answered or
  // changed date drops out once the list is read again.
  @override
  void didUpdateWidget(covariant _MyDutiesList old) {
    super.didUpdateWidget(old);
    final now = DateTime.now();
    final open = {
      for (final d in widget.duties.assignments)
        if (d.needsResponse(now)) d.assignmentId,
    };
    _selected.retainWhere(open.contains);
  }

  Future<void> _confirmBulk(List<MyDuty> chosen) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ChurchDialog(
        title:
            'Accept ${chosen.length} '
            '${chosen.length == 1 ? 'duty' : 'duties'}?',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('You are accepting these dates:'),
            const SizedBox(height: 8),
            for (final d in chosen)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${_dutyWhen(context, d)}: ${d.title} '
                  '(${d.ownerLabel})',
                  key: Key('bulk-date-${d.assignmentId}'),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'If any of them changed since you opened this list, nothing '
              'is accepted and the list is shown again.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Notes are not sent when accepting several dates. To add a '
              'note, accept that date on its own.',
              key: Key('duties-bulk-no-note'),
            ),
          ],
        ),
        actions: [
          FocusRing(
            child: TextButton(
              key: const Key('duties-bulk-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          FocusRing(
            child: FilledButton(
              key: const Key('duties-bulk-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'Accept ${chosen.length} '
                '${chosen.length == 1 ? 'duty' : 'duties'}',
              ),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(myDutiesProvider.notifier).acceptMany(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seg = MyDutySegments.of(widget.duties.assignments, DateTime.now());
    if (seg.needsResponse.isEmpty && seg.upcoming.isEmpty && seg.past.isEmpty) {
      return const Text(
        'You have no upcoming duties.',
        key: Key('my-duties-empty'),
      );
    }
    final current =
        _chosen ??
        (seg.needsResponse.isNotEmpty ? _Segment.needs : _Segment.upcoming);
    final chosen = [
      for (final d in seg.needsResponse)
        if (_selected.contains(d.assignmentId)) d,
    ];
    final list = switch (current) {
      _Segment.needs => seg.needsResponse,
      _Segment.upcoming => seg.upcoming,
      _Segment.past => seg.past,
    };
    final selectable =
        current == _Segment.needs && seg.needsResponse.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.duties.truncated)
          const Text(
            'Only your next 200 duties are shown.',
            key: Key('my-duties-truncated'),
          ),
        // Story 4.11 (review S2): rows this version cannot read are left out.
        if (widget.duties.skipped > 0)
          const Text(
            'Some of your duties cannot be shown in this version of the app. '
            'Update the app to see them.',
            key: Key('my-duties-skipped'),
          ),
        RadioSegments<_Segment>(
          key: const Key('my-duties-segments'),
          label: 'Show',
          options: [
            SegmentOption(
              _Segment.needs,
              'Needs a response (${seg.needsResponse.length})',
            ),
            SegmentOption(
              _Segment.upcoming,
              'Upcoming (${seg.upcoming.length})',
            ),
            SegmentOption(_Segment.past, 'Past (${seg.past.length})'),
          ],
          selected: current,
          onChanged: (v) => setState(() => _chosen = v),
        ),
        const SizedBox(height: 12),
        if (selectable) ...[
          _muted(
            context,
            'Select the dates you can do, then accept them together.',
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: FilledButton.icon(
                key: const Key('duties-accept-selected'),
                onPressed:
                    widget.busy ||
                        chosen.isEmpty ||
                        chosen.length > DutyCommands.maxBulk
                    ? null
                    : () => _confirmBulk(chosen),
                icon: const Icon(Icons.done_all),
                label: Text('Accept selected (${chosen.length})'),
              ),
            ),
          ),
          if (chosen.length > DutyCommands.maxBulk)
            _muted(
              context,
              'Select at most ${DutyCommands.maxBulk} dates at a time.',
            ),
          const SizedBox(height: 12),
        ],
        ChurchCard(
          padding: EdgeInsets.zero,
          child: list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    switch (current) {
                      _Segment.needs => 'Nothing waiting for your response.',
                      _Segment.upcoming => 'You have no upcoming duties.',
                      _Segment.past => 'No past duties yet.',
                    },
                    key: Key('my-duties-empty-${current.name}'),
                    style: ChurchType.body.copyWith(
                      color: ChurchColors.of(context).muted,
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, a) in list.indexed) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          indent: 78,
                          color: ChurchColors.of(context).line,
                        ),
                      _DutyCard(
                        duty: a,
                        busy: widget.busy,
                        full: false,
                        selected: selectable
                            ? _selected.contains(a.assignmentId)
                            : null,
                        onSelected: selectable
                            ? (v) => setState(() {
                                if (v) {
                                  _selected.add(a.assignmentId);
                                } else {
                                  _selected.remove(a.assignmentId);
                                }
                              })
                            : null,
                      ),
                    ],
                  ],
                ),
        ),
        // Story 4.10: the member's own assignment history, under the list.
        const SizedBox(height: 16),
        ChurchCard(
          padding: EdgeInsets.zero,
          child: MenuRow(
            key: const Key('my-duties-history'),
            label: 'My duty history',
            meta: 'All past duties',
            showDivider: false,
            onTap: () => context.go(DutyPaths.history),
          ),
        ),
      ],
    );
  }
}

class _OneDuty extends StatelessWidget {
  const _OneDuty({
    super.key,
    required this.duties,
    required this.assignmentId,
    required this.busy,
  });
  final MyDuties duties;
  final String assignmentId;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final duty = duties.findCurrent(assignmentId);
    if (duty == null) {
      return const RequestStateBanner(
        key: Key('duty-not-available'),
        tone: StatusTone.neutral,
        title: 'Not available',
        message:
            'This duty is no longer yours or no longer current. Your current '
            'duties are under My duties.',
      );
    }
    if (duty.assignmentId != assignmentId) {
      // Story 4.2: an old reminder or link for an earlier version.
      final needs = duty.needsResponse(DateTime.now());
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RequestStateBanner(
            key: const Key('duty-was-changed'),
            tone: StatusTone.info,
            title: 'This duty changed',
            message: needs
                ? 'It changed since that message. This is the current '
                      'version; your answer is needed for it.'
                : 'It changed since that message. This is the current '
                      'version.',
          ),
          const SizedBox(height: 12),
          _DutyCard(duty: duty, busy: busy, full: true),
        ],
      );
    }
    return _DutyCard(duty: duty, busy: busy, full: true);
  }
}

/// Story 4.5: is a command for [a] in flight, or sent with an unknown
/// outcome while the server still shows [a] as that command found it? Once
/// a read shows the duty answered (the server did record it) or changed,
/// the server's state wins over Not sent.
(bool sending, bool unsent) _commandState(WidgetRef ref, MyDuty a) => (
  ref.watch(
    myDutiesProvider.select((s) => s.pending?.touches(a.assignmentId) ?? false),
  ),
  ref.watch(
    myDutiesProvider.select(
      (s) => switch (s.unconfirmed) {
        final u? => MyDutiesController.awaits(u, a),
        null => false,
      },
    ),
  ),
);

/// The status a member reads: Sending… while a command for this duty is
/// out, Not sent while its outcome is unknown and the duty still waits for
/// it, otherwise the server's.
(String, StatusTone) _shownStatus(MyDuty a, bool sending, bool unsent) =>
    sending
    ? ('Sending…', StatusTone.info)
    : unsent
    ? ('Not sent', StatusTone.warning)
    // Story 4.9: an acceptance a leader recorded after a call or in person.
    : a.confirmedByLeader && a.response == DutyResponse.accepted
    ? (
        a.isSpecial ? 'Confirmed by the Pastor' : 'Confirmed by your leader',
        StatusTone.success,
      )
    : _answerLabel(a.response, a.priorAcceptedAt);

/// Story 4.5: Can't make it (a pending duty) or Can't make it anymore (an
/// accepted one): a sheet with an optional practical note and Cancel. The
/// command goes only when the member confirms.
Future<void> _showDeclineSheet(
  BuildContext context,
  WidgetRef ref,
  MyDuty duty,
) async {
  final later = duty.response == DutyResponse.accepted;
  // A note already typed on the card carries into Can't make it.
  final draft = later
      ? null
      : ref.read(dutyAnswerNotesProvider)[duty.assignmentId];
  final note = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _DeclineSheet(duty: duty, later: later, initialNote: draft),
  );
  if (note == null) return;
  final ctl = ref.read(myDutiesProvider.notifier);
  if (later) {
    await ctl.withdraw(duty, note: note);
  } else {
    await ctl.respond(duty, DutyResponse.declined, note: note);
  }
}

class _DeclineSheet extends StatefulWidget {
  const _DeclineSheet({
    required this.duty,
    required this.later,
    this.initialNote,
  });
  final MyDuty duty;
  final bool later;
  final String? initialNote;

  @override
  State<_DeclineSheet> createState() => _DeclineSheetState();
}

class _DeclineSheetState extends State<_DeclineSheet> {
  late final _note = TextEditingController(text: widget.initialNote ?? '');

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.duty;
    final title = widget.later ? 'Can\'t make it anymore?' : 'Can\'t make it?';
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading(context, title),
              Text('${d.title}, ${_dutyWhen(context, d)}'),
              const SizedBox(height: 8),
              Text(
                // Special assignments: the Pastor finds someone else.
                d.isSpecial
                    ? (widget.later
                          ? 'You accepted this. The Pastor sees at once that it '
                                'needs someone else.'
                          : 'The Pastor sees at once that it needs someone '
                                'else.')
                    : widget.later
                    ? 'You accepted this duty. Your leader sees at once that '
                          'this position needs cover again.'
                    : 'Your leader sees at once that this position needs '
                          'cover.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('decline-note'),
                controller: _note,
                maxLength: 280,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: 'Note for ${d.answersTo} (optional)',
                  helperText:
                      'Practical details only, for example "travelling '
                      'that weekend".',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FocusRing(
                    child: TextButton(
                      key: const Key('decline-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  FocusRing(
                    child: FilledButton(
                      key: const Key('decline-confirm'),
                      onPressed: () =>
                          Navigator.of(context).pop(_note.text.trim()),
                      child: Text(
                        widget.later
                            ? 'Send: can\'t make it anymore'
                            : 'Send: can\'t make it',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Story 4.5: the detail screen's sticky answer footer: Accept and Can't
/// make it while an answer is needed; Can't make it anymore after accepting
/// (until the duty starts); nothing otherwise.
class _DutyFooter extends ConsumerWidget {
  const _DutyFooter({required this.duty, required this.busy});
  final MyDuty duty;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final now = DateTime.now();
    final id = duty.assignmentId;
    final Widget? content;
    if (duty.needsResponse(now)) {
      content = Row(
        children: [
          Expanded(
            child: FocusRing(
              child: OutlinedButton(
                key: Key('duty-decline-$id'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                onPressed: busy
                    ? null
                    : () => _showDeclineSheet(context, ref, duty),
                child: const Text('Can\'t make it'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FocusRing(
              child: FilledButton(
                key: Key('duty-accept-$id'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                onPressed: busy
                    ? null
                    : () => ref
                          .read(myDutiesProvider.notifier)
                          .respond(
                            duty,
                            DutyResponse.accepted,
                            note: ref.read(dutyAnswerNotesProvider)[id],
                          ),
                child: const Text('Accept'),
              ),
            ),
          ),
        ],
      );
    } else if (duty.canWithdraw(now)) {
      content = Row(
        children: [
          Expanded(
            child: Text(
              'You accepted this duty',
              style: ChurchType.body.copyWith(
                color: c.greenFg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FocusRing(
            child: TextButton(
              key: Key('duty-withdraw-$id'),
              style: TextButton.styleFrom(foregroundColor: c.redFg),
              onPressed: busy
                  ? null
                  : () => _showDeclineSheet(context, ref, duty),
              child: const Text('Can\'t make it anymore'),
            ),
          ),
        ],
      );
    } else {
      content = null;
    }
    if (content == null) return const SizedBox.shrink();
    return KeyedSubtree(
      key: const Key('duty-footer'),
      child: BottomActionBar(child: content),
    );
  }
}

class _DutyCard extends ConsumerStatefulWidget {
  const _DutyCard({
    required this.duty,
    required this.busy,
    required this.full,
    this.selected,
    this.onSelected,
  });
  final MyDuty duty;
  final bool busy;

  /// Show every detail (the detail screen); the list shows a summary.
  final bool full;

  /// Story 4.5: selection for accepting several dates together (null: not
  /// selectable here).
  final bool? selected;
  final ValueChanged<bool>? onSelected;

  @override
  ConsumerState<_DutyCard> createState() => _DutyCardState();
}

class _DutyCardState extends ConsumerState<_DutyCard> {
  CalendarHandoff? _calendar;
  bool _exporting = false;

  // The optional note for Accept (shared with the detail footer).
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(
      text: ref.read(dutyAnswerNotesProvider)[widget.duty.assignmentId] ?? '',
    );
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _addToCalendar(MyDuty a, BuildContext button) async {
    // The share sheet points at the button (an iPad popover needs it).
    final box = button.findRenderObject();
    ShareOrigin? origin;
    if (box is RenderBox && box.hasSize) {
      final o = box.localToGlobal(Offset.zero);
      origin = ShareOrigin(o.dx, o.dy, box.size.width, box.size.height);
    }
    setState(() => _exporting = true);
    final result = await ref
        .read(dutyCalendarExportProvider)
        .export(
          fileName: DutyCalendar.fileName(a),
          ics: DutyCalendar.ics(a, now: DateTime.now()),
          origin: origin,
        );
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _calendar = result;
    });
    announce(context, _calendarText(result));
  }

  static String _calendarText(CalendarHandoff r) => switch (r) {
    CalendarHandoff.shared =>
      'Calendar file shared. Check the calendar app you chose; this copy '
          'won\'t update if the duty changes.',
    CalendarHandoff.handedOver =>
      'Calendar file handed to your phone. We can\'t tell whether it was '
          'saved; this copy won\'t update if the duty changes.',
    CalendarHandoff.dismissed => 'Not added: the share sheet was closed.',
    CalendarHandoff.unavailable =>
      'Add to calendar isn\'t available in this version of the app.',
    CalendarHandoff.failed =>
      'Couldn\'t hand over the calendar file. Try again.',
  };

  @override
  Widget build(BuildContext context) =>
      widget.full ? _detail(context) : _summary(context);

  /// The chips under a duty: the answer as the member reads it, and Short
  /// notice when it was given late.
  Widget _status(BuildContext context, MyDuty a, DateTime now) {
    final (sending, unsent) = _commandState(ref, a);
    final (shown, shownTone) = _shownStatus(a, sending, unsent);
    final id = a.assignmentId;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        StatusLabel(
          key: Key('my-duty-status-$id'),
          label: shown,
          tone: shownTone,
        ),
        // Story 4.8: given at short notice, the member is asked to answer
        // now (the answer-by time is when it was given).
        if (a.answerNow(now))
          StatusLabel(
            key: Key('duty-short-notice-$id'),
            label: 'Short notice: please answer now',
            tone: StatusTone.warning,
          ),
      ],
    );
  }

  /// "Ushering · Report 08:30" (the handoff's subline); "Special assignment
  /// · Due 30 Nov" for a due date.
  String _subline(BuildContext context, MyDuty a) => _dutySubline(context, a);

  /// What changed since the member last answered (story 4.2).
  List<Widget> _changes(BuildContext context, MyDuty a) {
    final id = a.assignmentId;
    final c = ChurchColors.of(context);
    return [
      if (a.changes case final ch?)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusLabel(
              key: Key('duty-changed-$id'),
              label: 'Changed',
              tone: StatusTone.info,
            ),
            Text(
              'What changed: ${DutyFields.describe(ch)}.',
              style: ChurchType.secondary.copyWith(color: c.ink),
            ),
          ],
        ),
      if (a.changes != null)
        if (a.previousResponse case final p? when p != DutyResponse.pending)
          _muted(
            context,
            'Your earlier answer was "${_responseLabel(p).$1}". '
                    '${a.response == DutyResponse.pending ? 'Please answer again.' : ''}'
                .trim(),
          ),
      if (a.notesUpdatedAt case final u?)
        _muted(
          context,
          'Details updated ${_when(context, u)}. Your answer stands.',
        ),
    ];
  }

  /// One row of My duties: date badge, the duty, department and report
  /// time, the place, its answer. A duty that needs an answer says by when
  /// (or what changed) and carries Accept and Can't make it on the row. The
  /// rest (topic, instructions, notes, outcome) is on the duty itself; the
  /// row opens it.
  Widget _summary(BuildContext context) {
    final c = ChurchColors.of(context);
    final a = widget.duty;
    final id = a.assignmentId;
    final now = DateTime.now();
    final canAnswer = a.needsResponse(now);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    // What the member most needs to know next, in one line.
    final String? hint = switch (a) {
      _ when a.changes != null && a.response == DutyResponse.pending =>
        'Changed: ${DutyFields.describe(a.changes!)}. Please answer again.',
      _ when a.changes != null =>
        'Changed: ${DutyFields.describe(a.changes!)}.',
      _ when a.response == DutyResponse.pending && !a.answerNow(now) =>
        'Answer by ${_when(context, a.responseDeadline)}',
      _ => null,
    };
    return Column(
      key: Key('my-duty-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: Key('duty-open-$id'),
          onTap: () => context.push(DutyPaths.assignment(id)),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, canAnswer ? 12 : 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.selected case final sel?)
                  Semantics(
                    label: 'Select ${a.title}, ${_dutyWhen(context, a)}',
                    child: Checkbox(
                      key: Key('duty-select-$id'),
                      value: sel,
                      onChanged: widget.busy
                          ? null
                          : (v) => widget.onSelected?.call(v ?? false),
                    ),
                  ),
                _DateBadge(at: a.times.arriveBy),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ChurchType.itemTitle.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subline(context, a),
                        key: Key('duty-owner-$id'),
                        style: muted,
                      ),
                      if (a.location case final l?)
                        Text(
                          l,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      const SizedBox(height: 8),
                      _status(context, a, now),
                      if (hint != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          hint,
                          key: a.changes != null
                              ? Key('duty-changed-$id')
                              : null,
                          style: ChurchType.secondary.copyWith(
                            color:
                                a.changes != null &&
                                    a.response == DutyResponse.pending
                                ? c.amberFg
                                : c.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (canAnswer)
          Padding(
            padding: const EdgeInsets.fromLTRB(78, 0, 16, 16),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                FocusRing(
                  child: FilledButton(
                    key: Key('duty-accept-$id'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                    onPressed: widget.busy
                        ? null
                        : () => ref
                              .read(myDutiesProvider.notifier)
                              .respond(
                                a,
                                DutyResponse.accepted,
                                note: ref.read(dutyAnswerNotesProvider)[id],
                              ),
                    child: const Text('Accept'),
                  ),
                ),
                FocusRing(
                  child: TextButton(
                    key: Key('duty-decline-$id'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      foregroundColor: c.ink,
                    ),
                    onPressed: widget.busy
                        ? null
                        : () => _showDeclineSheet(context, ref, a),
                    child: const Text('Can\'t make it'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// The detail screen (handoff "Duty"): chip, title, department; a table
  /// (date, report at, time, location, topic, scripture, respond by);
  /// instructions; the leader; Add to calendar. Answers are in the footer.
  Widget _detail(BuildContext context) {
    final c = ChurchColors.of(context);
    final a = widget.duty;
    final id = a.assignmentId;
    final now = DateTime.now();
    final canAnswer = a.needsResponse(now);
    final loc = MaterialLocalizations.of(context);
    final t = a.times;
    final rows = <DetailRow>[
      // Special assignments: a "done by" assignment has a due date, no time.
      if (t.dueOn case final d?)
        (label: 'Due', value: loc.formatFullDate(d))
      else ...[
        (label: 'Date', value: loc.formatFullDate(ChurchTime.wall(t.arriveBy))),
        if (t.reportingAt case final r?)
          (label: 'Report at', value: _clock(context, r)),
        (
          label: 'Time',
          value: t.endsAt == null
              ? _clock(context, t.startsAt)
              : '${_clock(context, t.startsAt)}–${_clock(context, t.endsAt!)}',
        ),
      ],
      if (a.location case final l?) (label: 'Location', value: l),
      if (a.topic case final tp?) (label: 'Topic', value: tp),
      if (a.scripture case final sc?) (label: 'Scripture', value: sc),
      if (a.response == DutyResponse.pending)
        (label: 'Respond by', value: _when(context, a.responseDeadline)),
    ];
    return Column(
      key: Key('my-duty-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: _status(context, a, now),
        ),
        const SizedBox(height: 6),
        Semantics(
          header: true,
          child: Text(
            a.title,
            style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          a.ownerLabel,
          key: Key('duty-owner-$id'),
          style: ChurchType.body.copyWith(color: c.muted),
        ),
        const SizedBox(height: 16),
        ..._changes(context, a),
        if (a.changes != null || a.notesUpdatedAt != null)
          const SizedBox(height: 12),
        DetailTable(rows: rows),
        // Story 6.12: the published event the duty is linked to.
        if (a.eventRef case final ev?)
          _DutyLinkedEvent(assignmentId: id, eventId: ev),
        if (a.instructions case final i?) ...[
          const SizedBox(height: 12),
          const CardLabel('Instructions'),
          const SizedBox(height: 6),
          Text(i, key: Key('duty-instructions-$id')),
        ],
        if (a.note case final n?) ...[
          const SizedBox(height: 12),
          Text('Your note: $n'),
        ],
        if (a.declinedLater) ...[
          const SizedBox(height: 8),
          _muted(
            context,
            'You had accepted on ${_when(context, a.priorAcceptedAt!)}, then '
            'told ${a.answersTo} you can\'t make it.',
          ),
        ],
        // Story 4.10: what your leader recorded after the duty (never assumed
        // from the time).
        if (a.outcome case final o?) ...[
          const SizedBox(height: 8),
          _OutcomeLines(record: o, keyPrefix: 'my-duty-outcome-$id'),
        ] else if (!t.arriveBy.isAfter(now) &&
            a.response != DutyResponse.declined) ...[
          const SizedBox(height: 8),
          _muted(context, 'Outcome: not recorded yet.'),
        ],
        // Story 4.8: the reminders this duty sends.
        if (a.response != DutyResponse.declined)
          if (a.reminders case final r?) ...[
            const SizedBox(height: 8),
            _muted(
              context,
              '${r.textFor(reporting: t.reportingAt != null, due: t.isDue)} '
              'You can snooze a reminder from the Inbox.',
            ),
          ],
        if (canAnswer) ...[
          const SizedBox(height: 12),
          TextField(
            key: Key('duty-note-$id'),
            controller: _note,
            enabled: !widget.busy,
            maxLength: 280,
            onChanged: (v) =>
                ref.read(dutyAnswerNotesProvider.notifier).set(id, v),
            decoration: InputDecoration(
              labelText: 'Note for ${a.answersTo} (optional)',
              helperText: 'Sent with Accept or Can\'t make it.',
            ),
          ),
        ],
        if (a.leaders.isNotEmpty) ...[
          const SizedBox(height: 12),
          ChurchCard(
            key: Key('duty-leaders-$id'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in a.leaders)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        InitialsAvatar(name: l.displayName),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.displayName,
                                style: ChurchType.body.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                l.roleLabel,
                                style: ChurchType.secondary.copyWith(
                                  color: c.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                _muted(
                  context,
                  'Contact ${a.answersTo} through the church if you have '
                  'questions.',
                ),
              ],
            ),
          ),
        ],
        if (!a.startedAt(now) && a.response != DutyResponse.declined) ...[
          const SizedBox(height: 12),
          FocusRing(
            child: Builder(
              builder: (button) => OutlinedButton.icon(
                key: Key('duty-calendar-$id'),
                onPressed: _exporting ? null : () => _addToCalendar(a, button),
                icon: const Icon(Icons.event_outlined),
                label: const Text('Add to calendar'),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(child: _muted(context, DutyCalendar.staleCaveat)),
          if (_calendar case final r?)
            Text(_calendarText(r), key: Key('duty-calendar-result-$id')),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Story 4.5: the Home My duties card (Home itself is home_screen.dart)
// ---------------------------------------------------------------------------

/// Story 4.5: the navy My duties card: how many duties await an answer, the
/// next one (date, duty, department, report time, place) with inline Accept
/// and Can't make it, and See all. A failed read never looks empty.
class MyDutiesHomeCard extends ConsumerStatefulWidget {
  const MyDutiesHomeCard({super.key});

  @override
  ConsumerState<MyDutiesHomeCard> createState() => _MyDutiesHomeCardState();
}

class _MyDutiesHomeCardState extends ConsumerState<MyDutiesHomeCard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    if (ref.read(myDutiesProvider).result != null) Future.microtask(_reload);
  }

  void _reload() {
    final s = ref.read(myDutiesProvider);
    if (mounted && !s.busy && !s.loading) {
      ref.read(myDutiesProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(myDutiesProvider);
    final ctl = ref.read(myDutiesProvider.notifier);
    const on = Colors.white;
    final soft = Colors.white.withValues(alpha: 0.78);
    final text = ChurchType.body.copyWith(color: on);
    Widget? pill;
    // The seal behind the card: wide while something waits for an answer,
    // in the corner otherwise (owner's choice).
    var mark = HeroWatermark.corner;
    final body = <Widget>[];
    if (s.notice case final n? when s.pending == null) {
      final (_, title, message) = _noticeText(n, s.noticeAction, s.fieldErrors);
      body.addAll([
        Text(
          '$title. $message',
          key: Key('home-duties-notice-${n.name}'),
          style: text,
        ),
        Wrap(
          spacing: 8,
          children: [
            if (n == DutyNotice.unconfirmed)
              TextButton(
                key: const Key('home-duties-check-again'),
                style: TextButton.styleFrom(foregroundColor: on),
                onPressed: ctl.checkAgain,
                child: const Text('Check again'),
              ),
            TextButton(
              key: const Key('home-duties-dismiss'),
              style: TextButton.styleFrom(foregroundColor: on),
              onPressed: ctl.dismissNotice,
              child: const Text('Dismiss'),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ]);
    }
    switch (s.result) {
      case null:
        body.add(
          Text(
            'Loading your duties…',
            key: const Key('home-duties-loading'),
            style: text.copyWith(color: soft),
          ),
        );
      case AccessReadDenied():
        body.add(
          Text(
            'Your duties are shown once you have member access.',
            key: const Key('home-duties-denied'),
            style: text,
          ),
        );
      case AccessReadFailed(:final unreachable):
        body.add(
          Text(
            unreachable
                ? 'No connection: we couldn\'t reach the church server. This '
                      'is not an empty list.'
                : 'Couldn\'t load your duties. Try again later.',
            key: const Key('home-duties-failed'),
            style: text,
          ),
        );
      case AccessReadOk(:final value):
        final seg = MyDutySegments.of(value.assignments, DateTime.now());
        final next = seg.next;
        final awaiting = seg.needsResponse.length;
        if (awaiting > 0) mark = HeroWatermark.wide;
        // Handoff: the count is an amber pill in the header; with nothing
        // waiting, a quiet line says so.
        final awaitingText = Text(
          awaiting == 0
              ? 'Nothing waiting for your response.'
              : '$awaiting awaiting your response',
          key: const Key('home-duties-awaiting'),
          style: awaiting == 0
              ? ChurchType.secondary.copyWith(color: soft)
              : ChurchType.secondary.copyWith(
                  color: const Color(0xFF3D2A00),
                  fontWeight: FontWeight.w700,
                ),
        );
        if (awaiting == 0) {
          body.add(awaitingText);
        } else {
          pill = Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFFFC94D),
              borderRadius: BorderRadius.circular(99),
            ),
            child: awaitingText,
          );
        }
        if (next == null) {
          body.add(
            Text(
              'You have no upcoming duties.',
              key: const Key('home-duties-empty'),
              style: text,
            ),
          );
        } else {
          final (sending, unsent) = _commandState(ref, next);
          final (shown, tone) = _shownStatus(next, sending, unsent);
          final id = next.assignmentId;
          final t = next.times;
          body.addAll([
            if (awaiting == 0) const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChurchDateBadge(at: t.arriveBy, tone: DateBadgeTone.hero),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        next.title,
                        key: Key('home-duty-$id'),
                        style: ChurchType.itemTitle.copyWith(color: on),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _dutySubline(context, next),
                        style: ChurchType.secondary.copyWith(color: soft),
                      ),
                      if (next.location case final l?)
                        Text(
                          l,
                          style: ChurchType.secondary.copyWith(color: soft),
                        ),
                      const SizedBox(height: 8),
                      StatusLabel(
                        key: Key('home-duty-status-$id'),
                        label: shown,
                        tone: tone,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (next.needsResponse(DateTime.now())) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FocusRing(
                      child: FilledButton(
                        key: Key('home-duty-accept-$id'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: c.hero,
                          minimumSize: const Size(0, 46),
                        ),
                        onPressed: s.busy
                            ? null
                            : () => ctl.respond(next, DutyResponse.accepted),
                        child: const Text('Accept'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FocusRing(
                      child: OutlinedButton(
                        key: Key('home-duty-decline-$id'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: on,
                          minimumSize: const Size(0, 46),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.5),
                            width: 1.5,
                          ),
                        ),
                        onPressed: s.busy
                            ? null
                            : () => _showDeclineSheet(context, ref, next),
                        child: const Text('Can\'t make it'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ]);
        }
    }
    return KeyedSubtree(
      key: const Key('home-duties-card'),
      child: HeroCard(
        watermark: mark,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The pill moves under the title when both don't fit (large text).
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'My duties',
                      style: ChurchType.cardTitle.copyWith(color: on),
                    ),
                  ),
                  ?pill,
                ],
              ),
            ),
            const SizedBox(height: 14),
            ...body,
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FocusRing(
                child: TextButton(
                  key: const Key('home-duties-see-all'),
                  style: TextButton.styleFrom(
                    foregroundColor: on,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => context.push(DutyPaths.mine),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text('See all my duties')),
                      SizedBox(width: 4),
                      Icon(Icons.arrow_forward, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Story 4.4: the assignment picker with each person's load and overlaps
// ---------------------------------------------------------------------------

/// The busy time of a conflict in church time ("18 Oct 2026 10:00 to 12:00").
String _spanText(BuildContext context, DateTime from, DateTime to) {
  final a = ChurchTime.wall(from), b = ChurchTime.wall(to);
  final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
  return '${_when(context, from)} to '
      '${sameDay ? _clock(context, to) : _when(context, to)}';
}

/// One overlapping duty, saying only what the server disclosed: another
/// team's duty is a busy time, never its name, place or instructions.
String _conflictText(BuildContext context, DutyConflict c) {
  final span = _spanText(context, c.from, c.to);
  if (!c.full) return '${c.ownerLabel}, $span';
  final what = c.positionName == null
      ? c.dutyName
      : '${c.dutyName} (${c.positionName})';
  return [
    '${c.ownerLabel}: $what',
    span,
    if (c.location case final l?) 'at $l',
    if (c.isDraft)
      'planned, not published'
    else if (c.response case final r?)
      r.label,
  ].join(', ');
}

/// A recorded override, for the department's readers (never the member).
String _overrideText(BuildContext context, DutyOverride o) =>
    'Assigned despite an overlap'
    '${o.reason == null ? '' : ': "${o.reason}"'}'
    '${o.by == null ? '' : ' (${o.by}, ${_when(context, o.at)})'}';

/// Who takes a position: the department's members with their upcoming load
/// and, for the chosen person, the overlapping duties the leader may see.
/// When the person has another duty at that time (or the server refused for
/// it), the leader must say why they are assigned anyway; the person still
/// chooses whether to accept. No overlap found never means "free". A new
/// query (times being typed) is read after a 400 ms pause.
class _CandidatePicker extends ConsumerStatefulWidget {
  const _CandidatePicker({
    required this.pickerKey,
    required this.members,
    required this.value,
    required this.onChanged,
    required this.reason,
    required this.busy,
    this.query,
    this.allowNobody = false,
    this.reasonError,
  });

  /// The dropdown's key; the reason field and warning use it as a prefix.
  final String pickerKey;
  final List<DepartmentMember> members;
  final String? value;
  final ValueChanged<String?> onChanged;
  final TextEditingController reason;
  final bool busy;

  /// Null while the times cannot be read (no check yet).
  final CandidateQuery? query;
  final bool allowNobody;

  /// The server's code for `override_reason` from the last refusal.
  final String? reasonError;

  @override
  ConsumerState<_CandidatePicker> createState() => _CandidatePickerState();
}

class _CandidatePickerState extends ConsumerState<_CandidatePicker> {
  late CandidateQuery? _query = widget.query;
  Timer? _debounce;

  @override
  void didUpdateWidget(_CandidatePicker old) {
    super.didUpdateWidget(old);
    if (widget.query == old.query) return;
    _debounce?.cancel();
    if (widget.query == null) {
      _query = null;
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _query = widget.query);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pickerKey = widget.pickerKey;
    final members = widget.members;
    final value = widget.value;
    final reason = widget.reason;
    final busy = widget.busy;
    final reasonError = widget.reasonError;
    final q = _query;
    final read = q == null ? null : ref.watch(dutyCandidatesProvider(q));
    final checks = switch (read) {
      AsyncData(value: AccessReadOk(:final value)) => value,
      _ => null,
    };
    final failed = switch (read) {
      AsyncError() => true,
      AsyncData(value: AccessReadOk()) => false,
      AsyncData() => true,
      _ => false,
    };
    final chosen = checks?.of(value);
    final overlapping = chosen?.overlaps ?? false;
    String name(DepartmentMember m) => m.account == AccountStanding.noLogin
        ? '${m.displayName} (no login: contact them directly)'
        : m.displayName;
    // The load and overlap count stay on their own line (never cut off by
    // the name) and in the item's screen-reader label.
    String? load(DepartmentMember m) => switch (checks?.of(m.memberId)) {
      null => null,
      final c =>
        '${c.loadLabel}'
            '${c.overlaps ? ', overlaps ${c.conflictCount} at this time' : ''}',
    };

    final (warnBg, warnFg) = toneColors(
      ChurchColors.of(context),
      StatusTone.warning,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Who',
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              key: Key(pickerKey),
              hint: const Text('Choose someone'),
              value: value,
              isExpanded: true,
              itemHeight: null,
              items: [
                if (widget.allowNobody)
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Nobody yet'),
                  ),
                for (final m in members)
                  DropdownMenuItem<String?>(
                    value: m.memberId,
                    child: Semantics(
                      label: [name(m), ?load(m)].join(', '),
                      excludeSemantics: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(name(m), overflow: TextOverflow.ellipsis),
                          if (load(m) case final l?)
                            Text(l, style: ChurchType.secondary),
                        ],
                      ),
                    ),
                  ),
              ],
              onChanged: busy ? null : widget.onChanged,
            ),
          ),
        ),
        if (read is AsyncLoading)
          _muted(context, 'Checking their other duties…'),
        if (failed)
          Text(
            'Could not check their other duties. The server still checks '
            'when you save.',
            key: Key('$pickerKey-check-failed'),
          ),
        if (chosen != null && overlapping)
          Semantics(
            liveRegion: true,
            child: Container(
              key: Key('$pickerKey-overlaps'),
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: warnBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${chosen.displayName} has ${chosen.conflictCount} other '
                    '${chosen.conflictCount == 1 ? 'duty' : 'duties'} at '
                    'that time:',
                    style: TextStyle(
                      color: warnFg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final c in chosen.conflicts)
                    Text(
                      '- ${_conflictText(context, c)}',
                      style: TextStyle(color: warnFg),
                    ),
                  if (chosen.conflictCount > chosen.conflicts.length)
                    Text(
                      'and ${chosen.conflictCount - chosen.conflicts.length} '
                      'more',
                      style: TextStyle(color: warnFg),
                    ),
                ],
              ),
            ),
          )
        else if (chosen != null)
          Text(
            'No overlapping duty found (${chosen.loadLabel} in the next 90 '
            'days). This does not mean they are free: check with them.',
            key: Key('$pickerKey-no-overlap'),
          ),
        if (value != null && (overlapping || reasonError != null))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextField(
              key: Key('$pickerKey-reason'),
              controller: reason,
              enabled: !busy,
              maxLength: DutyOverride.maxLength,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Why assign them anyway? (required)',
                helperText:
                    'Seen by this department\'s leaders and Pastor, not by '
                    'the member. They still choose whether to accept.',
                helperMaxLines: 2,
                errorText: switch (reasonError) {
                  null => null,
                  'required' => 'Give a reason, or choose someone else',
                  _ => 'At most ${DutyOverride.maxLength} characters',
                },
              ),
            ),
          ),
      ],
    );
  }
}
