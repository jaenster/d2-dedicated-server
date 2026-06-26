// Realm (BNCS chat + friends) end-to-end tests.
//
//   zig build && node --test tools/realmd-test/realm.e2e.test.mjs
//
// Self-contained: spawns its own realmd (fs store, REALMD_ADMINS=AdminUser) on a
// throwaway data dir, drives it with scripted BNCS clients over the real wire, and
// asserts the channel/user/op/admin/talk/whisper/friend behaviour. Each test uses
// unique account + channel names so they don't interfere.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REALMD = path.join(ROOT, 'zig-out', 'bin', 'realmd');
const HOST = '127.0.0.1';
const BNET_PORT = 6112;

// ── BNCS wire ────────────────────────────────────────────────────────────────
const SID = { AUTH_INFO:0x50, AUTH_CHECK:0x51, LOGON:0x3a, ENTERCHAT:0x0a, JOINCHANNEL:0x0c, CHATCOMMAND:0x0e, CHATEVENT:0x0f, FRIENDSLIST:0x65 };
const EID = { 1:'SHOWUSER', 2:'JOIN', 3:'LEAVE', 4:'WHISPER', 5:'TALK', 7:'CHANNEL', 0x12:'INFO', 0x13:'ERROR' };
const FLAG = { ADMIN:8, OPERATOR:2 };

const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n>>>0,0); return b; };
const cstr = s => Buffer.concat([Buffer.from(s,'latin1'), Buffer.from([0])]);
const pkt = (id, body=Buffer.alloc(0)) => { const b = Buffer.alloc(4+body.length); b[0]=0xff; b[1]=id; b.writeUInt16LE(b.length,2); body.copy(b,4); return b; };
const readCStr = (b,o) => { let e=o; while(e<b.length && b[e]!==0) e++; return { s:b.slice(o,e).toString('latin1'), o:e+1 }; };
const sleep = ms => new Promise(r=>setTimeout(r,ms));

class BncsClient {
  constructor(name){ this.name=name; this.buf=Buffer.alloc(0); this.events=[]; this.friends=null; this.sock=null; this.closed=false; }
  async connect(){
    this.sock = net.connect(BNET_PORT, HOST);
    await once(this.sock, 'connect');
    this.sock.write(Buffer.from([0x01])); // protocol selector
    this.sock.on('data', d => this._onData(d));
    this.sock.on('close', () => { this.closed = true; });
  }
  _send(id, body){ this.sock.write(pkt(id, body)); }
  _onData(d){
    this.buf = Buffer.concat([this.buf, d]);
    while (this.buf.length >= 4) {
      const len = this.buf.readUInt16LE(2);
      if (this.buf.length < len) break;
      const id = this.buf[1], body = this.buf.slice(4, len);
      this.buf = this.buf.slice(len);
      if (id === SID.CHATEVENT) {
        const eid = body.readUInt32LE(0), flags = body.readUInt32LE(4);
        let o = 24; const u = readCStr(body, o); o = u.o; const t = readCStr(body, o);
        this.events.push({ eid: EID[eid]||eid, flags, user: u.s, text: t.s });
      } else if (id === SID.FRIENDSLIST) {
        const cnt = body[0]; let o = 1; const out = [];
        for (let i=0;i<cnt;i++){ const nm=readCStr(body,o); o=nm.o; const status=body[o++], loc=body[o++]; o+=4; const ls=readCStr(body,o); o=ls.o; out.push({ name:nm.s, status, loc }); }
        this.friends = out;
      }
    }
  }
  async handshake(){
    this._send(SID.AUTH_INFO, Buffer.concat([u32(0), Buffer.from('IX86'), Buffer.from('PX2D'), Buffer.alloc(20)]));
    this._send(SID.AUTH_CHECK, Buffer.alloc(8));
    this._send(SID.LOGON, Buffer.concat([u32(1), u32(0), Buffer.alloc(20), cstr(this.name)]));
    this._send(SID.ENTERCHAT, cstr(this.name));
    await sleep(150);
  }
  join(ch){ this._send(SID.JOINCHANNEL, Buffer.concat([u32(0), cstr(ch)])); }
  talk(s){ this._send(SID.CHATCOMMAND, cstr(s)); }
  requestFriends(){ this.friends = null; this._send(SID.FRIENDSLIST, Buffer.alloc(0)); }
  end(){ this.sock?.end(); }
  // Wait until `pred(this)` is truthy (events arrive async), or throw after `ms`.
  async waitFor(pred, ms=2000){
    const t0 = Date.now();
    while (Date.now()-t0 < ms){ if (pred(this)) return; await sleep(25); }
    throw new Error(`timeout waiting (events: ${JSON.stringify(this.events)})`);
  }
}

