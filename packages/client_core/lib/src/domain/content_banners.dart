/// Story 6.2: Home banners, rights records and validated image uploads.
///
/// Everyone (signed in or not) reads the published banners
/// (`api.content_public_banners`): the yearly theme first, then campaigns,
/// each with an image the server has placed in the public bucket. Editors
/// (Media, Pastor, Admin) read every banner (`api.content_staff_banners`) and
/// every rights record (`api.content_staff_rights`), change them through
/// `api.content_command`, and upload images through the Edge function
/// `content-assets`, which measures the bytes (the declared type is never
/// trusted) and stores them in the private draft bucket. Free of widgets and
/// SDKs.
library;

import 'dart:typed_data';

import 'access_grants.dart';
import 'content_events.dart' show ContentState;
import 'wire_json.dart';

// Entry 6.16: the shared wire readers (wire_json.dart), under the short
// names this library has always used.
const _text = wireText;
const _optText = wireOptText;
const _positive = wirePositive;

/// The image media types the server accepts (PNG, JPEG, WebP).
const contentImageTypes = ['image/png', 'image/jpeg', 'image/webp'];

/// The bucket that serves published files to everyone.
const contentPublicBucket = 'content-public';

/// What a banner is.
enum BannerKind {
  /// The church's yearly theme: shown first.
  theme('theme'),

  /// A campaign or an event banner.
  campaign('campaign');

  const BannerKind(this.wire);
  final String wire;

  static BannerKind parse(Object? v) => switch (v) {
    'theme' => theme,
    'campaign' => campaign,
    _ => throw const FormatException('unexpected banner_kind'),
  };
}

/// The theme year a [kind] carries: required for a theme, absent for a
/// campaign.
int? _themeYear(Map m, BannerKind kind) {
  final year = wireOpt<int>(m, 'theme_year');
  if (kind == BannerKind.theme && (year == null || year < 2000)) {
    throw const FormatException('unexpected theme_year');
  }
  if (kind == BannerKind.campaign && year != null) {
    throw const FormatException('unexpected theme_year');
  }
  return year;
}

/// A published file as everyone reads it: its path in [contentPublicBucket].
class PublicImage {
  const PublicImage({
    required this.path,
    required this.mediaType,
    required this.width,
    required this.height,
  });

  factory PublicImage.fromJson(Object? json) {
    final m = wireMap(json, 'image');
    final type = wireReq<String>(m, 'media_type');
    if (!contentImageTypes.contains(type)) {
      throw const FormatException('unexpected media_type');
    }
    final path = _text(m, 'path');
    if (path.startsWith('/') || path.contains('..')) {
      throw const FormatException('unexpected path');
    }
    return PublicImage(
      path: path,
      mediaType: type,
      width: _positive(m, 'width'),
      height: _positive(m, 'height'),
    );
  }

  final String path;
  final String mediaType;
  final int width;
  final int height;
}

/// One published banner as everyone reads it: never a draft or who edited
/// it.
class PublicBanner {
  const PublicBanner({
    required this.bannerId,
    required this.kind,
    required this.themeYear,
    required this.title,
    required this.subtitle,
    required this.altText,
    required this.eventId,
    required this.image,
    required this.publicationRevision,
    required this.rightsRevision,
    required this.publishedAt,
    required this.offlineAllowed,
    this.offlineImageBytes,
  });

