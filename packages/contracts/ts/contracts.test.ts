// Runs every shared v1 fixture through the TypeScript mapping: `npm run contracts:test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  check, decode, encode, ContractViolation, LIFECYCLE_EVENTS, type Kind,
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
