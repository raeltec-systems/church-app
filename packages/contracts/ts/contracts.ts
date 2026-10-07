// Wire contract v1 — TypeScript mapping (for the Q10 React/Next.js alternative and any JS tool).
// Mirrors app.contract_check (supabase/migrations/20261003134340_cross_epic_contracts.sql) and
// must pass the shared fixtures in ../fixtures/v1. Types and shape checks only: no business
// rules. Registration membership, zone existence and money scale are server-side checks.
// Erasable TypeScript only, so Node runs it with built-in type stripping.

export const CONTRACT_VERSION = 1;

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type FieldErrors = Record<string, string>;
export type CheckResult = { valid: boolean; field_errors: FieldErrors };

export type Uuid = string;
export type Instant = string; // UTC RFC3339, e.g. 2026-10-03T12:34:56.123456Z
export type Revision = number; // integer value 1..2^53-1

export type MemberRef = { member_id: Uuid };
export type AccountRef = { auth_user_id: Uuid };
export type MemberActor = { kind: "member"; member_id: Uuid; auth_user_id: Uuid };
export type SystemActor = {
  kind: "system";
  system_principal_id: Uuid;
  job_id: Uuid;
  initiating_member_id?: Uuid | null;
};
export type Actor = MemberActor | SystemActor;
export type SourceRef = { source_type: string; source_id: Uuid; source_revision: Revision };
export type TaskSource = { source_type: string; source_id: Uuid; purpose: string };
export type NotificationKey = {
  source_type: string;
  source_id: Uuid;
  source_revision: Revision;
  recipient_member_id: Uuid;
  reminder_kind: string;
  scheduled_at: Instant;
};
export const LIFECYCLE_EVENTS = [
  "access_hold_applied",
  "access_hold_released",
  "scope_revoked",
  "account_deactivated",
  "deletion_requested",
  "cell_transferred",
  "sessions_revoked",
  "membership_deactivated",
  "membership_restored",
  "member_deleted",
] as const;
export type LifecycleEventName = (typeof LIFECYCLE_EVENTS)[number];
export type LifecycleEvent = {
  event: LifecycleEventName;
  member_id: Uuid;
  occurred_at: Instant;
  identity_revision: Revision;
};
export type ZonedLocal = { local: string; zone: string };
export type Money = { amount: string; currency: string }; // exact unsigned decimal string
export const ERROR_CODES = [
  "validation_failed",
  "unauthenticated",
  "forbidden",
  "not_found",
  "conflict",
  "rate_limited",
  "unavailable",
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];
/**
 * Core field error codes of the shape checks (mirrors app.contract_field_error_codes).
 * Not exhaustive: in contract v1 a field error code is any lower_snake_case token
 * (isFieldErrorCode), and commands return their own specific codes (last_admin, reauthenticate,
 * held, ...). A client maps a code it does not know to a generic field notice; it never rejects
 * the envelope for it.
 */
export const FIELD_ERROR_CODES = [
  "required",
  "invalid",
  "unknown_field",
  "must_be_object",
  "unsupported",
  "must_be_null",
  "out_of_range",
  "unknown",
  "unregistered",
  "scale_exceeded",
  "gate_closed",
] as const;
/** A core code, or any other lower_snake_case code a command returns (open vocabulary). */
export type FieldErrorCode = (typeof FIELD_ERROR_CODES)[number] | (string & {});
const FIELD_ERROR_CODE_RE = /^[a-z][a-z0-9_]{0,62}$/;
/** Whether code is a well-formed v1 field error code: ^[a-z][a-z0-9_]{0,62}$. */
export function isFieldErrorCode(code: string): boolean {
  return FIELD_ERROR_CODE_RE.test(code);
}
export type CommandRequest = {
  version: 1;
  command: string;
  request_id: Uuid;
  expected_revision?: Revision | null;
  payload: { [key: string]: Json };
};
export type CommandSuccess = { request_id: Uuid; data: Json; revision: Revision };
export type CommandError = {
  request_id: Uuid | null;
  code: ErrorCode;
  message: string;
  field_errors: Record<string, FieldErrorCode>;
  current_revision?: Revision | null;
};
export type CommandResponse = CommandSuccess | CommandError;

export type ContractKinds = {
  member_ref: MemberRef;
  account_ref: AccountRef;
  actor: Actor;
  source_ref: SourceRef;
  task_source: TaskSource;
  notification_key: NotificationKey;
  lifecycle_event: LifecycleEvent;
  instant: Instant;
  zoned_local: ZonedLocal;
  money: Money;
  command_request: CommandRequest;
  command_response: CommandResponse;
};
export type Kind = keyof ContractKinds;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN_RE = /^[a-z][a-z0-9_]{0,62}$/;
const COMMAND_RE = /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/;
const INSTANT_RE = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?Z$/;
const LOCAL_RE = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})$/;
const ZONE_RE =
  /^(UTC|(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)(\/[A-Za-z][A-Za-z0-9_+-]*){1,2})$/;
