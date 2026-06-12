#!/usr/bin/env node
/**
 * Minimal CDP (Chrome DevTools Protocol) client for Electron debugging.
 * No external dependencies - uses Node.js built-in modules only.
 *
 * Usage:
 *   node cdp-client.mjs launch [dev|build]    - Launch Electron app with debugging
 *   node cdp-client.mjs stop                  - Stop the running Electron app
 *   node cdp-client.mjs targets               - List debug targets
 *   node cdp-client.mjs screenshot [path]      - Capture screenshot
 *   node cdp-client.mjs eval "expression"      - Evaluate JS in renderer
 *   node cdp-client.mjs console [seconds]      - Monitor console for N seconds (main+renderer)
 *   node cdp-client.mjs health                 - Basic health check
 *   node cdp-client.mjs dom                    - Get page DOM snapshot
 *   node cdp-client.mjs network [seconds]      - Monitor network requests
 *   node cdp-client.mjs perf                   - Performance metrics
 *   node cdp-client.mjs click "selector"       - Click an element
 *   node cdp-client.mjs type "selector" "text" - Type text into an element
 *   node cdp-client.mjs key "KeyName"          - Send a keyboard shortcut
 *   node cdp-client.mjs wait "selector" [ms]   - Wait for element to appear
 *   node cdp-client.mjs a11y                   - Accessibility audit
 *   node cdp-client.mjs processes              - Process info & resource usage
 */

import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { URL } from 'node:url';
import { execSync, spawn } from 'node:child_process';
import path from 'node:path';

import net from 'node:net';

let PORT = process.env.CDP_PORT || 9222;
const HOST = process.env.CDP_HOST || 'localhost';
const STATE_FILE = '/tmp/.electron-debug-state.json';

// Virtual pointer: glide the resident software-cursor overlay to an absolute SCREEN point
// (so a human sees where a click lands) without moving the real cursor. Fire-and-forget.
const SCRIPT_DIR = path.dirname(new URL(import.meta.url).pathname);
function showPointer(action, sx, sy) {
  if (process.env.DK_POINTER === 'off' || process.env.MAC_POINTER === 'off') return;
  if (process.platform !== 'darwin') return;
  if (!Number.isFinite(sx) || !Number.isFinite(sy)) return;
  try {
    execSync(`bash ${JSON.stringify(path.join(SCRIPT_DIR, 'dk-pointer.sh'))} ${action} ${Math.round(sx)} ${Math.round(sy)}`,
             { timeout: 8000, stdio: 'ignore' });
  } catch { /* pointer is best-effort */ }
}

// Find a free port starting from `start`
function findFreePort(start = 9222) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.listen(start, '127.0.0.1', () => {
      server.close(() => resolve(start));
    });
    server.on('error', () => resolve(findFreePort(start + 1)));
  });
}

// --- State management ---
function saveState(state) {
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return null;
  }
}

function clearState() {
  try { fs.unlinkSync(STATE_FILE); } catch {}
}

// --- Minimal WebSocket client (no dependencies) ---
class MiniWebSocket {
  constructor(url) {
    this._url = new URL(url);
    this._listeners = {};
    this._socket = null;
    this._buffer = Buffer.alloc(0);
  }

  on(event, cb) {
    if (!this._listeners[event]) this._listeners[event] = [];
    this._listeners[event].push(cb);
    return this;
  }

  off(event, cb) {
    if (this._listeners[event]) {
      this._listeners[event] = this._listeners[event].filter(fn => fn !== cb);
    }
    return this;
  }

  _emit(event, ...args) {
    if (this._listeners[event]) {
      for (const cb of this._listeners[event]) cb(...args);
    }
  }

  connect() {
    return new Promise((resolve, reject) => {
      const key = crypto.randomBytes(16).toString('base64');
      const options = {
        hostname: this._url.hostname,
        port: this._url.port || 80,
        path: this._url.pathname + this._url.search,
        headers: {
          'Upgrade': 'websocket',
          'Connection': 'Upgrade',
          'Sec-WebSocket-Key': key,
          'Sec-WebSocket-Version': '13',
        },
      };

      const req = http.request(options);
      req.on('upgrade', (res, socket) => {
        this._socket = socket;
        socket.on('data', (data) => this._onData(data));
        socket.on('close', () => this._emit('close'));
        socket.on('error', (err) => this._emit('error', err));
        this._emit('open');
        resolve(this);
      });
      req.on('error', reject);
      req.end();
    });
  }

  send(data) {
    if (!this._socket) throw new Error('Not connected');
    const payload = Buffer.from(data);
    const mask = crypto.randomBytes(4);
    let header;

    if (payload.length < 126) {
      header = Buffer.alloc(6);
      header[0] = 0x81; // FIN + text
      header[1] = 0x80 | payload.length; // MASK + length
      mask.copy(header, 2);
    } else if (payload.length < 65536) {
      header = Buffer.alloc(8);
      header[0] = 0x81;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(payload.length, 2);
      mask.copy(header, 4);
    } else {
      header = Buffer.alloc(14);
      header[0] = 0x81;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(payload.length), 2);
      mask.copy(header, 10);
    }