async function newClient(name){ const c = new BncsClient(name); await c.connect(); await c.handshake(); return c; }

// ── realmd lifecycle ─────────────────────────────────────────────────────────
let realmd;
before(async () => {
  assert.ok(fs.existsSync(REALMD), `realmd not built — run "zig build" first (${REALMD})`);
  const dataDir = fs.mkdtempSync('/tmp/d2gs-realm-e2e-');
  realmd = spawn(REALMD, [], { env: { ...process.env,
    REALMD_BIND: '0.0.0.0', REALMD_DURABLE_STORE: 'fs', REALMD_EPHEMERAL_STORE: 'fs',
    REALMD_DATA_DIR: dataDir, REALMD_ADMINS: 'AdminUser', REALMD_HEALTH_PORT: '18099' },
    stdio: ['ignore', 'pipe', 'pipe'] });
  // Wait until the bnet port accepts connections.
  for (let i=0;i<100;i++){
    try { const s = net.connect(BNET_PORT, HOST); await once(s, 'connect'); s.destroy(); break; }
    catch { await sleep(50); }
    if (i===99) throw new Error('realmd did not start listening');
  }
});
after(() => { realmd?.kill('SIGKILL'); });

// ── tests ────────────────────────────────────────────────────────────────────
test('two users in a channel see each other (SHOWUSER + JOIN)', async () => {
  const a = await newClient('seeA'), b = await newClient('seeB');
  try {
    a.join('see-chan'); await a.waitFor(c => c.events.some(e=>e.eid==='CHANNEL'));
    b.join('see-chan');
    await b.waitFor(c => c.events.some(e=>e.eid==='SHOWUSER' && e.user==='seeA'));
    await a.waitFor(c => c.events.some(e=>e.eid==='JOIN' && e.user==='seeB'));
  } finally { a.end(); b.end(); }
});

test('configured admin account carries ADMIN + OPERATOR flags', async () => {
  const admin = await newClient('AdminUser'), other = await newClient('plainUser');
  try {
    admin.join('flag-chan'); await admin.waitFor(c => c.events.some(e=>e.eid==='CHANNEL'));
    other.join('flag-chan');
    await other.waitFor(c => c.events.some(e=>e.eid==='SHOWUSER' && e.user==='AdminUser'));
    const seen = other.events.find(e=>e.eid==='SHOWUSER' && e.user==='AdminUser');
    assert.ok(seen.flags & FLAG.ADMIN, 'AdminUser has bnet-admin flag (REALMD_ADMINS)');
    assert.ok(seen.flags & FLAG.OPERATOR, 'AdminUser has operator flag');
  } finally { admin.end(); other.end(); }
});

test('first user to join an empty channel becomes operator', async () => {
  const first = await newClient('firstOp'), second = await newClient('secondU');
  try {
    first.join('op-chan'); await first.waitFor(c => c.events.some(e=>e.eid==='CHANNEL'));
    second.join('op-chan');
    await second.waitFor(c => c.events.some(e=>e.eid==='SHOWUSER' && e.user==='firstOp'));
    const seen = second.events.find(e=>e.eid==='SHOWUSER' && e.user==='firstOp');
    assert.ok(seen.flags & FLAG.OPERATOR, 'first joiner is channel operator');
  } finally { first.end(); second.end(); }
});

test('channel talk is broadcast to other members and echoed to self', async () => {
  const a = await newClient('talkA'), b = await newClient('talkB');
  try {
    a.join('talk-chan'); b.join('talk-chan'); await sleep(200);
    a.talk('hello world');
    await b.waitFor(c => c.events.some(e=>e.eid==='TALK' && e.user==='talkA' && e.text==='hello world'));
    await a.waitFor(c => c.events.some(e=>e.eid==='TALK' && e.user==='talkA' && e.text==='hello world'));
  } finally { a.end(); b.end(); }
});

test('whisper delivers to the target; whisper to offline user errors', async () => {
  const a = await newClient('whA'), b = await newClient('whB');
  try {
    a.join('wh-chan'); b.join('wh-chan'); await sleep(200);
    a.talk('/w whB hey there');
    await b.waitFor(c => c.events.some(e=>e.eid==='WHISPER' && e.text==='hey there'));
    a.talk('/w NoSuchUser nope');
    await a.waitFor(c => c.events.some(e=>e.eid==='ERROR'));
  } finally { a.end(); b.end(); }
});

