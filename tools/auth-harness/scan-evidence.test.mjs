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
