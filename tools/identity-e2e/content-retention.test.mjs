import assert from 'node:assert/strict';
import { test } from 'node:test';

import { retentionVerdict } from './content-retention.mjs';

test('retention E2E verdict requires both metadata and Storage object removal', () => {
  const verdict = retentionVerdict({
    oldReady: { asset: false, object: false },
    oldPending: { asset: false, object: false },
    recent: { asset: true, object: true },
    referenced: { asset: true, object: true },
  });
  assert.deepEqual(verdict, {
    old_ready_removed: true,
    old_pending_removed: true,
    recent_retained: true,
    referenced_retained: true,
  });
});

test('partial or inconsistent deletion does not count as success', () => {
  const verdict = retentionVerdict({
    oldReady: { asset: false, object: true },
    oldPending: { asset: true, object: false },
    recent: { asset: true, object: false },
    referenced: { asset: false, object: true },
  });
  assert.deepEqual(verdict, {
    old_ready_removed: false,
    old_pending_removed: false,
    recent_retained: false,
    referenced_retained: false,
  });
});