    const masked = Buffer.alloc(payload.length);
    for (let i = 0; i < payload.length; i++) {
      masked[i] = payload[i] ^ mask[i % 4];
    }

    this._socket.write(Buffer.concat([header, masked]));
  }

  _onData(chunk) {
    this._buffer = Buffer.concat([this._buffer, chunk]);
    while (this._buffer.length >= 2) {
      const firstByte = this._buffer[0];
      const secondByte = this._buffer[1];
      const isMasked = (secondByte & 0x80) !== 0;
      let payloadLength = secondByte & 0x7f;
      let offset = 2;

      if (payloadLength === 126) {
        if (this._buffer.length < 4) return;
        payloadLength = this._buffer.readUInt16BE(2);
        offset = 4;
      } else if (payloadLength === 127) {
        if (this._buffer.length < 10) return;
        payloadLength = Number(this._buffer.readBigUInt64BE(2));
        offset = 10;
      }

      if (isMasked) offset += 4;
      if (this._buffer.length < offset + payloadLength) return;

      let payload = this._buffer.subarray(offset, offset + payloadLength);
      if (isMasked) {
        const mask = this._buffer.subarray(offset - 4, offset);
        payload = Buffer.from(payload);
        for (let i = 0; i < payload.length; i++) {
          payload[i] ^= mask[i % 4];
        }
      }

      const opcode = firstByte & 0x0f;
      if (opcode === 0x01) {
        // Text frame
        this._emit('message', payload.toString('utf8'));
      } else if (opcode === 0x08) {
        // Close
        this.close();
        return;
      } else if (opcode === 0x09) {
        // Ping -> Pong
        this._sendPong(payload);
      }

      this._buffer = this._buffer.subarray(offset + payloadLength);
    }
  }

  _sendPong(data) {
    if (!this._socket) return;
    const mask = crypto.randomBytes(4);
    const header = Buffer.alloc(6);
    header[0] = 0x8a; // FIN + pong
    header[1] = 0x80 | data.length;
    mask.copy(header, 2);
    const masked = Buffer.from(data);
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
    this._socket.write(Buffer.concat([header, masked]));
  }

  close() {
    if (this._socket) {
      this._socket.end();
      this._socket = null;
    }
  }
}

// --- HTTP helpers ---
function httpGet(path) {
  return new Promise((resolve, reject) => {
    http.get(`http://${HOST}:${PORT}${path}`, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch {
          resolve(data);
        }
      });
    }).on('error', reject);
  });
}

async function getPageTarget(index = 0) {
  const targets = await httpGet('/json');
  const pages = targets.filter((t) => t.type === 'page');
  if (pages.length === 0) throw new Error('No page target found. Is the Electron app running?');
  // If CDP_WINDOW is set, use that index; otherwise auto-skip DevTools pages
  let selectedIndex = process.env.CDP_WINDOW != null ? parseInt(process.env.CDP_WINDOW) : index;
  if (process.env.CDP_WINDOW == null && pages.length > 1) {
    const appIdx = pages.findIndex((p) => !p.url?.startsWith('devtools://'));
    if (appIdx >= 0) selectedIndex = appIdx;
  }
  if (selectedIndex >= pages.length) throw new Error(`Page index ${selectedIndex} out of range (${pages.length} pages available)`);
  if (pages.length > 1) {
    console.log(`  [info] ${pages.length} windows detected, using window ${selectedIndex}: "${pages[selectedIndex].title}"`);
  }
  return pages[selectedIndex];
}

async function cdpCommand(method, params = {}) {
  const target = await getPageTarget();
  const ws = new MiniWebSocket(target.webSocketDebuggerUrl);
  await ws.connect();

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error('CDP command timed out'));
    }, 10000);

    ws.on('message', (data) => {
      const msg = JSON.parse(data);
      if (msg.id === 1) {
        clearTimeout(timeout);
        ws.close();
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      }
    });

    ws.send(JSON.stringify({ id: 1, method, params }));
  });
}

// --- Commands ---
async function cmdTargets() {
  const targets = await httpGet('/json');
  const version = await httpGet('/json/version');
  console.log('=== Browser Version ===');
  console.log(JSON.stringify(version, null, 2));
  console.log('\n=== Debug Targets ===');
  for (const t of targets) {
    console.log(`  [${t.type}] ${t.title || t.url}`);
    console.log(`    URL: ${t.url}`);
    console.log(`    WS:  ${t.webSocketDebuggerUrl}`);
    console.log('');
  }
  return targets;
}

