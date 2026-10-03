// Wire contract v1 — TypeScript mapping (for the Q10 React/Next.js alternative and any JS tool).
// Mirrors app.contract_check (supabase/migrations/20261003190000_cross_epic_contracts.sql) and
// must pass the shared fixtures in ../fixtures/v1. Types and shape checks only: no business
// rules. Registration membership, zone existence and money scale are server-side checks.
// Erasable TypeScript only, so Node runs it with built-in type stripping.

export const CONTRACT_VERSION = 1;

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type FieldErrors = Record<string, string>;
export type CheckResult = { valid: boolean; field_errors: FieldErrors };

export type Uuid = string;
export type Instant = string; // UTC RFC3339, e.g. 2026-10-03T12:34:56.123456Z
export type Revision = number; // integer 1..2^53-1

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
] as const;
export type LifecycleEventName = (typeof LIFECYCLE_EVENTS)[number];
export type LifecycleEvent = {
  event: LifecycleEventName;
  member_id: Uuid;
  occurred_at: Instant;
  identity_revision: Revision;
};
export type ZonedLocal = { local: string; zone: string };
export type Money = { amount: string; currency: string }; // exact decimal string, never a float
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
  field_errors: FieldErrors;
  current_revision?: Revision;
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
const ZONE_RE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/;
const AMOUNT_RE = /^-?(0|[1-9][0-9]{0,14})(\.[0-9]{1,6})?$/;
const NEG_ZERO_RE = /^-0(\.0+)?$/;
const CURRENCY_RE = /^[A-Z]{3}$/;

type Value = unknown;
type ErrorFn = (v: Value) => string | null;

const isMissing = (v: Value): boolean => v === undefined || v === null;
const isObject = (v: Value): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

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
const nullable = (fn: ErrorFn): ErrorFn => (v) => (isMissing(v) ? null : fn(v));

function revisionError(v: Value): string | null {
  if (isMissing(v)) return "required";
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 1 ? null : "invalid";
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

function amountError(v: Value): string | null {
  if (isMissing(v)) return "required";
  return typeof v === "string" && AMOUNT_RE.test(v) && !NEG_ZERO_RE.test(v) ? null : "invalid";
}

function enumRule(values: readonly string[]): ErrorFn {
  return (v) => {
    if (isMissing(v)) return "required";
    return typeof v === "string" && values.includes(v) ? null : "invalid";
  };
}

function objectRules(
  o: Record<string, unknown>,
  rules: Record<string, ErrorFn>,
  root = "$",
): FieldErrors {
  const errors: FieldErrors = {};
  for (const [key, rule] of Object.entries(rules)) {
    const e = rule(o[key]);
    if (e !== null) errors[key] = e;
  }
  if (Object.keys(o).some((k) => !(k in rules))) errors[root] = "unknown_field";
  return errors;
}

function fieldErrorsError(v: Value): string | null {
  if (isMissing(v)) return "required";
  return isObject(v) && Object.values(v).every((x) => typeof x === "string") ? null : "invalid";
}

const RULES: Record<Exclude<Kind, "instant" | "actor" | "command_request" | "command_response">, Record<string, ErrorFn>> = {
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
  const root = kind === "command_request" ? "envelope" : "$";
  if (!isObject(value)) return done({ [root]: "must_be_object" });

  switch (kind) {
    case "actor":
      if (isMissing(value.kind)) return done({ kind: "required" });
      if (value.kind === "member") {
        return done(objectRules(value, { kind: () => null, member_id: uuidError, auth_user_id: uuidError }));
      }
      if (value.kind === "system") {
        return done(objectRules(value, {
          kind: () => null,
          system_principal_id: uuidError,
          job_id: uuidError,
          initiating_member_id: nullable(uuidError),
        }));
      }
      return done({ kind: "invalid" });
    case "command_request":
      return done(objectRules(value, {
        version: (v) => (isMissing(v) ? "required" : v === 1 ? null : "unsupported"),
        command: stringRule(COMMAND_RE, 127),
        request_id: uuidError,
        expected_revision: nullable(revisionError),
        payload: (v) => (isObject(v) ? null : "must_be_object"),
      }, "envelope"));
    case "command_response":
      if ("code" in value) {
        return done(objectRules(value, {
          request_id: (v) => (v === undefined ? "required" : nullable(uuidError)(v)),
          code: enumRule(ERROR_CODES),
          message: (v) => (isMissing(v) ? "required" : typeof v === "string" ? null : "invalid"),
          field_errors: fieldErrorsError,
          current_revision: nullable(revisionError),
        }));
      }
      return done(objectRules(value, {
        request_id: uuidError,
        data: (v) => (v === undefined ? "required" : null),
        revision: revisionError,
      }));
    default:
      return done(objectRules(value, RULES[kind]));
  }
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

/** Typed decode: returns the value unchanged when valid, otherwise throws ContractViolation. */
export function decode<K extends Kind>(kind: K, value: unknown): ContractKinds[K] {
  const result = check(kind, value);
  if (!result.valid) throw new ContractViolation(kind, result.field_errors);
  return value as ContractKinds[K];
}

export const isCommandError = (r: CommandResponse): r is CommandError => "code" in r;