const AMOUNT_RE = /^(0|[1-9][0-9]{0,14})(\.[0-9]{1,6})?$/;
const CURRENCY_RE = /^[A-Z]{3}$/;

type Value = unknown;
type ErrorFn = (v: Value) => string | null;
type Obj = Record<string, unknown>;

const hasOwn = (o: object, k: string): boolean => Object.prototype.hasOwnProperty.call(o, k);
const own = (o: Obj, k: string): unknown => (hasOwn(o, k) ? o[k] : undefined);
const isMissing = (v: Value): boolean => v === undefined || v === null;
const isObject = (v: Value): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
/** Sets a key as an own data property, even for names like "__proto__". */
const put = (o: Obj, k: string, v: unknown): void => {
  Object.defineProperty(o, k, { value: v, enumerable: true, writable: true, configurable: true });
};

function stringRule(re: RegExp, maxLength = Infinity): ErrorFn {
  return (v) => {
    if (isMissing(v)) return "required";
    return typeof v === "string" && v.length <= maxLength && re.test(v) ? null : "invalid";
  };
}

const uuidError = stringRule(UUID_RE);
const tokenError = stringRule(TOKEN_RE);
const zoneError = stringRule(ZONE_RE, 64);
const currencyError = stringRule(CURRENCY_RE);
const amountError = stringRule(AMOUNT_RE);
const nullable = (fn: ErrorFn): ErrorFn => (v) => (isMissing(v) ? null : fn(v));

/** Integers are defined by value (1, 1.0 and 1e0 are the same integer). */
const integerIn = (v: Value, min: number, max: number): boolean =>
  typeof v === "number" && Number.isInteger(v) && v >= min && v <= max;

function revisionError(v: Value): string | null {
  if (isMissing(v)) return "required";
  return integerIn(v, 1, Number.MAX_SAFE_INTEGER) ? null : "invalid";
}

function calendarOk(m: RegExpExecArray): boolean {
  const [y, mo, d, h, mi, s] = m.slice(1, 7).map(Number);
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const dim = mo === 2 ? (leap ? 29 : 28) : [4, 6, 9, 11].includes(mo) ? 30 : 31;
  return y >= 1 && mo >= 1 && mo <= 12 && d >= 1 && d <= dim && h <= 23 && mi <= 59 && s <= 59;
}

function dateTimeRule(re: RegExp): ErrorFn {
  return (v) => {
    if (isMissing(v)) return "required";
    if (typeof v !== "string") return "invalid";
    const m = re.exec(v);
    return m && calendarOk(m) ? null : "invalid";
  };
}

const instantError = dateTimeRule(INSTANT_RE);
const localError = dateTimeRule(LOCAL_RE);

function enumRule(values: readonly string[]): ErrorFn {
  return (v) => {
    if (isMissing(v)) return "required";
    return typeof v === "string" && values.includes(v) ? null : "invalid";
  };
}

function fieldErrorsError(v: Value): string | null {
  if (isMissing(v)) return "required";
  return isObject(v) &&
    Object.keys(v).every((k) => {
      const code = v[k];
      return typeof code === "string" && isFieldErrorCode(code);
    })
    ? null
    : "invalid";
}

/** Rule errors per key plus {"<key>": "unknown_field"} for every own key outside the rules. */
function objectRules(o: Obj, rules: Record<string, ErrorFn>): FieldErrors {
  const errors: FieldErrors = {};
  for (const key of Object.keys(rules)) {
    const e = rules[key](own(o, key));
    if (e !== null) put(errors, key, e);
  }
  for (const key of Object.keys(o)) {
    if (!hasOwn(rules, key)) put(errors, key, "unknown_field");
  }
  return errors;
}

const accept: ErrorFn = () => null;

type PlainKind = "member_ref" | "account_ref" | "source_ref" | "task_source" | "notification_key" |
  "lifecycle_event" | "zoned_local" | "money";

const RULES: Record<PlainKind, Record<string, ErrorFn>> = {
  member_ref: { member_id: uuidError },
  account_ref: { auth_user_id: uuidError },
  source_ref: { source_type: tokenError, source_id: uuidError, source_revision: revisionError },
  task_source: { source_type: tokenError, source_id: uuidError, purpose: tokenError },
  notification_key: {
    source_type: tokenError,
    source_id: uuidError,
    source_revision: revisionError,
    recipient_member_id: uuidError,
    reminder_kind: tokenError,
    scheduled_at: instantError,
  },
  lifecycle_event: {
    event: enumRule(LIFECYCLE_EVENTS),
    member_id: uuidError,
    occurred_at: instantError,
    identity_revision: revisionError,
  },
  zoned_local: { local: localError, zone: zoneError },
  money: { amount: amountError, currency: currencyError },
};