test('friend add / list (shows online) / remove', async () => {
  const a = await newClient('frA'), b = await newClient('frB');
  try {
    a.join('fr-chan'); b.join('fr-chan'); await sleep(200);
    a.talk('/f add frB');
    await a.waitFor(c => c.events.some(e=>e.eid==='INFO' && /Added/.test(e.text)));
    a.requestFriends();
    await a.waitFor(c => c.friends !== null);
    const fr = a.friends.find(f=>f.name==='frB');
    assert.ok(fr, 'friends list contains frB');
    assert.equal(fr.loc, 1, 'frB shows online (presence)');
    a.talk('/f remove frB'); await sleep(150);
    a.requestFriends();
    await a.waitFor(c => c.friends !== null && !c.friends.some(f=>f.name==='frB'));
  } finally { a.end(); b.end(); }
});

test('/away delivers the whisper but tells the sender the target is away', async () => {
  const a = await newClient('awaySend'), b = await newClient('awayRecv');
  try {
    a.join('away-chan'); b.join('away-chan'); await sleep(200);
    b.talk('/away at lunch');
    await b.waitFor(c => c.events.some(e=>e.eid==='INFO' && /Away/.test(e.text)));
    a.talk('/w awayRecv you there?');
    await b.waitFor(c => c.events.some(e=>e.eid==='WHISPER' && e.text==='you there?')); // still delivered
    await a.waitFor(c => c.events.some(e=>e.eid==='INFO' && /is away \(at lunch\)/.test(e.text)));
  } finally { a.end(); b.end(); }
});

test('/dnd suppresses delivery and reports the target as unavailable', async () => {
  const a = await newClient('dndSend'), b = await newClient('dndRecv');
  try {
    a.join('dnd-chan'); b.join('dnd-chan'); await sleep(200);
    b.talk('/dnd do not disturb');
    await b.waitFor(c => c.events.some(e=>e.eid==='INFO' && /Do Not Disturb mode engaged/.test(e.text)));
    a.talk('/w dndRecv ping');
    await a.waitFor(c => c.events.some(e=>e.eid==='INFO' && /is unavailable \(do not disturb\)/.test(e.text)));
    await sleep(200);
    assert.ok(!b.events.some(e=>e.eid==='WHISPER'), 'DND target received no whisper');
  } finally { a.end(); b.end(); }
});

test('/ignore squelches a user\'s talk; /unignore restores it', async () => {
  const a = await newClient('igMe'), b = await newClient('igThem');
  try {
    a.join('ig-chan'); b.join('ig-chan'); await sleep(200);
    a.talk('/ignore igThem');
    await a.waitFor(c => c.events.some(e=>e.eid==='INFO' && /squelched/.test(e.text)));
    b.talk('first message'); await sleep(250);
    assert.ok(!a.events.some(e=>e.eid==='TALK' && e.user==='igThem'), 'squelched talk not seen');
    a.talk('/unignore igThem');
    await a.waitFor(c => c.events.some(e=>e.eid==='INFO' && /no longer squelched/.test(e.text)));
    b.talk('second message');
    await a.waitFor(c => c.events.some(e=>e.eid==='TALK' && e.user==='igThem' && e.text==='second message'));
  } finally { a.end(); b.end(); }
});

test('/whois reports the channel a user is in', async () => {
  const a = await newClient('whoMe'), b = await newClient('whoThem');
  try {
    a.join('whois-here'); b.join('whois-here'); await sleep(200);
    a.talk('/whois whoThem');
    await a.waitFor(c => c.events.some(e=>e.eid==='INFO' && /whoThem is in channel whois-here/.test(e.text)));
    a.talk('/whois NoSuchUser');
    await a.waitFor(c => c.events.some(e=>e.eid==='ERROR' && /not logged on/.test(e.text)));
  } finally { a.end(); b.end(); }
});

test('an operator can /kick a user out of the channel', async () => {
  const op = await newClient('kickOp'), victim = await newClient('kickVic');
  try {
    op.join('kick-chan'); // first joiner -> operator
    await op.waitFor(c => c.events.some(e=>e.eid==='CHANNEL'));
    victim.join('kick-chan');
    await op.waitFor(c => c.events.some(e=>e.eid==='JOIN' && e.user==='kickVic'));
    op.talk('/kick kickVic');
    await op.waitFor(c => c.events.some(e=>e.eid==='INFO' && /kicked/.test(e.text)));
    await op.waitFor(c => c.events.some(e=>e.eid==='LEAVE' && e.user==='kickVic')); // victim's thread announces leave
    await victim.waitFor(c => c.closed, 3000); // socket torn down
    // A non-operator can't kick.
    const plain = await newClient('kickPlain');
    plain.join('kick-chan'); await sleep(200);
    plain.talk('/kick kickOp');
    await plain.waitFor(c => c.events.some(e=>e.eid==='ERROR' && /not a channel operator/.test(e.text)));
    plain.end();
  } finally { op.end(); victim.end(); }
});
