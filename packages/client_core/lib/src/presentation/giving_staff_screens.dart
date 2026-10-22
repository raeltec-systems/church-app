import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/content_controllers.dart' show ContentAction;
import '../application/access_controllers.dart' show myAccessProvider;
import '../application/giving_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/content_events.dart' show ContentState;
import '../domain/content_giving.dart';
import 'calendar_screens.dart' show churchShortWhen;

// Story 6.3, staff web: Admins keep the church's giving methods. The screen
// answers "what can givers see now, and what waits for a second Admin?"
// first: the finding line, then the methods in the order givers see them,
// one status mark each. A revision is published only after an Admin who
// saved none of it has verified it (owner decision 2026-10-21; review
// 2026-10-22); the screen shows who saved, verified and published each
// revision and when, and says why an Admin cannot verify changes they saved.
// Unpublished changes of a live method can be discarded.
// Every list comes from a server-checked read and every action is a
// server-checked command. No amount, payer or gift appears anywhere.

/// The staff route of the Giving screen.
abstract final class GivingStaffPaths {
  /// Staff web: the Giving editor (Admin only).
  static const giving = '/content/giving';
}

const _needs = 'Giving methods are managed by Admins.';
const _ownSave =
    'You saved changes to these details, so a different Admin must verify '
    'them.';