const MEMBER_ACTOR: Record<string, ErrorFn> = { kind: accept, member_id: uuidError, auth_user_id: uuidError };
const SYSTEM_ACTOR: Record<string, ErrorFn> = {
  kind: accept,
  system_principal_id: uuidError,
  job_id: uuidError,
  initiating_member_id: nullable(uuidError),
};
const COMMAND_REQUEST: Record<string, ErrorFn> = {
  version: (v) => (isMissing(v) ? "required" : integerIn(v, 1, 1) ? null : "unsupported"),
  command: stringRule(COMMAND_RE, 127),
  request_id: uuidError,
  expected_revision: nullable(revisionError),
  payload: (v) => (isObject(v) ? null : "must_be_object"),
};
const commandError = (o: Obj): Record<string, ErrorFn> => ({
  request_id: (v) => (hasOwn(o, "request_id") ? nullable(uuidError)(v) : "required"),
  code: enumRule(ERROR_CODES),
  message: (v) => (isMissing(v) ? "required" : typeof v === "string" ? null : "invalid"),
  field_errors: fieldErrorsError,
  current_revision: nullable(revisionError),
});
const commandSuccess = (o: Obj): Record<string, ErrorFn> => ({
  request_id: uuidError,
  data: () => (hasOwn(o, "data") ? null : "required"),
  revision: revisionError,
});

/** The key rules that apply to an object value of this kind (null when the shape is unknown). */
function rulesFor(kind: Exclude<Kind, "instant">, o: Obj): Record<string, ErrorFn> | null {
  switch (kind) {
    case "actor": {
      const k = own(o, "kind");
      return k === "member" ? MEMBER_ACTOR : k === "system" ? SYSTEM_ACTOR : null;
    }
    case "command_request":
      return COMMAND_REQUEST;
    case "command_response":
      return hasOwn(o, "code") ? commandError(o) : commandSuccess(o);
    default:
      return RULES[kind];
  }
}

const KINDS: readonly Kind[] = [
  "member_ref", "account_ref", "actor", "source_ref", "task_source", "notification_key",
  "lifecycle_event", "instant", "zoned_local", "money", "command_request", "command_response",
];

/** Same result shape and field errors as app.contract_check(kind, value). */
export function check(kind: Kind, value: Value): CheckResult {
  if (!KINDS.includes(kind)) throw new Error(`unknown contract kind: ${String(kind)}`);
  const done = (field_errors: FieldErrors): CheckResult => ({
    valid: Object.keys(field_errors).length === 0,
    field_errors,
  });
  if (kind === "instant") {
    const e = instantError(value);
    return done(e === null ? {} : { $: e });
  }
  if (!isObject(value)) return done({ [kind === "command_request" ? "envelope" : "$"]: "must_be_object" });
  if (kind === "actor") {
    if (isMissing(own(value, "kind"))) return done({ kind: "required" });
    if (rulesFor(kind, value) === null) return done({ kind: "invalid" });
  }
  return done(objectRules(value, rulesFor(kind, value)!));
}

export class ContractViolation extends Error {
  readonly kind: Kind;
  readonly fieldErrors: FieldErrors;
  constructor(kind: Kind, fieldErrors: FieldErrors) {
    super(`${kind} violates wire contract v${CONTRACT_VERSION}: ${JSON.stringify(fieldErrors)}`);
    this.kind = kind;
    this.fieldErrors = fieldErrors;
  }
}

const cloneJson = (v: unknown): unknown => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

/** Typed decode: a fresh copy of the contract keys when valid, otherwise ContractViolation. */
export function decode<K extends Kind>(kind: K, value: unknown): ContractKinds[K] {
  const result = check(kind, value);
  if (!result.valid) throw new ContractViolation(kind, result.field_errors);
  return encode(kind, value as ContractKinds[K]) as ContractKinds[K];
}

/**
 * Wire form of a contract value: exactly the contract keys the value carries, so an omitted
 * optional key stays omitted and an explicit null stays null. Throws if the value is invalid.
 */
export function encode<K extends Kind>(kind: K, value: ContractKinds[K]): Json {
  const result = check(kind, value);
  if (!result.valid) throw new ContractViolation(kind, result.field_errors);
  if (kind === "instant") return value as Json;
  const o = value as unknown as Obj;
  const out: Obj = {};
  for (const key of Object.keys(rulesFor(kind as Exclude<Kind, "instant">, o)!)) {
    if (hasOwn(o, key)) put(out, key, cloneJson(o[key]));
  }
  return out as Json;
}

export const isCommandError = (r: CommandResponse): r is CommandError => hasOwn(r, "code");
