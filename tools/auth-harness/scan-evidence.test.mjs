import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const scanner = new URL('./scan-evidence.sh', import.meta.url).pathname;

test('Story 3.10 personal-data scan rejects identifiers and contact details', () => {
  const directory = mkdtempSync(join(tmpdir(), 'scan-evidence-'));
  try {
    const evidence = join(directory, 'owner-review.md');
    const cases = [
      'member id: 123e4567-e89b-12d3-a456-426614174000',
      'phone: +12025550123',
      'phone: (202) 555-0101',
      'phone: 07700 900800',
      'mobile number: 260 97 1234567',
      'email: member@example.org',
      'Witness: Jordan Example',
      'witness name: Jordan Example',
      // Review 3.8-3.10 finding 13: spaced international numbers and unlabeled names.
      'Called +260 97 123 4567 after the run.',
      'reached +44 7700 900800',
      'reached +1 (202) 555-0101',
      '| Android | pass | Jordan Example |',
      'Checked by Mary Banda on Android.',
      // Local formats without a country code, and a label without a separator.
      'phone 0971234567',
      'called 097 123 4567',
      'reached 0977-123-456',
    ];

    for (const value of cases) {
      writeFileSync(evidence, `${value}\n`);
      const result = spawnSync('bash', [scanner, '--personal-data', evidence], { encoding: 'utf8' });
      assert.notEqual(result.status, 0, `expected scan to reject ${value}`);
    }

    writeFileSync(evidence, 'Redacted checks complete. No personal values recorded.\n');
    const clean = spawnSync('bash', [scanner, '--personal-data', evidence], { encoding: 'utf8' });
    assert.equal(clean.status, 0, clean.stderr || clean.stdout);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('Story 3.10 personal-data scan keeps product vocabulary clean', () => {
  const directory = mkdtempSync(join(tmpdir(), 'scan-evidence-'));
  try {
    const evidence = join(directory, 'README.md');
    writeFileSync(evidence, '## Staging Owner Acceptance\nMobile Android build: pass. Local Supabase and Edge Function suites pass. Client Core 428 tests.\n');
    const clean = spawnSync('bash', [scanner, '--personal-data', evidence], { encoding: 'utf8' });
    assert.equal(clean.status, 0, clean.stderr || clean.stdout);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('a missing path, an unknown flag or a flag in second position never reports clean', () => {
  const directory = mkdtempSync(join(tmpdir(), 'scan-evidence-'));
  try {
    const evidence = join(directory, 'owner-review.md');
    writeFileSync(evidence, 'phone: +12025550123\n');
    const missing = spawnSync('bash', [scanner, '--personal-data', join(directory, 'nope')], { encoding: 'utf8' });
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /no such path/);
    assert.doesNotMatch(missing.stdout, /clean/);
    const unknown = spawnSync('bash', [scanner, '--personal', evidence], { encoding: 'utf8' });
    assert.equal(unknown.status, 2);
    assert.match(unknown.stderr, /unknown option/);
    const second = spawnSync('bash', [scanner, evidence, '--personal-data'], { encoding: 'utf8' });
    assert.notEqual(second.status, 0, 'the flag applies in any position');
    assert.doesNotMatch(second.stdout, /clean/);
    const bare = spawnSync('bash', [scanner, '--personal-data'], { encoding: 'utf8' });
    assert.equal(bare.status, 2, '--personal-data needs an explicit path');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
