import test from 'node:test';
import assert from 'node:assert/strict';
import {assertDisposableSetupTarget,fictionalSetupPhone} from './admin-onboarding.mjs';
const isolated={project:'church-admin-test',apiPort:56421,dbPort:56422,origin:'http://127.0.0.1:56421'};
test('commissioning rehearsal accepts only its dedicated local stack',()=>assert.doesNotThrow(()=>assertDisposableSetupTarget(isolated)));
for(const [name,change] of [
 ['shared project',{project:'church-app'}],['shared API port',{apiPort:54321,origin:'http://127.0.0.1:54321'}],
 ['shared DB port',{dbPort:54322}],['hosted URL',{origin:'https://project.supabase.co'}],
 ['mismatched local origin',{origin:'http://127.0.0.1:56423'}],['port collision',{dbPort:56421}],
 ['invalid port',{apiPort:70000,origin:'http://127.0.0.1:70000'}],['nonintegral port',{apiPort:56421.5}],
])test(`commissioning rehearsal refuses ${name}`,()=>assert.throws(()=>assertDisposableSetupTarget({...isolated,...change})));
test('only the rehearsal fictional number range is accepted',()=>{
 for(const p of ['+447700900810','+447700900818','+447700900819'])assert.equal(fictionalSetupPhone(p),true);
 for(const p of ['+260970000000','+447700900820','447700900818','+12025550101',''])assert.equal(fictionalSetupPhone(p),false);
});
