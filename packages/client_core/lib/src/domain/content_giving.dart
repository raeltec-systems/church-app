/// Story 6.3: the church's giving methods through Content's publication
/// lifecycle. Everyone, signed in or not, reads the published methods
/// (`api.content_public_giving_methods`, `api.content_public_giving_method`):
/// only the live revision's giver-facing fields and the date the church
/// checked them, never who verified them, how, or a draft. Admins read every
/// method with its live and draft revisions and their verification
/// (`api.content_staff_giving_methods`) and change them through
/// `api.content_command`. A revision is published only after it has been
/// verified by an Admin who saved none of it (owner decision 2026-10-21;
/// review 2026-10-22: no Admin who saved the draft revision may verify it);
/// the server enforces it, the client only shows it.
///
/// No amount, payer, gift or transaction field exists here: the app never
/// processes or records a gift. Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'church_time.dart';
import 'content_events.dart' show ContentCommands, ContentState;
import 'wire_json.dart';

/// The most steps a method carries.
const givingMaxSteps = 12;

/// What kind of destination a method is. Fixed when the method is created.
enum GivingMethodType {
  mobileMoney('mobile_money', 'Mobile money'),
  bank('bank', 'Bank'),
  other('other', 'Other');

  const GivingMethodType(this.wire, this.label);
  final String wire;
  final String label;

  static GivingMethodType parse(Object? v) => switch (v) {
    'mobile_money' => mobileMoney,
    'bank' => bank,
    'other' => other,
    _ => throw const FormatException('unexpected method_type'),
  };

  /// Does the giver check a beneficiary name with their provider?
  bool get hasBeneficiary => this != other;
}

/// The one identifier a mobile money method gives.
enum MobileMoneyIdentifier {
  merchant('merchant', 'merchant_id', 'Merchant ID'),
  till('till', 'till_number', 'Till number'),
  phone('phone', 'phone_number', 'Phone number');

  const MobileMoneyIdentifier(this.wire, this.detailKey, this.label);

  /// The `identifier_kind` value of the editors' read and the commands.
  final String wire;

  /// The key of its row in the public `details`.
  final String detailKey;
  final String label;

  static MobileMoneyIdentifier parse(Object? v) => switch (v) {
    'merchant' => merchant,
    'till' => till,
    'phone' => phone,
    _ => throw const FormatException('unexpected identifier_kind'),
  };
}

/// A required, non-blank string at [key].
String _text(Map json, String key) {
  final v = wireReq<String>(json, key);
  if (v.trim().isEmpty) throw FormatException('unexpected $key');
  return v;
}

/// An optional string at [key]: absent or null is null; blank is refused.
String? _optText(Map json, String key) {
  final v = wireOpt<String>(json, key);
  if (v != null && v.trim().isEmpty) throw FormatException('unexpected $key');
  return v;
}

final _date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// A calendar date `YYYY-MM-DD` that exists (a church date, no zone).
DateTime? parseChurchDate(String text) {
  final m = _date.firstMatch(text);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final t = DateTime.utc(y, mo, d);
  if (t.year != y || t.month != mo || t.day != d) return null;
  return t;
}

DateTime _wireDate(Map json, String key) {
  final t = parseChurchDate(wireReq<String>(json, key));
  if (t == null) throw FormatException('unexpected $key');
  return t;
}

final _currency = RegExp(r'^[A-Z]{3}$');
final _ussd = RegExp(r'^[*][0-9*]{1,20}#$');

String? _optCurrency(Map json) {
  final v = wireOpt<String>(json, 'currency');
  if (v != null && !_currency.hasMatch(v)) {
    throw const FormatException('unexpected currency');
  }
  return v;
}

String? _optUssd(Map json) {
  final v = wireOpt<String>(json, 'ussd_code');
  if (v != null && !_ussd.hasMatch(v)) {
    throw const FormatException('unexpected ussd_code');
  }
  return v;
}

List<String> _steps(Map json) {
  final raw = wireReq<List>(json, 'steps');
  if (raw.isEmpty ||
      raw.length > givingMaxSteps ||
      raw.any((s) => s is! String || s.trim().isEmpty)) {
    throw const FormatException('unexpected steps');
  }
  return List.unmodifiable(raw.cast<String>());
}