async function cmdScreenshot(outputPath = '/tmp/electron-screenshot.png') {
  console.log('Capturing screenshot...');
  const result = await cdpCommand('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(outputPath, Buffer.from(result.data, 'base64'));
  // Resize to fit Claude's image dimension limit (max 1900px either side, under 2000px API limit)
  try {
    const { execSync } = await import('child_process');
    const dims = execSync(`sips -g pixelWidth -g pixelHeight "${outputPath}" 2>/dev/null`, { encoding: 'utf8' });
    const w = parseInt((dims.match(/pixelWidth:\s*(\d+)/) || [])[1]) || 0;
    const h = parseInt((dims.match(/pixelHeight:\s*(\d+)/) || [])[1]) || 0;
    const MAX = 1900;
    if (w > MAX || h > MAX) {
      // Scale down proportionally so the largest dimension = MAX
      if (w >= h) {
        execSync(`sips --resampleWidth ${MAX} "${outputPath}" >/dev/null 2>&1`);
      } else {
        execSync(`sips --resampleHeight ${MAX} "${outputPath}" >/dev/null 2>&1`);
      }
    }
  } catch {}
  console.log(`Screenshot saved to ${outputPath}`);
}

async function cmdEval(expression) {
  console.log(`Evaluating: ${expression}`);
  const result = await cdpCommand('Runtime.evaluate', {
    expression,
    returnByValue: true,
  });
  console.log('Result:', JSON.stringify(result, null, 2));
}

// Old console command replaced by cmdConsoleV2 below (with main process log tailing)

async function cmdHealth() {
  console.log('=== Electron App Health Check ===\n');

  // 1. Check if debug port is responsive
  try {
    const version = await httpGet('/json/version');
    console.log('[OK] Debug port responsive');
    console.log(`     Browser: ${version.Browser || 'unknown'}`);
    console.log(`     V8: ${version.V8 || 'unknown'}`);
  } catch (e) {
    console.error(`[FAIL] Cannot connect to debug port ${PORT}: ${e.message}`);
    console.error('       Is the app running with --remote-debugging-port?');
    process.exit(1);
  }

  // 2. Check targets
  const targets = await httpGet('/json');
  const pages = targets.filter((t) => t.type === 'page');
  console.log(`[OK] Found ${targets.length} target(s), ${pages.length} page(s)`);

  if (pages.length === 0) {
    console.error('[WARN] No page targets found - app may not have loaded yet');
    return;
  }

  // 3. Check page load
  try {
    const result = await cdpCommand('Runtime.evaluate', {
      expression: 'JSON.stringify({ title: document.title, url: location.href, readyState: document.readyState, bodyChildren: document.body?.children?.length || 0 })',
      returnByValue: true,
    });
    const info = JSON.parse(result.result.value);
    console.log(`[OK] Page loaded`);
    console.log(`     Title: ${info.title}`);
    console.log(`     URL: ${info.url}`);
    console.log(`     ReadyState: ${info.readyState}`);
    console.log(`     Body children: ${info.bodyChildren}`);
  } catch (e) {
    console.error(`[WARN] Cannot evaluate page: ${e.message}`);
  }

  // 4. Check for JS errors
  try {
    const result = await cdpCommand('Runtime.evaluate', {
      expression: 'window.__electronDebugErrors?.length || 0',
      returnByValue: true,
    });
    console.log(`[OK] Error tracking: ${result.result.value || 0} errors captured`);
  } catch {
    // ignore
  }

  // 5. Check renderer process memory
  try {
    const result = await cdpCommand('Runtime.evaluate', {
      expression: 'JSON.stringify(performance.memory || {})',
      returnByValue: true,
    });
    const mem = JSON.parse(result.result.value || '{}');
    if (mem.usedJSHeapSize) {
      console.log(`[OK] Renderer memory: ${(mem.usedJSHeapSize / 1024 / 1024).toFixed(1)}MB used / ${(mem.totalJSHeapSize / 1024 / 1024).toFixed(1)}MB total`);
    }
  } catch {
    // ignore
  }

  console.log('\n=== Health check complete ===');
}

async function cmdDom() {
  console.log('Getting DOM snapshot...');
  const result = await cdpCommand('Runtime.evaluate', {
    expression: 'document.documentElement.outerHTML',
    returnByValue: true,
  });
  console.log(result.result.value);
}

async function cmdNetwork(seconds = 15) {
  const target = await getPageTarget();
  const ws = new MiniWebSocket(target.webSocketDebuggerUrl);
  await ws.connect();

  console.log(`Monitoring network for ${seconds} seconds...`);
  console.log('---');

  const requests = new Map();
  let msgId = 0;

  ws.on('message', (data) => {
    const msg = JSON.parse(data);
    if (msg.method === 'Network.requestWillBeSent') {
      const r = msg.params.request;
      requests.set(msg.params.requestId, { url: r.url, method: r.method, ts: Date.now() });
      console.log(`[REQ] ${r.method} ${r.url}`);
    }
    if (msg.method === 'Network.responseReceived') {
      const r = msg.params.response;
      const req = requests.get(msg.params.requestId);
      const duration = req ? `${Date.now() - req.ts}ms` : '?';
      console.log(`[RES] ${r.status} ${r.url} (${duration}) [${r.mimeType}]`);
    }
    if (msg.method === 'Network.loadingFailed') {
      const req = requests.get(msg.params.requestId);
      console.error(`[FAIL] ${req?.url || 'unknown'} - ${msg.params.errorText}`);
    }
  });

  ws.send(JSON.stringify({ id: ++msgId, method: 'Network.enable' }));

  await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
  ws.close();
  console.log(`--- Network monitoring ended (${requests.size} requests captured) ---`);
}

async function cmdPerf() {
  console.log('=== Performance Metrics ===\n');

  // Navigation timing
  try {
    const result = await cdpCommand('Runtime.evaluate', {
      expression: `JSON.stringify((() => {
        const nav = performance.getEntriesByType('navigation')[0] || {};
        const paint = performance.getEntriesByType('paint');
        const fcp = paint.find(e => e.name === 'first-contentful-paint');
        return {
          domContentLoaded: Math.round(nav.domContentLoadedEventEnd - nav.startTime),
          loadComplete: Math.round(nav.loadEventEnd - nav.startTime),
          domInteractive: Math.round(nav.domInteractive - nav.startTime),
          firstContentfulPaint: fcp ? Math.round(fcp.startTime) : null,
          transferSize: nav.transferSize,
          domNodes: document.querySelectorAll('*').length,
          jsHeapUsed: performance.memory?.usedJSHeapSize,
          jsHeapTotal: performance.memory?.totalJSHeapSize,
        };
      })())`,
      returnByValue: true,
    });
    const p = JSON.parse(result.result.value);
    console.log(`  DOM Content Loaded: ${p.domContentLoaded}ms`);
    console.log(`  Load Complete:      ${p.loadComplete}ms`);
    console.log(`  DOM Interactive:    ${p.domInteractive}ms`);
    if (p.firstContentfulPaint) console.log(`  First Contentful Paint: ${p.firstContentfulPaint}ms`);
    console.log(`  DOM Nodes:          ${p.domNodes}`);
    if (p.jsHeapUsed) console.log(`  JS Heap:            ${(p.jsHeapUsed / 1024 / 1024).toFixed(1)}MB / ${(p.jsHeapTotal / 1024 / 1024).toFixed(1)}MB`);
    if (p.transferSize) console.log(`  Transfer Size:      ${(p.transferSize / 1024).toFixed(1)}KB`);
  } catch (e) {
    console.error(`  Navigation timing error: ${e.message}`);
  }

  // Resource timing
  try {
    const result = await cdpCommand('Runtime.evaluate', {
      expression: `JSON.stringify(performance.getEntriesByType('resource').map(r => ({
        name: r.name.split('/').pop().substring(0, 40),
        type: r.initiatorType,
        duration: Math.round(r.duration),
        size: r.transferSize
      })).sort((a,b) => b.duration - a.duration).slice(0, 10))`,
      returnByValue: true,
    });
    const resources = JSON.parse(result.result.value);
    if (resources.length) {
      console.log('\n  Top 10 Resources by Duration:');
      for (const r of resources) {
        console.log(`    ${r.duration}ms  ${r.type.padEnd(8)} ${r.name}`);
      }
    }
  } catch {
    // ignore
  }

  console.log('\n=== Performance check complete ===');
}

// --- Reusable CDP session for multi-command interactions ---
async function withCdpSession(fn) {
  const target = await getPageTarget();
  const ws = new MiniWebSocket(target.webSocketDebuggerUrl);
  await ws.connect();

  let id = 0;
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const myId = ++id;
    const handler = (data) => {
      const msg = JSON.parse(data);
      if (msg.id === myId) {
        ws.off('message', handler);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      }
    };
    ws.on('message', handler);
    ws.send(JSON.stringify({ id: myId, method, params }));
  });

  try {
    await fn(send, ws);
  } finally {
    ws.close();
  }
}