  /// Maps the wire object; throws [FormatException] on any other shape.
  factory PublicBanner.fromJson(Object? json) {
    final m = wireMap(json, 'banner');
    final kind = BannerKind.parse(m['banner_kind']);
    return PublicBanner(
      bannerId: _text(m, 'banner_id'),
      kind: kind,
      themeYear: _themeYear(m, kind),
      title: _text(m, 'title'),
      subtitle: _optText(m, 'subtitle'),
      altText: _text(m, 'alt_text'),
      eventId: _optText(m, 'event_id'),
      image: PublicImage.fromJson(m['image']),
      publicationRevision: wireRevision(m, 'publication_revision'),
      rightsRevision: wireRevision(m, 'rights_revision'),
      publishedAt: wireInstant(m, 'published_at'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final String bannerId;
  final BannerKind kind;

  /// The theme's year (`THEME FOR 2026`); null for a campaign.
  final int? themeYear;
  final String title;

  /// The theme's scripture reference or a campaign's short line.
  final String? subtitle;

  /// The image's text alternative.
  final String altText;

  /// The published event a campaign links to (public while that event is).
  final String? eventId;
  final PublicImage image;
  final int publicationRevision;
  final int rightsRevision;
  final DateTime publishedAt;

  /// Whether the current rights record clears offline storage for this image.
  final bool offlineAllowed;

  /// Local image bytes supplied only by the mobile cache adapter.
  /// It is never read from or written to the server projection.
  final Uint8List? offlineImageBytes;

  PublicBanner withOfflineImageBytes(Uint8List bytes) => PublicBanner(
    bannerId: bannerId,
    kind: kind,
    themeYear: themeYear,
    title: title,
    subtitle: subtitle,
    altText: altText,
    eventId: eventId,
    image: image,
    publicationRevision: publicationRevision,
    rightsRevision: rightsRevision,
    publishedAt: publishedAt,
    offlineAllowed: offlineAllowed,
    offlineImageBytes: bytes,
  );
}

/// `api.content_public_banners`: the theme first, then campaigns.
class PublicBanners {
  const PublicBanners(this.banners, {this.truncated = false});

  factory PublicBanners.fromJson(Object? json) {
    final m = wireMap(json, 'public banners');
    return PublicBanners(
      List.unmodifiable(wireReq<List>(m, 'banners').map(PublicBanner.fromJson)),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  final List<PublicBanner> banners;

  /// More public banners exist than the bounded carousel returns.
  final bool truncated;

  /// The banner with [bannerId], or null when it is not public.
  PublicBanner? byId(String bannerId) {
    for (final b in banners) {
      if (b.bannerId == bannerId) return b;
    }
    return null;
  }
}

/// A file an editor uploaded, as the editors' read describes it.
class StaffImage {
  const StaffImage({
    required this.assetId,
    required this.mediaType,
    required this.byteSize,
    required this.width,
    required this.height,
  });

  factory StaffImage.fromJson(Object? json) {
    final m = wireMap(json, 'image');
    final type = wireReq<String>(m, 'media_type');
    if (!contentImageTypes.contains(type)) {
      throw const FormatException('unexpected media_type');
    }
    return StaffImage(
      assetId: _text(m, 'asset_id'),
      mediaType: type,
      byteSize: _positive(m, 'byte_size'),
      width: _positive(m, 'width'),
      height: _positive(m, 'height'),
    );
  }

  final String assetId;
  final String mediaType;
  final int byteSize;
  final int width;
  final int height;
}

/// The rights record a banner revision cites, with the server's rights check
/// for display (null when it clears).
class BannerRights {
  const BannerRights({
    required this.rightsId,
    required this.label,
    required this.state,
    required this.liveRevisionNo,
    required this.display,
  });

  factory BannerRights.fromJson(Object? json) {
    final m = wireMap(json, 'rights');
    final live = wireOpt<int>(m, 'live_revision_no');
    if (live != null && live < 1) {
      throw const FormatException('unexpected live_revision_no');
    }
    return BannerRights(
      rightsId: _text(m, 'rights_id'),
      label: _text(m, 'label'),
      state: ContentState.parse(m['state']),
      liveRevisionNo: live,
      display: _optText(m, 'display'),
    );
  }

  final String rightsId;
  final String label;
  final ContentState state;
  final int? liveRevisionNo;

  /// Why the record does not clear display now (`not_in_force`,
  /// `use_not_cleared`, `source_not_cleared`, ...); null when it clears.
  final String? display;
}

/// The fields of a banner revision.
class BannerFields {
  const BannerFields({
    required this.kind,
    required this.themeYear,
    required this.title,
    required this.subtitle,
    required this.altText,
    required this.eventId,
  });

  final BannerKind kind;
  final int? themeYear;
  final String title;
  final String? subtitle;
  final String altText;
  final String? eventId;
}

/// One revision of a banner as an editor reads it.
class StaffBannerRevision {
  const StaffBannerRevision({
    required this.revisionNo,
    required this.fields,
    required this.eventTitle,
    required this.image,
    required this.rights,
    required this.savedAt,
    required this.savedBy,
  });

  factory StaffBannerRevision.fromJson(Object? json) {
    final m = wireMap(json, 'banner revision');
    final kind = BannerKind.parse(m['banner_kind']);
    return StaffBannerRevision(
      revisionNo: wireRevision(m, 'revision_no'),
      fields: BannerFields(
        kind: kind,
        themeYear: _themeYear(m, kind),
        title: _text(m, 'title'),
        subtitle: _optText(m, 'subtitle'),
        altText: _text(m, 'alt_text'),
        eventId: _optText(m, 'event_id'),
      ),
      eventTitle: _optText(m, 'event_title'),
      image: m['image'] == null ? null : StaffImage.fromJson(m['image']),
      rights: m['rights'] == null ? null : BannerRights.fromJson(m['rights']),
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: _text(m, 'saved_by'),
    );
  }

  final int revisionNo;
  final BannerFields fields;

  /// The linked event's title (editors only), when one is linked.
  final String? eventTitle;
  final StaffImage? image;
  final BannerRights? rights;
  final DateTime savedAt;

  /// The editor's display name (`Former member` once erased).
  final String savedBy;
}

/// Where a published banner's image stands in the public bucket.
enum PublicImageState {
  /// Placed: Home shows the banner.
  shown('shown'),

  /// Published but not yet placed: a sync places it.
  waiting('waiting'),

  /// Not shown: its rights no longer clear display (or the file is not
  /// ready).
  blocked('blocked'),

  /// Not shown: it is linked to an event that is not public now (withdrawn,
  /// archived or over).
  eventNotPublic('event_not_public');

  const PublicImageState(this.wire);
  final String wire;

  static PublicImageState? parse(Object? v) => switch (v) {
    null => null,
    'shown' => shown,
    'waiting' => waiting,
    'blocked' => blocked,
    'event_not_public' => eventNotPublic,
    _ => throw const FormatException('unexpected public_image'),
  };
}

/// One banner as an editor reads it.
class StaffBanner {
  const StaffBanner({
    required this.bannerId,
    required this.revision,
    required this.state,
    required this.createdAt,
    required this.createdBy,
    required this.updatedAt,
    required this.publicImage,
    required this.live,
    required this.draft,
    this.publishedAt,
    this.publishedBy,
    this.withdrawnAt,
    this.archivedAt,
  });

  factory StaffBanner.fromJson(Object? json) {
    final m = wireMap(json, 'staff banner');
    final state = ContentState.parse(m['state']);
    final live = m['live'] == null
        ? null
        : StaffBannerRevision.fromJson(m['live']);
    final draft = m['draft'] == null
        ? null
        : StaffBannerRevision.fromJson(m['draft']);
    if ((state == ContentState.draft && (live != null || draft == null)) ||
        ((state == ContentState.published || state == ContentState.withdrawn) &&
            live == null) ||
        (live == null && draft == null)) {
      throw const FormatException('unexpected staff banner revisions');
    }
    return StaffBanner(
      bannerId: _text(m, 'banner_id'),
      revision: wireRevision(m),
      state: state,
      createdAt: wireInstant(m, 'created_at'),
      createdBy: _text(m, 'created_by'),
      updatedAt: wireInstant(m, 'updated_at'),
      publishedAt: wireOptInstant(m, 'published_at'),
      publishedBy: wireOpt<String>(m, 'published_by'),
      withdrawnAt: wireOptInstant(m, 'withdrawn_at'),
      archivedAt: wireOptInstant(m, 'archived_at'),
      publicImage: PublicImageState.parse(m['public_image']),
      live: live,
      draft: draft,
    );
  }

  final String bannerId;

  /// The expected revision of the next command on this banner.
  final int revision;
  final ContentState state;
  final DateTime createdAt;
  final String createdBy;
  final DateTime updatedAt;
  final DateTime? publishedAt;
  final String? publishedBy;
  final DateTime? withdrawnAt;
  final DateTime? archivedAt;

  /// Published banners only: whether Home shows its image.
  final PublicImageState? publicImage;
  final StaffBannerRevision? live;
  final StaffBannerRevision? draft;

  /// What an edit starts from: the draft, otherwise the live revision.
  StaffBannerRevision get current => (draft ?? live)!;

  bool get hasChanges => state == ContentState.published && draft != null;
  bool get canPublish =>
      state != ContentState.archived &&
      (draft != null || state == ContentState.withdrawn);
  bool get canWithdraw => state == ContentState.published;
  bool get canArchive => state != ContentState.archived;
  bool get canEdit => state != ContentState.archived;
}

/// `api.content_staff_banners`: every banner, for the editors.
class StaffBanners {
  const StaffBanners({
    required this.capacity,
    required this.banners,
    required this.removalsPending,
    required this.truncated,
  });

  factory StaffBanners.fromJson(Object? json) {
    final m = wireMap(json, 'staff banners');
    final pending = wireReq<int>(m, 'removals_pending');
    if (pending < 0) throw const FormatException('unexpected removals_pending');
    return StaffBanners(
      capacity: _capacity(m),
      banners: List.unmodifiable(
        wireReq<List>(m, 'banners').map(StaffBanner.fromJson),
      ),
      removalsPending: pending,
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  final String capacity;
  final List<StaffBanner> banners;

  /// Public files outside the published set that a sync still has to remove.
  final int removalsPending;
  final bool truncated;
}

const _capacity = wireEditorCapacity;

/// The legal basis a rights record names.
enum RightsBasis {
  publicDomain('public_domain', 'Public domain'),
  licence('licence', 'Licence'),
  permission('permission', 'Permission'),
  churchOwned('church_owned', 'Church-owned');

  const RightsBasis(this.wire, this.label);
  final String wire;
  final String label;

  static RightsBasis parse(Object? v) => switch (v) {
    'public_domain' => publicDomain,
    'licence' => licence,
    'permission' => permission,
    'church_owned' => churchOwned,
    _ => throw const FormatException('unexpected basis'),
  };
}

/// The uses a rights record can clear.
abstract final class RightsUses {
  static const display = 'display';
  static const offline = 'offline';
  static const audio = 'audio';
  static const all = [display, offline, audio];
}

/// The fields of a rights record revision.
class RightsFields {
  const RightsFields({
    required this.label,
    required this.sourceKey,
    required this.holder,
    required this.basis,
    required this.clearsDisplay,
    required this.clearsOffline,
    required this.clearsAudio,
    required this.evidence,
  });

  final String label;
  final String sourceKey;
  final String holder;
  final RightsBasis basis;
  final bool clearsDisplay;
  final bool clearsOffline;
  final bool clearsAudio;
  final String evidence;

  /// The cleared uses in words ("Display · Offline").
  List<String> get clearedLabels => [
    if (clearsDisplay) 'Display',
    if (clearsOffline) 'Offline',
    if (clearsAudio) 'Audio',
  ];
}

/// One revision of a rights record.
class RightsRevision {
  const RightsRevision({
    required this.revisionNo,
    required this.fields,
    required this.savedAt,
    required this.savedBy,
  });

  factory RightsRevision.fromJson(Object? json) {
    final m = wireMap(json, 'rights revision');
    return RightsRevision(
      revisionNo: wireRevision(m, 'revision_no'),
      fields: RightsFields(
        label: _text(m, 'label'),
        sourceKey: _text(m, 'source_key'),
        holder: _text(m, 'holder'),
        basis: RightsBasis.parse(m['basis']),
        clearsDisplay: wireReq<bool>(m, 'clears_display'),
        clearsOffline: wireReq<bool>(m, 'clears_offline'),
        clearsAudio: wireReq<bool>(m, 'clears_audio'),
        evidence: _text(m, 'evidence'),
      ),
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: _text(m, 'saved_by'),
    );
  }

  final int revisionNo;
  final RightsFields fields;
  final DateTime savedAt;
  final String savedBy;
}

/// One rights record as an editor reads it: the revision in force (`live`,
/// verified) and the open draft.
class RightsRecord {
  const RightsRecord({
    required this.rightsId,
    required this.revision,
    required this.state,
    required this.createdAt,
    required this.createdBy,
    required this.updatedAt,
    required this.q5Uses,
    required this.live,
    required this.draft,
    this.verifiedAt,
    this.verifiedBy,
    this.withdrawnAt,
    this.archivedAt,
  });

  factory RightsRecord.fromJson(Object? json) {
    final m = wireMap(json, 'rights record');
    final state = ContentState.parse(m['state']);
    final live = m['live'] == null ? null : RightsRevision.fromJson(m['live']);
    final draft = m['draft'] == null
        ? null
        : RightsRevision.fromJson(m['draft']);
    if ((state == ContentState.draft && (live != null || draft == null)) ||
        ((state == ContentState.published || state == ContentState.withdrawn) &&
            live == null) ||
        (live == null && draft == null)) {
      throw const FormatException('unexpected rights revisions');
    }
    final uses = wireReq<List>(m, 'q5_uses');
    if (uses.any((u) => !RightsUses.all.contains(u))) {
      throw const FormatException('unexpected q5_uses');
    }
    return RightsRecord(
      rightsId: _text(m, 'rights_id'),
      revision: wireRevision(m),
      state: state,
      createdAt: wireInstant(m, 'created_at'),
      createdBy: _text(m, 'created_by'),
      updatedAt: wireInstant(m, 'updated_at'),
      verifiedAt: wireOptInstant(m, 'verified_at'),
      verifiedBy: wireOpt<String>(m, 'verified_by'),
      withdrawnAt: wireOptInstant(m, 'withdrawn_at'),
      archivedAt: wireOptInstant(m, 'archived_at'),
      q5Uses: List.unmodifiable(uses.cast<String>()),
      live: live,
      draft: draft,
    );
  }

  final String rightsId;
  final int revision;
  final ContentState state;
  final DateTime createdAt;
  final String createdBy;
  final DateTime updatedAt;
  final DateTime? verifiedAt;
  final String? verifiedBy;
  final DateTime? withdrawnAt;
  final DateTime? archivedAt;

  /// The uses the owner's Q5 list clears for this record's source (empty
  /// when the gate is closed or the source is not on it).
  final List<String> q5Uses;
  final RightsRevision? live;
  final RightsRevision? draft;

  RightsRevision get current => (draft ?? live)!;

  /// In force: verified and not withdrawn or archived.
  bool get inForce => state == ContentState.published;

  /// May an image cite it for display now (in force and its live revision
  /// clears display; Q5 is required unless the basis is church-owned)?
  bool get clearsDisplayNow =>
      inForce &&
      (live?.fields.clearsDisplay ?? false) &&
      (live?.fields.basis == RightsBasis.churchOwned ||
          q5Uses.contains(RightsUses.display));

  bool get hasChanges => state == ContentState.published && draft != null;
  bool get canVerify =>
      state != ContentState.archived &&
      (draft != null || state == ContentState.withdrawn);
  bool get canWithdraw => state == ContentState.published;
  bool get canArchive => state != ContentState.archived;
  bool get canEdit => state != ContentState.archived;
}

/// `api.content_staff_rights`: every rights record, for the editors.
class StaffRights {
  const StaffRights({
    required this.capacity,
    required this.rights,
    required this.truncated,
  });

  factory StaffRights.fromJson(Object? json) {
    final m = wireMap(json, 'staff rights');
    return StaffRights(
      capacity: _capacity(m),
      rights: List.unmodifiable(
        wireReq<List>(m, 'rights').map(RightsRecord.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  final String capacity;
  final List<RightsRecord> rights;
  final bool truncated;

  RightsRecord? byId(String rightsId) {
    for (final r in rights) {
      if (r.rightsId == rightsId) return r;
    }
    return null;
  }
}

/// What an editor typed for a banner (a save sends every field).
class BannerInput {
  const BannerInput({
    required this.kind,
    required this.themeYear,
    required this.title,
    required this.subtitle,
    required this.altText,
    required this.eventId,
    this.imageAssetId,
    this.imageRightsId,
  });

  final BannerKind kind;
  final int? themeYear;
  final String title;
  final String? subtitle;
  final String altText;
  final String? eventId;
  final String? imageAssetId;
  final String? imageRightsId;

  /// The create payload (no image: an upload needs the saved banner).
  Map<String, Object?> toCreatePayload() => {
    'banner_kind': kind.wire,
    'theme_year': kind == BannerKind.theme ? themeYear : null,
    'title': title.trim(),
    'subtitle': _blankToNull(subtitle),
    'alt_text': altText.trim(),
    'event_id': kind == BannerKind.campaign ? eventId : null,
  };

  /// The save payload: every field, image and rights included.
  Map<String, Object?> toSavePayload(String bannerId) => {
    'banner_id': bannerId,
    ...toCreatePayload(),
    'image_asset_id': imageAssetId,
    'image_rights_id': imageRightsId,
  };
}

String? _blankToNull(String? v) {
  final t = v?.trim();
  return t == null || t.isEmpty ? null : t;
}

/// What an editor typed for a rights record (a save sends every field).
class RightsInput {
  const RightsInput({
    required this.label,
    required this.sourceKey,
    required this.holder,
    required this.basis,
    required this.clearsDisplay,
    required this.clearsOffline,
    required this.clearsAudio,
    required this.evidence,
  });

  final String label;
  final String sourceKey;
  final String holder;
  final RightsBasis basis;
  final bool clearsDisplay;
  final bool clearsOffline;
  final bool clearsAudio;
  final String evidence;

  Map<String, Object?> toPayload({String? rightsId}) => {
    'rights_id': ?rightsId,
    'label': label.trim(),
    'source_key': sourceKey.trim(),
    'holder': holder.trim(),
    'basis': basis.wire,
    'clears_display': clearsDisplay,
    'clears_offline': clearsOffline,
    'clears_audio': clearsAudio,
    'evidence': evidence.trim(),
  };
}

/// The Content commands of banners and rights records (1.4 envelope).
abstract final class BannerCommands {
  static const createBanner = 'content.create_banner';
  static const saveBanner = 'content.save_banner';
  static const publishBanner = 'content.publish_banner';
  static const withdrawBanner = 'content.withdraw_banner';
  static const archiveBanner = 'content.archive_banner';
  static const createRights = 'content.create_rights_record';
  static const saveRights = 'content.save_rights_record';
  static const verifyRights = 'content.verify_rights_record';
  static const withdrawRights = 'content.withdraw_rights_record';
  static const archiveRights = 'content.archive_rights_record';
}

/// The upload purposes the server registers.
abstract final class ContentPurposes {
  static const bannerImage = 'banner_image';
  static const givingLogo = 'giving_logo';

  /// Story 6.11: an event's poster.
  static const eventPoster = 'event_poster';

  /// Story 6.9: a sermon series' poster.
  static const sermonSeriesPoster = 'sermon_series_poster';
}

/// A file an editor picked: its name, the type the browser declared (never
/// trusted: the server measures the bytes) and its bytes. [size] is the
/// file's size; [bytes] is empty when the picker refused to read a file
/// larger than [ContentFilePicker.maxReadBytes].
class PickedFile {
  PickedFile({
    required this.name,
    required this.declaredType,
    required this.bytes,
    int? size,
  }) : size = size ?? bytes.length;

  final String name;
  final String? declaredType;
  final Uint8List bytes;
  final int size;

  /// Too large to send at all (the Edge function reads at most 10 MiB).
  bool get unreadable => bytes.isEmpty && size > 0;
}

/// An image the server measured and stored in the private draft area.
class UploadedImage {
  const UploadedImage({
    required this.assetId,
    required this.mediaType,
    required this.byteSize,
    required this.width,
    required this.height,
  });

  factory UploadedImage.fromJson(Object? json) {
    final m = wireMap(json, 'upload');
    if (m['outcome'] != 'uploaded') {
      throw const FormatException('unexpected outcome');
    }
    final type = wireReq<String>(m, 'media_type');
    if (!contentImageTypes.contains(type)) {
      throw const FormatException('unexpected media_type');
    }
    return UploadedImage(
      assetId: _text(m, 'asset_id'),
      mediaType: type,
      byteSize: _positive(m, 'byte_size'),
      width: _positive(m, 'width'),
      height: _positive(m, 'height'),
    );
  }

  final String assetId;
  final String mediaType;
  final int byteSize;
  final int width;
  final int height;
}

/// How an upload ended.
sealed class ImageUploadOutcome {
  const ImageUploadOutcome();
}

/// Measured and stored as a private draft file.
final class ImageUploaded extends ImageUploadOutcome {
  const ImageUploaded(this.image);
  final UploadedImage image;
}

/// The server refused the file or the request; nothing was stored.
final class ImageUploadRefused extends ImageUploadOutcome {
  const ImageUploadRefused({this.code, this.fieldErrors = const {}});
  final String? code;
  final Map<String, String> fieldErrors;

  /// The first reason the server gave (`too_large`, `unsupported_type`,
  /// `type_mismatch`, `too_small`, `bad_ratio`, ...).
  String? get reason {
    for (final key in const ['file', 'byte_size', 'media_type', 'width']) {
      if (fieldErrors[key] case final v?) return v;
    }
    return fieldErrors.values.firstOrNull;
  }
}

/// Signed out, or the session is no longer trusted.
final class ImageUploadSignedOut extends ImageUploadOutcome {
  const ImageUploadSignedOut();
}

/// The caller does not edit this item.
final class ImageUploadNotAllowed extends ImageUploadOutcome {
  const ImageUploadNotAllowed();
}

/// No answer ([unreachable]) or the server could not do it now.
final class ImageUploadFailed extends ImageUploadOutcome {
  const ImageUploadFailed({required this.unreachable});
  final bool unreachable;
}

/// This build has no server configured.
final class ImageUploadNotSent extends ImageUploadOutcome {
  const ImageUploadNotSent();
}

/// How a public-file sync ended.
sealed class FileSyncOutcome {
  const FileSyncOutcome();
}

final class FileSyncDone extends FileSyncOutcome {
  const FileSyncDone({
    required this.placed,
    required this.removed,
    required this.waiting,
    required this.removalsPending,
  });

  factory FileSyncDone.fromJson(Object? json) {
    final m = wireMap(json, 'sync');
    if (m['outcome'] != 'synced') {
      throw const FormatException('unexpected outcome');
    }
    int count(String key) {
      final v = wireReq<int>(m, key);
      if (v < 0) throw FormatException('unexpected $key');
      return v;
    }

    return FileSyncDone(
      placed: count('placed'),
      removed: count('removed'),
      waiting: count('waiting'),
      removalsPending: count('removals_pending'),
    );
  }

  final int placed;
  final int removed;

  /// Published files still not placed after this sync.
  final int waiting;

  /// Public files still to remove after this sync.
  final int removalsPending;

  bool get complete => waiting == 0 && removalsPending == 0;
}

final class FileSyncNotAllowed extends FileSyncOutcome {
  const FileSyncNotAllowed();
}

final class FileSyncFailed extends FileSyncOutcome {
  const FileSyncFailed({required this.unreachable});
  final bool unreachable;
}

final class FileSyncNotSent extends FileSyncOutcome {
  const FileSyncNotSent();
}

/// Application port for banners, rights records and their files. Never
/// throws.
abstract interface class BannerRepository {
  /// Everyone (signed in or not): the published banners.
  Future<AccessRead<PublicBanners>> fetchPublicBanners();

  /// Media, Pastor and Admin: every banner with its revisions.
  Future<AccessRead<StaffBanners>> fetchStaffBanners();

  /// Media, Pastor and Admin: every rights record.
  Future<AccessRead<StaffRights>> fetchStaffRights();

  /// The public address of a published file at [path] in
  /// [contentPublicBucket].
  Uri publicFileUrl(String path);

  /// Fetches the public bytes for an image whose current server projection
  /// explicitly allows offline storage. Null on any request or type failure.
  Future<Uint8List?> fetchPublicImage(PublicBanner banner);

  /// Fetch a public image path after the caller confirmed its offline rights.
  Future<Uint8List?> fetchPublicAsset(
    String path,
    String mediaType, {
    int maxBytes = 2 * 1024 * 1024,
  });

  /// Uploads [file] for the content item [itemId] (a saved banner) as
  /// [purpose]; the server measures and checks it.
  Future<ImageUploadOutcome> uploadImage(
    String itemId,
    String purpose,
    PickedFile file,
  );

  /// Asks the server to place published files and remove withdrawn ones.
  Future<FileSyncOutcome> syncFiles();

  /// An uploaded (private) file's bytes for an editor's preview, or null.
  Future<Uint8List?> previewImage(String assetId);
}

class UnconfiguredBannerRepository implements BannerRepository {
  const UnconfiguredBannerRepository();

  @override
  Future<AccessRead<PublicBanners>> fetchPublicBanners() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffBanners>> fetchStaffBanners() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffRights>> fetchStaffRights() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Uri publicFileUrl(String path) => Uri(path: path);

  @override
  Future<Uint8List?> fetchPublicImage(PublicBanner banner) async => null;

  @override
  Future<Uint8List?> fetchPublicAsset(
    String path,
    String mediaType, {
    int maxBytes = 2 * 1024 * 1024,
  }) async => null;

  @override
  Future<ImageUploadOutcome> uploadImage(
    String itemId,
    String purpose,
    PickedFile file,
  ) async => const ImageUploadNotSent();

  @override
  Future<FileSyncOutcome> syncFiles() async => const FileSyncNotSent();

  @override
  Future<Uint8List?> previewImage(String assetId) async => null;
}

/// Picks a file from the editor's computer (staff web). Never throws.
abstract interface class ContentFilePicker {
  /// Files larger than this are not read (the Edge function reads at most
  /// 10 MiB of a body).
  static const maxReadBytes = 10 * 1024 * 1024;

  /// Whether this platform can pick a file.
  bool get supported;

  /// One PNG, JPEG or WebP file, or null when the editor cancelled.
  Future<PickedFile?> pickImage();

  /// One CSV file, or null when the editor cancelled.
  Future<PickedFile?> pickCsv();
}

class UnsupportedContentFilePicker implements ContentFilePicker {
  const UnsupportedContentFilePicker();

  @override
  bool get supported => false;

  @override
  Future<PickedFile?> pickImage() async => null;

  @override
  Future<PickedFile?> pickCsv() async => null;
}
