import test from 'node:test';
import assert from 'node:assert/strict';
import {parseRequest,publicReply,providerResult,runRequest,sha256,MAX_REQUEST_BYTES} from './logic.mjs';
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const token = `adm1_local_${'a'.repeat(43)}`;
const common = {version:1,action:'inspect',invitation:token,phone_username:'+12025550101'};
const complete = {...common,action:'complete',request_id:id(1),full_name:'SYNTHETIC Setup Owner',
  password:'SYNTHETIC-only-password',privacy_notice_version:'synthetic-admin-setup-1',privacy_accepted:true};
const ready = {outcome:'ready',mode:'new_account',privacy_notice_version:complete.privacy_notice_version,
  privacy_notice_text:'SYNTHETIC fixture notice, not an approved church policy.',expires_at:'2099-01-01T00:00:00.000Z'};
const provision = {outcome:'provision',auth_user_id:id(2),operation_id:id(3),correlation_nonce:id(4)};
const completed = {outcome:'completed',sign_in_required:true};
const pending = {outcome:'pending',request_id:id(1)};
function fixture(answers=[ready,provision,completed]) {
  const calls = [],creates = [],auths = [];
  let disposed = 0;
  const ports = {
    system:async payload => { calls.push(payload); const next=answers.shift(); if(next instanceof Error) throw next; return next; },
    createAuthUser:async payload => { creates.push(payload); return 'observed'; },
    authenticate:async (...args) => {auths.push(args);return {sessionId:id(5),dispose:async()=>{disposed++;}};},
  };
  return {ports,calls,creates,auths,get disposed(){return disposed;}};
}