// --- Launch & Stop ---
async function cmdLaunch(mode = 'dev') {
  const cwd = process.cwd();
  const pkgPath = path.join(cwd, 'package.json');

  if (!fs.existsSync(pkgPath)) {
    console.error('No package.json found in current directory');
    process.exit(1);
  }

  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));

  // Auto-find free port if CDP_PORT not explicitly set
  let port;
  if (process.env.CDP_PORT) {
    port = parseInt(PORT);
    // Check if explicitly set port is already in use
    try {
      await httpGet('/json/version');
      console.log(`Port ${port} already has an Electron app running. Use 'stop' first or set a different CDP_PORT.`);
      return;
    } catch {
      // Port is free, good
    }
  } else {
    port = await findFreePort(9222);
    PORT = port; // Update global for subsequent commands in this session
  }

  // Detect project type and build launch command
  let cmd, args;
  const hasElectronVite = pkg.devDependencies?.['electron-vite'] || pkg.dependencies?.['electron-vite'];
  const hasForge = pkg.devDependencies?.['@electron-forge/cli'] || pkg.dependencies?.['@electron-forge/cli'];

  if (mode === 'dev') {
    if (hasElectronVite) {
      cmd = 'npx';
      args = ['electron-vite', 'dev', '--', `--remote-debugging-port=${port}`];
    } else if (hasForge) {
      cmd = 'npx';
      args = ['electron-forge', 'start', '--', `--remote-debugging-port=${port}`];
    } else {
      const main = pkg.main || 'index.js';
      cmd = 'npx';
      args = ['electron', main, `--remote-debugging-port=${port}`];
    }
  } else {
    // Build first, then run
    console.log('Building app...');
    try {
      if (hasElectronVite) {
        execSync('npx electron-vite build', { cwd, stdio: 'inherit' });
        cmd = 'npx';
        args = ['electron-vite', 'preview', '--', `--remote-debugging-port=${port}`];
      } else {
        execSync('npm run build', { cwd, stdio: 'inherit' });
        const main = pkg.main || 'index.js';
        cmd = 'npx';
        args = ['electron', main, `--remote-debugging-port=${port}`];
      }
    } catch (e) {
      console.error('Build failed:', e.message);
      process.exit(1);
    }
  }

  console.log(`Launching: ${cmd} ${args.join(' ')}`);
  console.log(`Debug port: ${port}`);

  // Redirect stdout/stderr to a log file for main process monitoring
  const logFile = '/tmp/electron-debug-main.log';
  const logStream = fs.openSync(logFile, 'w');

  const child = spawn(cmd, args, {
    cwd,
    stdio: ['ignore', logStream, logStream],
    detached: true,
    env: { ...process.env, ELECTRON_ENABLE_LOGGING: '1' },
  });
  child.unref();

  saveState({ pid: child.pid, port, cwd, logFile, launchedAt: new Date().toISOString() });
  console.log(`Process started (PID: ${child.pid})`);
  console.log(`Main process logs: ${logFile}`);

  // Wait for debug port to become available
  console.log('Waiting for app to start...');
  for (let i = 0; i < 20; i++) {
    await new Promise(r => setTimeout(r, 1000));
    try {
      const version = await httpGet('/json/version');
      console.log(`[OK] App ready! (${version.Browser})`);
      return;
    } catch {
      // not ready yet
    }
  }
  console.error('[WARN] App started but debug port not responding after 20s');
}

