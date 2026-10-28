part of 'duties_screens.dart';

// Story 6.18: send a preaching duty's topic and scripture to Media as a
// sermon draft. Shown on the mobile duty detail (the duty's current assignee)
// and on the staff rota's date panel (its managers) when the duty has a topic
// or scripture. The server decides who may send (the Duties owner read) and
// makes one private draft per duty; Media completes and publishes it in the
// sermon editor, and nothing is published here.

/// The duty's Sermon section: "Send to Media", or when it was sent. A
/// refused read (not the assignee or a manager any more) shows nothing; a
/// failed read says so and offers Try again.
class DutySermonDraftSection extends ConsumerWidget {
  const DutySermonDraftSection({
    super.key,
    required this.occurrenceId,
    required this.keyPrefix,
  });

  final String occurrenceId;

  /// Prefix of every widget key (`duty-sermon-<occurrence>` on mobile,
  /// `rota-sermon-<occurrence>` on staff web).
  final String keyPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(dutySermonDraftProvider(occurrenceId));
    final ctl = ref.read(dutySermonDraftProvider(occurrenceId).notifier);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final k = '$keyPrefix-$occurrenceId';
    final loc = MaterialLocalizations.of(context);

    final draft = s.value;
    final Widget? body = switch (s.result) {
      null => null,
      AccessReadOk() when draft != null && draft.sent => Text(
        draft.published
            ? 'Sent to Media on '
                  '${loc.formatMediumDate(ChurchTime.wall(draft.sentAt!))}. '
                  'Media has published the sermon.'
            : 'Sent to Media on '
                  '${loc.formatMediumDate(ChurchTime.wall(draft.sentAt!))}. '
                  'Media adds the speaker and publishes it.',
        key: Key('$k-sent'),
        style: muted,
      ),
      AccessReadOk() when draft != null && draft.canSend => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Send the topic and scripture to Media to start the sermon '
            'page. Nothing is published until Media publishes it.',
            style: muted,
          ),
          const SizedBox(height: 8),
          FocusRing(
            child: OutlinedButton.icon(
              key: Key('$k-send'),
              onPressed: s.busy ? null : ctl.send,
              icon: const Icon(Icons.send_outlined, size: 18),
              label: Text(
                s.unconfirmed != null
                    ? 'Check again'
                    : s.busy
                    ? 'Sending…'
                    : 'Send to Media',
              ),
            ),
          ),
        ],
      ),
      AccessReadOk() => null,
      AccessReadDenied(denial: AccessDenial.notGranted) => null,
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not check whether this was sent to Media.',
            key: Key('$k-failed'),
            style: muted,
          ),
          FocusRing(
            child: TextButton(
              key: Key('$k-retry'),
              onPressed: s.loading ? null : ctl.reload,
              child: const Text('Try again'),
            ),
          ),
        ],
      ),
    };
    final notice = switch (s.notice) {
      DutySermonDraftNotice.sent => 'Sent. Media will prepare the sermon.',
      DutySermonDraftNotice.alreadySent =>
        'Media already has this duty\'s sermon draft.',
      DutySermonDraftNotice.noTopic =>
        'This duty has no topic or scripture to send.',
      DutySermonDraftNotice.notAllowed =>
        'Only the person on this duty or its leaders can send it.',
      DutySermonDraftNotice.signInAgain => 'Sign in again to send it.',
      DutySermonDraftNotice.notAvailable =>
        'Sending is not available right now.',
      DutySermonDraftNotice.refused => 'It could not be sent.',
      DutySermonDraftNotice.unconfirmed =>
        'We could not confirm it was sent. Check again.',
      DutySermonDraftNotice.notSent =>
        'Not sent. Check your connection and try again.',
      null => null,
    };
    if (body == null && notice == null) return const SizedBox.shrink();
    final warn =
        s.notice != null &&
        s.notice != DutySermonDraftNotice.sent &&
        s.notice != DutySermonDraftNotice.alreadySent;
    return Column(
      key: Key(k),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const CardLabel('Sermon'),
        const SizedBox(height: 6),
        ?body,
        if (notice != null) ...[
          const SizedBox(height: 6),
          Text(
            notice,
            key: Key('$k-notice'),
            style: ChurchType.secondary.copyWith(
              color: warn ? c.amberFg : c.ink,
            ),
          ),
        ],
      ],
    );
  }
}