test('valid inspect, complete and status requests parse',()=>{
  for(const p of [common,complete,{...common,action:'status',request_id:id(1)}])
    assert.deepEqual(parseRequest(JSON.stringify(p),'local'),p);
});
for(const [name,change] of [
  ['version',{version:2}],['action',{action:'grant_admin'}],['wrong environment',{invitation:token.replace('_local_','_production_')}],
  ['short invitation',{invitation:'not-an-invitation'}],['unnormalized phone',{phone_username:'02025550101'}],
  ['forged account',{auth_user_id:id(9)}],['forged role',{role:'admin'}],['forged metadata',{app_metadata:{role:'admin'}}],
]) test(`parse refuses ${name}`,()=>assert.equal(parseRequest(JSON.stringify({...common,...change}),'local'),null));
for(const [name,change] of [
  ['missing consent',{privacy_accepted:false}],['invalid request id',{request_id:'abc'}],
  ['control name',{full_name:'person\nname'}],['empty name',{full_name:'  '}],
  ['missing notice',{privacy_notice_version:''}],['short password',{password:'tiny'}],
  ['oversized password',{password:'a'.repeat(73)}],['utf8 password truncation',{password:'😀'.repeat(19)}],
]) test(`complete refuses ${name}`,()=>assert.equal(parseRequest(JSON.stringify({...complete,...change}),'local'),null));
test('oversized and malformed JSON are refused',()=>{
  for(const s of ['{','[]','null','x'.repeat(MAX_REQUEST_BYTES+1)]) assert.equal(parseRequest(s,'local'),null);
});
test('status cannot carry password or overwrite profile',()=>{
  assert.equal(parseRequest(JSON.stringify({...common,action:'status',request_id:id(1),password:'SYNTHETIC'}),'local'),null);
});
test('prototype-named keys are rejected',()=>{
  assert.equal(parseRequest(JSON.stringify(common).replace('"version":1','"version":1,"__proto__":{}'),'local'),null);
});
test('public responses strip internal ids, credentials and metadata',()=>{
  assert.deepEqual(publicReply({...completed,access_token:'do-not-emit',auth_user_id:id(2),actor:{},correlation_nonce:id(4)}),completed);
});
test('ready response is explicit and bounded',()=>{
  assert.deepEqual(publicReply({...ready,account:id(2)}),ready);
  for(const change of [{mode:'admin'},{privacy_notice_text:''},{expires_at:'wrong'},{privacy_notice_text:'x'.repeat(12001)}])
    assert.deepEqual(publicReply({...ready,...change}),{outcome:'unavailable'});
});
test('success cannot mint a session or silently activate private access',()=>{
  assert.deepEqual(publicReply({outcome:'completed',sign_in_required:false}),{outcome:'unavailable'});
  assert.deepEqual(publicReply({outcome:'activation_pending',sign_in_required:true}),{outcome:'activation_pending',sign_in_required:true});
});
for(const status of [undefined,408,429,500,502,503]) test(`provider ${status} stays unknown`,()=>assert.equal(providerResult(status,{}),'unknown'));
test('provider distinguishes definitive weak password, collision and success',()=>{
  assert.equal(providerResult(422,{code:'weak_password'}),'password_rejected');
  assert.equal(providerResult(422,{error_code:'weak_password'}),'password_rejected');
  assert.equal(providerResult(422,{code:'user_already_exists'}),'rejected');
  assert.equal(providerResult(201,{}),'observed');
});
test('hash is deterministic and not the usable invitation',async()=>{
  const digest=await sha256(token); assert.match(digest,/^[0-9a-f]{64}$/);
  assert.equal(digest,await sha256(token)); assert.notEqual(digest,token);
});
test('new-account path creates exactly the server-reserved id and then finalizes',async()=>{
  const f=fixture(); assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),completed);
  assert.equal(f.creates.length,1); assert.equal(f.auths.length,0);
  assert.deepEqual(f.creates[0],{id:id(2),phone:common.phone_username,password:complete.password,operationId:id(3),nonce:id(4)});
  assert.deepEqual(f.calls.map(x=>x.action),['inspect','begin','finish']);
  assert.equal(f.calls[2].provider_result,'observed');
  assert.ok(f.calls.every(x=>!('password' in x)&&!('invitation' in x)));
});
test('invalid or revoked invitation never reaches account creation',async()=>{
  const f=fixture([{outcome:'refused'}]);assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),{outcome:'refused'});
  assert.equal(f.creates.length,0);assert.equal(f.auths.length,0);
});
test('changed notice version prevents account creation',async()=>{
  const f=fixture([{...ready,privacy_notice_version:'newer'}]);
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),{outcome:'refused'});assert.equal(f.creates.length,0);
});
test('duplicate pending request never dispatches another provider creation',async()=>{
  const f=fixture([ready,pending]);assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),pending);
  assert.equal(f.creates.length,0);
});
test('malformed reservation never becomes account-creation authority',async()=>{
  const f=fixture([ready,{...provision,auth_user_id:'bad'}]);
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),{outcome:'uncertain'});assert.equal(f.creates.length,0);
});
test('provider timeout is reconciled without retrying or claiming completion',async()=>{
  const f=fixture([ready,provision,pending]);
  f.ports.createAuthUser=async()=>{f.creates.push({});throw new Error('private provider diagnostic');};
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),pending);
  assert.equal(f.creates.length,1);assert.equal(f.calls[2].provider_result,'unknown');
});
test('lost completion response is uncertain, not success',async()=>{
  const f=fixture([ready,provision,new Error('private diagnostic')]);
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),{outcome:'uncertain'});
  assert.equal(f.creates.length,1);
});
test('status uses the original request and never sends a password or creates a user',async()=>{
  const f=fixture([completed]);
  assert.deepEqual(await runRequest({...common,action:'status',request_id:id(1)},'b'.repeat(64),f.ports),completed);
  assert.equal(f.calls[0].request_id,id(1));assert.equal(f.calls[0].action,'status');
  assert.equal(f.creates.length,0);assert.equal(f.auths.length,0);assert.ok(!('password' in f.calls[0]));
});
test('existing account is authenticated, never created or reset',async()=>{
  const f=fixture([{...ready,mode:'existing_account'},completed]);
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),completed);
  assert.equal(f.creates.length,0);assert.equal(f.auths.length,1);assert.equal(f.disposed,1);
  assert.equal(f.calls[1].session_id,id(5));
});
test('incorrect existing password cannot request a privileged database mutation',async()=>{
  const f=fixture([{...ready,mode:'existing_account'}]);f.ports.authenticate=async()=>null;
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),{outcome:'password_rejected'});
  assert.equal(f.calls.length,1);assert.equal(f.creates.length,0);
});
test('existing proof session is cleaned even when database completion is unavailable',async()=>{
  const f=fixture([{...ready,mode:'existing_account'},new Error('network')]);
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),{outcome:'uncertain'});
  assert.equal(f.disposed,1);
});
test('expired or malformed private metadata never appears in errors',async()=>{
  const f=fixture([new Error(`${complete.password} ${token}`)]);
  const r=await runRequest(common,'b'.repeat(64),f.ports);
  assert.deepEqual(r,{outcome:'unavailable'});assert.ok(!JSON.stringify(r).includes(complete.password));
});

test('a competing complete request cannot borrow a prior completion',async()=>{
  const f=fixture([completed,{outcome:'refused'}]);
  assert.deepEqual(await runRequest({...complete,request_id:id(9)},'b'.repeat(64),f.ports),{outcome:'refused'});
  assert.deepEqual(f.calls.map(x=>x.action),['inspect','status']);
  assert.equal(f.calls[1].request_id,id(9));assert.equal(f.creates.length,0);
});
test('completed-request retry reconciles its own request without a password resend',async()=>{
  const f=fixture([completed,completed]);
  assert.deepEqual(await runRequest(complete,'b'.repeat(64),f.ports),completed);
  assert.deepEqual(f.calls.map(x=>x.action),['inspect','status']);
  assert.ok(f.calls.every(x=>!('password' in x)));assert.equal(f.creates.length,0);
});
test('an already pending completion still checks the callers request identity',async()=>{
  const f=fixture([pending,{outcome:'refused'}]);
  assert.deepEqual(await runRequest({...complete,request_id:id(9)},'b'.repeat(64),f.ports),{outcome:'refused'});
  assert.equal(f.calls[1].action,'status');assert.equal(f.creates.length,0);
});