async function cmdStop() {
  const state = loadState();
  if (!state) {
    console.log('No tracked Electron process. Trying to find one...');
    try {
      const pids = execSync('pgrep -f "electron-vite dev|electron-forge start|electron ."', { encoding: 'utf8' }).trim();
      if (pids) {
        console.log(`Found PIDs: ${pids.replace(/\n/g, ', ')}`);
        for (const pid of pids.split('\n')) {
          try { process.kill(parseInt(pid), 'SIGTERM'); } catch {}
        }
        console.log('Sent SIGTERM to all');
      }
    } catch {
      console.log('No Electron processes found');
    }
    return;
  }

  console.log(`Stopping PID ${state.pid}...`);
  try {
    // Kill the process group (detached process + children)
    process.kill(-state.pid, 'SIGTERM');
  } catch {
    try { process.kill(state.pid, 'SIGTERM'); } catch {}
  }

  // Also kill child electron processes
  try {
    execSync(`pkill -P ${state.pid} 2>/dev/null; pkill -f "remote-debugging-port=${state.port}" 2>/dev/null`, { encoding: 'utf8' });
  } catch {}

  clearState();
  console.log('Stopped.');

  // Show last few lines of main process log
  if (state.logFile && fs.existsSync(state.logFile)) {
    const log = fs.readFileSync(state.logFile, 'utf8');
    const lines = log.trim().split('\n');
    if (lines.length > 0 && lines[0]) {
      console.log(`\nLast main process output (${state.logFile}):`);
      console.log(lines.slice(-10).join('\n'));
    }
  }
}

// --- Console: now includes main process logs ---
async function cmdConsoleV2(seconds = 30) {
  const state = loadState();
  const logFile = state?.logFile || '/tmp/electron-debug-main.log';

  const target = await getPageTarget();
  const ws = new MiniWebSocket(target.webSocketDebuggerUrl);
  await ws.connect();

  console.log(`Monitoring console for ${seconds}s (main + renderer)...`);
  console.log('---');

  let msgId = 0;

  // Monitor renderer via CDP
  ws.on('message', (data) => {
    const msg = JSON.parse(data);
    if (msg.method === 'Runtime.consoleAPICalled') {
      const args = msg.params.args.map((a) => a.value ?? a.description ?? JSON.stringify(a)).join(' ');
      const ts = new Date().toISOString().slice(11, 23);
      console.log(`[${ts}] [RENDERER] [${msg.params.type.toUpperCase()}] ${args}`);
    }
    if (msg.method === 'Runtime.exceptionThrown') {
      const detail = msg.params.exceptionDetails;
      console.error(`[RENDERER] [ERROR] ${detail.text} at ${detail.url}:${detail.lineNumber}:${detail.columnNumber}`);
      if (detail.exception?.description) {
        console.error(`  ${detail.exception.description}`);
      }
    }
    if (msg.method === 'Log.entryAdded') {
      const entry = msg.params.entry;
      console.log(`[RENDERER] [${entry.level.toUpperCase()}] [${entry.source}] ${entry.text}`);
    }
  });

  ws.send(JSON.stringify({ id: ++msgId, method: 'Runtime.enable' }));
  ws.send(JSON.stringify({ id: ++msgId, method: 'Console.enable' }));
  ws.send(JSON.stringify({ id: ++msgId, method: 'Log.enable' }));

  // Monitor main process via log file tailing
  let lastLogSize = 0;
  try { lastLogSize = fs.statSync(logFile).size; } catch {}

  const logInterval = setInterval(() => {
    try {
      const stat = fs.statSync(logFile);
      if (stat.size > lastLogSize) {
        const fd = fs.openSync(logFile, 'r');
        const buf = Buffer.alloc(stat.size - lastLogSize);
        fs.readSync(fd, buf, 0, buf.length, lastLogSize);
        fs.closeSync(fd);
        const newLines = buf.toString('utf8').trim();
        if (newLines) {
          for (const line of newLines.split('\n')) {
            if (line.trim()) {
              const ts = new Date().toISOString().slice(11, 23);
              console.log(`[${ts}] [MAIN] ${line}`);
            }
          }
        }
        lastLogSize = stat.size;
      }
    } catch {}
  }, 500);

  await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
  clearInterval(logInterval);
  ws.close();
  console.log('--- Console monitoring ended ---');
}

