const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../web/app.js'), 'utf8');
function setup() {
  class Element {
    constructor() { this.dataset = {}; this.hidden = true; this.children = []; this.style = {}; this.attributes = {}; this.textContent = ''; this.value = ''; this.classList = { toggle() {}, add() {}, remove() {} }; }
    appendChild(node) { this.children.push(node); return node; }
    replaceChildren() { this.children = []; }
    set innerHTML(value) { this.children = []; }
    setAttribute(name, value) { this.attributes[name] = value; }
    addEventListener() {}
    get options() { return this.children; }
  }
  const elements = new Map();
  const document = { querySelector() { return new Element(); }, addEventListener() {}, createElement: () => new Element(), getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); } };
  const context = vm.createContext({ document, window: { webkit: { messageHandlers: { pocketvm: { postMessage() {} } } } }, location: { search: '' }, URLSearchParams, console });
  vm.runInContext(source, context);
  return { context, get: id => document.getElementById(id), receive: message => context.window.pocketvmReceive(message) };
}
test('model entry exists on first entry and updates without switching conversations', () => {
  const {context, get, receive} = setup();
  vm.runInContext('renderModelChip()', context);
  assert.equal(get('modelChip').hidden, false);
  receive({action:'models',payload:{models:[],loading:true}});
  assert.equal(get('modelName').textContent, '获取模型…');
  receive({action:'models',payload:{models:[{id:'account-model',displayName:'Account model',isDefault:true,supportedReasoningEfforts:[{reasoningEffort:'low'}],defaultReasoningEffort:'low'}]}});
  assert.equal(get('modelName').textContent,'Account model');
  assert.equal(get('modelEffort').textContent,'轻度');
});
test('host quota error is rendered, and pending state ends', () => {
  const {get, receive} = setup();
  receive({action:'promptState',payload:{busy:true}});
  assert.equal(get('replyState').hidden,false);
  receive({action:'messages',payload:[{role:'user',text:'test'},{role:'error',text:'usage_limit_exceeded'}]});
  const all = [...get('messages').children];
  // Inspect rendered content rather than a flag or the implementation source.
  const texts = node => [node.textContent,...node.children.flatMap(texts)];
  assert.ok([...all.flatMap(texts)].includes('usage_limit_exceeded'));
  receive({action:'promptState',payload:{busy:false}});
  assert.equal(get('replyState').hidden,true);
});
test('attachments remain until native host accepts the prompt', () => {
  const {get, receive} = setup();
  receive({action:'attachment',payload:{id:'file-1',name:'photo.jpg'}});
  assert.equal(get('attachmentList').children.length,1);
  receive({action:'promptState',payload:{busy:false}});
  assert.equal(get('attachmentList').children.length,1);
  receive({action:'promptAccepted',payload:{text:'',attachments:['file-1']}});
  assert.equal(get('attachmentList').children.length,0);
});

test('send control becomes interrupt with empty input and steer with content', () => {
  const {context,get,receive}=setup();
  receive({action:'promptState',payload:{busy:true}});
  assert.equal(get('sendBtn').attributes['aria-label'],'中断');
  get('composerInput').value='change direction';
  vm.runInContext('updateSendButton()',context);
  assert.equal(get('sendBtn').attributes['aria-label'],'引导');
  receive({action:'promptState',payload:{busy:false}});
  assert.equal(get('sendBtn').attributes['aria-label'],'发送');
});
test('steer acknowledgement preserves a newer draft and new attachments', () => {
  const {get,receive}=setup();
  receive({action:'attachment',payload:{id:'old',name:'a'}});
  receive({action:'attachment',payload:{id:'new',name:'b'}});
  get('composerInput').value='new draft';
  receive({action:'promptAccepted',payload:{text:'old draft',attachments:['old']}});
  assert.equal(get('composerInput').value,'new draft');
  assert.equal(get('attachmentList').children.length,1);
});
