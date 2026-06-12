# Chrome Extension Debug Reference

**Protocol**: CDP (via `web-ext` or manual Chrome launch)
**Frameworks**: WXT, Plasmo, vanilla Manifest V3

## Launch Methods

### Method 1: web-ext (Recommended)

The most reliable way to load and test unpacked Chrome extensions.

```bash
npx web-ext run \
  --source-dir=dist/chrome-mv3 \
  --target=chromium \
  --chromium-binary="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --start-url="https://example.com" \
  --no-reload
```

**Notes:**
- Automatically enables developer mode and loads the extension
- Uses `--remote-debugging-pipe` (not a port), so CDP tools can't connect directly
- Uses `--enable-unsafe-extension-debugging` for full extension access
- Creates a temp profile at `/tmp/tmp-web-ext-*`

### Method 2: Puppeteer (Programmatic)

```javascript
import puppeteer from 'puppeteer-core';

const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: false,
  args: [
    `--disable-extensions-except=${EXTENSION_PATH}`,
    `--load-extension=${EXTENSION_PATH}`,
    '--no-first-run',
  ],
  userDataDir: '/tmp/puppeteer-ext-test',
});

// Wait for service worker
const swTarget = await browser.waitForTarget(
  t => t.type() === 'service_worker' && t.url().includes('service_worker.js'),
  { timeout: 10000 }
);
const extId = swTarget.url().split('/')[2];
```

**Note:** `--load-extension` may not work reliably in newer Chrome versions. Prefer `web-ext`.

### Method 3: Manual CDP Chrome

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9223 \
  --user-data-dir=/tmp/chrome-ext-debug \
  --load-extension="/path/to/dist/chrome-mv3" \
  --disable-extensions-except="/path/to/dist/chrome-mv3" \
  --no-first-run
```

**Caveats:**
- Requires developer mode enabled in the profile (may not auto-enable)
- Port 9222 often conflicts with user's own Chrome; use 9223+
- Must navigate to target page AFTER extension loads for content scripts to inject

## Extension Architecture (Manifest V3)

```
Extension
├── service_worker (background.js)    — Persistent background logic
├── content_scripts (*.js)            — Injected into matching pages
├── side_panel (sidepanel.html)       — Extension sidebar UI
├── popup (popup.html)                — Toolbar popup UI
└── options (options.html)            — Settings page
```

## Debugging via CDP

### Connecting to Targets

Extensions expose multiple CDP targets:

| Target Type | Description | CDP Access |
|------------|-------------|------------|
| `page` | Web pages with content scripts | Direct WebSocket via `/json/list` |
| `service_worker` | Background service worker | Browser-level `Target.attachToTarget` only |
| `page` (extension) | Popup/options/sidepanel pages | Direct if opened as tab, otherwise via `Target.attachToTarget` |

### Accessing Service Worker via Browser Target

Service workers can't be connected to via `/devtools/page/` URLs. Use the browser WebSocket:

```javascript
// 1. Get browser WS URL
const version = await fetch('http://localhost:9223/json/version').then(r => r.json());
const browserWs = version.webSocketDebuggerUrl;

// 2. Connect and attach to service worker
const ws = new WebSocket(browserWs);
ws.send(JSON.stringify({
  id: 1,
  method: 'Target.getTargets'
}));
// Find service_worker target, then:
ws.send(JSON.stringify({
  id: 2,
  method: 'Target.attachToTarget',
  params: { targetId: swTargetId, flatten: true }
}));
// Use returned sessionId for Runtime.evaluate calls
```

### Setting Extension Storage

From extension context (service worker or extension page):
```javascript
chrome.storage.local.set({ key: JSON.stringify(value) });
```

From page context (CDP eval on web page): **Not possible** — `chrome.storage` is only available in extension contexts.

**Workaround:** Open extension page as tab, or use service worker attachment.

## Content Script Debugging

### Verifying Injection

```bash
P=~/.claude/skills/debug-kit/scripts
CDP_PORT=9223 bash $P/web-ctl.sh eval "
  (() => {
    const styles = document.querySelectorAll('style');
    for (const s of styles) {
      if (s.textContent.includes('my-extension-class')) return 'Content script loaded';
    }
    return 'Not injected';
  })()
