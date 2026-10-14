import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isFictionalGrantPhone } from './grants.mjs';

test('the grants run uses only its reserved fictional numbers', () => {
  for (const p of ['+12025550151', '+12025550156']) assert.ok(isFictionalGrantPhone(p), p);
  for (const p of ['+12025550150', '+12025550157', '+12025550171', '+9990000000', '12025550151']) {
    assert.ok(!isFictionalGrantPhone(p), p);
  }
});
