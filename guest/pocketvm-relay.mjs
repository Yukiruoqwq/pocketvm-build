import { StringDecoder } from 'node:string_decoder';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

// One child for the service lifetime. stdout is exclusively JSON-RPC;
// stderr is diagnostic output and never drives application state.
export class Relay {
  constructor(child, epoch = randomUUID()) {
    this.child = child; this.epoch = epoch; this.ready = false;
    this.seq = 0; this.events = []; this.received = new Set(); this.buffer = '';
    this.failure = null; this.decoder = new StringDecoder('utf8');
    child.stdout.on('data', chunk => this.read(chunk));
    child.stderr.on('data', chunk => process.stderr.write(chunk));
    child.on('error', error => this.fail('spawn', error.code ?? 'UNKNOWN'));
    child.on('exit', (code, signal) => this.fail('exit', { code, signal }));
    child.stdin.on('error', error => this.fail('stdin', error.code ?? 'UNKNOWN'));
    this.write({ id: 'initialize', method: 'initialize', params: { clientInfo: { name: 'pocketvm', version: '1.0' } } });
  }
  write(message) { this.child.stdin.write(JSON.stringify(message) + '\n'); }
  fail(kind, detail) { this.ready = false; this.failure = { kind, detail }; }
  read(chunk) {
    this.buffer += this.decoder.write(chunk);
    if (this.buffer.length > 8 * 1024 * 1024) { this.fail('frame_limit', null); this.child.kill(); return; }
    for (;;) {
      const end = this.buffer.indexOf('\n'); if (end < 0) break;
      const line = this.buffer.slice(0, end); this.buffer = this.buffer.slice(end + 1);
      let message;
      try { message = JSON.parse(line); } catch { this.fail('invalid_json', null); this.child.kill(); return; }
      if (message.id === 'initialize') {
        if (message.error) { this.fail('initialize', message.error); continue; }
        this.write({ method: 'initialized', params: {} }); this.ready = true;
      } else {
        if (this.events.length >= 4096) { this.fail('event_limit', null); this.child.kill(); return; }
        this.events.push({ seq: ++this.seq, message });
      }
    }
  }
  packet() { return { version: 1, epoch: this.epoch, ready: this.ready, failure: this.failure, received: [...this.received].slice(-128), events: this.events.slice(0, 128) }; }
  accept(reply) {
    if (reply.epoch !== this.epoch) return;
    this.events = this.events.filter(event => event.seq > reply.ack);
    for (const message of reply.requests ?? []) {
      if (!this.ready || this.received.has(message.id)) continue;
      this.received.add(message.id); this.write(message);
    }
  }
}

async function main() {
  const child = spawn('codex', ['app-server'], { stdio: ['pipe', 'pipe', 'pipe'], cwd: '/home/codex' });
  const relay = new Relay(child);
  const timer = setTimeout(() => { if (!relay.ready) { relay.fail('initialize_timeout', null); child.kill(); } }, 60000);
  timer.unref();
  process.on('SIGTERM', () => { child.kill(); process.exit(0); });
  const base = process.env.POCKETVM_BASE ?? 'http://10.0.2.2:8474';
  let lastContact = Date.now();
  for (;;) {
    try {
      const response = await fetch(base + '/rpc', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(relay.packet()), signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error('transport');
      relay.accept(await response.json()); lastContact = Date.now();
      if (relay.failure) { child.kill(); process.exit(1); }
    } catch { /* Unacknowledged events stay queued. Never replay a mutation. */ }
    if (Date.now() - lastContact > 20000) { child.kill(); process.exit(1); }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
