// Original fictional content for an owner pilot, not a record of church activity.
export const PROJECT_REF = 'tmurpotfluignacfueki';
export const STAGING_URL = 'https://' + PROJECT_REF + '.supabase.co';
export const HYMN_EDITION = 'bicc-tonga-2012';

export function churchDate(now = Date.now()) {
  return new Date(now + 2 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

export function buildManifest(anchorDate = churchDate()) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(anchorDate)
      || new Date(anchorDate + 'T00:00:00Z').toISOString().slice(0, 10) !== anchorDate) {
    throw new Error('Anchor date must be a valid YYYY-MM-DD Africa/Lusaka date.');
  }
  const anchor = Date.parse(anchorDate + 'T00:00:00Z');
  const firstSunday = (7 - new Date(anchor).getUTCDay()) % 7 || 7;
  const day = (offset) => new Date(anchor + offset * 86400000).toISOString().slice(0, 10);
  const at = (offset, clock) => new Date(day(offset) + 'T' + clock + ':00+02:00').toISOString();
  const namespace = 'SYNTHETIC PILOT ' + anchorDate;
  const title = (value) => namespace + ' | ' + value;
  const label = 'SYNTHETIC owner-test fixture. All names, plans and locations below are fictional; this is not a real church notice.';
  const series = [
    {
      key: 'series-neighbour',
      kind: 'sermon_series',
      fields: {
        title: title('Faith in everyday Kafue life'),
        description: label + ' Original practice teaching notes about listening, generosity of time and dependable neighbourly care. Prepared for app reading and search tests.',
        alt_text: '',
      },
    },
    {
      key: 'series-hope',
      kind: 'sermon_series',
      fields: {
        title: title('Hope that becomes service'),
        description: label + ' Original practice teaching notes about prayer, patient service and encouragement. No recording, photograph or third-party media is attached.',
        alt_text: '',
      },
    },
  ];
  const events = [
    {
      key: 'event-sunday',
      kind: 'event',
      fields: {
        title: title('Sunday worship and welcome'),
        description: label + ' A sample Sunday programme: welcome at 09:00, singing and Scripture reflection, then conversation over tea. Use this event to check the calendar, local time and detail screen. There is no attendance sign-up for this example.',
        starts_at: at(firstSunday, '09:00'),
        ends_at: at(firstSunday, '11:30'),
        location: 'SYNTHETIC Riverside fellowship hall, Kafue',
        rsvp_enabled: false,
        rsvp_capacity: null,
      },
    },
    {
      key: 'event-study',
      kind: 'event',
      fields: {
        title: title('Wednesday Scripture conversation'),
        description: label + ' A sample small-group evening on James 1:19-27. Bring questions and practise listening before offering advice. Thirty test spaces let the owner try Going and Cancel. Do not travel to this fictional meeting.',
        starts_at: at(firstSunday + 3, '17:30'),
        ends_at: at(firstSunday + 3, '19:00'),
        location: 'SYNTHETIC Chikondi meeting room, Kafue',
        rsvp_enabled: true,
        rsvp_capacity: 30,
      },
    },
    {
      key: 'event-service',
      kind: 'event',
      fields: {
        title: title('Neighbour-care planning morning'),
        description: label + ' A sample discussion about respectful visits, checking what help is wanted and sharing tasks fairly. The fictional programme includes a short welcome, planning groups and a closing review. RSVP has no capacity limit in this example.',
        starts_at: at(firstSunday + 6, '09:00'),
        ends_at: at(firstSunday + 6, '11:00'),
        location: 'SYNTHETIC Kafue community practice room',
        rsvp_enabled: true,
        rsvp_capacity: null,
      },
    },
    {
      key: 'event-weekend',
      kind: 'event',
      fields: {
        title: title('Youth music and reflection weekend'),
        description: label + ' A two-day calendar example with a Friday evening discussion and Saturday morning singing practice. The time span is for testing a multi-day event; it is not an overnight booking. Sixty test places are available.',
        starts_at: at(firstSunday + 12, '17:00'),
        ends_at: at(firstSunday + 13, '12:00'),
        location: 'SYNTHETIC Mupundu hall, Kafue',
        rsvp_enabled: true,
        rsvp_capacity: 60,
      },
    },
  ];
  const sermon = (key, name, speaker, offset, reference, seriesKey, paragraphs) => ({
    key, kind: 'sermon', series_key: seriesKey,
    fields: {
      title: title(name),
      speaker: 'SYNTHETIC ' + speaker + ' (fictional)',
      sermon_date: day(offset),
      scripture_reference: reference,
      notes: '# Original sample teaching notes\n\n' + label
        + ' These are prepared practice notes for the displayed future date, not a claim that a sermon has been delivered. Scripture references identify passages; no Bible translation is reproduced.\n\n'
        + paragraphs.join('\n\n'),
      youtube_video_id: null, facebook_video_url: null, video_rights_id: null,
    },
  });
  const sermons = [
    sermon('sermon-listening', 'Listening before speaking', 'Ruth Mwansa',
      firstSunday, 'James 1:19-27', 'series-neighbour', [
        '## Begin with attention\nA busy week can train us to answer before we understand. At a bus stop, in a family conversation or during a church meeting, patient attention gives another person room to explain. Listening is a practical way to respect the neighbour in front of us.',
        '## Let understanding lead to action\nJames connects hearing with doing. We can ask what help is actually useful, agree on one manageable task and follow through. A small promise kept is more helpful than an impressive promise forgotten.',
        '## Discuss together\n- When have you felt heard?\n- What makes us interrupt or assume?\n- Which ordinary responsibility could we carry out more faithfully this week?',
        '## A practice for the week\nBefore giving advice, ask one sincere question and repeat what you understood. If help is requested, agree on a realistic next step. Respect a person who declines help.',
        '## Closing prayer\nGod, give us patience to listen, courage to act with care and humility to learn from one another. Amen.',
      ]),
    sermon('sermon-neighbour', 'Care that crosses the road', 'Daniel Tembo',
      firstSunday + 7, 'Luke 10:25-37', 'series-neighbour', [
        '## Notice the person\nThe Good Samaritan invites reflection on who receives our attention. Neighbourly care begins when we stop treating another person as an interruption. We need not know a whole life story to offer a respectful greeting and ask what is needed.',
        '## Help with dignity\nGood intentions benefit from good questions. A household may need quiet, practical assistance or time to decide. Care should preserve choice and privacy. In a fictional Kafue planning group, the most useful first action might be listening rather than arriving with a fixed plan.',
        '## Share responsibility\nService becomes dependable when tasks and limits are clear. Agree who will do what, when they will report back and whom to contact if plans change. No one should promise money or transport on another person\'s behalf.',
        '## Discuss together\n- Whose needs are easy for us to overlook?\n- How can we offer help without taking control?\n- What small act of care can we sustain?',
        '## Closing prayer\nGod, open our eyes to our neighbours. Teach us to offer help with wisdom, kindness and respect. Amen.',
      ]),
    sermon('sermon-hope', 'Encouragement for the ordinary week', 'Esther Phiri',
      firstSunday + 14, 'Romans 12:9-18', 'series-hope', [
        '## Practise sincere care\nEncouragement can be simple: remembering a name, asking a thoughtful question or acknowledging work that is easy to miss. Sincere care is attentive to the person, not to the recognition the helper might receive.',
        '## Keep hope practical\nA difficult week does not always need a quick explanation. Patient company and a reliable next step can offer support. We can pray together, make room for grief and celebrate progress without pretending every problem is solved.',
        '## Seek peace responsibly\nLiving peaceably includes honest conversation and healthy limits. It does not require hiding harm or making promises we cannot keep. Where a problem needs skilled help, we can support a person in finding the appropriate assistance.',
        '## Discuss together\n- What encouragement has helped you continue?\n- Who does quiet work that deserves thanks?\n- What would a peaceful and honest conversation look like this week?',
        '## A practice for the week\nOffer one specific word of thanks and one realistic act of support. Follow through on the action you agreed.',
        '## Closing prayer\nGod of hope, help us to be patient in difficulty, faithful in prayer and generous in encouragement. Amen.',
      ]),
  ];
  const announcements = [
    {
      key: 'announcement-welcome', kind: 'announcement',
      fields: {
        title: title('Welcome to the owner phone pilot'),
        body: label + '\n\nThis staged content is here to practise browsing, search, Bible reading, hymns and event RSVP on the Samsung Galaxy A26. No fixture is a real invitation or payment request. Please record what you observe; this message does not mean any acceptance check has passed.',
        pinned: true,
      },
    },
    {
      key: 'announcement-study', kind: 'announcement',
      fields: {
        title: title('Sample midweek reading plan'),
        body: label + '\n\nFor the sample week beginning ' + day(firstSunday) + ', read James 1:19-27 and think about listening before speaking. Open the Bible reader using an already published translation if available. The fixture package does not import or approve a translation.',
        pinned: false,
      },
    },
    {
      key: 'announcement-music', kind: 'announcement',
      fields: {
        title: title('Sample Sunday music suggestions'),
        body: label + '\n\nSuggested selections from the existing Inyimbo zya Bakristo book: hymn 1, Leza Usimanga (Cila); hymn 12, Pupulala Basinkombe (Cila); hymn 45, Mbunono Ncobeni; hymn 100, Ibbwe Eli Ngu-Mwami Wesu. These suggestions do not replace the church\'s saved Sunday list. No lyrics are copied into this notice.',
        pinned: false,
      },
    },
  ];
  return {
    format: 1, project_ref: PROJECT_REF, timezone: 'Africa/Lusaka', anchor_date: anchorDate,
    namespace, label, items: [...series, ...events, ...sermons, ...announcements],
    sunday_hymns: {
      status: 'suggestion_only_no_write', sunday: day(firstSunday), edition: HYMN_EDITION,
      items: [
        { id: 'hymn-1', number: 1, title: 'Leza Usimanga (Cila)' },
        { id: 'hymn-12', number: 12, title: 'Pupulala Basinkombe (Cila)' },
        { id: 'hymn-45', number: 45, title: 'Mbunono Ncobeni' },
        { id: 'hymn-100', number: 100, title: 'Ibbwe Eli Ngu-Mwami Wesu' },
      ],
    },
    giving_proposal: {
      status: 'SAMPLE_only_not_executable', label: 'SAMPLE owner pilot giving information',
      body: 'Do not pay. No payment destination is supplied. The owner must provide the actual destination and the required independent eligible verifier must approve it before publication.',
      payment_destination: null, publish: false,
    },
    media: {
      status: 'owner_cleared_links_required',
      note: 'No sample video IDs, posters, logos or rights records are created. Positive playback needs owner-supplied links and the applicable recorded rights approval.',
    },
    bible: {
      status: 'read_existing_published_WEB_if_present',
      note: 'No source download, import, rights verification or policy approval is part of this package.',
    },
  };
}
