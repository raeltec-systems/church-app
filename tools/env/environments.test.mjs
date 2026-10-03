import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertRecipients, isSyntheticPattern, loadEnvironments, recipientAllowed,
  resolveDeployTarget, validateEnvironments,
} from './environments.mjs';

const clone = (o) => JSON.parse(JSON.stringify(o));
const envs = () => clone(loadEnvironments());
const FAKE_PROD = 'zzzzzzzzzzzzzzzzzzzz';

test('the committed configs are valid and separate', () => {
  assert.deepEqual(validateEnvironments(envs(), { productionRef: FAKE_PROD }), []);
});

test('production baseline keeps private access and sending disabled behind approval', () => {
  const e = envs();
  assert.equal(e.production.features.private_access, false);
  assert.equal(e.production.features.outbound_sending, false);
  assert.equal(e.production.deploy.requires_approval, true);
  for (const [key, value] of [
    ['features.private_access', true], ['features.outbound_sending', true],
    ['deploy.requires_approval', false], ['recipients.mode', 'synthetic_only'],
  ]) {
    const bad = envs();
    const [a, b] = key.split('.');
    bad.production[a][b] = value;
    assert.notDeepEqual(validateEnvironments(bad), [], `${key}=${value} must be rejected`);
  }
});

test('SMS cannot be enabled in any environment', () => {
  for (const name of ['local', 'staging', 'production']) {
    const bad = envs();
    bad[name].features.sms = true;
    assert.match(validateEnvironments(bad).join('\n'), /sms/);
  }
});

test('non-production recipient patterns must be synthetic', () => {
  for (const p of ['*@example.test', 'a@example.com', '*.invalid', 'x@foo.test', 'israelmuyoba+*@gmail.com']) {
    assert.ok(isSyntheticPattern(p), p);
  }
  for (const p of ['*@gmail.com', 'israelmuyoba@gmail.com', '*@*', 'pastor@church.org', '*', '*@example.*', '*invalid', '*test']) {
    assert.ok(!isSyntheticPattern(p), p);
  }
  const bad = envs();
  bad.staging.recipients.allowed_patterns.push('*@gmail.com');
  assert.match(validateEnvironments(bad).join('\n'), /can reach a real person/);
});

test('staging may only address synthetic recipients', () => {
  const { staging, local } = envs();
  assert.ok(recipientAllowed(staging, 'member-1@example.test'));
  assert.ok(recipientAllowed(staging, 'israelmuyoba+bicauth-reset@gmail.com'));
  assert.ok(recipientAllowed(local, 'x@y.invalid'));
  for (const a of ['israelmuyoba@gmail.com', 'someone@gmail.com', 'pastor@bickafue.org', 'not-an-email', '', 'a@example.test@gmail.com']) {
    assert.ok(!recipientAllowed(staging, a), a);
  }
  assert.throws(() => assertRecipients(staging, ['a@example.test', 'real@gmail.com']), /synthetic/);
});

test('a hand-edited non-synthetic pattern is still refused at send time', () => {
  const { staging } = envs();
  staging.recipients.allowed_patterns = ['*@gmail.com'];
  assert.ok(!recipientAllowed(staging, 'someone@gmail.com'));
});

test('production refuses every recipient while sending is disabled', () => {
  const { production } = envs();
  assert.ok(!recipientAllowed(production, 'member-1@example.test'));
  assert.throws(() => assertRecipients(production, ['member-1@example.test']), /disabled/);
});

test('deploy targets cannot cross environments', () => {
  const e = envs();
  const t = resolveDeployTarget(e, 'staging', 'tmurpotfluignacfueki');
  assert.equal(t.githubEnvironment, 'staging');
  assert.equal(t.apiUrl, 'https://tmurpotfluignacfueki.supabase.co');
  assert.throws(() => resolveDeployTarget(e, 'staging', FAKE_PROD), /expected project/);
  assert.throws(() => resolveDeployTarget(e, 'production', 'tmurpotfluignacfueki'), /another environment/);
  assert.throws(() => resolveDeployTarget(e, 'production', ''), /owner step/);
  assert.throws(() => resolveDeployTarget(e, 'local', 'tmurpotfluignacfueki'), /not a deployable/);
  const p = resolveDeployTarget(e, 'production', FAKE_PROD);
  assert.equal(p.githubEnvironment, 'production');
  assert.equal(p.databaseMarker, 'production');
});

test('a non-production config naming the production project is rejected', () => {
  const bad = envs();
  bad.staging.supabase.project_ref = FAKE_PROD;
  bad.staging.supabase.api_url = `https://${FAKE_PROD}.supabase.co`;
  assert.match(validateEnvironments(bad, { productionRef: FAKE_PROD }).join('\n'), /production project ref/);
});

test('configs cannot carry secret values', () => {
  const bad = envs();
  bad.staging.supabase.note = 'sb_' + 'secret_' + 'A'.repeat(32);
  assert.match(validateEnvironments(bad).join('\n'), /secret-like/);
});

test('operations: bounded system route, named operator, alerting and scheduler fail closed', () => {
  for (const [name, mutate, re] of [
    ['staging', (o) => { o.system_route.allowed_commands.push('fixture_counter.increment'); }, /allowed_commands/],
    ['local', (o) => { o.system_route.allowed_commands = []; }, /allowed_commands/],
    ['production', (o) => { o.system_route.activation = 'open_nonproduction'; }, /activation/],
    ['staging', (o) => { o.system_route.activation = 'owner_gate:ops_system_access'; }, /activation/],
    ['staging', (o) => { o.restricted_operators = ['israel', 'someone']; }, /restricted_operators/],
    ['local', (o) => { o.restricted_operators = []; }, /restricted_operators/],
    ['production', (o) => { o.alerting.enabled = true; }, /alerting.enabled/],
    ['staging', (o) => { o.alerting.destination = 'ops@example.test'; }, /no destination/],
    ['staging', (o) => { o.alerting.thresholds = { p95_ms: 1 }; }, /no destination or thresholds/],
    ['production', (o) => { o.scheduler.enabled = true; }, /scheduler/],
    ['local', (o) => { o.system_route.credential_digest = 'a'.repeat(64); }, /credential material/],
    ['staging', (o) => { o.system_route.credential_header = 'authorization'; }, /credential_header/],
  ]) {
    const bad = envs();
    mutate(bad[name].operations);
    assert.match(validateEnvironments(bad).join('\n'), re, `${name}: ${mutate}`);
  }
  const missing = envs();
  delete missing.staging.operations;
  assert.match(validateEnvironments(missing).join('\n'), /operations block is required/);
});