async function cmdClick(selector) {
  if (!selector) {
    console.log('Usage: node cdp-client.mjs click "selector"');
    return;
  }
  console.log(`Clicking: ${selector}`);

  // Get element position + the window's screen offset (to map CSS coords → screen points).
  const result = await cdpCommand('Runtime.evaluate', {
    expression: `JSON.stringify((() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      if (!el) return { error: 'Element not found: ${selector}' };
      const rect = el.getBoundingClientRect();
      return {
        x: rect.x + rect.width / 2, y: rect.y + rect.height / 2,
        text: el.textContent?.trim().substring(0, 50),
        winX: window.screenX, winY: window.screenY,
        chromeY: Math.max(0, window.outerHeight - window.innerHeight)
      };
    })())`,
    returnByValue: true,
  });
  const info = JSON.parse(result.result.value);

  if (info.error) {
    console.error(info.error);
    return;
  }

  console.log(`  Found element: "${info.text}" at (${info.x}, ${info.y})`);

  // Glide the virtual pointer to the on-screen location (browser window origin + viewport
  // CSS coords + top-chrome height) before dispatching the (in-page) click.
  showPointer('tap', info.winX + info.x, info.winY + info.chromeY + info.y);

  await withCdpSession(async (send) => {
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: info.x, y: info.y, button: 'left', clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: info.x, y: info.y, button: 'left', clickCount: 1 });
  });

  console.log('  Click dispatched!');
}

async function cmdType(selector, text) {
  if (!selector || !text) {
    console.log('Usage: node cdp-client.mjs type "selector" "text to type"');
    return;
  }
  console.log(`Typing into: ${selector}`);

  // Focus the element
  await cdpCommand('Runtime.evaluate', {
    expression: `(() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      if (!el) throw new Error('Element not found');
      el.focus();
      if (el.select) el.select();
    })()`,
  });

  // Type each character
  await withCdpSession(async (send) => {
    for (const char of text) {
      await send('Input.dispatchKeyEvent', { type: 'keyDown', text: char });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', text: char });
    }
  });

  console.log(`  Typed ${text.length} character(s)`);
}

async function cmdKey(keySpec) {
  if (!keySpec) {
    console.log('Usage: node cdp-client.mjs key "KeyName" (e.g., F12, Enter, Escape, Tab)');
    console.log('       node cdp-client.mjs key "ctrl+r" (modifiers: ctrl, alt, shift, meta)');
    return;
  }

  const parts = keySpec.toLowerCase().split('+');
  const key = parts.pop();
  const modifiers =
    (parts.includes('ctrl') ? 2 : 0) |
    (parts.includes('alt') ? 1 : 0) |
    (parts.includes('shift') ? 8 : 0) |
    (parts.includes('meta') || parts.includes('cmd') ? 4 : 0);

  // Map common key names to CDP key identifiers
  const keyMap = {
    enter: { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 },
    escape: { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 },
    esc: { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 },
    tab: { key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 },
    backspace: { key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 },
    delete: { key: 'Delete', code: 'Delete', windowsVirtualKeyCode: 46 },
    space: { key: ' ', code: 'Space', windowsVirtualKeyCode: 32 },
    arrowup: { key: 'ArrowUp', code: 'ArrowUp', windowsVirtualKeyCode: 38 },
    arrowdown: { key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 },
    arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', windowsVirtualKeyCode: 37 },
    arrowright: { key: 'ArrowRight', code: 'ArrowRight', windowsVirtualKeyCode: 39 },
    f1: { key: 'F1', code: 'F1', windowsVirtualKeyCode: 112 },
    f5: { key: 'F5', code: 'F5', windowsVirtualKeyCode: 116 },
    f11: { key: 'F11', code: 'F11', windowsVirtualKeyCode: 122 },
    f12: { key: 'F12', code: 'F12', windowsVirtualKeyCode: 123 },
    r: { key: 'r', code: 'KeyR', windowsVirtualKeyCode: 82 },
    a: { key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65 },
  };

  const keyInfo = keyMap[key] || { key, code: `Key${key.toUpperCase()}`, windowsVirtualKeyCode: key.toUpperCase().charCodeAt(0) };

  console.log(`Sending key: ${keySpec}`);

  await withCdpSession(async (send) => {
    await send('Input.dispatchKeyEvent', {
      type: 'keyDown',
      modifiers,
      ...keyInfo,
    });
    await send('Input.dispatchKeyEvent', {
      type: 'keyUp',
      modifiers,
      ...keyInfo,
    });
  });

  console.log('  Key dispatched!');
}