/// "Tithes & Offerings · ZMW": the purpose and currency a method is for.
String givingSubline(String? purpose, String? currency) =>
    [?purpose, ?currency].join(' · ');

/// One value a giver copies into their provider's app (a merchant ID, an
/// account number), as everyone reads it.
class GivingDetail {
  const GivingDetail({required this.key, required this.value});

  final String key;
  final String value;

  /// The row's label for a method of [type].
  String labelFor(GivingMethodType type) => switch (key) {
    'beneficiary' when type == GivingMethodType.bank => 'Account name',
    'beneficiary' => 'Beneficiary',
    'merchant_id' => MobileMoneyIdentifier.merchant.label,
    'till_number' => MobileMoneyIdentifier.till.label,
    'phone_number' => MobileMoneyIdentifier.phone.label,
    'bank_name' => 'Bank',
    'account_number' => 'Account number',
    'branch' => 'Branch',
    'branch_code' => 'Branch code',
    'swift_code' => 'SWIFT code',
    'reference' => 'Reference',
    _ => key,
  };
}

const _bankDetailOrder = [
  'bank_name',
  'beneficiary',
  'account_number',
  'branch',
  'branch_code',
  'swift_code',
  'reference',
];

/// The public `details` of a method of [type], in the contract's order:
/// mobile money its beneficiary then its one identifier; bank its bank,
/// account name and number, then the optional ones present; other none.
List<GivingDetail> _details(Map json, GivingMethodType type) {
  final details = wireReq<List>(json, 'details').map((d) {
    final m = wireMap(d, 'detail');
    return GivingDetail(key: _text(m, 'key'), value: _text(m, 'value'));
  }).toList();
  final keys = [for (final d in details) d.key];
  final ok = switch (type) {
    GivingMethodType.mobileMoney =>
      keys.length == 2 &&
          keys.first == 'beneficiary' &&
          MobileMoneyIdentifier.values.any((i) => i.detailKey == keys.last),
    GivingMethodType.bank =>
      keys.toSet().length == keys.length &&
          keys.every(_bankDetailOrder.contains) &&
          [
                for (final k in _bankDetailOrder)
                  if (keys.contains(k)) k,
              ].join(',') ==
              keys.join(',') &&
          keys.contains('bank_name') &&
          keys.contains('beneficiary') &&
          keys.contains('account_number'),
    GivingMethodType.other => keys.isEmpty,
  };
  if (!ok) throw const FormatException('unexpected details');
  return List.unmodifiable(details);
}

/// One published giving method as everyone reads it: the live revision's
/// giver-facing fields and the date the church checked them. Never who
/// verified or edited it, how it was tested, or a draft.
class PublicGivingMethod {
  const PublicGivingMethod({
    required this.methodId,
    required this.methodType,
    required this.name,
    required this.purpose,
    required this.currency,
    required this.details,
    required this.ussdCode,
    required this.steps,
    required this.note,
    required this.contact,
    required this.verifiedOn,
    required this.publicationRevision,
    required this.publishedAt,
  });

  /// Maps the wire object; throws [FormatException] on any other shape.
  /// Keys a later entry adds (a logo, the dialler) are ignored, so an older
  /// app keeps reading the methods.
  factory PublicGivingMethod.fromJson(Object? json) {
    final m = wireMap(json, 'giving method');
    final type = GivingMethodType.parse(m['method_type']);
    final ussd = _optUssd(m);
    if (ussd != null && type != GivingMethodType.mobileMoney) {
      throw const FormatException('unexpected ussd_code');
    }
    return PublicGivingMethod(
      methodId: _text(m, 'method_id'),
      methodType: type,
      name: _text(m, 'name'),
      purpose: _optText(m, 'purpose'),
      currency: _optCurrency(m),
      details: _details(m, type),
      ussdCode: ussd,
      steps: _steps(m),
      note: _optText(m, 'note'),
      contact: _text(m, 'contact'),
      verifiedOn: _wireDate(m, 'verified_on'),
      publicationRevision: wireRevision(m, 'publication_revision'),
      publishedAt: wireInstant(m, 'published_at'),
    );
  }

  final String methodId;
  final GivingMethodType methodType;
  final String name;
  final String? purpose;

  /// A three-letter code (`ZMW`), or null.
  final String? currency;
  final List<GivingDetail> details;

