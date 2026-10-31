import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync,existsSync,writeFileSync,chmodSync,symlinkSync,readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {validateIssue,mintInvitation,invitationDigest,operatorSql,operatorSummary,reconcileInvitation} from './admin-onboarding-core.mjs';
import {parseArgs,hostedTarget,executeOperator} from './admin-onboarding.mjs';
import {privateDirectory,readPrivateJson,writePrivateJson} from './admin-onboarding-files.mjs';

const id='00000000-0000-4000-8000-000000000081';
const account='00000000-0000-4000-8000-000000000082';
const operation='00000000-0000-4000-8000-000000000083';
const request={phone_username:'+447700900818',existing_account:null,synthetic:true,
  identity_check:'in_person',case_reference:'SETUP-unit-test'};
const preparation={outcome:'delete_orphan',invitation_id:id,auth_user_id:account,operation_id:operation};

for(const environment of ['local','staging','production']) test(`invitation generation is environment bound: ${environment}`,()=>{
  const token=mintInvitation(environment);assert.match(token,new RegExp(`^adm1_${environment}_[A-Za-z0-9_-]{43}$`));
  assert.match(invitationDigest(token,environment),/^[a-f0-9]{64}$/);
  assert.notEqual(token,mintInvitation(environment));
  assert.throws(()=>invitationDigest(token,environment==='local'?'staging':'local'));
});
test('synthetic issuance is restricted to fictional accounts outside production',()=>{
  assert.deepEqual(validateIssue(request,'local'),request);
  assert.throws(()=>validateIssue(request,'production'));
  assert.throws(()=>validateIssue({...request,phone_username:'+260971234567'},'staging'));
});
for(const [name,change] of [
  ['password',{password:'must-never-be-accepted'}],['role',{role:'admin'}],['arbitrary operator',{operator:'someone'}],
  ['raw private data in case reference',{case_reference:'person name phone'}],['bad phone',{phone_username:'0971234567'}],
  ['no explicit synthetic choice',{synthetic:null}],['unbound existing identity',{existing_account:'not-a-uuid'}],
  ['unsupported identity check',{identity_check:'matching_phone'}],
])test(`operator issue rejects ${name}`,()=>assert.throws(()=>validateIssue({...request,...change},'local')));
test('SQL sends digest, not invitation, and checks the marker on every operation',()=>{
  const invitation=mintInvitation('local');
  const query=operatorSql('local','issue',{invitation,request});
  assert.ok(query.includes("platform_current_environment()='local'"));
  assert.ok(query.includes(invitationDigest(invitation,'local')));assert.ok(!query.includes(invitation));
  for(const action of ['status','revoke','prepare','finish'])assert.ok(operatorSql('local',action,{invitationId:id}).startsWith("select case when app.platform_current_environment()='local'"));
  assert.throws(()=>operatorSql('local','prepare',{invitationId:"bad';select 1;--"}));
  assert.throws(()=>operatorSql('local','unknown',{}));
});
test('operator output excludes account identifiers, token and correlation',()=>{
  assert.deepEqual(operatorSummary({...preparation,invitation:'private',phone_username:request.phone_username,
    correlation_nonce:'private',access_token:'private',password:'private'}),{outcome:'delete_orphan',invitation_id:id});
});
test('cleanup never deletes an existing/completed/review-required account',async()=>{
  for(const outcome of ['cleaned','completed','operator_review_required']) {
    let deletes=0;
    const result=await reconcileInvitation('local',id,{query:async()=>({outcome}),deleteAuthUser:async()=>{deletes++;}});
    assert.equal(result.outcome,outcome);assert.equal(deletes,0);
  }
});
test('cleanup requires exact valid server authority before deleting any account',async()=>{
  for(const change of [{invitation_id:operation},{auth_user_id:'bad'},{operation_id:null},{outcome:'delete_any_user'}]) {
    let deletes=0;
    await assert.rejects(()=>reconcileInvitation('local',id,{query:async()=>({...preparation,...change}),deleteAuthUser:async()=>{deletes++;}}));
    assert.equal(deletes,0);
  }
});
test('unknown provider deletion stays pending when SQL still sees an account',async()=>{
  const queries=[];let deletes=0;
  const result=await reconcileInvitation('local',id,{query:async q=>{queries.push(q);return queries.length===1?preparation:{outcome:'cleanup_pending'};},
    deleteAuthUser:async user=>{assert.equal(user,account);deletes++;throw new Error('private provider response');}});
  assert.equal(result.outcome,'cleanup_pending');assert.equal(deletes,1);assert.equal(queries.length,2);
});
test('lost deletion response may be completed only by authoritative SQL absence',async()=>{
  let calls=0;
  const result=await reconcileInvitation('local',id,{query:async()=>++calls===1?preparation:{outcome:'cleaned',late_provider_fenced:true},deleteAuthUser:async()=>{throw new Error('timeout');}});
  assert.deepEqual(result,{outcome:'cleaned',late_provider_fenced:true});
});
test('CLI requires an exact explicit target and refuses secret-bearing arguments',()=>{
  assert.equal(parseArgs(['status','--env','local','--confirm-target','disposable']).action,'status');
  for(const args of [[],['status','--env','local'],['issue','--env','local','--confirm-target','x'],
    ['status','--env','local','--confirm-target','x','--password','private'],
    ['status','--env','local','--env','production','--confirm-target','x']])assert.throws(()=>parseArgs(args));
});
test('hosted operations cannot be redirected to another environment or unknown production',()=>{
  const envs={local:{name:'local',supabase:{}},staging:{name:'staging',supabase:{project_ref:'aaaaaaaaaaaaaaaaaaaa',api_url:'https://aaaaaaaaaaaaaaaaaaaa.supabase.co'},deploy:{github_environment:'staging'}},
    production:{name:'production',supabase:{project_ref:null},deploy:{github_environment:'production'}}};
  assert.throws(()=>hostedTarget('staging','bbbbbbbbbbbbbbbbbbbb','bbbbbbbbbbbbbbbbbbbb',null,envs));
  assert.throws(()=>hostedTarget('production','bbbbbbbbbbbbbbbbbbbb','bbbbbbbbbbbbbbbbbbbb',null,envs));
  assert.throws(()=>hostedTarget('production','aaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaa',envs));
  assert.equal(hostedTarget('staging','aaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaa',null,envs).projectRef,'aaaaaaaaaaaaaaaaaaaa');
});
test('private source publication is atomic and refuses a second invitation overwrite',()=>{
  const parent=mkdtempSync(join(tmpdir(),'church-admin-private-test-'));
  try {
    const dir=privateDirectory(join(parent,'private'));const file=join(dir,'invitation.json');
    writePrivateJson(file,{one:1});assert.deepEqual(readPrivateJson(file),{one:1});
    assert.throws(()=>writePrivateJson(file,{two:2}));assert.deepEqual(readPrivateJson(file),{one:1});
    writePrivateJson(file,{one:2},{replace:true});assert.deepEqual(readPrivateJson(file),{one:2});
    if(process.platform!=='win32') {chmodSync(file,0o644);assert.throws(()=>readPrivateJson(file));}
  } finally {rmSync(parent,{recursive:true,force:true});}
});
test('issue saves recoverable authority before SQL and retries the same invitation',async()=>{
  const parent=mkdtempSync(join(tmpdir(),'church-admin-issue-test-'));
  try {
    const dir=join(parent,'private');const opts=parseArgs(['issue','--env','local','--confirm-target','isolated','--state-dir',dir]);
    const queries=[];const ports={tag:'isolated',query:async q=>{queries.push(q);assert.ok(existsSync(join(dir,'invitation.json')));if(queries.length===1)throw new Error('connection interrupted');return {invitation_id:id,expires_at:'2099-01-01T00:00:00Z'};}};
    await assert.rejects(()=>executeOperator(opts,ports,{prompt:async()=>request}));
    const token=readPrivateJson(join(dir,'invitation.json')).invitation;
    const result=await executeOperator(opts,ports,{prompt:async()=>{throw new Error('must reuse prepared request');}});
    assert.equal(queries[0],queries[1]);assert.equal(readPrivateJson(join(dir,'invitation.json')).invitation,token);
    assert.equal(result.outcome,'issued');assert.ok(!JSON.stringify(result).includes(token));assert.ok(!JSON.stringify(result).includes(request.phone_username));
  } finally {rmSync(parent,{recursive:true,force:true});}
});
test('status of an interrupted issue uses the prepared digest without minting or issuing',async()=>{
  const parent=mkdtempSync(join(tmpdir(),'church-admin-status-test-'));
  try {
    const dir=privateDirectory(join(parent,'private'));const invitation=mintInvitation('local');
    writePrivateJson(join(dir,'invitation.json'),{version:1,environment:'local',target:'isolated',request,invitation});
    const queries=[];const result=await executeOperator(parseArgs(['status','--env','local','--confirm-target','isolated','--state-dir',dir]),
      {tag:'isolated',query:async q=>{queries.push(q);return null;}});
    assert.equal(result.outcome,'not_observed');assert.equal(queries.length,1);assert.ok(queries[0].includes('lookup_digest'));assert.ok(!queries[0].includes(invitation));
  } finally {rmSync(parent,{recursive:true,force:true});}
});
