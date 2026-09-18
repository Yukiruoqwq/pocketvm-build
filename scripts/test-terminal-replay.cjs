const test = require('node:test');
const assert = require('node:assert/strict');
const { TerminalReplay } = require('../web/terminal-replay.js');
test('history replies are muted through async parsing; live replies resume', () => {
  const replay = new TerminalReplay(), queue = [], sent = [];
  const terminal = {options:{disableStdin:false}, write(data, done){queue.push({data,done});}};
  replay.write(terminal, ['boot query 1', 'boot query 2']);
  terminal.write('live query');
  assert.equal(terminal.options.disableStdin,true);
  for (const {data,done} of queue) {
    if (data !== '\x18' && !replay.active) sent.push(data);
    done?.();
  }
  assert.deepEqual(sent,['live query']);
  assert.equal(terminal.options.disableStdin,false);
  assert.equal(replay.active,false);
});
test('empty replay does not disable user input', () => {
  const replay = new TerminalReplay();
  replay.write({options:{disableStdin:false}},[]);
  assert.equal(replay.active,false);
});
