import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Relay } from '../guest/pocketvm-relay.mjs';
function fixture() {
 const child = new EventEmitter(); child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.stdin=new EventEmitter();
 const sent=[];child.stdin.write=data=>sent.push(JSON.parse(data));child.kill=()=>child.emit('exit',1,null);
 const relay=new Relay(child,'12345678-1234-1234-1234-123456789abc');
 const emit=message=>child.stdout.emit('data',Buffer.from(JSON.stringify(message)+'\n'));
 return {child,relay,sent,emit,init(){emit({id:'initialize',result:{}})}};
}
test('initialization is structured and does not query account or exit',()=>{const f=fixture();assert.equal(f.relay.ready,false);f.init();assert.equal(f.relay.ready,true);assert.deepEqual(f.sent.map(x=>x.method),['initialize','initialized']);});
test('process exit revokes readiness',()=>{const f=fixture();f.init();f.child.emit('exit',2,null);assert.equal(f.relay.packet().ready,false);assert.equal(f.relay.failure.kind,'exit');});
test('login response and streaming notifications survive HTTP retry until acknowledged',()=>{const f=fixture();f.init();f.emit({id:'login',result:{type:'chatgptDeviceCode',userCode:'any-format',verificationUrl:'https://auth.openai.com/device'}});f.emit({method:'item/agentMessage/delta',params:{delta:'你好'}});assert.equal(f.relay.packet().events.length,2);assert.deepEqual(f.relay.packet(),f.relay.packet());f.relay.accept({epoch:f.relay.epoch,ack:1,requests:[]});assert.equal(f.relay.packet().events.length,1);});
test('repeated transport request never executes a turn twice',()=>{const f=fixture();f.init();const r={epoch:f.relay.epoch,ack:0,requests:[{id:'turn',method:'turn/start',params:{}}]};f.relay.accept(r);f.relay.accept(r);assert.equal(f.sent.filter(x=>x.id==='turn').length,1);});
test('previous process epoch commands are rejected',()=>{const f=fixture();f.init();f.relay.accept({epoch:'old',ack:99,requests:[{id:'old',method:'turn/start'}]});assert.equal(f.sent.length,2);});
test('spawn failure is a process event not stderr text',()=>{const f=fixture();f.child.emit('error',{code:'ENOENT'});assert.equal(f.relay.failure.kind,'spawn');assert.equal(f.relay.ready,false);});
test('malformed protocol fails closed',()=>{const f=fixture();f.init();f.child.stdout.emit('data',Buffer.from('logged in\n'));assert.equal(f.relay.ready,false);});
test('split JSON is reassembled',()=>{const f=fixture();f.child.stdout.emit('data',Buffer.from('{"id":"init'));f.child.stdout.emit('data',Buffer.from('ialize","result":{}}\n'));assert.equal(f.relay.ready,true);});
test('initialize errors never grant readiness',()=>{const f=fixture();f.emit({id:'initialize',error:{code:-32600,message:'error'}});assert.equal(f.relay.ready,false);});
test('server requests retain their typed ids and params',()=>{const f=fixture();f.init();f.emit({id:42,method:'item/commandExecution/requestApproval',params:{}});assert.equal(f.relay.packet().events[0].message.id,42);});