async function cmdWait(selector, timeoutMs = 10000) {
  if (!selector) {
    console.log('Usage: node cdp-client.mjs wait "selector" [timeoutMs]');
    return;
  }

  console.log(`Waiting for: ${selector} (timeout: ${timeoutMs}ms)`);
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    try {
      const result = await cdpCommand('Runtime.evaluate', {
        expression: `!!document.querySelector(${JSON.stringify(selector)})`,
        returnByValue: true,
      });
      if (result.result.value === true) {
        console.log(`  [OK] Element found after ${Date.now() - start}ms`);
        return;
      }
    } catch {
      // connection issues, retry
    }
    await new Promise(r => setTimeout(r, 300));
  }

  console.error(`  [FAIL] Element "${selector}" not found after ${timeoutMs}ms`);
  process.exit(1);
}

// --- Main process log viewer ---
async function cmdMainLog(lines = 50) {
  const state = loadState();
  const logFile = state?.logFile || '/tmp/electron-debug-main.log';

  if (!fs.existsSync(logFile)) {
    console.log('No main process log file found. Launch app with "launch" command first.');
    return;
  }

  const content = fs.readFileSync(logFile, 'utf8');
  const allLines = content.trim().split('\n');
  const tail = allLines.slice(-lines);

  console.log(`=== Main Process Log (last ${tail.length} of ${allLines.length} lines) ===`);
  console.log(tail.join('\n'));
  console.log('===');
}

async function cmdA11y() {
  console.log('=== Accessibility Audit ===\n');

  const result = await cdpCommand('Runtime.evaluate', {
    expression: `JSON.stringify((() => {
      const issues = [];
      // Check images without alt
      document.querySelectorAll('img:not([alt])').forEach(img => {
        issues.push({ type: 'error', rule: 'img-alt', msg: 'Image missing alt attribute', el: img.src?.substring(0, 60) });
      });
      // Check empty buttons
      document.querySelectorAll('button').forEach(btn => {
        if (!btn.textContent?.trim() && !btn.getAttribute('aria-label')) {
          issues.push({ type: 'error', rule: 'button-label', msg: 'Button has no accessible label', el: btn.outerHTML.substring(0, 60) });
        }
      });
      // Check empty links
      document.querySelectorAll('a').forEach(a => {
        if (!a.textContent?.trim() && !a.getAttribute('aria-label')) {
          issues.push({ type: 'error', rule: 'link-label', msg: 'Link has no accessible label', el: a.outerHTML.substring(0, 60) });
        }
      });
      // Check form inputs without labels
      document.querySelectorAll('input:not([type=hidden]):not([type=submit])').forEach(input => {
        const id = input.id;
        const hasLabel = id && document.querySelector('label[for="' + id + '"]');
        const hasAriaLabel = input.getAttribute('aria-label') || input.getAttribute('aria-labelledby');
        if (!hasLabel && !hasAriaLabel && !input.placeholder) {
          issues.push({ type: 'warning', rule: 'input-label', msg: 'Input missing label', el: input.outerHTML.substring(0, 60) });
        }
      });
      // Check color contrast (basic - just check for very small text)
      document.querySelectorAll('*').forEach(el => {
        const style = getComputedStyle(el);
        const fontSize = parseFloat(style.fontSize);
        if (fontSize > 0 && fontSize < 12 && el.textContent?.trim()) {
          issues.push({ type: 'warning', rule: 'text-size', msg: 'Very small text (<12px)', el: el.textContent.trim().substring(0, 40) });
        }
      });
      // Check heading order
      const headings = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')];
      for (let i = 1; i < headings.length; i++) {
        const prev = parseInt(headings[i-1].tagName[1]);
        const curr = parseInt(headings[i].tagName[1]);
        if (curr > prev + 1) {
          issues.push({ type: 'warning', rule: 'heading-order', msg: 'Heading level skipped: h' + prev + ' -> h' + curr, el: headings[i].textContent?.trim().substring(0, 40) });
        }
      }
      // Check lang attribute
      if (!document.documentElement.lang) {
        issues.push({ type: 'warning', rule: 'html-lang', msg: 'Missing lang attribute on <html>' });
      }
      // Summary
      const summary = {
        totalElements: document.querySelectorAll('*').length,
        images: document.querySelectorAll('img').length,
        buttons: document.querySelectorAll('button').length,
        links: document.querySelectorAll('a').length,
        inputs: document.querySelectorAll('input').length,
        headings: headings.length,
        ariaRoles: document.querySelectorAll('[role]').length,
        ariaLabels: document.querySelectorAll('[aria-label]').length,
      };
      return { issues, summary };
    })())`,
    returnByValue: true,
  });

  const audit = JSON.parse(result.result.value);

  console.log('  Element Summary:');
  for (const [key, val] of Object.entries(audit.summary)) {
    console.log(`    ${key}: ${val}`);
  }

  if (audit.issues.length === 0) {
    console.log('\n  [OK] No accessibility issues found!');
  } else {
    console.log(`\n  Found ${audit.issues.length} issue(s):`);
    for (const issue of audit.issues) {
      const icon = issue.type === 'error' ? '[ERROR]' : '[WARN] ';
      console.log(`    ${icon} [${issue.rule}] ${issue.msg}`);
      if (issue.el) console.log(`           ${issue.el}`);
    }
  }

  console.log('\n=== Accessibility audit complete ===');
}

