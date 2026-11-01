import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assertContainer, assertLocalDocker, assertLocalEndpoint, parseLocalTarget } from './local-target.mjs';

const config = 'project_id = "church-content-pilot"\n[api]\nport = 55421\n[db]\nport = 55422\n';
const target = parseLocalTarget(config);
function container(kind = 'db') {
  return { Id: 'a'.repeat(64), Name: `/supabase_${kind}_${target.project}`, State: { Running: true },
    Config: { Labels: { 'com.supabase.cli.project': target.project } },
    NetworkSettings: { Networks: { [target.network]: {} }, Ports: {
      '5432/tcp': [{ HostPort: '55422' }], '8000/tcp': [{ HostPort: '55421' }],
    } } };
}

test('target comes only from explicit project, API and database settings', () => {
  assert.deepEqual(target, { project: 'church-content-pilot', apiPort: 55421, dbPort: 55422,
    origin: 'http://127.0.0.1:55421', network: 'supabase_network_church-content-pilot' });
  assert.deepEqual(parseLocalTarget(config.replaceAll('\n', '\r\n')), target);
});
for (const [name, changed] of [
  ['absent project', config.replace('project_id', 'other_id')],
  ['duplicate project', 'project_id = "other"\n' + config],
  ['invalid project', config.replace('church-content-pilot', '../church')],
  ['absent API port', config.replace('[api]\nport = 55421', '[api]\nenabled = true')],
  ['duplicate port', config.replace('port = 55421', 'port = 55421\nport = 55423')],
  ['duplicate section', config + '[api]\nport = 55421\n'],
  ['overlapping ports', config.replace('55422', '55421')],
  ['privileged port', config.replace('55421', '80')],
  ['invalid port', config.replace('55421', '65536')],
  ['expression port', config.replace('55421', '55421 + 1')],
]) test(`refuses ${name}`, () => assert.throws(() => parseLocalTarget(changed)));

test('HTTP target must exactly match the configured loopback API', () => {
  assert.equal(assertLocalEndpoint(target.origin, target), target.origin);
  for (const bad of ['http://127.0.0.1:54321', 'http://localhost:55421', 'https://example.org',
    'http://user:pw@127.0.0.1:55421', target.origin + '/path', target.origin + '?x=1', undefined]) {
    assert.throws(() => assertLocalEndpoint(bad, target));
  }
  assert.throws(() => assertLocalEndpoint('https://example.org', { ...target, origin: 'https://example.org' }));
});

test('only local daemon transports are accepted', () => {
  assertLocalDocker('unix:///var/run/docker.sock');
  assertLocalDocker('npipe:////./pipe/dockerDesktopLinuxEngine');
  for (const endpoint of ['tcp://127.0.0.1:2375', 'ssh://server', 'https://server', '', undefined]) {
    assert.throws(() => assertLocalDocker(endpoint));
  }
});

test('database and API container identities and mapped ports agree', () => {
  assert.equal(assertContainer(container(), target, 'db'), 'a'.repeat(64));
  assert.equal(assertContainer(container('kong'), target, 'kong'), 'a'.repeat(64));
  assert.equal(assertContainer(container('edge_runtime'), target, 'edge_runtime'), 'a'.repeat(64));
});
for (const [name, mutate] of [
  ['default project beside the test project', (x) => { x.Name = '/supabase_db_church-app'; }],
  ['wrong project label', (x) => { x.Config.Labels['com.supabase.cli.project'] = 'church-app'; }],
  ['unlabelled container', (x) => { x.Config.Labels = {}; }],
  ['wrong network', (x) => { x.NetworkSettings.Networks = { supabase_network_church_app: {} }; }],
  ['stopped container', (x) => { x.State.Running = false; }],
  ['wrong published port', (x) => { x.NetworkSettings.Ports['5432/tcp'][0].HostPort = '54322'; }],
  ['unpublished port', (x) => { x.NetworkSettings.Ports = {}; }],
  ['mutable name rather than immutable id', (x) => { x.Id = 'supabase_db_church-content-pilot'; }],
]) test(`container refuses ${name}`, () => {
  const info = container(); mutate(info);
  assert.throws(() => assertContainer(info, target, 'db'));
});
test('unknown service cannot be selected', () => assert.throws(() => assertContainer(container(), target, 'auth')));
