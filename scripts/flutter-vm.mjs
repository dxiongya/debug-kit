#!/usr/bin/env node
// flutter-vm.mjs — minimal zero-dep Dart VM Service client for debug-kit (Flutter).
//
// The Dart VM Service is the *semantic* way to inspect/drive a Flutter app (its UI is a
// custom canvas with no native AX tree). This speaks the VM Service JSON-RPC over a raw
// WebSocket (no deps) and exposes:
//   node flutter-vm.mjs <vmServiceHttpUrl> widgets            # dump the widget tree (collection)
//   node flutter-vm.mjs <vmServiceHttpUrl> call <method> [jsonParams]   # any VM RPC / service ext
//
// In params, the token $ISOLATE is replaced with the main isolate id.
// <vmServiceHttpUrl> is the http://127.0.0.1:PORT/TOKEN/ line Flutter prints (and that
// flutter-ctl captures); the ws endpoint is derived from it.

import net from 'node:net';
import crypto from 'node:crypto';

const url = process.argv[2] || '';
const sub = process.argv[3] || 'widgets';
const m = url.match(/^http:\/\/([^:/]+):(\d+)(\/.*)?$/);
if (!m) { console.error('usage: flutter-vm.mjs <http://host:port/token/> <widgets|call> ...'); process.exit(2); }
const host = m[1], port = +m[2];
const path = ((m[3] || '/').replace(/\/*$/, '/')) + 'ws';

const sock = net.connect(port, host);
let up = false, buf = Buffer.alloc(0), frag = Buffer.alloc(0);
const pend = new Map(); let nid = 0;

function send(o) {
  const p = Buffer.from(JSON.stringify(o)); const len = p.length; let h;
  if (len < 126) h = Buffer.from([0x81, 0x80 | len]);
  else if (len < 65536) { h = Buffer.alloc(4); h[0] = 0x81; h[1] = 0x80 | 126; h.writeUInt16BE(len, 2); }
  else { h = Buffer.alloc(10); h[0] = 0x81; h[1] = 0x80 | 127; h.writeUInt32BE(0, 2); h.writeUInt32BE(len, 6); }
  const mk = crypto.randomBytes(4), mp = Buffer.alloc(len);
  for (let i = 0; i < len; i++) mp[i] = p[i] ^ mk[i % 4];
  sock.write(Buffer.concat([h, mk, mp]));
}
function rpc(method, params = {}) {
  const id = ++nid;
  return new Promise((res, rej) => {
    pend.set(id, { res, rej });
    send({ jsonrpc: '2.0', id, method, params });
    setTimeout(() => { if (pend.has(id)) { pend.delete(id); rej(new Error('timeout: ' + method)); } }, 10000);
  });
}
function parseFrames() {
  while (buf.length >= 2) {
    const b1 = buf[1] & 0x7f; let off = 2, len = b1;
    if (b1 === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
    else if (b1 === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
    if (buf.length < off + len) return;
    const pl = buf.slice(off, off + len); const fin = buf[0] & 0x80; buf = buf.slice(off + len);
    frag = Buffer.concat([frag, pl]); if (!fin) continue;
    const txt = frag.toString(); frag = Buffer.alloc(0);
    try {
      const msg = JSON.parse(txt);
      if (msg.id && pend.has(msg.id)) {
        const { res, rej } = pend.get(msg.id); pend.delete(msg.id);
        msg.error ? rej(new Error(JSON.stringify(msg.error))) : res(msg.result);
      }
    } catch (e) { /* ignore non-JSON / stream events */ }
  }
}
sock.on('data', d => {
  if (!up) { buf = Buffer.concat([buf, d]); const i = buf.indexOf('\r\n\r\n'); if (i >= 0) { up = true; buf = buf.slice(i + 4); parseFrames(); } return; }
  buf = Buffer.concat([buf, d]); parseFrames();
});
sock.on('connect', () => {
  const k = crypto.randomBytes(16).toString('base64');
  sock.write(`GET ${path} HTTP/1.1\r\nHost: ${host}:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${k}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
});
sock.on('error', e => { console.error('VM connect error:', e.message); process.exit(1); });

function printTree(node, depth, count) {
  if (!node || depth > 40 || count.n > 400) return;
  const desc = node.description || node.name || node.type || '?';
  const extra = node.textPreview ? ` "${String(node.textPreview).slice(0, 40)}"` : '';
  console.log('  '.repeat(depth) + desc + extra);
  count.n++;
  const kids = node.children || [];
  for (const c of kids) printTree(c, depth + 1, count);
}

async function main() {
  await new Promise(r => { const t = setInterval(() => { if (up) { clearInterval(t); r(); } }, 20); });
  const vm = await rpc('getVM');
  const iso = vm.isolates && vm.isolates[0] && vm.isolates[0].id;
  if (!iso) { console.error('no isolate'); process.exit(1); }

  if (sub === 'widgets') {
    const r = await rpc('ext.flutter.inspector.getRootWidgetTree',
      { isolateId: iso, groupName: 'debug-kit', isSummaryTree: true, withPreviews: true });
    const tree = r && (r.result || r);
    console.log('=== Flutter widget tree (VM Service) ===');
    printTree(tree, 0, { n: 0 });
  } else if (sub === 'call') {
    const method = process.argv[4];
    let params = {};
    if (process.argv[5]) params = JSON.parse(process.argv[5].replace(/\$ISOLATE/g, iso));
    if (params.isolateId === undefined && /^(s\d|ext\.|_)/.test(method)) params.isolateId = iso;
    const res = await rpc(method, params);
    console.log(JSON.stringify(res, null, 2));
  } else {
    console.error('unknown subcommand: ' + sub); process.exit(2);
  }
  sock.end(); process.exit(0);
}
main().catch(e => { console.error('FATAL', e.message); process.exit(1); });
