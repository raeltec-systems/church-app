#!/usr/bin/env node
// Normal staff UI against real LOCAL Edge/Auth/PostgREST. No mocked application
// data. Requires an explicit compiled web root and externally installed Playwright.
// Synthetic identities only; stops its own servers and resets its empty local DB.
import {spawn,spawnSync} from 'node:child_process';
import {randomBytes,randomUUID,createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {createReadStream,existsSync,readFileSync,writeFileSync,rmSync,mkdirSync} from 'node:fs';
import {join,resolve,dirname,extname,sep} from 'node:path';
import {tmpdir} from 'node:os';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {ROOT,localTarget,localStatus,localContainer,assertContainer} from '../auth-harness/local-target.mjs';
import {assertDisposableSetupTarget} from './admin-onboarding.mjs';
import {privateDirectory,writePrivateJson,readPrivateJson} from '../ops/admin-onboarding-files.mjs';
import {startRun,sleep,EPOCH_WAIT_MS} from './harness.mjs';
const q=s=>`'${String(s).replaceAll("'","''")}'`;
async function main(){
 const arg=n=>process.argv[process.argv.indexOf(n)+1];
 if(!process.argv.includes('--web-root')||!process.argv.includes('--evidence'))throw new Error('explicit_web_root_and_evidence_required');
 const web=resolve(arg('--web-root'));if(!existsSync(join(web,'flutter_bootstrap.js')))throw new Error('compiled_staff_required');
 const target=localTarget();assertDisposableSetupTarget(target);let db=localContainer('db',target);localContainer('kong',target);
 const env=localStatus();const {check,finish}=startRun();const out=dirname(resolve(arg('--evidence')));mkdirSync(out,{recursive:true});
 const sql=text=>{const p=spawnSync('docker',['exec','-i',db,'psql','-U','postgres','-X','-qtA','-v','ON_ERROR_STOP=1'],{input:text,encoding:'utf8',maxBuffer:4<<20});if(p.status!==0)throw new Error('fixture_sql_failed');return p.stdout.trim();};
 if(sql('select count(*) from auth.users;')!=='0'||sql('select count(*) from app.identity_members;')!=='0')throw new Error('empty_dedicated_database_required');
 if(spawnSync('docker',['container','inspect',`supabase_edge_runtime_${target.project}`],{stdio:'pipe'}).status===0)throw new Error('existing_edge_runtime_refused');
 const {chromium}=createRequire(import.meta.url)(process.env.CHURCH_PLAYWRIGHT_MODULE||'playwright');
 const priv=privateDirectory(join(tmpdir(),`church-admin-browser-${randomUUID()}`));
 const pw=`Synthetic-${randomBytes(18).toString('base64url')}`;const system=`sysc_local_${randomBytes(32).toString('base64url')}`;
 const secrets=[pw,system,env.SECRET_KEY,env.SERVICE_ROLE_KEY];const scrub=s=>secrets.filter(Boolean).reduce((t,x)=>t.split(x).join('[redacted]'),String(s));
 let phase='configuration',serve,edge,browser,page,server,mutated=false;const errors=[];let backendCalls=0;
 const must=(name,ok,detail={})=>{check(name,ok,detail);if(!ok)throw new Error('browser_assertion_failed');};
 const button=(name)=>page.getByRole('button',{name,exact:true});
 const label=(text)=>page.getByLabel(text,{exact:false});
 const enter=async(name,value)=>{const field=label(name);await field.click();await page.waitForTimeout(120);await page.keyboard.press('Control+A');await page.keyboard.insertText(value);await page.waitForTimeout(180);};
 const text=(value)=>page.getByText(value,{exact:true});
 const shown=async locator=>{await locator.first().waitFor({state:'visible',timeout:30000});return true;};
 const snap=async name=>{await page.screenshot({path:join(out,`${name}.png`),fullPage:true});};
 const api=async(path,body,admin=false)=>{const h={apikey:admin?env.SECRET_KEY:env.PUBLISHABLE_KEY,'content-type':'application/json'};if(admin)h.authorization=`Bearer ${env.SERVICE_ROLE_KEY}`;const res=await fetch(target.origin+path,{method:'POST',headers:h,body:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(20000)});return {status:res.status,body:await res.json()};};
 try{
  sql("select app.platform_set_environment('local','SYNTHETIC normal UI walkthrough');");mutated=true;
  const principal=sql("select app.sys_create_principal('browser-first-admin','identity_admin_onboarding','israel');");
  sql(`select app.sys_register_credential(${q(principal)}::uuid,${q(createHash('sha256').update(system).digest('hex'))},'synthetic browser',interval '1 hour','israel');`);
  const state=privateDirectory(join(priv,'invitation'));const request=join(state,'request.json');
  writePrivateJson(request,{phone_username:'+447700900818',existing_account:null,synthetic:true,identity_check:'in_person',case_reference:'SETUP-browser-local'});
  const issued=spawnSync(process.execPath,[join(ROOT,'tools/ops/admin-onboarding.mjs'),'issue','--env','local','--confirm-target',target.project,'--state-dir',state,'--request-file',request],{cwd:ROOT,encoding:'utf8',timeout:30000});
  if(issued.status!==0)throw new Error('operator_issue_failed');const invitation=readPrivateJson(join(state,'invitation.json')).invitation;secrets.push(invitation);
  writeFileSync(join(priv,'functions.env'),`IDENTITY_ADMIN_SETUP_SYSTEM_CREDENTIAL=${system}\nIDENTITY_ADMIN_SETUP_ENVIRONMENT=local\nIDENTITY_ADMIN_SETUP_ALLOWED_ORIGINS=http://127.0.0.1:56480\n`,{mode:0o600});
  serve=spawn(process.execPath,[join(ROOT,'node_modules/supabase/dist/supabase.js'),'functions','serve','--env-file',join(priv,'functions.env')],{cwd:ROOT,stdio:['ignore','pipe','pipe'],windowsHide:true});
  // Drain but never persist service startup output (it can contain config).
  serve.stdout.on('data',()=>{});serve.stderr.on('data',()=>{});
  let ready=false;for(let i=0;i<60;i++){try{const p=await api('/functions/v1/identity-admin-onboarding',{});if(p.status===400){ready=true;break;}}catch{}await sleep(1000);}
  if(!ready)throw new Error('edge_not_ready');edge=localContainer('edge_runtime',target);
  server=createServer((req,res)=>{let p;try{p=resolve(web,'.'+decodeURIComponent(new URL(req.url,'http://localhost').pathname));}catch{res.writeHead(400).end();return;}
   if(!p.startsWith(web+sep)&&p!==web){res.writeHead(403).end();return;}if(p===web)p=join(web,'index.html');
   if(!existsSync(p)){res.writeHead(404).end();return;}
   const types={'.html':'text/html','.js':'text/javascript','.wasm':'application/wasm','.json':'application/json','.png':'image/png','.woff2':'font/woff2'};
   res.writeHead(200,{'content-type':types[extname(p)]||'application/octet-stream','cache-control':'no-store'});createReadStream(p).pipe(res);
  });await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(56480,'127.0.0.1',resolve);});
  browser=await chromium.launch({headless:true,executablePath:process.env.CHURCH_TEST_CHROME||'C:/Program Files/Google/Chrome/Application/chrome.exe'});
  const context=await browser.newContext({viewport:{width:1440,height:1080}});page=await context.newPage();page.setDefaultTimeout(20000);
  page.on('pageerror',e=>errors.push(scrub(e.message)));page.on('request',r=>{if(r.url().startsWith(target.origin))backendCalls++;});
  phase='guest-navigation';await page.goto('http://127.0.0.1:56480',{waitUntil:'domcontentloaded'});await shown(page.locator('flutter-view'));
  await button('Have an owner setup invitation?').click();
  must('landing-enters-first-admin-setup',await shown(text('First Admin setup')));
  phase='invitation';await enter('Setup invitation',invitation);await enter('Phone username','+447700900818');await button('Check invitation').click();
  await shown(text('Choose your own sign-in details'));must('browser-loads-real-account-bound-invitation',true);
  phase='complete';await enter('Full name','SYNTHETIC Naomi Phiri');await enter('New password',pw);await enter('Confirm password',pw);
  await page.getByRole('checkbox',{name:'I have read the privacy notice and agree to this setup.'}).click();await page.waitForTimeout(200);await button('Complete Admin setup').click();
  must('normal-wizard-creates-first-admin',await shown(page.getByRole('heading',{name:/^Setup complete /})));
  must('setup-authority-stays-out-of-location',!page.url().includes(invitation)&&!page.url().includes(pw));
  const competing=await api('/functions/v1/identity-admin-onboarding',{version:1,action:'complete',
    invitation,phone_username:'+447700900818',request_id:randomUUID(),full_name:'SYNTHETIC Naomi Phiri',
    password:pw,privacy_notice_version:'synthetic-admin-setup-1',privacy_accepted:true});
  must('supplemental-http-competing-request-refused',competing.status===200&&competing.body.outcome==='refused');
  await sleep(EPOCH_WAIT_MS);await button('Go to sign in').click();
  phase='sign-in';await enter('Phone number (your username)','+447700900818');await enter('Password',pw);await button('Sign in').click();
  await shown(page.getByRole('heading',{name:'Overview',exact:true}));await button('People section People').click();await page.getByRole('tab',{name:'Users & access',exact:true}).click();
  phase='management-directory';must('normal-signin-opens-current-admin-directory',await shown(page.getByRole('button',{name:/^SYNTHETIC Naomi Phiri, Approved/})));await snap('users-directory-desktop');
  phase='management-add-member';await button('Add member record').click();await enter('Full name','SYNTHETIC Grace Banda');
  await page.getByRole('radio',{name:'Agreed in person',exact:true}).click();await page.waitForTimeout(200);await button('Add member record').last().click();
  await shown(page.getByRole('button',{name:/^SYNTHETIC Grace Banda,/}));must('normal-form-creates-no-login-member',sql("select count(*) from app.identity_members where display_name='SYNTHETIC Grace Banda';")==='1');
  await page.getByRole('tab',{name:'Users & access',exact:true}).click();await page.getByRole('button',{name:/^SYNTHETIC Grace Banda, Approved/}).click();
  phase='management-profile';await button('Edit name & contacts').click();await enter('Full name','SYNTHETIC Grace Phiri');
  await button('Add contact route').click();await enter('Contact number with country code','+447700900817');
  await button('How were these details agreed?').click();await page.getByRole('menuitem',{name:'Agreed in person',exact:true}).click();await button('Save changes').click();
  await shown(page.getByRole('banner',{name:/^Saved /}));must('profile-editor-persists-real-name-and-contact',sql("select count(*) from app.identity_members m join app.identity_contact_routes c using(member_id) where m.display_name='SYNTHETIC Grace Phiri' and c.value='+447700900817' and c.ended_at is null;")==='1');
  await page.reload({waitUntil:'domcontentloaded'});await shown(button('Edit name & contacts'));must('reload-preserves-selected-person-and-saved-profile',await shown(page.getByRole('button',{name:/^SYNTHETIC Grace Phiri, Approved/})));
  await button('Load activity').click();must('activity-shows-real-audited-profile-change',await shown(page.getByRole('banner',{name:/SYNTHETIC Grace Phiri.*profile corrected/})));await snap('users-person-desktop');
  phase='management-support';await button('Account recovery').click();must('support-keeps-selected-person-context',await shown(text('Selected: SYNTHETIC Grace Phiri')));
  await button('Back to person').click();must('support-returns-to-same-person',await shown(button('Edit name & contacts')));
  phase='management-failure-recovery';await page.route('**/rest/v1/rpc/identity_admin_users',route=>route.abort('failed'));await page.getByRole('button',{name:'Reload',exact:true}).click();
  must('network-failure-is-not-empty-directory',await shown(page.getByRole('banner',{name:/^Could not load people /}))&&await text('No people match these filters.').count()===0);
  await page.unroute('**/rest/v1/rpc/identity_admin_users');await button('Try again').first().click();must('directory-recovers-after-connection-restored',await shown(page.getByRole('button',{name:/^SYNTHETIC Grace Phiri, Approved/})));
  phase='management-narrow';await page.setViewportSize({width:390,height:844});await page.reload({waitUntil:'domcontentloaded'});await shown(page.getByRole('button',{name:/^SYNTHETIC Grace Phiri, Approved/}));await snap('users-person-mobile-width');
  must('narrow-layout-has-no-document-horizontal-overflow',await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
  must('browser-has-no-unhandled-errors',errors.length===0,{errors:errors.length,backend_requests:backendCalls});
 }catch(error){check('browser-workflow-completed',false,{phase,error_name:error?.name||'Error'});
  writeFileSync(join(out,'browser-error-details.json'),JSON.stringify({phase,name:error?.name,message:scrub(error?.message)},null,2));
  if(page){try{writeFileSync(join(out,'browser-failure-state.txt'),scrub(await page.locator('body').ariaSnapshot()));}catch{}
   if(phase.startsWith('management'))try{await snap('browser-failure');}catch{}}
  throw error;
 }finally{
  if(browser)await browser.close();if(server)await new Promise(resolve=>server.close(resolve));
  if(serve&&serve.exitCode===null){if(process.platform==='win32')spawnSync('taskkill',['/PID',String(serve.pid),'/T','/F'],{stdio:'pipe'});else serve.kill('SIGTERM');await sleep(1000);}
  if(edge)spawnSync('docker',['rm','-f',edge],{stdio:'pipe'});rmSync(priv,{recursive:true,force:true});
  if(mutated){const reset=spawnSync(process.execPath,[join(ROOT,'node_modules/supabase/dist/supabase.js'),'db','reset','--local'],{cwd:ROOT,encoding:'utf8',maxBuffer:32<<20,timeout:180000});
   if(reset.status===0){const info=JSON.parse(spawnSync('docker',['inspect',`supabase_db_${target.project}`],{encoding:'utf8'}).stdout);db=assertContainer(info[0],target,'db');}
   check('browser-disposable-fixtures-cleaned',reset.status===0&&sql('select count(*) from auth.users;')==='0'&&sql('select count(*) from app.identity_members;')==='0',{reset_exit:reset.status});}
  writeFileSync(join(out,'browser-errors.json'),JSON.stringify(errors,null,2));finish();
 }
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(error=>{const reason=/^[a-z_]+$/.test(error?.message??'')?error.message:'unexpected_failure';console.error(`Browser walkthrough failed: ${reason}; inspect redacted state/evidence.`);process.exitCode=1;});
