/// Published sermon teaching and the editors' revisioned catalog (story 6.9).
library;

import 'dart:typed_data';

import 'access_grants.dart';
import 'content_banners.dart';
import 'content_events.dart' show ContentState;
import 'content_giving.dart' show parseChurchDate;
import 'wire_json.dart';

Map _object(Object? raw, String name, Set<String> keys) {
  final m = wireMap(raw, name);
  if (m.length != keys.length || m.keys.any((k) => !keys.contains(k))) {
    throw FormatException('unexpected $name fields');
  }
  return m;
}

// Entry 6.16: the shared wire readers (wire_json.dart), under the short
// names this library has always used.
const _text = wireText;

const sermonLinkHosts = {
  'ebible.org',
  'biblegateway.com',
  'www.biblegateway.com',
  'youtube.com',
  'www.youtube.com',
  'youtu.be',
};

/// The editor may paste a normal HTTPS watch, shorts, embed or short link.
/// Commands always receive just the strict 11-character ID.
String? normalizeSermonVideoId(String input) {
  final text = input.trim();
  final id = RegExp(r'^[A-Za-z0-9_-]{11}$');
  if (id.hasMatch(text)) return text;
  if (!RegExp(r'^https://(?:www[.])?(?:youtube[.]com|youtu[.]be)(?:[/#?]|$)')
      .hasMatch(text)) {
    return null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.authority != uri.host ||
      !const {
        'youtube.com',
        'www.youtube.com',
        'youtu.be',
      }.contains(uri.host)) {
    return null;
  }
  final parts = uri.pathSegments;
  String? candidate;
  if (uri.host == 'youtu.be' && parts.length == 1) {
    candidate = parts.single;
  } else if (uri.host != 'youtu.be') {
    if (uri.path == '/watch' && uri.queryParametersAll['v']?.length == 1) {
      candidate = uri.queryParameters['v'];
    } else if (parts.length == 2 &&
        const {'shorts', 'embed'}.contains(parts.first)) {
      candidate = parts.last;
    }
  }
  return candidate != null && id.hasMatch(candidate) ? candidate : null;
}

/// Why a pasted Facebook link was refused, the same codes as the server's
/// `app.content_sermon_facebook_url`.
enum SermonFacebookProblem { invalid, notFacebook, notEmbeddable, tooLong }

/// The stored (normal) form of a Facebook video or live link, exactly as the
/// server writes it: `https://www.facebook.com/<page>/videos/<id>/`,
/// `https://www.facebook.com/watch/?v=<id>` or `https://fb.watch/<code>/`.
final _facebookNormal = RegExp(
  r'^https://(?:www[.]facebook[.]com/(?:[A-Za-z0-9][A-Za-z0-9.-]{0,99}/videos/[0-9]{5,25}/'
  r'|watch/[?]v=[0-9]{5,25})|fb[.]watch/[A-Za-z0-9_-]{5,32}/)$',
);
bool isNormalFacebookVideoUrl(String value) => _facebookNormal.hasMatch(value);

/// Mirrors the server's exact allowlist so the editor can explain a refusal
/// before sending; the server validates and normalises again.
({String? url, SermonFacebookProblem? problem}) normalizeSermonFacebookUrl(
  String input,
) {
  const none = (url: null, problem: null);
  ({String? url, SermonFacebookProblem? problem}) fail(
    SermonFacebookProblem p,
  ) => (url: null, problem: p);
  final text = input.trim();
  if (text.isEmpty) return none;
  if (text.runes.length > 500) return fail(SermonFacebookProblem.tooLong);
  final m = RegExp(
    r'^https://([A-Za-z0-9.-]+)(/[A-Za-z0-9._/-]*)?([?][A-Za-z0-9._~%=&+-]*)?(#[A-Za-z0-9._~%=&+/-]*)?$',
  ).firstMatch(text);
  if (m == null) return fail(SermonFacebookProblem.invalid);
  final host = m[1]!.toLowerCase();
  final path = m[2] ?? '/';
  final query = (m[3] ?? '').replaceFirst('?', '');
  if (host == 'fb.watch') {
    final code = RegExp(r'^/([A-Za-z0-9_-]{5,32})/?$').firstMatch(path);
    return code == null
        ? fail(SermonFacebookProblem.invalid)
        : (url: 'https://fb.watch/${code[1]}/', problem: null);
  }
  if (!const {
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'web.facebook.com',
  }.contains(host)) {
    return fail(SermonFacebookProblem.notFacebook);
  }
  if (RegExp(r'^/watch(?:/live)?/?$').hasMatch(path)) {
    final ids = [
      for (final p in RegExp(r'(?:^|&)v=([^&]*)').allMatches(query)) p[1]!,
    ];
    return ids.length != 1 || !RegExp(r'^[0-9]{5,25}$').hasMatch(ids.single)
        ? fail(SermonFacebookProblem.invalid)
        : (
            url: 'https://www.facebook.com/watch/?v=${ids.single}',
            problem: null,
          );
  }
  final video = RegExp(
    r'^/([A-Za-z0-9][A-Za-z0-9.-]{0,99})/videos/([0-9]{5,25})/?$',
  ).firstMatch(path);
  if (video != null) {
    return (
      url: 'https://www.facebook.com/${video[1]}/videos/${video[2]}/',
      problem: null,
    );
  }
  if (RegExp(r'^/[A-Za-z0-9][A-Za-z0-9.-]{0,99}/live(?:_videos)?/?$')
      .hasMatch(path)) {
    return fail(SermonFacebookProblem.notEmbeddable);
  }
  return fail(SermonFacebookProblem.invalid);
}