  /// The starting code a mobile money giver dials (`*115#`), or null.
  final String? ussdCode;
  final List<String> steps;
  final String? note;

  /// Who to ask about this method (the church office).
  final String contact;

  /// The church date the details were last checked (a date, no time).
  final DateTime verifiedOn;
  final int publicationRevision;
  final DateTime publishedAt;

  /// "Tithes & Offerings · ZMW".
  String get subline => givingSubline(purpose, currency);

  /// The name the giver's provider must show (mobile money and bank).
  String? get beneficiary {
    for (final d in details) {
      if (d.key == 'beneficiary') return d.value;
    }
    return null;
  }
}

/// `api.content_public_giving_methods`: the published methods in the
/// church's order. [sample] is true off production: the details are test
/// data and the app says so.
class PublicGivingMethods {
  const PublicGivingMethods({
    required this.sample,
    required this.methods,
    required this.truncated,
  });

  factory PublicGivingMethods.fromJson(Object? json) {
    final m = wireMap(json, 'public giving methods');
    return PublicGivingMethods(
      sample: wireReq<bool>(m, 'sample'),
      methods: List.unmodifiable(
        wireReq<List>(m, 'methods').map(PublicGivingMethod.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  final bool sample;
  final List<PublicGivingMethod> methods;

  /// More methods exist than the read returns (the first are listed).
  final bool truncated;

  /// The contact every listed method shares, or null when they differ.
  String? get sharedContact {
    final contacts = {for (final m in methods) m.contact};
    return contacts.length == 1 ? contacts.single : null;
  }
}

/// `api.content_public_giving_method`: one method, or null when it is not
/// published (draft only, hidden, archived or unknown).
class PublicGivingMethodRead {
  const PublicGivingMethodRead({required this.sample, required this.method});

  factory PublicGivingMethodRead.fromJson(Object? json) {
    final m = wireMap(json, 'public giving method');
    if (!m.containsKey('method')) {
      throw const FormatException('unexpected public giving method shape');
    }
    final g = m['method'];
    return PublicGivingMethodRead(
      sample: wireReq<bool>(m, 'sample'),
      method: g == null ? null : PublicGivingMethod.fromJson(g),
    );
  }

  final bool sample;
  final PublicGivingMethod? method;
}

/// Every field of a method an Admin saves (a save carries all of its type's
/// keys). Type-specific fields are null for the other types.
class GivingFields {
  const GivingFields({
    required this.methodType,
    required this.name,
    required this.steps,
    required this.contact,
    this.purpose,
    this.currency,
    this.note,
    this.beneficiary,
    this.identifierKind,
    this.identifier,
    this.ussdCode,
    this.bankName,
    this.accountNumber,
    this.branch,
    this.branchCode,
    this.swiftCode,
    this.reference,
  });

  /// The fields of a revision object of [type]; throws [FormatException]
  /// when a key of its type is missing or malformed.
  factory GivingFields.fromJson(Map m, GivingMethodType type) {
    final mobile = type == GivingMethodType.mobileMoney;
    final bank = type == GivingMethodType.bank;
    final ussd = mobile ? _optUssd(m) : null;
    return GivingFields(
      methodType: type,
      name: _text(m, 'name'),
      purpose: _optText(m, 'purpose'),
      currency: _optCurrency(m),
      steps: _steps(m),
      note: _optText(m, 'note'),
      contact: _text(m, 'contact'),
      beneficiary: mobile || bank ? _text(m, 'beneficiary') : null,
      identifierKind: mobile
          ? MobileMoneyIdentifier.parse(m['identifier_kind'])
          : null,
      identifier: mobile ? _text(m, 'identifier') : null,
      ussdCode: ussd,
      bankName: bank ? _text(m, 'bank_name') : null,
      accountNumber: bank ? _text(m, 'account_number') : null,
      branch: bank ? _optText(m, 'branch') : null,
      branchCode: bank ? _optText(m, 'branch_code') : null,
      swiftCode: bank ? _optText(m, 'swift_code') : null,
      reference: bank ? _optText(m, 'reference') : null,
    );
  }

  final GivingMethodType methodType;
  final String name;
  final String? purpose;
  final String? currency;
  final List<String> steps;
  final String? note;
  final String contact;
  final String? beneficiary;
  final MobileMoneyIdentifier? identifierKind;
  final String? identifier;
  final String? ussdCode;
  final String? bankName;
  final String? accountNumber;
  final String? branch;
  final String? branchCode;
  final String? swiftCode;
  final String? reference;
}

/// The church's check of one revision: who verified it (never an Admin who
/// saved it), when, the date the details were tested and how.
class GivingVerification {
  const GivingVerification({
    required this.verifiedAt,
    required this.verifiedBy,
    required this.verifiedByYou,
    required this.testedOn,
    required this.testMethod,
  });

  factory GivingVerification.fromJson(Object? json) {
    final m = wireMap(json, 'verification');
    return GivingVerification(
      verifiedAt: wireInstant(m, 'verified_at'),
      verifiedBy: _text(m, 'verified_by'),
      verifiedByYou: wireReq<bool>(m, 'verified_by_you'),
      testedOn: _wireDate(m, 'tested_on'),
      testMethod: _text(m, 'test_method'),
    );
  }

  final DateTime verifiedAt;

  /// The verifier's display name (`Former member` once erased).
  final String verifiedBy;
  final bool verifiedByYou;

  /// The church date the details were tested (a date, no time).
  final DateTime testedOn;
  final String testMethod;
}

/// One revision of a method as an Admin reads it.
class StaffGivingRevision {
  const StaffGivingRevision({
    required this.revisionNo,
    required this.fields,
    required this.savedAt,
    required this.savedBy,
    required this.savedByYou,
    required this.verification,
    this.publishedAt,
    this.publishedBy,
  });

  factory StaffGivingRevision.fromJson(Object? json, GivingMethodType type) {
    final m = wireMap(json, 'giving revision');
    final v = m['verification'];
    return StaffGivingRevision(
      revisionNo: wireRevision(m, 'revision_no'),
      fields: GivingFields.fromJson(m, type),
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: _text(m, 'saved_by'),
      savedByYou: wireReq<bool>(m, 'saved_by_you'),
      publishedAt: wireOptInstant(m, 'published_at'),
      publishedBy: _optText(m, 'published_by'),
      verification: v == null ? null : GivingVerification.fromJson(v),
    );
  }

  final int revisionNo;
  final GivingFields fields;
  final DateTime savedAt;

  /// The Admin who last saved it (`Former member` once erased).
  final String savedBy;

  /// The caller saved this revision at some point (not only last), so an
  /// Admin who saved none of it must verify it.
  final bool savedByYou;
  final DateTime? publishedAt;
  final String? publishedBy;

  /// Null until an Admin who saved none of this revision verifies it; any
  /// save clears it.
  final GivingVerification? verification;

  bool get verified => verification != null;
}

/// Where a method stands, as the Giving screen names it.
enum GivingStage {
  draftNeedsVerifying('Draft, needs verifying'),
  draftVerified('Verified, ready to publish'),
  live('Live'),
  liveChangesNeedVerifying('Live, changes need verifying'),
  liveChangesVerified('Live, changes ready to publish'),
  hidden('Hidden'),
  archived('Archived');

  const GivingStage(this.label);
  final String label;
}

/// One method as an Admin reads it: the live revision (what givers see, or
/// saw before it was hidden) and the open draft, with their verification.
class StaffGivingMethod {
  const StaffGivingMethod({
    required this.methodId,
    required this.methodType,
    required this.position,
    required this.revision,
    required this.state,
    required this.createdAt,
    required this.createdBy,
    required this.updatedAt,
    required this.live,
    required this.draft,
    this.publishedAt,
    this.publishedBy,
    this.withdrawnAt,
    this.archivedAt,
  });

  factory StaffGivingMethod.fromJson(Object? json) {
    final m = wireMap(json, 'staff giving method');
    final type = GivingMethodType.parse(m['method_type']);
    final state = ContentState.parse(m['state']);
    final live = m['live'] == null
        ? null
        : StaffGivingRevision.fromJson(m['live'], type);
    final draft = m['draft'] == null
        ? null
        : StaffGivingRevision.fromJson(m['draft'], type);
    final position = wireOpt<int>(m, 'position');
    // A never-published method has its draft and no live revision; a live
    // or hidden one has a live revision. Only an archived method has no
    // position.
    if ((state == ContentState.draft && (live != null || draft == null)) ||
        ((state == ContentState.published || state == ContentState.withdrawn) &&
            live == null) ||
        (live == null && draft == null) ||
        ((state == ContentState.archived) != (position == null)) ||
        (position != null && position < 1)) {
      throw const FormatException('unexpected staff giving method');
    }
    return StaffGivingMethod(
      methodId: _text(m, 'method_id'),
      methodType: type,
      position: position,
      revision: wireRevision(m),
      state: state,
      createdAt: wireInstant(m, 'created_at'),
      createdBy: _text(m, 'created_by'),
      updatedAt: wireInstant(m, 'updated_at'),
      publishedAt: wireOptInstant(m, 'published_at'),
      publishedBy: _optText(m, 'published_by'),
      withdrawnAt: wireOptInstant(m, 'withdrawn_at'),
      archivedAt: wireOptInstant(m, 'archived_at'),
      live: live,
      draft: draft,
    );
  }

  final String methodId;
  final GivingMethodType methodType;

  /// 1-based among the methods that are not archived; null when archived.
  final int? position;

  /// The expected revision of the next command on this method.
  final int revision;
  final ContentState state;
  final DateTime createdAt;
  final String createdBy;
  final DateTime updatedAt;
  final DateTime? publishedAt;
  final String? publishedBy;

  /// When it was hidden (the lifecycle's withdraw).
  final DateTime? withdrawnAt;
  final DateTime? archivedAt;
  final StaffGivingRevision? live;
  final StaffGivingRevision? draft;

  /// What an edit starts from: the draft, otherwise the live revision.
  GivingFields get current => (draft ?? live)!.fields;

  GivingStage get stage => switch (state) {
    ContentState.draft when draft!.verified => GivingStage.draftVerified,
    ContentState.draft => GivingStage.draftNeedsVerifying,
    ContentState.published when draft == null => GivingStage.live,
    ContentState.published when draft!.verified =>
      GivingStage.liveChangesVerified,
    ContentState.published => GivingStage.liveChangesNeedVerifying,
    ContentState.withdrawn => GivingStage.hidden,
    ContentState.archived => GivingStage.archived,
  };

  bool get canEdit => state != ContentState.archived;

  /// An unverified draft waits for a verification.
  bool get needsVerifying =>
      state != ContentState.archived && draft != null && !draft!.verified;

  /// The caller saved changes to the draft: an Admin who saved none of it
  /// must verify it.
  bool get verifyBlockedForYou => needsVerifying && draft!.savedByYou;

  /// A verified draft, or a hidden method with no draft (its live revision
  /// is shown again).
  bool get canPublish =>
      state != ContentState.archived &&
      (draft != null ? draft!.verified : state == ContentState.withdrawn);

  bool get canHide => state == ContentState.published;
  bool get canArchive => state != ContentState.archived;

  /// Unpublished changes to a method with a live revision (live or hidden)
  /// can be dropped; a never-published draft is archived instead.
  bool get canDiscard =>
      state != ContentState.archived && live != null && draft != null;

  /// Is it in the givers' list now?
  bool get isPublic => state == ContentState.published;
}

/// `api.content_staff_giving_methods`: every method, for Admins: the
/// methods in their order, then the archived ones.
class StaffGivingMethods {
  const StaffGivingMethods({
    required this.capacity,
    required this.methods,
    required this.truncated,
  });

  factory StaffGivingMethods.fromJson(Object? json) {
    final m = wireMap(json, 'staff giving methods');
    if (wireReq<String>(m, 'capacity') != ChurchRoles.admin) {
      throw const FormatException('unexpected capacity');
    }
    return StaffGivingMethods(
      capacity: ChurchRoles.admin,
      methods: List.unmodifiable(
        wireReq<List>(m, 'methods').map(StaffGivingMethod.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  /// Always `admin` (giving methods are edited by Admins only).
  final String capacity;
  final List<StaffGivingMethod> methods;
  final bool truncated;

  /// The methods that are not archived, in the public order.
  List<StaffGivingMethod> get ordered {
    final list = [
      for (final g in methods)
        if (g.position != null) g,
    ]..sort((a, b) => a.position!.compareTo(b.position!));
    return list;
  }

  List<StaffGivingMethod> get archived => [
    for (final g in methods)
      if (g.state == ContentState.archived) g,
  ];
}

/// What an Admin typed: the whole method (a save sends every key of its
/// type; an empty optional is null).
class GivingMethodInput {
  const GivingMethodInput({
    required this.methodType,
    required this.name,
    required this.steps,
    required this.contact,
    this.purpose = '',
    this.currency = '',
    this.note = '',
    this.beneficiary = '',
    this.identifierKind = MobileMoneyIdentifier.merchant,
    this.identifier = '',
    this.ussdCode = '',
    this.bankName = '',
    this.accountNumber = '',
    this.branch = '',
    this.branchCode = '',
    this.swiftCode = '',
    this.reference = '',
  });

  final GivingMethodType methodType;
  final String name;
  final String purpose;
  final String currency;
  final List<String> steps;
  final String note;
  final String contact;
  final String beneficiary;
  final MobileMoneyIdentifier identifierKind;
  final String identifier;
  final String ussdCode;
  final String bankName;
  final String accountNumber;
  final String branch;
  final String branchCode;
  final String swiftCode;
  final String reference;

  static String? _opt(String v) => v.trim().isEmpty ? null : v.trim();

  /// The command payload: `method_type` for a create, [methodId] for a save
  /// (the type is fixed once created). Only the keys of the method's type.
  Map<String, Object?> toPayload({String? methodId}) => {
    if (methodId == null) 'method_type': methodType.wire,
    'method_id': ?methodId,
    'name': name.trim(),
    'purpose': _opt(purpose),
    'currency': _opt(currency)?.toUpperCase(),
    'steps': [
      for (final s in steps)
        if (s.trim().isNotEmpty) s.trim(),
    ],
    'note': _opt(note),
    'contact': contact.trim(),
    if (methodType == GivingMethodType.mobileMoney) ...{
      'beneficiary': beneficiary.trim(),
      'identifier_kind': identifierKind.wire,
      'identifier': identifier.trim(),
      'ussd_code': _opt(ussdCode),
    },
    if (methodType == GivingMethodType.bank) ...{
      'bank_name': bankName.trim(),
      'beneficiary': beneficiary.trim(),
      'account_number': accountNumber.trim(),
      'branch': _opt(branch),
      'branch_code': _opt(branchCode),
      'swift_code': _opt(swiftCode)?.toUpperCase(),
      'reference': _opt(reference),
    },
  };
}

/// The giving commands (1.4 envelope, through `content_command`).
abstract final class GivingCommands {
  static const function = ContentCommands.function;
  static const create = 'content.create_giving_method';
  static const save = 'content.save_giving_method';
  static const verify = 'content.verify_giving_method';
  static const publish = 'content.publish_giving_method';
  static const hide = 'content.hide_giving_method';
  static const archive = 'content.archive_giving_method';
  static const move = 'content.move_giving_method';

  /// Drops the open draft of a method that has a live revision.
  static const discard = 'content.discard_giving_draft';
}

/// Application port for the giving reads. Never throws.
abstract interface class GivingRepository {
  /// Everyone (signed in or not): the published methods, in order.
  Future<AccessRead<PublicGivingMethods>> fetchPublicGivingMethods();

  /// Everyone: one published method, or null when it is not published.
  Future<AccessRead<PublicGivingMethodRead>> fetchPublicGivingMethod(
    String methodId,
  );

  /// Admins: every method with its revisions and verification.
  Future<AccessRead<StaffGivingMethods>> fetchStaffGivingMethods();
}

class UnconfiguredGivingRepository implements GivingRepository {
  const UnconfiguredGivingRepository();

  @override
  Future<AccessRead<PublicGivingMethods>> fetchPublicGivingMethods() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<PublicGivingMethodRead>> fetchPublicGivingMethod(
    String methodId,
  ) async => const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffGivingMethods>> fetchStaffGivingMethods() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Does [grants] manage giving methods (Admin only)? Navigation only; the
/// server checks every read and command.
bool editsGiving(MemberGrants? grants) => grants?.isAdmin ?? false;

const _monthsShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "28 Sep 2026" for a church date (a calendar date, no zone applied).
String churchDateText(DateTime date) =>
    '${date.day} ${_monthsShort[date.month - 1]} ${date.year}';

/// Today's church date (Africa/Lusaka) as a calendar date.
DateTime churchToday([DateTime? now]) {
  final w = ChurchTime.wall(now ?? DateTime.now());
  return DateTime.utc(w.year, w.month, w.day);
}
