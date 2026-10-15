/* No external dependencies. Run: node tests/test_submission_fix.js */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');

const errorFn=html.match(/  function submissionFailureMessage\(stage, err\)\{[\s\S]*?\n  \}\n\n  async function collectDevice/);
assert.ok(errorFn, 'diagnostic function must be present');
const ctx={t:()=> 'Something went wrong saving your response. Please try again.'};
vm.createContext(ctx);
vm.runInContext(errorFn[0].replace(/\n\n  async function collectDevice$/,'')+'\nthis.report=submissionFailureMessage;',ctx);
const cases = [
  ['PGRST202','A required database function is missing'],
  ['42P01','A required database table is missing'],
  ['42703','The database schema is older'],
  ['42501','Database permissions blocked'],
  ['23505','unique value'],
  ['23514','validation rule'],
];
for(const [code,needle] of cases){
 const actual=ctx.report('claim-employee-id',{code,message:'failed'});
 assert.ok(actual.includes(needle), `${code} -> expected ${needle}, got: ${actual}`);
 assert.ok(actual.includes('code: '+code));
}
assert.ok(ctx.report('save-submission',{message:'Failed to fetch'}).includes('verify whether a record was already saved'));
assert.ok(ctx.report('save-submission',{message:'Failed to fetch'}).includes('Do not resubmit'));
assert.ok(ctx.report('save-submission',{status:413}).includes('too large'));

const upsertMatch=html.match(/  async function upsertDevice\(d, employeeName, employeeId, employeeEmail\)\{[\s\S]*?\n  \}\n\n  document.getElementById\('intakeForm'\)/);
assert.ok(upsertMatch,'inventory sync function must be present');
const fn=upsertMatch[0].replace(/\n\n  document.getElementById\('intakeForm'\)$/,'');
async function exerciseInventory(failStage){
  const calls=[];
  const sb={from:(table)=>({
    upsert: async()=>{calls.push(table+'.upsert');return {error:failStage==='upsert'?{code:'42501'}:null};},
    insert: async()=>{calls.push(table+'.insert');return {error:failStage==='history'?{code:'23505'}:null};}
  })};
  const ctx={sb,console:{error:(...msg)=>calls.push('error')}};
  vm.createContext(ctx);
  vm.runInContext(fn+'\nthis.testUpsert=upsertDevice;',ctx);
  return {ok:await ctx.testUpsert({imei1:'123456789012345',brand:'Test'},'Tester','EMP','test@example.org'),calls};
}
(async()=>{
  assert.equal((await exerciseInventory()).ok,true);
  assert.equal((await exerciseInventory('upsert')).ok,false);
  assert.equal((await exerciseInventory('history')).ok,false);
  assert.match(html,/if\(!inserted \|\| inserted.length!==1/);
  assert.match(html,/aria-live="polite"/);
  assert.match(html,/Form build: 2026-10-15.1/);
  console.log('PASS: diagnostic error mapping (9 checks), inventory error handling (3 checks), save confirmation, accessibility, build marker');
})().catch(e=>{console.error(e);process.exitCode=1;});