/// Facebook's embedded video player for a stored link: no autoplay and no
/// text panel. It plays public videos and live broadcasts without signing in.
/// [width] (logical pixels) sizes the player to its 16:9 slot.
Uri facebookSermonEmbedUri(String videoUrl, {int? width}) {
  if (!isNormalFacebookVideoUrl(videoUrl)) {
    throw ArgumentError.value(videoUrl, 'videoUrl', 'not a stored link');
  }
  final w = width?.clamp(220, 1280);
  return Uri.https('www.facebook.com', '/plugins/video.php', {
    'href': videoUrl,
    'show_text': 'false',
    'autoplay': 'false',
    'mute': 'false',
    'allowfullscreen': 'true',
    if (w != null) 'width': '$w',
    if (w != null) 'height': '${(w * 9 / 16).round()}',
  });
}

/// Exact HTTPS authorities only: no credentials, ports or encoded hosts. The
/// same characters as the server's `app.content_sermon_link_ok`.
Uri? safeSermonLink(String value) {
  if (!RegExp(r'''^https://[a-z.]+(?:[/?#][^\s<>\[\]()"'\\]*)?$''')
      .hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      !sermonLinkHosts.contains(uri.host) ||
      uri.authority != uri.host) {
    return null;
  }
  return uri;
}

/// Refuse unsupported Markdown instead of relying on a renderer's defaults.
/// The UI renders only the nodes this validator accepts; it never renders HTML.
/// It is never stricter than the server's `app.content_sermon_notes_error`
/// (which also refuses U+2028/U+2029 and counts characters, not UTF-16
/// units), so a note the server stored can always be read.
void validateSermonNotes(String value) {
  if (value.runes.length > 20000 ||
      RegExp(r'[<>`\\\x00-\x08\x0b\x0c\x0e-\x1f  ]').hasMatch(value) ||
      value.contains('![') ||
      value.contains('~~') ||
      RegExp(r'^\s*(?:>|\||[-*_]{3,}\s*$)', multiLine: true).hasMatch(value)) {
    throw const FormatException('unsupported sermon notes');
  }
  var remainder = value;
  final links = RegExp(r'\[([^\[\]\n]+)\]\(([^()\s]+)\)');
  for (final m in links.allMatches(value)) {
    if (safeSermonLink(m[2]!) == null) {
      throw const FormatException('unsafe sermon link');
    }
  }
  remainder = remainder.replaceAll(links, '');
  if (remainder.contains('[') ||
      remainder.contains(']') ||
      RegExp(
        r'(?:https?://|www\.)',
        caseSensitive: false,
      ).hasMatch(remainder) ||
      RegExp(
        r'^\s*#{7,}|^\s*\S.*\n\s*(?:===+|---+)\s*$',
        multiLine: true,
      ).hasMatch(remainder)) {
    throw const FormatException('unsupported sermon link form');
  }
}

class SermonPoster {
  const SermonPoster({
    required this.image,
    required this.rightsRevision,
    required this.offlineAllowed,
    this.offlineBytes,
  });

