import { test } from 'node:test';
import assert from 'node:assert/strict';
import { captureOriginals, projectId, smsViolations, withPhoneOn, withValues } from './local-phone-auth.mjs';

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

test('on changes exactly the phone switch and autoconfirm', () => {
  const env = ['A=1', 'GOTRUE_EXTERNAL_PHONE_ENABLED=false', 'GOTRUE_SMS_AUTOCONFIRM=false'];
  assert.deepEqual(withPhoneOn(env).sort(),
    ['A=1', 'GOTRUE_EXTERNAL_PHONE_ENABLED=true', 'GOTRUE_SMS_AUTOCONFIRM=true'].sort());
  assert.deepEqual(smsViolations(withPhoneOn(env)), []);
});

test('off restores the captured CLI values exactly, including unset keys', () => {
  const cli = ['A=1', 'GOTRUE_EXTERNAL_PHONE_ENABLED=false'];
  const originals = JSON.parse(JSON.stringify(captureOriginals(cli)));
  assert.deepEqual(originals, { GOTRUE_EXTERNAL_PHONE_ENABLED: 'false', GOTRUE_SMS_AUTOCONFIRM: null });
  assert.deepEqual(withValues(withPhoneOn(cli), originals).sort(), [...cli].sort());
  const cli2 = ['GOTRUE_EXTERNAL_PHONE_ENABLED=false', 'GOTRUE_SMS_AUTOCONFIRM=false'];
  assert.deepEqual(withValues(withPhoneOn(cli2), captureOriginals(cli2)).sort(), [...cli2].sort());
});