async function cmdProcesses() {
  console.log('=== Electron Process Monitor ===\n');

  // Get Electron processes from the project directory
  const projectDir = process.cwd();

  const result = await cdpCommand('Runtime.evaluate', {
    expression: `JSON.stringify({
      userAgent: navigator.userAgent,
      platform: navigator.platform,
      windowCount: 1,
      url: location.href,
      title: document.title,
    })`,
    returnByValue: true,
  });
  const appInfo = JSON.parse(result.result.value);
  console.log(`  App: ${appInfo.title}`);
  console.log(`  URL: ${appInfo.url}`);
  console.log(`  UA:  ${appInfo.userAgent}`);

  // Use shell to get process info
  const { execSync } = await import('node:child_process');
  try {
    const output = execSync(`ps -o pid,rss,vsz,%cpu,%mem,command -p $(pgrep -f "${projectDir}" | tr '\\n' ',') 2>/dev/null`, { encoding: 'utf8' });
    console.log('\n  OS Processes:');
    for (const line of output.trim().split('\n')) {
      console.log(`    ${line}`);
    }
  } catch {
    console.log('  Could not get process details');
  }

  console.log('\n=== Process monitor complete ===');
}

// --- Main ---
const [, , command, ...args] = process.argv;

try {
  switch (command) {
    case 'launch':
      await cmdLaunch(args[0] || 'dev');
      break;
    case 'stop':
      await cmdStop();
      break;
    case 'targets':
      await cmdTargets();
      break;
    case 'screenshot':
      await cmdScreenshot(args[0]);
      break;
    case 'eval':
      await cmdEval(args.join(' '));
      break;
    case 'console':
      await cmdConsoleV2(parseInt(args[0]) || 30);
      break;
    case 'health':
      await cmdHealth();
      break;
    case 'dom':
      await cmdDom();
      break;
    case 'network':
      await cmdNetwork(parseInt(args[0]) || 15);
      break;
    case 'perf':
      await cmdPerf();
      break;
    case 'click':
      await cmdClick(args.join(' '));
      break;
    case 'type':
      await cmdType(args[0], args.slice(1).join(' '));
      break;
    case 'key':
      await cmdKey(args.join('+'));
      break;
    case 'wait':
      await cmdWait(args[0], parseInt(args[1]) || 10000);
      break;
    case 'a11y':
      await cmdA11y();
      break;
    case 'processes':
      await cmdProcesses();
      break;
    case 'main-log':
      await cmdMainLog(parseInt(args[0]) || 50);
      break;
    default:
      console.log(`Usage: node cdp-client.mjs <command> [args]

Lifecycle:
  launch [dev|build]   Launch Electron app with debug port
  stop                 Stop the running Electron app

Inspection:
  targets              List debug targets
  health               Run health check
  screenshot [path]    Capture screenshot
  dom                  Get page DOM
  eval "expression"    Evaluate JS in renderer
  perf                 Performance metrics and resource timing
  a11y                 Basic accessibility audit
  processes            Show Electron process info & resource usage

Monitoring:
  console [seconds]    Monitor main + renderer console output (default: 30s)
  network [seconds]    Monitor network requests (default: 15s)
  main-log [lines]     Show main process log (default: last 50 lines)

Interaction:
  click "selector"     Click an element by CSS selector
  type "selector" "text"  Type text into an input element
  key "KeyName"        Send keyboard key (e.g., F12, Enter, ctrl+r)
  wait "selector" [ms] Wait for element to appear (default: 10000ms)

Environment:
  CDP_PORT=9222        Debug port (default: 9222)
  CDP_HOST=localhost   Debug host (default: localhost)
  CDP_WINDOW=0         Window index for multi-window apps (default: 0)`);
  }
} catch (e) {
  console.error(`Error: ${e.message}`);
  process.exit(1);
}