"
```

### Content Script Not Injecting

Common causes:
1. **Page loaded before extension**: Navigate/reload page after extension is ready
2. **URL mismatch**: Check `matches` in manifest `content_scripts` section
3. **Script error**: Check `chrome://extensions` for error badge
4. **Execution context**: CDP `Runtime.evaluate` runs in page context, not content script context. Content scripts have separate execution contexts.

### Analyzing Page DOM (for writing content scripts)

Use CDP to explore target page structure:

```bash
CDP_PORT=9223 bash $P/web-ctl.sh eval "
  (() => {
    // Find elements matching a pattern
    const els = document.querySelectorAll('a[class*=\"some-class\"]');
    return Array.from(els).slice(0, 5).map(el => ({
      text: el.textContent?.trim(),
      tag: el.tagName,
      cls: el.className.substring(0, 100),
    }));
  })()
"
```

Then trace up to find card/container:

```bash
CDP_PORT=9223 bash $P/web-ctl.sh eval "
  (() => {
    const el = document.querySelector('target-selector');
    let cur = el;
    const path = [];
    for (let i = 0; i < 10 && cur && cur !== document.body; i++) {
      path.push({
        tag: cur.tagName,
        cls: cur.className?.substring(0, 100),
        w: Math.round(cur.getBoundingClientRect().width),
        h: Math.round(cur.getBoundingClientRect().height),
      });
      cur = cur.parentElement;
    }
    return JSON.stringify(path, null, 2);
  })()
"
```

## WXT-Specific

### Build & Test Workflow

```bash
# Build
pnpm run build

# Test with web-ext
npx web-ext run \
  --source-dir=dist/chrome-mv3 \
  --target=chromium \
  --chromium-binary="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --start-url="https://target-site.com" \
  --no-reload

# Dev mode with HMR (manual extension load required)
pnpm run dev
```

### WXT Storage

WXT uses `wxt/storage` which wraps `chrome.storage`:
- Key format: `"local:keyName"` → stored in `chrome.storage.local` as `keyName`
- Values are JSON-serialized automatically
- `storage.watch()` for reactive updates across contexts

### Output Structure

```
dist/chrome-mv3/
├── manifest.json
├── background.js           # Service worker
├── sidepanel.html          # Side panel
├── content-scripts/
│   ├── content.js          # Content script (main)
│   └── my-content.js       # Named content scripts
└── ...
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Extension not loaded | Use `web-ext run` instead of `--load-extension` |
| Content script not injecting | Reload page after extension loads; check URL matches |
| `chrome.storage` undefined | Only available in extension contexts, not page context |
| Service worker not in /json/list | Use browser WebSocket + `Target.attachToTarget` |
| CDP port conflict | User's Chrome may occupy 9222; use 9223+ |
| Side panel ERR_FILE_NOT_FOUND | Side panels can only be opened via sidePanel API, not as tabs |
| Multiple Chrome instances | Use `--user-data-dir` with unique path for isolation |

## Interaction fidelity

Chrome Extensions (MV3) are driven over **CDP** like Web/Electron (page + service-worker targets).
- **Collection:** CDP `dom` / `eval` / `screenshot` / `a11y` against the popup/options/content page.
- **T1 semantic (default):** CDP `click "selector"` / `eval` in the target page.
- **T2 synthetic:** CDP `Input.dispatchMouseEvent` at coordinates (canvas-only).
- **T3 real OS HID:** rarely needed.

> Not functionally verified in this workspace — no MV3 extension project was available to run.

> **Virtual pointer:** extension pages are driven via `web-ctl`/`cdp-client`, so `click` glides
> the software cursor to the on-screen location just like Web. `DK_POINTER=off` to disable.