  factory SermonPoster.fromJson(Object? raw) {
    final m = _object(raw, 'sermon poster', const {
      'path',
      'media_type',
      'width',
      'height',
      'rights_revision',
      'offline_allowed',
    });
    return SermonPoster(
      image: PublicImage.fromJson(m),
      rightsRevision: wireRevision(m, 'rights_revision'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final PublicImage image;
  final int rightsRevision;
  final bool offlineAllowed;
  final Uint8List? offlineBytes;

  SermonPoster withBytes(Uint8List bytes) => SermonPoster(
    image: image,
    rightsRevision: rightsRevision,
    offlineAllowed: offlineAllowed,
    offlineBytes: bytes,
  );

  Map<String, Object?> toJson() => {
    'path': image.path,
    'media_type': image.mediaType,
    'width': image.width,
    'height': image.height,
    'rights_revision': rightsRevision,
    'offline_allowed': offlineAllowed,
  };
}

class PublicSermonSeries {
  const PublicSermonSeries({
    required this.seriesId,
    required this.title,
    required this.description,
    required this.altText,
    required this.poster,
    required this.publicationRevision,
    required this.publishedAt,
    required this.offlineAllowed,
  });

  factory PublicSermonSeries.fromJson(Object? raw) {
    final m = _object(raw, 'sermon series', const {
      'series_id',
      'title',
      'description',
      'alt_text',
      'poster',
      'publication_revision',
      'published_at',
      'offline_allowed',
    });
    return PublicSermonSeries(
      seriesId: _text(m, 'series_id'),
      title: _text(m, 'title'),
      description: wireReq<String>(m, 'description'),
      altText: wireReq<String>(m, 'alt_text'),
      poster: m['poster'] == null ? null : SermonPoster.fromJson(m['poster']),
      publicationRevision: wireRevision(m, 'publication_revision'),
      publishedAt: wireInstant(m, 'published_at'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final String seriesId;
  final String title;
  final String description;
  final String altText;
  final SermonPoster? poster;
  final int publicationRevision;
  final DateTime publishedAt;
  final bool offlineAllowed;

  PublicSermonSeries withPoster(SermonPoster? value) => PublicSermonSeries(
    seriesId: seriesId,
    title: title,
    description: description,
    altText: altText,
    poster: value,
    publicationRevision: publicationRevision,
    publishedAt: publishedAt,
    offlineAllowed: offlineAllowed,
  );

  Map<String, Object?> toJson() => {
    'series_id': seriesId,
    'title': title,
    'description': description,
    'alt_text': altText,
    'poster': poster?.toJson(),
    'publication_revision': publicationRevision,
    'published_at': publishedAt.toIso8601String(),
    'offline_allowed': offlineAllowed,
  };
}

class PublicSermon {
  const PublicSermon({
    required this.sermonId,
    required this.title,
    required this.speaker,
    required this.sermonDate,
    required this.scriptureReference,
    required this.notes,
    required this.series,
    required this.youtubeVideoId,
    this.facebookVideoUrl,
    required this.rightsRevision,
    required this.publicationRevision,
    required this.publishedAt,
    required this.offlineAllowed,
  });

  factory PublicSermon.fromJson(Object? raw) {
    final m = _object(raw, 'sermon', const {
      'sermon_id',
      'title',
      'speaker',
      'sermon_date',
      'scripture_reference',
      'notes',
      'series',
      'youtube_video_id',
      'facebook_video_url',
      'rights_revision',
      'publication_revision',
      'published_at',
      'offline_allowed',
    });
    final date = parseChurchDate(wireReq<String>(m, 'sermon_date'));
    final notes = wireReq<String>(m, 'notes');
    validateSermonNotes(notes);
    final video = wireOpt<String>(m, 'youtube_video_id');
    final facebook = wireOpt<String>(m, 'facebook_video_url');
    final rights = wireOpt<int>(m, 'rights_revision');
    if (date == null ||
        (video != null && !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(video)) ||
        (facebook != null && !isNormalFacebookVideoUrl(facebook)) ||
        (video != null && facebook != null) ||
        (rights != null && rights < 1) ||
        ((video != null || facebook != null) && rights == null)) {
      throw const FormatException('unexpected sermon video/date');
    }
    return PublicSermon(
      sermonId: _text(m, 'sermon_id'),
      title: _text(m, 'title'),
      speaker: _text(m, 'speaker'),
      sermonDate: date,
      scriptureReference: _text(m, 'scripture_reference'),
      notes: notes,
      series: m['series'] == null
          ? null
          : PublicSermonSeries.fromJson(m['series']),
      youtubeVideoId: video,
      facebookVideoUrl: facebook,
      rightsRevision: rights,
      publicationRevision: wireRevision(m, 'publication_revision'),
      publishedAt: wireInstant(m, 'published_at'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final String sermonId;
  final String title;
  final String speaker;
  final DateTime sermonDate;
  final String scriptureReference;
  final String notes;
  final PublicSermonSeries? series;
  final String? youtubeVideoId;

  /// Story 6.10: a public Facebook video or live link in its stored form; a
  /// sermon has at most one video source.
  final String? facebookVideoUrl;
  final int? rightsRevision;
  final int publicationRevision;

  /// Whether this answer carries a playable video from either source.
  bool get hasVideo => youtubeVideoId != null || facebookVideoUrl != null;
  final DateTime publishedAt;
  final bool offlineAllowed;

  PublicSermon withSeries(PublicSermonSeries? value) => PublicSermon(
    sermonId: sermonId,
    title: title,
    speaker: speaker,
    sermonDate: sermonDate,
    scriptureReference: scriptureReference,
    notes: notes,
    series: value,
    youtubeVideoId: youtubeVideoId,
    facebookVideoUrl: facebookVideoUrl,
    rightsRevision: rightsRevision,
    publicationRevision: publicationRevision,
    publishedAt: publishedAt,
    offlineAllowed: offlineAllowed,
  );

  Map<String, Object?> toJson({bool cache = false}) => {
    'sermon_id': sermonId, 'title': title, 'speaker': speaker,
    'sermon_date': sermonDate.toIso8601String().substring(0, 10),
    'scripture_reference': scriptureReference,
    'notes': notes,
    'series': series?.toJson(),
    // Offline teaching never starts a third-party player or stores its media.
    'youtube_video_id': cache ? null : youtubeVideoId,
    'facebook_video_url': cache ? null : facebookVideoUrl,
    'rights_revision': cache ? null : rightsRevision,
    'publication_revision': publicationRevision,
    'published_at': publishedAt.toIso8601String(),
    'offline_allowed': offlineAllowed,
  };
}

class PublicSermons {
  const PublicSermons({
    required this.sermons,
    required this.series,
    this.truncated = false,
  });
  factory PublicSermons.fromJson(Object? raw) {
    final m = _object(raw, 'sermons catalog', const {
      'sermons',
      'series',
      'truncated',
    });
    return PublicSermons(
      sermons: List.unmodifiable(
        wireReq<List>(m, 'sermons').map(PublicSermon.fromJson),
      ),
      series: List.unmodifiable(
        wireReq<List>(m, 'series').map(PublicSermonSeries.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }
  final List<PublicSermon> sermons;
  final List<PublicSermonSeries> series;
  final bool truncated;
  PublicSermon? byId(String id) =>
      sermons.where((s) => s.sermonId == id).firstOrNull;

  /// The series the church is preaching now: the series of the newest sermon
  /// that belongs to a published series. Null when no sermon is in one.
  PublicSermonSeries? get currentSeries {
    for (final sermon in sermons) {
      final id = sermon.series?.seriesId;
      if (id == null) continue;
      final match = series.where((s) => s.seriesId == id).firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  List<PublicSermon> filter({
    String query = '',
    String? seriesId,
    String? speaker,
  }) {
    final q = query.trim().toLowerCase();
    return sermons
        .where(
          (s) =>
              (seriesId == null || s.series?.seriesId == seriesId) &&
              (speaker == null || s.speaker == speaker) &&
              (q.isEmpty ||
                  '${s.title} ${s.speaker} ${s.series?.title ?? ''}'
                      .toLowerCase()
                      .contains(q)),
        )
        .toList();
  }

  Map<String, Object?> toCacheJson() => {
    'sermons': sermons.map((s) => s.toJson(cache: true)).toList(),
    'series': series.map((s) => s.toJson()).toList(),
    'truncated': truncated,
  };
}

class PublicSermonRead {
  const PublicSermonRead(this.sermon);
  factory PublicSermonRead.fromJson(Object? raw) {
    final m = _object(raw, 'sermon detail', const {'sermon'});
    return PublicSermonRead(
      m['sermon'] == null ? null : PublicSermon.fromJson(m['sermon']),
    );
  }
  final PublicSermon? sermon;
}

class SermonInput {
  const SermonInput({
    required this.title,
    this.speaker = '',
    this.sermonDate,
    this.scriptureReference = '',
    this.notes = '',
    this.seriesId,
    this.youtubeVideoId,
    this.facebookVideoUrl,
    this.videoRightsId,
  });
  final String title, speaker, scriptureReference, notes;
  final String? sermonDate, seriesId, youtubeVideoId, videoRightsId;
  final String? facebookVideoUrl;
  Map<String, Object?> toPayload({String? sermonId}) => {
    'sermon_id': ?sermonId,
    'title': title.trim(),
    'speaker': speaker.trim(),
    'sermon_date': sermonDate,
    'scripture_reference': scriptureReference.trim(),
    'notes': notes.trim(),
    'series_id': seriesId,
    'youtube_video_id': youtubeVideoId,
    'facebook_video_url': facebookVideoUrl,
    'video_rights_id': videoRightsId,
  };
}

class SermonSeriesInput {
  const SermonSeriesInput({
    required this.title,
    this.description = '',
    this.altText = '',
    this.posterAssetId,
    this.posterRightsId,
  });
  final String title, description, altText;
  final String? posterAssetId, posterRightsId;
  Map<String, Object?> toPayload({String? seriesId}) => {
    'series_id': ?seriesId,
    'title': title.trim(),
    'description': description.trim(),
    'alt_text': altText.trim(),
    if (seriesId != null) 'poster_asset_id': posterAssetId,
    if (seriesId != null) 'poster_rights_id': posterRightsId,
  };
}

class StaffSermonRevision {
  StaffSermonRevision({
    required this.revisionNo,
    required this.fields,
    required this.videoRights,
    required this.savedAt,
    required this.savedBy,
  });
  factory StaffSermonRevision.fromJson(Object? raw) {
    final m = wireMap(raw, 'sermon revision');
    final notes = wireReq<String>(m, 'notes');
    validateSermonNotes(notes);
    final date = wireOpt<String>(m, 'sermon_date');
    if (date != null && parseChurchDate(date) == null) {
      throw const FormatException('unexpected sermon_date');
    }
    return StaffSermonRevision(
      revisionNo: wireRevision(m, 'revision_no'),
      fields: SermonInput(
        title: _text(m, 'title'),
        speaker: wireReq<String>(m, 'speaker'),
        sermonDate: date,
        scriptureReference: wireReq<String>(m, 'scripture_reference'),
        notes: notes,
        seriesId: wireOpt<String>(m, 'series_id'),
        youtubeVideoId: wireOpt<String>(m, 'youtube_video_id'),
        facebookVideoUrl: wireOpt<String>(m, 'facebook_video_url'),
        videoRightsId: m['video_rights'] == null
            ? null
            : BannerRights.fromJson(m['video_rights']).rightsId,
      ),
      videoRights: m['video_rights'] == null
          ? null
          : BannerRights.fromJson(m['video_rights']),
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: _text(m, 'saved_by'),
    );
  }
  final int revisionNo;
  final SermonInput fields;
  final BannerRights? videoRights;
  final DateTime savedAt;
  final String savedBy;
}

class StaffSermonSeriesRevision {
  StaffSermonSeriesRevision({
    required this.revisionNo,
    required this.fields,
    required this.poster,
    required this.rights,
    required this.savedAt,
    required this.savedBy,
  });
  factory StaffSermonSeriesRevision.fromJson(Object? raw) {
    final m = wireMap(raw, 'series revision');
    final poster = m['poster'] == null
        ? null
        : StaffImage.fromJson(m['poster']);
    final rights = m['rights'] == null
        ? null
        : BannerRights.fromJson(m['rights']);
    return StaffSermonSeriesRevision(
      revisionNo: wireRevision(m, 'revision_no'),
      fields: SermonSeriesInput(
        title: _text(m, 'title'),
        description: wireReq<String>(m, 'description'),
        altText: wireReq<String>(m, 'alt_text'),
        posterAssetId: poster?.assetId,
        posterRightsId: rights?.rightsId,
      ),
      poster: poster,
      rights: rights,
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: _text(m, 'saved_by'),
    );
  }
  final int revisionNo;
  final SermonSeriesInput fields;
  final StaffImage? poster;
  final BannerRights? rights;
  final DateTime savedAt;
  final String savedBy;
}

/// Shared lifecycle shape, retaining separate typed revision tables.
class StaffSermonItem<T> {
  StaffSermonItem({
    required this.id,
    required this.revision,
    required this.state,
    required this.live,
    required this.draft,
    required this.publishedAt,
    required this.publishedBy,
    this.publicImage,
    this.fromDuty,
  });
  factory StaffSermonItem.fromJson(
    Object? raw,
    String idKey,
    T Function(Object?) parse,
  ) {
    final m = wireMap(raw, 'staff sermon item');
    final state = ContentState.parse(m['state']);
    final live = m['live'] == null ? null : parse(m['live']);
    final draft = m['draft'] == null ? null : parse(m['draft']);
    if ((live == null && draft == null) ||
        (state == ContentState.draft && (live != null || draft == null)) ||
        ((state == ContentState.published || state == ContentState.withdrawn) &&
            live == null)) {
      throw const FormatException('unexpected staff sermon revisions');
    }
    return StaffSermonItem(
      id: _text(m, idKey),
      revision: wireRevision(m),
      state: state,
      live: live,
      draft: draft,
      publishedAt: wireOptInstant(m, 'published_at'),
      publishedBy: wireOpt<String>(m, 'published_by'),
      publicImage: PublicImageState.parse(m['public_image']),
      fromDuty: m['from_duty'] == null
          ? null
          : SermonFromDuty.fromJson(m['from_duty']),
    );
  }
  final String id;
  final int revision;
  final ContentState state;
  final T? live, draft;
  final DateTime? publishedAt;
  final String? publishedBy;

  /// A published series whose live revision has a poster: whether the public
  /// file is placed (null without a poster, and for sermons).
  final PublicImageState? publicImage;

  /// Story 6.18: a sermon draft sent from a duty (null otherwise).
  final SermonFromDuty? fromDuty;
  T get current => (draft ?? live)!;
  bool get canEdit => state != ContentState.archived;
  bool get canPublish =>
      canEdit && (draft != null || state == ContentState.withdrawn);
  bool get canWithdraw => state == ContentState.published;
  bool get hasChanges => state == ContentState.published && draft != null;
}

typedef StaffSermon = StaffSermonItem<StaffSermonRevision>;
typedef StaffSermonSeries = StaffSermonItem<StaffSermonSeriesRevision>;

class StaffSermons {
  const StaffSermons({
    required this.capacity,
    required this.sermons,
    this.truncated = false,
  });
  factory StaffSermons.fromJson(Object? raw) {
    final m = wireMap(raw, 'staff sermons');
    return StaffSermons(
      capacity: _capacity(m),
      sermons: List.unmodifiable(
        wireReq<List>(m, 'sermons').map(
          (s) => StaffSermon.fromJson(
            s,
            'sermon_id',
            StaffSermonRevision.fromJson,
          ),
        ),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }
  final String capacity;
  final List<StaffSermon> sermons;
  final bool truncated;
}

class StaffSermonSeriesCatalog {
  const StaffSermonSeriesCatalog({
    required this.capacity,
    required this.series,
    this.removalsPending = 0,
    this.truncated = false,
  });
  factory StaffSermonSeriesCatalog.fromJson(Object? raw) {
    final m = wireMap(raw, 'staff sermon series');
    final pending = wireReq<int>(m, 'removals_pending');
    if (pending < 0) throw const FormatException('unexpected removals_pending');
    return StaffSermonSeriesCatalog(
      capacity: _capacity(m),
      series: List.unmodifiable(
        wireReq<List>(m, 'series').map(
          (s) => StaffSermonSeries.fromJson(
            s,
            'series_id',
            StaffSermonSeriesRevision.fromJson,
          ),
        ),
      ),
      removalsPending: pending,
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }
  final String capacity;
  final List<StaffSermonSeries> series;
  final int removalsPending;
  final bool truncated;
}

const _capacity = wireEditorCapacity;

/// Story 6.18: the duty a sermon draft was sent from, as the editors read it:
/// the duty's name and start when it was sent, and when. Never who sent it.
class SermonFromDuty {
  const SermonFromDuty({
    required this.dutyName,
    required this.dutyStartsAt,
    required this.sentAt,
  });
  factory SermonFromDuty.fromJson(Object? raw) {
    final m = _object(raw, 'from_duty', const {
      'duty_name',
      'duty_starts_at',
      'sent_at',
    });
    return SermonFromDuty(
      dutyName: _text(m, 'duty_name'),
      dutyStartsAt: wireInstant(m, 'duty_starts_at'),
      sentAt: wireInstant(m, 'sent_at'),
    );
  }
  final String dutyName;
  final DateTime dutyStartsAt;
  final DateTime sentAt;
}

/// Story 6.18, `api.content_duty_sermon_draft`: whether a duty's topic and
/// scripture can be sent to Media, and whether they were. Read by the duty's
/// current assignee or its managers; anyone else is refused.
class DutySermonDraft {
  const DutySermonDraft({
    required this.occurrenceId,
    required this.canSend,
    this.sentAt,
    this.published = false,
  });
  factory DutySermonDraft.fromJson(Object? raw) {
    final m = _object(raw, 'duty sermon draft', const {
      'occurrence_id',
      'can_send',
      'draft',
    });
    final draft = m['draft'] == null
        ? null
        : _object(m['draft'], 'draft', const {'sent_at', 'published'});
    return DutySermonDraft(
      occurrenceId: _text(m, 'occurrence_id'),
      canSend: wireReq<bool>(m, 'can_send'),
      sentAt: draft == null ? null : wireInstant(draft, 'sent_at'),
      published: draft == null ? false : wireReq<bool>(draft, 'published'),
    );
  }
  final String occurrenceId;
  final bool canSend;

  /// When it was sent to Media (null: not yet).
  final DateTime? sentAt;

  /// Media has published the sermon.
  final bool published;
  bool get sent => sentAt != null;
}

abstract final class SermonCommands {
  static const create = 'content.create_sermon';
  static const save = 'content.save_sermon';
  static const publish = 'content.publish_sermon';
  static const withdraw = 'content.withdraw_sermon';
  static const archive = 'content.archive_sermon';
  static const createSeries = 'content.create_sermon_series';
  static const saveSeries = 'content.save_sermon_series';
  static const publishSeries = 'content.publish_sermon_series';
  static const withdrawSeries = 'content.withdraw_sermon_series';
  static const archiveSeries = 'content.archive_sermon_series';
  static const posterPurpose = 'sermon_series_poster';

  /// Story 6.18, a member command: the duty's assignee or its managers.
  static const draftFromDuty = 'content.draft_sermon_from_duty';
}

abstract interface class SermonsRepository {
  Future<AccessRead<PublicSermons>> fetchPublicSermons();
  Future<AccessRead<PublicSermonRead>> fetchPublicSermon(String sermonId);
  Future<AccessRead<StaffSermons>> fetchStaffSermons();
  Future<AccessRead<StaffSermonSeriesCatalog>> fetchStaffSeries();

  /// Story 6.18: the duty's assignee or managers only.
  Future<AccessRead<DutySermonDraft>> fetchDutySermonDraft(String occurrenceId);
}

class UnconfiguredSermonsRepository implements SermonsRepository {
  const UnconfiguredSermonsRepository();
  @override
  Future<AccessRead<PublicSermons>> fetchPublicSermons() async =>
      const AccessReadDenied(AccessDenial.unavailable);
  @override
  Future<AccessRead<PublicSermonRead>> fetchPublicSermon(
    String sermonId,
  ) async => const AccessReadDenied(AccessDenial.unavailable);
  @override
  Future<AccessRead<StaffSermons>> fetchStaffSermons() async =>
      const AccessReadDenied(AccessDenial.unavailable);
  @override
  Future<AccessRead<StaffSermonSeriesCatalog>> fetchStaffSeries() async =>
      const AccessReadDenied(AccessDenial.unavailable);
  @override
  Future<AccessRead<DutySermonDraft>> fetchDutySermonDraft(
    String occurrenceId,
  ) async => const AccessReadDenied(AccessDenial.unavailable);
}

abstract interface class SermonLinkLauncher {
  Future<bool> open(Uri uri);
}

class UnavailableSermonLinkLauncher implements SermonLinkLauncher {
  const UnavailableSermonLinkLauncher();
  @override
  Future<bool> open(Uri uri) async => false;
}
