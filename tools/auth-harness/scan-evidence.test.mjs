import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// A URL pathname is not a native filesystem path on Windows and does not
// decode spaces. Pass decoded paths to Bash with portable separators; no shell
// interpolation is involved. An unavailable scanner must never count as a
// successful negative security check.
const scanner = fileURLToPath(new URL('./scan-evidence.sh', import.meta.url));
// Native Windows Node must use Git Bash, not the unrelated System32 WSL launcher.
// Nonstandard Git installations can provide an explicit executable path.
const bash = process.env.SCAN_EVIDENCE_BASH ?? (process.platform === 'win32'
  ? join(process.env.ProgramFiles ?? 'C:/Program Files', 'Git', 'bin', 'bash.exe')
  : 'bash');
const bashPath = (value) => process.platform === 'win32' ? value.replaceAll('\\', '/') : value;
function scan(...args) {
  const result = spawnSync(bash, [scanner, ...args].map(bashPath), { encoding: 'utf8' });
  assert.ifError(result.error);
  assert.ok([0, 1, 2].includes(result.status),
    `scanner did not complete normally (${result.status}): ${result.stderr || result.stdout}`);
  return result;
}

test('Story 3.10 personal-data scan rejects identifiers and contact details', () => {
  const directory = mkdtempSync(join(tmpdir(), 'scan evidence #path-'));
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
      const result = scan('--personal-data', evidence);
      assert.notEqual(result.status, 0, `expected scan to reject ${value}`);
    }

    writeFileSync(evidence, 'Redacted checks complete. No personal values recorded.\n');
    const clean = scan('--personal-data', evidence);
    assert.equal(clean.status, 0, clean.stderr || clean.stdout);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('Story 3.10 personal-data scan keeps product vocabulary clean', () => {
  const directory = mkdtempSync(join(tmpdir(), 'scan evidence #path-'));
  try {
    const evidence = join(directory, 'README.md');
    writeFileSync(evidence, '## Staging Owner Acceptance\nMobile Android build: pass. Local Supabase and Edge Function suites pass. Client Core 428 tests.\n');
    const clean = scan('--personal-data', evidence);
    assert.equal(clean.status, 0, clean.stderr || clean.stdout);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('a missing path, an unknown flag or a flag in second position never reports clean', () => {
  const directory = mkdtempSync(join(tmpdir(), 'scan evidence #path-'));
  try {
    const evidence = join(directory, 'owner-review.md');
    writeFileSync(evidence, 'phone: +12025550123\n');
    const missing = scan('--personal-data', join(directory, 'nope'));
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /no such path/);
    assert.doesNotMatch(missing.stdout, /clean/);
    const unknown = scan('--personal', evidence);
    assert.equal(unknown.status, 2);
    assert.match(unknown.stderr, /unknown option/);
    const second = scan(evidence, '--personal-data');
    assert.notEqual(second.status, 0, 'the flag applies in any position');
    assert.doesNotMatch(second.stdout, /clean/);
    const bare = scan('--personal-data');
    assert.equal(bare.status, 2, '--personal-data needs an explicit path');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
