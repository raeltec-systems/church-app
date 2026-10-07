// Runs every shared v1 fixture through the TypeScript mapping: `npm run contracts:test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  check, decode, encode, ContractViolation, FIELD_ERROR_CODES, LIFECYCLE_EVENTS,
  isCommandError, isFieldErrorCode, type Kind,
} from "./contracts.ts";

const dir = join(import.meta.dirname, "..", "fixtures", "v1");
const files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();

type Case = { name: string; value: unknown; field_errors?: Record<string, string> };
type Fixture = { kind: Kind; contract_version: number; valid: Case[]; invalid: Case[] };
const load = (file: string): Fixture => JSON.parse(readFileSync(join(dir, file), "utf8")) as Fixture;

test("fixture set is present", () => {
  assert.ok(files.length >= 12, `expected the v1 fixture files, found ${files.length}`);
});

for (const file of files) {
  const fixture = load(file);
  assert.equal(fixture.contract_version, 1);

  for (const c of fixture.valid) {
    test(`${fixture.kind} valid: ${c.name}`, () => {
      assert.deepEqual(check(fixture.kind, c.value), { valid: true, field_errors: {} });
      // Decode -> encode returns the identical wire value: no key added, dropped or nulled.
      assert.deepStrictEqual(encode(fixture.kind, decode(fixture.kind, c.value)), c.value);
    });
  }
  for (const c of fixture.invalid) {
    test(`${fixture.kind} invalid: ${c.name}`, () => {
      assert.deepStrictEqual(check(fixture.kind, c.value), { valid: false, field_errors: c.field_errors });
      assert.throws(() => decode(fixture.kind, c.value), ContractViolation);
    });
  }
}

test("the lifecycle event list equals the valid lifecycle fixtures", () => {
  const events = load("lifecycle_event.json").valid.map((c) => (c.value as { event: string }).event);
  assert.deepEqual([...LIFECYCLE_EVENTS].sort(), [...events].sort());
});

test("unknown kind is a programming error", () => {
  assert.throws(() => check("nope" as Kind, {}));
});

test("field error codes are an open lower_snake_case vocabulary", () => {
  for (const code of FIELD_ERROR_CODES) assert.ok(isFieldErrorCode(code), code);
  for (const code of ["last_admin", "reauthenticate", "password_reset_required", "held"]) {
    assert.ok(isFieldErrorCode(code), code);
  }
  for (const code of ["", "Held", "too-big", "9lives", "a".repeat(64)]) {
    assert.ok(!isFieldErrorCode(code), code);
  }
});

test("an identity refusal with a command-specific code decodes as its top-level error", () => {
  const r = decode("command_response", {
    request_id: "00000000-0000-4000-8000-000000000001",
    code: "forbidden",
    message: "You are not allowed to do this.",
    field_errors: { member_id: "last_admin" },
  });
  assert.ok(isCommandError(r));
  assert.equal(r.code, "forbidden");
  assert.equal(r.message, "You are not allowed to do this.");
  assert.deepEqual(r.field_errors, { member_id: "last_admin" });
});
