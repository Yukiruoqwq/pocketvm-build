import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const source = readFileSync(new URL('../guest/pocketvm-app.mjs', import.meta.url), 'utf8').replace('import { spawn } from "node:child_process";', '');
function harness(only='', id='test-thread') {
  const child = new EventEmitter();
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  const sent=[]; const outputs=[]; let expired; let killed=0;
  child.stdin.writable=true;
  child.stdin.write=s=>sent.push(JSON.parse(s)); child.kill=()=>killed++;
  const context = { spawn:()=>child, process:{argv:['node','helper',only,id],stdout:{write:s=>outputs.push(JSON.parse(s))}}, setTimeout:fn=>{expired=fn;return 1}, clearTimeout:()=>{} };
  vm.runInNewContext(source,context);
  const reply=(id,result,error)=>child.stdout.emit('data',Buffer.from(JSON.stringify({id,result,error})+'\n'));
  return {child,sent,outputs,reply,expire:()=>expired(),killed:()=>killed};
}
test('initialization, unique IDs, ignored unrelated responses, and compact report',()=>{
 const h=harness();h.reply(1,{});assert.equal(h.sent[1].method,'initialized');
 const replies={ 'model/list':{data:[{id:'m',displayName:'M',secret:'unused'}]}, 'account/rateLimits/read':{rateLimits:{}}, 'account/read':{account:null}, 'thread/list':{data:[{id:'t',turns:[{large:true}]}]} };
 const ids=[];
 for(let i=0;i<4;i++){const q=h.sent.at(-1);ids.push(q.id);h.reply(999,{data:[]});h.reply(q.id,replies[q.method]);}
 assert.equal(new Set(ids).size,4);assert.equal(h.outputs.length,1);assert.equal(h.outputs[0].initialized,true);assert.deepEqual(h.outputs[0].models,[{id:'m',displayName:'M'}]);assert.deepEqual(h.outputs[0].threads,[{id:'t'}]);assert.equal(h.killed(),1);
});
test('thread/read requests turns and returns history',()=>{
 const h=harness('thread/read');h.reply(1,{});const q=h.sent.at(-1);assert.deepEqual(q.params,{threadId:'test-thread',includeTurns:true});h.reply(q.id,{thread:{id:'test-thread',turns:[]}});assert.deepEqual(h.outputs,[{thread:{id:'test-thread',turns:[]}}]);
});
test('initialization rejection does not report readiness',()=>{const h=harness();h.reply(1,null,{message:'rejected'});assert.deepEqual(h.outputs,[{error:'rejected'}]);});
test('missing executable produces explicit error',()=>{const h=harness();h.child.emit('error',new Error('ENOENT'));assert.deepEqual(h.outputs,[{error:'ENOENT'}]);});
test('broken stdin is handled',()=>{const h=harness();h.child.stdin.emit('error',new Error('EPIPE'));assert.deepEqual(h.outputs,[{error:'EPIPE'}]);});
test('timeout produces error instead of empty success',()=>{const h=harness();h.expire();assert.match(h.outputs[0].error,/超时/);assert.equal(h.outputs[0].initialized,undefined);});
test('premature process close is explicit',()=>{const h=harness();h.child.emit('close',1);assert.match(h.outputs[0].error,/提前退出/);});
test('split JSON chunks are reassembled',()=>{const h=harness('account/read');h.child.stdout.emit('data',Buffer.from('{"id":1,"res'));h.child.stdout.emit('data',Buffer.from('ult":{}}\n'));h.reply(h.sent.at(-1).id,{account:{type:'chatgpt'}});assert.deepEqual(h.outputs,[{account:{type:'chatgpt'}}]);});
test('method errors remain visible',()=>{const h=harness('thread/read');h.reply(1,{});h.reply(h.sent.at(-1).id,null,{message:'missing thread'});assert.deepEqual(h.outputs,[{error:'missing thread'}]);});