(StatusTone, String, String) _noticeText(GivingNotice n, ContentAction? a) {
  final what = a?.subject ?? 'the method';
  return switch (n) {
    GivingNotice.created => (
      StatusTone.success,
      'Draft saved',
      '$what is saved as a draft. A different Admin must verify it before it '
          'can be published.',
    ),
    GivingNotice.saved => (
      StatusTone.success,
      'Changes saved',
      'Your changes to $what are saved as a draft. An Admin who saved none '
          'of these changes must verify them; givers see only the live '
          'details until the changes are published.',
    ),
    GivingNotice.verified => (
      StatusTone.success,
      'Verified',
      '$what is verified with your name. It can be published now.',
    ),
    GivingNotice.published => (
      StatusTone.success,
      'Published',
      '$what is live in How to give. Phones show it on their next refresh.',
    ),
    GivingNotice.hidden => (
      StatusTone.success,
      'Hidden',
      '$what is hidden from How to give. Phones drop it on their next '
          'refresh. You can publish it again.',
    ),
    GivingNotice.archived => (
      StatusTone.success,
      'Archived',
      '$what is archived. Givers no longer see it and it can no longer change.',
    ),
    GivingNotice.moved => (
      StatusTone.success,
      'Moved',
      '$what moved. How to give lists the methods in this order.',
    ),
    GivingNotice.discarded => (
      StatusTone.success,
      'Changes discarded',
      'The unpublished changes to $what are discarded. Its live details are '
          'unchanged.',
    ),
    GivingNotice.unchanged => (
      StatusTone.warning,
      'Nothing changed',
      'Nothing changed, so nothing was saved.',
    ),
    GivingNotice.nothingToDiscard => (
      StatusTone.warning,
      'Nothing to discard',
      '$what has no unpublished changes to discard. The list now shows where '
          'it stands.',
    ),
    GivingNotice.neverPublished => (
      StatusTone.warning,
      'Never published',
      '$what has never been published, so there are no live details to go '
          'back to. Archive it instead if it is not needed. Nothing was '
          'changed.',
    ),
    GivingNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      '$what was changed in another tab or by another Admin. The list now '
          'shows the current details; check them and try again.',
    ),
    GivingNotice.nothingToVerify => (
      StatusTone.warning,
      'Nothing to verify',
      '$what has no unverified changes. The list now shows where it stands.',
    ),
    GivingNotice.alreadyVerified => (
      StatusTone.warning,
      'Already verified',
      '$what was verified already. The list now shows who verified it.',
    ),
    GivingNotice.savedByYou => (
      StatusTone.warning,
      'Another Admin must verify',
      '$_ownSave Nothing was changed.',
    ),
    GivingNotice.notVerified => (
      StatusTone.warning,
      'Not verified yet',
      '$what can\'t be published until an Admin who saved none of its '
          'changes verifies them. Nothing was changed.',
    ),
    GivingNotice.nothingToPublish => (
      StatusTone.warning,
      'Nothing to publish',
      '$what has no verified changes to publish.',
    ),
    GivingNotice.notPublished => (
      StatusTone.warning,
      'Not live',
      '$what is not live, so there is nothing to hide.',
    ),
    GivingNotice.alreadyArchived => (
      StatusTone.warning,
      'Archived',
      '$what is archived and can no longer change.',
    ),
    GivingNotice.sampleOnly => (
      StatusTone.warning,
      'Sample details only',
      'This server takes sample giving methods only: the name must start with '
          '"SAMPLE ". Nothing was changed.',
    ),
    GivingNotice.gateClosed => (
      StatusTone.warning,
      'Not open yet',
      'Giving methods can\'t be published here until the church owner '
          'approves publishing real giving details. Drafts and verification '
          'still work; nothing was changed.',
    ),
    GivingNotice.positionOutOfRange => (
      StatusTone.warning,
      'The list changed',
      'The list changed meanwhile, so $what was not moved. The list now '
          'shows the current order.',
    ),
    GivingNotice.invalid => (
      StatusTone.warning,
      'Check the details',
      'Some details need changing; see the marked fields. Nothing was saved.',
    ),
    GivingNotice.notAllowed => (
      StatusTone.danger,
      'Not allowed',
      '$_needs Nothing was changed.',
    ),
    GivingNotice.signInAgain => (
      StatusTone.danger,
      'Please sign in again',
      'Your session is no longer trusted. Nothing was changed.',
    ),
    GivingNotice.notFound => (
      StatusTone.warning,
      'Not found',
      'That method no longer exists. The list now shows the current methods.',
    ),
    GivingNotice.notAvailable => (
      StatusTone.warning,
      'Not available right now',
      'The church server could not do this now. Nothing was changed.',
    ),
    GivingNotice.refused => (
      StatusTone.danger,
      'Not done',
      'The church server refused this. Nothing was changed.',
    ),
    GivingNotice.unconfirmed => (
      StatusTone.warning,
      'Not confirmed',
      'We could not tell whether $what was changed. Check again sends the '
          'same request, so it cannot apply twice.',
    ),
    GivingNotice.notSent => (
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
  'too_long' => 'Too long',
  'too_many' => 'At most $givingMaxSteps steps',
  'unknown_field' => 'The server does not accept this field',
  'sample_only' => 'On this server the name must start with "SAMPLE "',
  'out_of_range' when wire == 'tested_on' =>
    'Use a date in the last 90 days, not in the future',
  'before_saved' when wire == 'tested_on' =>
    'Use the day of the test, on or after the day these details were saved.',
  'not_eligible' when wire == 'admin_tenure' => 'The server could not confirm 14 full days of Admin access. Refresh access and try again later.',
  'invalid' => switch (wire) {
    'currency' => 'Use a three-letter code, such as ZMW',
    'ussd_code' => 'Use a code such as *115#: a star, digits or stars, then #',
    'swift_code' => 'Use an 8 or 11 character SWIFT code',
    'identifier' =>
      'Up to 40 letters, digits, spaces or hyphens, with an optional '
          'leading +',
    'account_number' => '4 to 34 letters, digits, spaces or hyphens',
    'identifier_kind' => 'Choose merchant ID, till number or phone number',
    'steps' => 'Each step is one line of up to 200 characters',
    'tested_on' => 'Use a real date (YYYY-MM-DD)',
    _ => 'Check this',
  },
  _ => 'Check this',
};

StatusTone _tone(GivingStage s) => switch (s) {
  GivingStage.draftNeedsVerifying => StatusTone.warning,
  GivingStage.liveChangesNeedVerifying => StatusTone.warning,
  GivingStage.draftVerified => StatusTone.info,
  GivingStage.liveChangesVerified => StatusTone.info,
  GivingStage.live => StatusTone.success,
  GivingStage.hidden => StatusTone.neutral,
  GivingStage.archived => StatusTone.neutral,
};

/// The screen's finding, in one line under the title: what givers see and
/// what waits for a second Admin or for publishing.
String _givingFinding(StaffGivingMethods value) {
  final methods = value.methods;
  if (methods.isEmpty) {
    return 'No giving methods yet. A new method stays a private draft until '
        'a different Admin verifies it and it is published.';
  }
  final live = methods.where((g) => g.isPublic).length;
  final verify = methods.where((g) => g.needsVerifying).length;
  final ready = methods.where((g) => g.draft != null && g.canPublish).length;
  return [
    '$live live in How to give',
    if (verify > 0) '$verify waiting for a second Admin to verify',
    if (ready > 0) '$ready ready to publish',
  ].join(' · ');
}

/// `/content/giving` (staff web; Admin only).
class StaffGivingScreen extends ConsumerStatefulWidget {
  const StaffGivingScreen({super.key});

  @override
  ConsumerState<StaffGivingScreen> createState() => _StaffGivingScreenState();
}

class _StaffGivingScreenState extends ConsumerState<StaffGivingScreen> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'giving notice');

  /// The new-method form is open (the header's main action toggles it).
  var _creating = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    if (ref.read(staffGivingProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    final s = ref.read(staffGivingProvider);
    if (mounted && !s.busy && !s.loading) {
      ref.read(staffGivingProvider.notifier).reload();
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
    final s = ref.watch(staffGivingProvider);
    final ctl = ref.read(staffGivingProvider.notifier);
    ref.listen(staffGivingProvider.select((x) => x.notice), (prev, next) {
      if (next == null || next == prev) return;
      final action = ref.read(staffGivingProvider).noticeAction;
      final (_, title, message) = _noticeText(next, action);
      // A verification is answered while its dialog is still open: speak
      // and move focus once it has closed.
      final fromDialog = action?.command == GivingCommands.verify;
      announce(
        context,
        '$title. $message',
        delay: fromDialog ? kAnnouncementAfterDialog : Duration.zero,
      );
      void focusNotice() {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      }

      if (fromDialog) {
        Future<void>.delayed(kAnnouncementAfterDialog, focusNotice);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => focusNotice());
      }
    });
    final children = <Widget>[];
    if (s.pending case final p?) {
      children.add(
        RequestStateBanner(
          key: const Key('giving-pending'),
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
          key: Key('giving-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == GivingNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('giving-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('giving-dismiss'),
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
            key: Key('giving-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading giving methods…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        children.add(
          _GivingBody(
            value: value,
            state: s,
            creating: _creating,
            onCreatingChanged: (v) => setState(() => _creating = v),
          ),
        );
      case AccessReadDenied(:final denial):
        children.add(
          RequestStateBanner(
            key: Key('giving-denied-${denial.name}'),
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
            key: const Key('giving-failed'),
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
    // method) and Reload; on a phone the bar keeps its Reload button.
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final value = s.value;
    final newMethod = value == null
        ? null
        : FocusRing(
            child: FilledButton.icon(
              key: const Key('giving-new'),
              onPressed: s.busy
                  ? null
                  : () => setState(() => _creating = !_creating),
              icon: Icon(_creating ? Icons.close : Icons.add),
              label: Text(_creating ? 'Close the form' : 'New method'),
            ),
          );
    return ChurchPageScaffold(
      title: 'Giving',
      subtitle: value == null ? null : _givingFinding(value),
      actions: phone
          ? [
              ?newMethod,
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('giving-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [?newMethod, staffReloadButton(const Key('giving-reload'), reload)],
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

class _GivingBody extends ConsumerStatefulWidget {
  const _GivingBody({
    required this.value,
    required this.state,
    required this.creating,
    required this.onCreatingChanged,
  });

  final StaffGivingMethods value;
  final StaffGivingState state;
  final bool creating;
  final ValueChanged<bool> onCreatingChanged;

  @override
  ConsumerState<_GivingBody> createState() => _GivingBodyState();
}

class _GivingBodyState extends ConsumerState<_GivingBody> {
  String? _open;
  var _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final busy = widget.state.busy;
    // A confirmed create closes the new-method form.
    ref.listen(staffGivingProvider.select((x) => x.notice), (prev, next) {
      if (next == GivingNotice.created && mounted) {
        widget.onCreatingChanged(false);
      }
    });
    final ordered = widget.value.ordered;
    final archived = widget.value.archived;
    Widget rows(List<StaffGivingMethod> list, String key) => ChurchCard(
      key: Key(key),
      padding: EdgeInsets.zero,
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, g) in list.indexed) ...[
            if (i > 0) Divider(height: 1, color: c.line),
            _MethodRow(
              key: Key('giving-${g.methodId}'),
              method: g,
              count: ordered.length,
              open: _open == g.methodId,
              busy: busy,
              state: widget.state,
              onToggle: () => setState(
                () => _open = _open == g.methodId ? null : g.methodId,
              ),
            ),
          ],
        ],
      ),
    );
    Widget heading(String text, String key) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          key: Key(key),
          style: ChurchType.cardTitle.copyWith(color: c.ink),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.creating) ...[
          ChurchCard(
            radius: 12,
            child: _FormWidth(
              child: _GivingForm(
                key: const Key('giving-form-new'),
                method: null,
                busy: busy,
                state: widget.state,
                onCancel: () => widget.onCreatingChanged(false),
              ),
            ),
          ),
          const SizedBox(height: ChurchGeometry.sectionGap),
        ],
        if (widget.value.truncated) ...[
          const RequestStateBanner(
            key: Key('giving-truncated'),
            tone: StatusTone.warning,
            title: 'Not every method is listed',
            message:
                'There are more giving methods than this list shows; the '
                'first in order are listed.',
          ),
          const SizedBox(height: 12),
        ],
        heading(
          'Methods in How to give order (${ordered.length})',
          'giving-order',
        ),
        if (ordered.isEmpty)
          ChurchCard(
            key: const Key('giving-empty'),
            radius: 12,
            child: Text(
              'No giving methods yet. Add the church\'s first with New method.',
              style: ChurchType.body.copyWith(color: c.muted),
            ),
          )
        else
          rows(ordered, 'giving-list'),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: ChurchGeometry.sectionGap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('giving-show-archived'),
                onPressed: () => setState(() => _showArchived = !_showArchived),
                child: Text(
                  _showArchived
                      ? 'Hide archived methods'
                      : 'Show archived methods (${archived.length})',
                ),
              ),
            ),
          ),
          if (_showArchived) ...[
            const SizedBox(height: 8),
            heading('Archived (${archived.length})', 'giving-archived'),
            rows(archived, 'giving-archived-list'),
          ],
        ],
        const SizedBox(height: 16),
        Text(
          'Times are church time (Kafue). Every saved change is a private '
          'draft until an Admin who saved none of it verifies it; only then '
          'can it be published. If a draft is wrong, the Admin who entered it '
          'corrects it, or its changes are discarded. Givers see the live '
          'version only, with the date it was checked. Order changes apply at '
          'once.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ],
    );
  }
}

/// One method: its place in the order, name, what it is for, one status
/// mark and Move up/down; when opened, its live and draft versions with who
/// saved, verified and published them, and its actions.
class _MethodRow extends ConsumerStatefulWidget {
  const _MethodRow({
    super.key,
    required this.method,
    required this.count,
    required this.open,
    required this.busy,
    required this.state,
    required this.onToggle,
  });

  final StaffGivingMethod method;

  /// How many methods are in the order (the last cannot move down).
  final int count;
  final bool open;
  final bool busy;
  final StaffGivingState state;
  final VoidCallback onToggle;

  @override
  ConsumerState<_MethodRow> createState() => _MethodRowState();
}

class _MethodRowState extends ConsumerState<_MethodRow> {
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
              key: const Key('giving-confirm-no'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep it'),
            ),
          ),
          FocusRing(
            child: FilledButton(
              key: const Key('giving-confirm-yes'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(yes),
            ),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _verify(StaffGivingMethod g) => showDialog<void>(
    context: context,
    builder: (context) => _VerifyDialog(method: g),
  );

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final g = widget.method;
    final id = g.methodId;
    final busy = widget.busy;
    final f = g.current;
    final stage = g.stage;
    final ctl = ref.read(staffGivingProvider.notifier);
    // A confirmed save or discard closes this method's form.
    ref.listen(staffGivingProvider.select((x) => x.notice), (prev, next) {
      final a = ref.read(staffGivingProvider).noticeAction;
      if ((next == GivingNotice.saved || next == GivingNotice.discarded) &&
          a?.request.payload['method_id'] == id &&
          mounted) {
        setState(() => _editing = false);
      }
    });
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final sub = [g.methodType.label, ?f.purpose, ?f.currency].join(' · ');
    final position = g.position;
    final summary = InkWell(
      key: Key('giving-open-$id'),
      onTap: widget.onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                position == null ? '–' : '$position',
                style: ChurchType.figures.copyWith(color: c.muted),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.name,
                    style: ChurchType.itemTitle.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: muted),
                ],
              ),
            ),
            const SizedBox(width: 12),
            StatusLabel(
              key: Key('giving-mark-$id'),
              label: stage.label,
              tone: _tone(stage),
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
    // Order is outside revisions: a move applies at once.
    final moves = position == null
        ? const <Widget>[]
        : [
            FocusRing(
              radius: 22,
              child: IconButton(
                key: Key('giving-up-$id'),
                style: _moveStyle(c),
                tooltip: 'Move ${f.name} up',
                onPressed: busy || position <= 1
                    ? null
                    : () => ctl.move(g, position - 1),
                icon: const Icon(Icons.arrow_upward),
              ),
            ),
            FocusRing(
              radius: 22,
              child: IconButton(
                key: Key('giving-down-$id'),
                style: _moveStyle(c),
                tooltip: 'Move ${f.name} down',
                onPressed: busy || position >= widget.count
                    ? null
                    : () => ctl.move(g, position + 1),
                icon: const Icon(Icons.arrow_downward),
              ),
            ),
            const SizedBox(width: 8),
          ];
    final head = Row(
      children: [
        Expanded(child: FocusRing(radius: 4, child: summary)),
        ...moves,
      ],
    );
    if (!widget.open) return head;

    final live = g.live;
    final draft = g.draft;
    final publishLabel = switch (g) {
      _ when g.state == ContentState.published => 'Publish changes',
      _ when g.state == ContentState.withdrawn && draft == null =>
        'Publish again',
      _ => 'Publish',
    };
    final actions = <Widget>[
      if (g.canEdit)
        FocusRing(
          child: OutlinedButton(
            key: Key('giving-edit-$id'),
            onPressed: busy ? null : () => setState(() => _editing = !_editing),
            child: Text(_editing ? 'Close the form' : 'Edit'),
          ),
        ),
      if (g.needsVerifying)
        FocusRing(
          child: OutlinedButton(
            key: Key('giving-verify-$id'),
            onPressed: busy || g.verifyBlockedForYou ? null : () => _verify(g),
            child: const Text('Verify'),
          ),
        ),
      if (g.canPublish)
        FocusRing(
          child: FilledButton(
            key: Key('giving-publish-$id'),
            onPressed: busy ? null : () => ctl.publish(g),
            child: Text(publishLabel),
          ),
        ),
      if (g.canHide)
        FocusRing(
          child: OutlinedButton(
            key: Key('giving-hide-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      'Hide ${f.name}?',
                      'It disappears from How to give the next time a phone '
                          'refreshes. You can publish it again later.',
                      'Hide',
                    )) {
                      await ctl.hide(g);
                    }
                  },
            child: const Text('Hide'),
          ),
        ),
      if (g.canDiscard)
        FocusRing(
          child: OutlinedButton(
            key: Key('giving-discard-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      'Discard the unpublished changes to ${live!.fields.name}?',
                      g.state == ContentState.published
                          ? 'Givers keep seeing the live details.'
                          : 'The last live details stay as they were, and the '
                                'method stays hidden.',
                      'Discard changes',
                    )) {
                      await ctl.discard(g);
                    }
                  },
            child: const Text('Discard changes'),
          ),
        ),
      if (g.canArchive)
        FocusRing(
          child: TextButton(
            key: Key('giving-archive-$id'),
            onPressed: busy
                ? null
                : () async {
                    if (await _confirm(
                      'Archive ${f.name}?',
                      'Givers no longer see it, and it can no longer be '
                          'changed or published.',
                      'Archive',
                    )) {
                      await ctl.archive(g);
                    }
                  },
            child: const Text('Archive'),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        Padding(
          key: Key('giving-details-$id'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The live and draft versions side by side when there is room
              // (the verifier compares them), otherwise one under the other;
              // a lone version keeps a readable width.
              LayoutBuilder(
                builder: (context, box) {
                  final versions = [
                    if (live != null)
                      _Version(
                        key: Key('giving-live-$id'),
                        label: g.state == ContentState.published
                            ? 'Live in How to give'
                            : 'Last live version (not shown to givers)',
                        revision: live,
                      ),
                    if (draft != null)
                      _Version(
                        key: Key('giving-draft-$id'),
                        label: live == null
                            ? 'Draft (Admins only)'
                            : 'Changes not live yet (Admins only)',
                        revision: draft,
                        live: live,
                      ),
                  ];
                  if (versions.length == 2 && box.maxWidth >= 900) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: versions.first),
                          const SizedBox(width: 16),
                          Expanded(child: versions.last),
                        ],
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final v in versions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 760),
                              child: v,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (g.withdrawnAt case final at?
                  when g.state == ContentState.withdrawn)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Hidden ${churchShortWhen(at)}', style: muted),
                ),
              if (g.archivedAt case final at?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Archived ${churchShortWhen(at)}', style: muted),
                ),
              Text(
                'Created by ${g.createdBy} · ${churchShortWhen(g.createdAt)}',
                style: muted,
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
              if (g.verifyBlockedForYou) ...[
                const SizedBox(height: 8),
                Text(
                  _ownSave,
                  key: Key('giving-verify-reason-$id'),
                  style: muted,
                ),
              ],
              if (_editing && g.canEdit) ...[
                const SizedBox(height: 14),
                _FormWidth(
                  child: _GivingForm(
                    key: Key('giving-form-$id'),
                    method: g,
                    busy: busy,
                    state: widget.state,
                    onCancel: () => setState(() => _editing = false),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Every field of a revision as rows (a dash for an empty optional).
List<DetailRow> _fieldRows(GivingFields f) {
  String dash(String? v) => v ?? '—';
  return [
    (label: 'Type', value: f.methodType.label),
    (label: 'Name', value: f.name),
    (label: 'Purpose', value: dash(f.purpose)),
    (label: 'Currency', value: dash(f.currency)),
    if (f.methodType == GivingMethodType.mobileMoney) ...[
      (label: 'Beneficiary', value: f.beneficiary!),
      (label: f.identifierKind!.label, value: f.identifier!),
      (label: 'Starting code', value: dash(f.ussdCode)),
    ],
    if (f.methodType == GivingMethodType.bank) ...[
      (label: 'Bank', value: f.bankName!),
      (label: 'Account name', value: f.beneficiary!),
      (label: 'Account number', value: f.accountNumber!),
      (label: 'Branch', value: dash(f.branch)),
      (label: 'Branch code', value: dash(f.branchCode)),
      (label: 'SWIFT code', value: dash(f.swiftCode)),
      (label: 'Reference', value: dash(f.reference)),
    ],
    (
      label: 'Steps',
      value: [for (final (i, s) in f.steps.indexed) '${i + 1}. $s'].join('\n'),
    ),
    (label: 'Note', value: dash(f.note)),
    (label: 'Contact', value: f.contact),
  ];
}

/// One revision: every field of its type, then who saved, verified and
/// published it and when. A draft of a live method also names the fields
/// that differ from the live version, so the verifier sees what changed.
class _Version extends StatelessWidget {
  const _Version({
    super.key,
    required this.label,
    required this.revision,
    this.live,
  });

  final String label;
  final StaffGivingRevision revision;

  /// The live revision this draft would replace.
  final StaffGivingRevision? live;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final r = revision;
    final rows = _fieldRows(r.fields);
    final before = live == null ? null : _fieldRows(live!.fields);
    // A changed identifier kind renames its row: compare by position (the
    // type, so the rows, never change).
    final changed = before == null
        ? null
        : [
            for (final (i, row) in rows.indexed)
              if (i >= before.length ||
                  before[i].label != row.label ||
                  before[i].value != row.value)
                row.label,
          ];
    final v = r.verification;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CardLabel(label),
        if (changed != null) ...[
          const SizedBox(height: 4),
          Text(
            changed.isEmpty
                ? 'Same details as the live version.'
                : 'Changed from the live version: ${changed.join(', ')}.',
            key: Key('giving-changed-${r.revisionNo}'),
            style: ChurchType.secondary.copyWith(
              color: c.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 6),
        DetailTable(labelWidth: 132, rows: rows),
        const SizedBox(height: 6),
        Text(
          'Saved by ${r.savedByYou ? 'you' : r.savedBy} · '
          '${churchShortWhen(r.savedAt)}',
          style: muted,
        ),
        Text(
          v == null
              ? 'Not verified yet: an Admin who saved none of it must verify '
                    'it.'
              : 'Verified by ${v.verifiedByYou ? 'you' : v.verifiedBy} · '
                    '${churchShortWhen(v.verifiedAt)} · tested on '
                    '${churchDateText(v.testedOn)}: ${v.testMethod}',
          key: Key('giving-verification-${r.revisionNo}'),
          style: v == null ? muted.copyWith(color: c.amberFg) : muted,
        ),
        if (r.publishedAt case final at?)
          Text(
            [
              if (r.publishedBy case final by?) 'Published by $by',
              churchShortWhen(at),
            ].join(' · '),
            style: muted,
          ),
      ],
    );
  }
}

/// The verification of a draft: the date the details were tested and how.
/// It stays open until the server answers, so a field error is shown here
/// and the typed text is kept.
class _VerifyDialog extends ConsumerStatefulWidget {
  const _VerifyDialog({required this.method});

  final StaffGivingMethod method;

  @override
  ConsumerState<_VerifyDialog> createState() => _VerifyDialogState();
}

class _VerifyDialogState extends ConsumerState<_VerifyDialog> {
  // Today's church date by default.
  late final _testedOn = TextEditingController(
    text: ChurchTime.ymd(churchToday()),
  );
  final _how = TextEditingController();

  @override
  void dispose() {
    _testedOn.dispose();
    _how.dispose();
    super.dispose();
  }

  bool _mine(StaffGivingState s) {
    final a = s.noticeAction;
    return a?.command == GivingCommands.verify &&
        a?.request.payload['method_id'] == widget.method.methodId;
  }

  Future<void> _send(DateTime testedOn) async {
    await ref
        .read(staffGivingProvider.notifier)
        .verify(widget.method, testedOn: testedOn, testMethod: _how.text);
    if (!mounted) return;
    final s = ref.read(staffGivingProvider);
    // A field error keeps the dialog and what was typed; any other answer
    // is reported on the page.
    if (_mine(s) && s.notice == GivingNotice.invalid) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(staffGivingProvider);
    final tenure = ref.watch(
      myAccessProvider.select((a) => a.grants?.adminTenure),
    );
    final busy = s.busy;
    final errors = _mine(s) && s.notice == GivingNotice.invalid
        ? s.fieldErrors
        : const <String, String>{};
    final draft = widget.method.draft!;
    final f = draft.fields;
    final check = switch (f.beneficiary) {
      final name? => 'that your provider shows $name for these details',
      null => 'that the steps lead only to the church\'s own channels',
    };
    // The test can't predate the details it checks (the server refuses
    // `before_saved`).
    final saved = churchDateText(
      parseChurchDate(ChurchTime.dateText(draft.savedAt))!,
    );
    void edited(String _) =>
        ref.read(staffGivingProvider.notifier).clearFieldErrors();
    void refreshAccess() {
      ref.read(myAccessProvider.notifier).refresh();
    }

    return ChurchDialog(
      title: 'Verify ${f.name}',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Last saved by ${draft.savedBy} · '
            '${churchShortWhen(draft.savedAt)}. Test every detail yourself '
            'before you verify, including $check. Your name is recorded with '
            'the verification.',
            key: const Key('giving-verify-intro'),
            style: ChurchType.secondary.copyWith(color: c.ink),
          ),
          const SizedBox(height: 12),
          if (tenure case final tenureDetails?)
            Text(
              'Admin since ${tenureDetails.adminSince}, granted by ${tenureDetails.grantedBy}',
              key: const Key('giving-verify-admin-tenure'),
              style: ChurchType.secondary.copyWith(color: c.ink),
            )
          else
            Text(
              'Your Admin grant details could not be loaded. Refresh access before verifying.',
              key: const Key('giving-verify-admin-tenure-missing'),
              style: ChurchType.secondary.copyWith(color: c.ink),
            ),
          Text(
            'An Admin must have held the role for 14 full days before verifying.',
            key: const Key('giving-verify-tenure-rule'),
            style: ChurchType.secondary.copyWith(color: c.ink),
          ),
          if (errors['admin_tenure'] != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _fieldError('admin_tenure', errors['admin_tenure'])!,
                key: const Key('giving-verify-tenure-error'),
                style: TextStyle(color: c.redFg),
              ),
            ),
          ],
          if (tenure == null || errors['admin_tenure'] != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('giving-refresh-access'),
                onPressed: busy ? null : refreshAccess,
                child: const Text('Refresh access'),
              ),
            ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('giving-tested-on'),
            controller: _testedOn,
            enabled: !busy,
            maxLength: 10,
            onChanged: edited,
            decoration: InputDecoration(
              labelText: 'Tested on',
              hintText: 'YYYY-MM-DD',
              helperText:
                  'The day of the test: on or after $saved, within the last '
                  '90 days',
              helperMaxLines: 3,
              errorText: _fieldError('tested_on', errors['tested_on']),
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('giving-test-method'),
            controller: _how,
            enabled: !busy,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            onChanged: edited,
            decoration: InputDecoration(
              labelText: 'How it was tested',
              hintText:
                  'For example: the provider showed the beneficiary name for '
                  'this ID',
              helperText:
                  'Say how the details were checked. Don\'t include phone '
                  'numbers, amounts or transaction IDs.',
              helperMaxLines: 3,
              errorText: _fieldError('test_method', errors['test_method']),
              errorMaxLines: 3,
            ),
          ),
          if (errors.keys.any(
            (k) =>
                k != 'tested_on' && k != 'test_method' && k != 'admin_tenure',
          ))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'The server could not read this verification. Close it, '
                'reload and try again.',
                style: TextStyle(color: c.redFg),
              ),
            ),
        ],
      ),
      actions: [
        FocusRing(
          child: TextButton(
            key: const Key('giving-verify-cancel'),
            onPressed: busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_testedOn, _how]),
          builder: (context, _) {
            final testedOn = parseChurchDate(_testedOn.text.trim());
            final ready = testedOn != null && _how.text.trim().isNotEmpty;
            return FocusRing(
              child: FilledButton(
                key: const Key('giving-verify-send'),
                onPressed: busy || !ready ? null : () => _send(testedOn),
                child: Text(busy ? 'Verifying…' : 'Verify'),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Move and remove buttons that look unavailable when they are (at the
/// first or last place, or while a command is sent): the shared theme
/// paints every icon button in ink.
ButtonStyle _moveStyle(ChurchColors c) => IconButton.styleFrom(
  foregroundColor: c.ink,
  disabledForegroundColor: c.muted.withValues(alpha: 0.45),
);

/// A form keeps a readable width on a wide page (fields stretched across
/// the canvas read as one long line).
class _FormWidth extends StatelessWidget {
  const _FormWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: child,
    ),
  );
}

/// One step of the form, with a stable identity while steps are reordered.
class _StepField {
  _StepField(String text) : controller = TextEditingController(text: text);
  final key = UniqueKey();
  final TextEditingController controller;
}

/// A new method ([method] null) or an edit of one: every field of its type,
/// saved as a draft a different Admin must verify. The type is chosen once,
/// on a new method.
class _GivingForm extends ConsumerStatefulWidget {
  const _GivingForm({
    super.key,
    required this.method,
    required this.busy,
    required this.state,
    required this.onCancel,
  });

  final StaffGivingMethod? method;
  final bool busy;
  final StaffGivingState state;
  final VoidCallback onCancel;

  @override
  ConsumerState<_GivingForm> createState() => _GivingFormState();
}

class _GivingFormState extends ConsumerState<_GivingForm> {
  var _type = GivingMethodType.mobileMoney;
  var _identifierKind = MobileMoneyIdentifier.merchant;
  final _name = TextEditingController();
  final _purpose = TextEditingController();
  final _currency = TextEditingController();
  final _note = TextEditingController();
  final _contact = TextEditingController();
  final _beneficiary = TextEditingController();
  final _identifier = TextEditingController();
  final _ussd = TextEditingController();
  final _bankName = TextEditingController();
  final _accountNumber = TextEditingController();
  final _branch = TextEditingController();
  final _branchCode = TextEditingController();
  final _swift = TextEditingController();
  final _reference = TextEditingController();
  final _steps = <_StepField>[];

  /// Rebuilds the Save button whenever a field or the step list changes.
  final _changed = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    // An edit starts from the draft, otherwise from the live version.
    if (widget.method?.current case final f?) {
      _type = f.methodType;
      _identifierKind = f.identifierKind ?? MobileMoneyIdentifier.merchant;
      _name.text = f.name;
      _purpose.text = f.purpose ?? '';
      _currency.text = f.currency ?? '';
      _note.text = f.note ?? '';
      _contact.text = f.contact;
      _beneficiary.text = f.beneficiary ?? '';
      _identifier.text = f.identifier ?? '';
      _ussd.text = f.ussdCode ?? '';
      _bankName.text = f.bankName ?? '';
      _accountNumber.text = f.accountNumber ?? '';
      _branch.text = f.branch ?? '';
      _branchCode.text = f.branchCode ?? '';
      _swift.text = f.swiftCode ?? '';
      _reference.text = f.reference ?? '';
      _steps.addAll(f.steps.map(_StepField.new));
    } else {
      _steps.add(_StepField(''));
    }
  }

  List<TextEditingController> get _fields => [
    _name,
    _purpose,
    _currency,
    _note,
    _contact,
    _beneficiary,
    _identifier,
    _ussd,
    _bankName,
    _accountNumber,
    _branch,
    _branchCode,
    _swift,
    _reference,
  ];

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    for (final s in _steps) {
      s.controller.dispose();
    }
    _changed.dispose();
    super.dispose();
  }

  void _edited() {
    ref.read(staffGivingProvider.notifier).clearFieldErrors();
    _changed.value++;
  }

  void _changeSteps(VoidCallback change) {
    setState(change);
    _edited();
  }

  /// What is typed, or null while something required is missing.
  GivingMethodInput? _input() {
    bool blank(TextEditingController c) => c.text.trim().isEmpty;
    final steps = [
      for (final s in _steps)
        if (s.controller.text.trim().isNotEmpty) s.controller.text,
    ];
    final missing =
        blank(_name) ||
        blank(_contact) ||
        steps.isEmpty ||
        switch (_type) {
          GivingMethodType.mobileMoney =>
            blank(_beneficiary) || blank(_identifier),
          GivingMethodType.bank =>
            blank(_bankName) || blank(_beneficiary) || blank(_accountNumber),
          GivingMethodType.other => false,
        };
    if (missing) return null;
    return GivingMethodInput(
      methodType: _type,
      name: _name.text,
      purpose: _purpose.text,
      currency: _currency.text,
      steps: steps,
      note: _note.text,
      contact: _contact.text,
      beneficiary: _beneficiary.text,
      identifierKind: _identifierKind,
      identifier: _identifier.text,
      ussdCode: _ussd.text,
      bankName: _bankName.text,
      accountNumber: _accountNumber.text,
      branch: _branch.text,
      branchCode: _branchCode.text,
      swiftCode: _swift.text,
      reference: _reference.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final g = widget.method;
    final tag = g?.methodId ?? 'new';
    final st = widget.state;
    // Only a refusal of this form's own command names its fields.
    final a = st.noticeAction;
    final mine = g == null
        ? a?.command == GivingCommands.create
        : a?.command == GivingCommands.save &&
              a?.request.payload['method_id'] == g.methodId;
    final errors = mine ? st.fieldErrors : const <String, String>{};
    final busy = widget.busy;
    Widget field(
      String key,
      TextEditingController ctl,
      String label, {
      required String wire,
      String? hint,
      String? helper,
      int maxLength = 120,
      bool required = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$tag'),
        controller: ctl,
        enabled: !busy,
        maxLength: maxLength,
        onChanged: (_) => _edited(),
        decoration: InputDecoration(
          labelText: required ? label : '$label (optional)',
          hintText: hint,
          helperText: helper,
          errorText: _fieldError(wire, errors[wire]),
          errorMaxLines: 3,
        ),
      ),
    );
    final known = {
      'method_type',
      'method_id',
      'name',
      'purpose',
      'currency',
      'steps',
      'note',
      'contact',
      'beneficiary',
      'identifier_kind',
      'identifier',
      'ussd_code',
      'bank_name',
      'account_number',
      'branch',
      'branch_code',
      'swift_code',
      'reference',
    };
    final shownWires = {
      'name',
      'purpose',
      'currency',
      'steps',
      'note',
      'contact',
      if (_type == GivingMethodType.mobileMoney) ...[
        'beneficiary',
        'identifier_kind',
        'identifier',
        'ussd_code',
      ],
      if (_type == GivingMethodType.bank) ...[
        'bank_name',
        'beneficiary',
        'account_number',
        'branch',
        'branch_code',
        'swift_code',
        'reference',
      ],
    };
    // A field error this form cannot show (an unknown key, or a method_id
    // code with no notice of its own). Refusals with their own notice
    // (`unchanged`, `sample_only`) are said there instead.
    final unread =
        st.notice == GivingNotice.invalid &&
        errors.keys.any((k) => !known.contains(k) || !shownWires.contains(k));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            g == null ? 'New giving method' : 'Edit ${g.current.name}',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          g != null && g.live != null
              ? 'Saving makes a draft that an Admin who saved none of its '
                    'changes must verify, so you can\'t verify changes you '
                    'save. Givers keep seeing the live details until the '
                    'draft is verified and published.'
              : 'Saved as a private draft. An Admin who saved none of it '
                    'must verify it before it can be published.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 12),
        if (g == null) ...[
          RadioSegments<GivingMethodType>(
            label: 'Kind of method',
            options: [
              for (final t in GivingMethodType.values)
                SegmentOption(t, t.label),
            ],
            selected: _type,
            onChanged: busy
                ? null
                : (t) {
                    setState(() => _type = t);
                    _edited();
                  },
          ),
          const SizedBox(height: 4),
          Text(
            'The kind can\'t change once the method is saved.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
        ] else ...[
          Text(
            'Kind: ${g.methodType.label}',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
        ],
        field(
          'giving-name',
          _name,
          'Name',
          wire: 'name',
          maxLength: 60,
          required: true,
          hint: 'For example: Airtel Money',
        ),
        field(
          'giving-purpose',
          _purpose,
          'Purpose',
          wire: 'purpose',
          maxLength: 60,
        ),
        field(
          'giving-currency',
          _currency,
          'Currency',
          wire: 'currency',
          maxLength: 3,
          hint: 'ZMW',
        ),
        if (_type == GivingMethodType.mobileMoney) ...[
          field(
            'giving-beneficiary',
            _beneficiary,
            'Beneficiary (the name the provider shows)',
            wire: 'beneficiary',
            required: true,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: RadioSegments<MobileMoneyIdentifier>(
              label: 'Identifier',
              options: [
                for (final k in MobileMoneyIdentifier.values)
                  SegmentOption(k, k.label),
              ],
              selected: _identifierKind,
              onChanged: busy
                  ? null
                  : (k) {
                      setState(() => _identifierKind = k);
                      _edited();
                    },
            ),
          ),
          field(
            'giving-identifier',
            _identifier,
            _identifierKind.label,
            wire: 'identifier',
            maxLength: 40,
            required: true,
          ),
          field(
            'giving-ussd',
            _ussd,
            'Starting code',
            wire: 'ussd_code',
            maxLength: 22,
            hint: '*115#',
          ),
        ],
        if (_type == GivingMethodType.bank) ...[
          field(
            'giving-bank-name',
            _bankName,
            'Bank',
            wire: 'bank_name',
            maxLength: 80,
            required: true,
          ),
          field(
            'giving-beneficiary',
            _beneficiary,
            'Account name',
            wire: 'beneficiary',
            required: true,
          ),
          field(
            'giving-account-number',
            _accountNumber,
            'Account number',
            wire: 'account_number',
            maxLength: 34,
            required: true,
          ),
          field(
            'giving-branch',
            _branch,
            'Branch',
            wire: 'branch',
            maxLength: 80,
          ),
          field(
            'giving-branch-code',
            _branchCode,
            'Branch code',
            wire: 'branch_code',
            maxLength: 20,
          ),
          field(
            'giving-swift',
            _swift,
            'SWIFT code',
            wire: 'swift_code',
            maxLength: 11,
          ),
          field(
            'giving-reference',
            _reference,
            'Reference',
            wire: 'reference',
            hint: 'For example: TITHE + your name',
          ),
        ],
        const SizedBox(height: 4),
        _StepsEditor(
          tag: tag,
          steps: _steps,
          busy: busy,
          error: _fieldError('steps', errors['steps']),
          onEdited: _edited,
          onAdd: () => _changeSteps(() => _steps.add(_StepField(''))),
          onRemove: (i) => _changeSteps(() {
            final removed = _steps.removeAt(i);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => removed.controller.dispose(),
            );
          }),
          onMove: (i, to) => _changeSteps(() {
            final s = _steps.removeAt(i);
            _steps.insert(to, s);
          }),
        ),
        const SizedBox(height: 8),
        field('giving-note', _note, 'Note', wire: 'note', maxLength: 200),
        field(
          'giving-contact',
          _contact,
          'Contact for questions',
          wire: 'contact',
          maxLength: 160,
          required: true,
          hint: 'For example: the church office, +260 ...',
        ),
        if (unread)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'The server could not read this method. Reload and try again.',
              key: Key('giving-form-unread-$tag'),
              style: TextStyle(color: c.redFg),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ValueListenableBuilder(
              valueListenable: _changed,
              builder: (context, _, _) {
                final input = _input();
                return FocusRing(
                  child: FilledButton(
                    key: Key('giving-save-$tag'),
                    onPressed: busy || input == null
                        ? null
                        : () {
                            final ctl = ref.read(staffGivingProvider.notifier);
                            if (g == null) {
                              ctl.create(input);
                            } else {
                              ctl.save(g, input);
                            }
                          },
                    child: const Text('Save draft'),
                  ),
                );
              },
            ),
            FocusRing(
              child: TextButton(
                key: Key('giving-cancel-$tag'),
                onPressed: busy ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
        // Save draft says why it is unavailable.
        ValueListenableBuilder(
          valueListenable: _changed,
          builder: (context, _, _) => _input() != null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'To save, fill in every field not marked optional and at '
                    'least one step.',
                    key: Key('giving-save-hint-$tag'),
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The ordered steps: one line each, added, removed and reordered with
/// named buttons.
class _StepsEditor extends StatelessWidget {
  const _StepsEditor({
    required this.tag,
    required this.steps,
    required this.busy,
    required this.error,
    required this.onEdited,
    required this.onAdd,
    required this.onRemove,
    required this.onMove,
  });

  final String tag;
  final List<_StepField> steps;
  final bool busy;
  final String? error;
  final VoidCallback onEdited;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;
  final void Function(int from, int to) onMove;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Column(
      key: Key('giving-steps-$tag'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CardLabel('Steps'),
        const SizedBox(height: 4),
        Text(
          'What the giver does, in order: one line each, at most '
          '$givingMaxSteps.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 8),
        // Each row keeps its identity (the step's key) when steps move, so
        // the moved step's field and buttons keep focus; finders use the
        // buttons' names.
        for (final (i, s) in steps.indexed)
          Padding(
            key: s.key,
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: s.controller,
                    enabled: !busy,
                    maxLength: 200,
                    onChanged: (_) => onEdited(),
                    decoration: InputDecoration(labelText: 'Step ${i + 1}'),
                  ),
                ),
                const SizedBox(width: 4),
                FocusRing(
                  radius: 22,
                  child: IconButton(
                    style: _moveStyle(c),
                    tooltip: 'Move step ${i + 1} up',
                    onPressed: busy || i == 0 ? null : () => onMove(i, i - 1),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ),
                FocusRing(
                  radius: 22,
                  child: IconButton(
                    style: _moveStyle(c),
                    tooltip: 'Move step ${i + 1} down',
                    onPressed: busy || i == steps.length - 1
                        ? null
                        : () => onMove(i, i + 1),
                    icon: const Icon(Icons.arrow_downward),
                  ),
                ),
                FocusRing(
                  radius: 22,
                  child: IconButton(
                    style: _moveStyle(c),
                    tooltip: 'Remove step ${i + 1}',
                    onPressed: busy || steps.length == 1
                        ? null
                        : () => onRemove(i),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        if (error case final e?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              e,
              key: Key('giving-steps-error-$tag'),
              style: ChurchType.secondary.copyWith(color: c.redFg),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FocusRing(
            child: TextButton.icon(
              key: Key('giving-step-add-$tag'),
              onPressed: busy || steps.length >= givingMaxSteps ? null : onAdd,
              icon: const Icon(Icons.add),
              label: Text(
                steps.length >= givingMaxSteps
                    ? 'At most $givingMaxSteps steps'
                    : 'Add a step',
              ),
            ),
          ),
        ),
      ],
    );
  }
}
