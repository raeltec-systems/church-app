import { test } from 'node:test';
import assert from 'node:assert/strict';
import { projectId, smsViolations, withPhone } from './local-phone-auth.mjs';

test('reads project_id from config.toml', () => {
  assert.equal(projectId('# x\nproject_id = "church-app"\n'), 'church-app');
  assert.throws(() => projectId('nothing here'));
});

test('the CLI defaults carry no SMS route', () => {
  const env = ['GOTRUE_SMS_AUTOCONFIRM=true', 'GOTRUE_SMS_TEST_OTP=', 'GOTRUE_SMS_TEMPLATE=Your code is {{ .Code }}',
    'GOTRUE_MFA_PHONE_ENROLL_ENABLED=false', 'GOTRUE_EXTERNAL_PHONE_ENABLED=false'];
  assert.deepEqual(smsViolations(env), []);
});

test('any SMS provider, credential, hook, test OTP or phone MFA is refused', () => {
  for (const e of ['GOTRUE_SMS_PROVIDER=twilio', 'GOTRUE_SMS_TWILIO_ACCOUNT_SID=AC1',
    'GOTRUE_SMS_VONAGE_API_KEY=k', 'GOTRUE_SMS_TEST_OTP=12025550101:123456',
    'GOTRUE_HOOK_SEND_SMS_ENABLED=true', 'GOTRUE_HOOK_SEND_SMS_URI=pg-functions://x',
    'GOTRUE_MFA_PHONE_ENROLL_ENABLED=true', 'GOTRUE_MFA_PHONE_VERIFY_ENABLED=true']) {
    assert.deepEqual(smsViolations([e]), [e], e);
  }
});

test('withPhone changes exactly the phone switch and autoconfirm', () => {
  const env = ['A=1', 'GOTRUE_EXTERNAL_PHONE_ENABLED=false', 'GOTRUE_SMS_AUTOCONFIRM=false'];
  assert.deepEqual(withPhone(env, true).sort(),
    ['A=1', 'GOTRUE_EXTERNAL_PHONE_ENABLED=true', 'GOTRUE_SMS_AUTOCONFIRM=true'].sort());
  assert.ok(withPhone(env, false).includes('GOTRUE_EXTERNAL_PHONE_ENABLED=false'));
  assert.deepEqual(smsViolations(withPhone(env, true)), []);
});
