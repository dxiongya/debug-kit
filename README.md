<h1 align="center">🧩 debug-kit</h1>

<p align="center"><b>An <a href="https://docs.claude.com/en/docs/claude-code/skills">Agent Skill</a> for Claude Code (and Cursor · Codex · Cline · Gemini CLI …)</b><br/>
Install it once and your AI gains hands &amp; eyes to <b>drive, inspect, and test real apps across 9 platforms</b> —<br/>
in the background, <b>without ever touching your real cursor</b>, with a virtual pointer you can watch.</p>

<p align="center">
<a href="https://skills.sh/dxiongya/debug-kit"><img alt="Agent Skill" src="https://img.shields.io/badge/Agent-Skill-7c3aed"></a>
<a href="https://skills.sh/dxiongya/debug-kit"><img alt="install: npx skills add" src="https://img.shields.io/badge/install-npx_skills_add-black?logo=npm"></a>
<a href="https://docs.claude.com/en/docs/claude-code/skills"><img alt="Claude Code Skill" src="https://img.shields.io/badge/Claude_Code-Skill-d97757"></a>
<a href="https://skills.sh/dxiongya/debug-kit"><img alt="skills.sh" src="https://skills.sh/b/dxiongya/debug-kit"></a>
<a href="./LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg"></a>
<img alt="platforms 9" src="https://img.shields.io/badge/platforms-9-blue">
<img alt="host macOS" src="https://img.shields.io/badge/host-macOS-black">
</p>

<p align="center"><b><a href="#english">English</a> · <a href="#简体中文">简体中文</a></b></p>

```bash
npx skills add dxiongya/debug-kit        # ← one-line install (it's a skill, not a library)
```

> [!NOTE]
> **This is an _Agent Skill_, not an app or a library.** You don't run or `import` it — you
> **install** it into your AI coding agent. After that, the agent automatically uses it whenever
> you say things like *"run the app", "tap the button", "take a screenshot", "test this"*. Under
> the hood it's a `SKILL.md` manifest plus the scripts the agent calls. Manage it with
> [skills.sh](https://skills.sh).

---

<a name="english"></a>

## English

**debug-kit** gives an AI agent — like [Claude Code](https://claude.com/claude-code) — *hands and eyes* on real applications across **macOS, iOS, Android, Web, Electron, Flutter, React Native, Tauri, and Chrome Extensions**. Build, launch, screenshot, read the UI tree, tap, type, drag, scroll, inspect, and stream logs — through **one unified interface** that auto‑detects the project type.

Its defining principle: **never hijack the human's machine.** Every interaction is delivered in the background (Accessibility actions, `CGEventPostToPid`, CDP, `simctl`/`adb`, the Dart VM Service), so your real cursor never moves and focus is never stolen — while a **resident "software cursor" glides to each action**, so you can *see* exactly where the AI is working.

### Install

**Recommended — via [skills.sh](https://skills.sh):**

```bash
npx skills add dxiongya/debug-kit        # into ./.claude/skills (project scope)
npx skills add -g dxiongya/debug-kit     # into ~/.claude/skills (global)
```

**Manual — git clone:**

```bash
git clone git@github.com:dxiongya/debug-kit.git
bash debug-kit/install.sh                # symlink → ~/.claude/skills/debug-kit
bash debug-kit/install.sh --copy         # or copy instead of symlink
```

Then in Claude Code the `debug-kit` skill auto‑triggers on "run the app", "test the app",
"take screenshot", "tap button", "debug", etc. The scripts under `scripts/` also work standalone.

> **macOS setup:** grant **Accessibility** + **Screen Recording** to your terminal
> (System Settings → Privacy & Security), then fully quit and relaunch it.

### Why it's different

- 🖱️ **Background by default — your cursor is sacred.** Clicks/keys/scrolls go straight to the target app; the system pointer stays exactly where you left it, focus never jumps. Real HID (which moves the cursor) is a manual, opt‑in escape hatch only.
- 👻 **A virtual pointer on every platform.** A gliding, click‑through software cursor (Codex/Operator‑style) shows where the AI taps — screen overlay on macOS/Tauri/Web/Electron, sim overlay on iOS, native touch feedback on Android.
- 🧠 **Semantic‑first, not pixel‑guessing.** Reads structured UI via the Accessibility tree (macOS/iOS), CDP DOM (Web/Electron), uiautomator (Android), and the Flutter VM Service — then acts by element, not coordinates, when possible.
- 🧩 **One router, nine platforms.** `pilot.sh auto <command>` detects the project (`package.json`, `pubspec.yaml`, `*.xcodeproj`, `build.gradle`, `src-tauri/`, `manifest.json` MV3…) and dispatches to the right controller.
- ⚡ **Zero heavyweight deps.** Plain bash + Node built‑ins + a little Swift/JXA. No Selenium, no Playwright runtime.

### Supported platforms

| Platform | Driven via | Virtual pointer |
|----------|-----------|-----------------|
| macOS | Accessibility + `CGEventPostToPid` | software cursor (screen) |
| iOS | `xcrun simctl` + XCUITest | sim overlay indicator |
| Android | `adb` + uiautomator | native `show_touches` |
| Web | Chrome + CDP | software cursor (CSS→screen) |
| Electron | CDP | software cursor (CSS→screen) |
| Flutter | Dart VM Service + mobile/desktop targets | mobile native / desktop screen |
| React Native | Metro + delegates to iOS | via iOS |
| Tauri | Accessibility through WKWebView | software cursor (via macOS) |
| Chrome Extension | CDP against extension pages | software cursor (via Web) |

### Quick example

```bash
P=~/.claude/skills/debug-kit/scripts

# auto-detect the project and drive it
bash $P/pilot.sh auto run                    # build + launch
bash $P/pilot.sh auto tree                   # dump the semantic UI tree
bash $P/pilot.sh auto tap label "Login"      # background AXPress — your cursor untouched
bash $P/pilot.sh auto type "hello@example.com"
bash $P/pilot.sh auto screenshot

# or target a platform explicitly
MAC_APP=MyApp bash $P/mac-ctl.sh tap label incrementButton
bash $P/android-ctl.sh tap 540 1000          # native touch feedback shown on device
bash $P/flutter-ctl.sh vm widgets            # semantic widget tree over the Dart VM Service
```

### Best testing recipe per platform

Collection is always native/semantic; interaction stays background.

| Platform | collect → interact → verify |
|----------|------------------------------|
| **macOS** | `tree`/`read` → `tap label`/`type`/`drag`/`scroll` → `read` + `screenshot` |
| **iOS** | `tree` (XCUITest) → `tap identifier`/`type` (simctl) → `screenshot` |
| **Android** | `tree` (uiautomator) → `tap`/`swipe`/`type` (adb) → `screenshot` |
| **Web / Electron** | `dom`/`eval` → `click "sel"`/`type` → `screenshot` |
| **Flutter** | `vm widgets` → mobile‑target `tap` / `vm call` → `vm widgets` |
| **React Native** | `run` (auto Metro port) → `tree`/`tap`/`type` (via iOS) → `screenshot` |
| **Tauri** | `tree`/`read` (WKWebView AX) → `tap-bg label`/`type-bg` → `screenshot` |
| **Chrome Extension** | CDP via `web-ctl` against the extension page |

See `references/<platform>.md` for each platform's full command set.

### How it works

debug-kit runs on a **macOS host** and drives each platform with its *native, professional*
protocol — never screen‑scraping when a real API exists. A small shared service
(`dk-pointer.sh` + a Swift overlay daemon) renders the virtual cursor in screen space, fed by
each controller after it maps the action to absolute screen coordinates. An
**interaction‑fidelity ladder** keeps everything in the background unless you explicitly ask
for a real‑cursor click:

- **T1 semantic** (default) — AX actions, CDP `click`, uiautomator, VM Service. No cursor.
- **T2 synthetic** — `CGEventPostToPid` / `simctl io` / `adb input` at coordinates. No cursor.
- **Escape hatch** — `MAC_INPUT=hid` is the *only* path that moves your real cursor; manual opt‑in.

**Knobs:** `DK_POINTER=off` (hide the virtual pointer), `DK_FIDELITY=semantic|synthetic|real`,
`MAC_INPUT=bg|hid`, `MAC_POINTER=on|off`.

### Requirements

- **macOS** host with Accessibility + Screen Recording granted to the terminal.
- Per‑platform toolchains as needed: Xcode (iOS/macOS), Android SDK + emulator,
  Node + Chrome (Web/Electron), Flutter SDK, Rust + Tauri CLI.
- Optional: Swift toolchain (`swiftc`) for the virtual‑pointer overlay — degrades gracefully if absent.

### Credits

- Virtual‑cursor glyph & motion referenced from the **open‑computer‑use** project
  (a reverse‑engineering of Codex Computer Use's software cursor); see `scripts/assets/NOTICE.md`.
- The interaction action model aligns with **OpenAI's computer‑use** tool spec.

---

<a name="简体中文"></a>

## 简体中文

> [!NOTE]
> **这是一个 _Agent Skill(智能体技能)_,不是 App、也不是库。** 你不需要"运行"或 `import` 它 —— 你把它**安装**进你的 AI 编程助手(Claude Code / Cursor / Codex …)。装好后,当你说"运行 app""点这个按钮""截个图""测一下"时,助手会**自动调用**它。底层就是一个 `SKILL.md` 清单 + 一组助手调用的脚本。用 [skills.sh](https://skills.sh) 管理。一行安装:`npx skills add dxiongya/debug-kit`

**debug-kit** 让 AI 智能体(如 [Claude Code](https://claude.com/claude-code))在 **macOS、iOS、Android、Web、Electron、Flutter、React Native、Tauri、Chrome 扩展**这 9 个平台上长出"手和眼":构建、启动、截图、读取 UI 树、点击、输入、拖拽、滚动、检视、看日志——全部通过**一套统一接口**,自动识别项目类型。

核心原则:**绝不接管你的机器。** 所有交互都在**后台**送达(Accessibility 动作、`CGEventPostToPid`、CDP、`simctl`/`adb`、Dart VM Service),**你的真实光标从不移动、焦点从不被抢**;同时一个**常驻"软光标"滑向每个操作点**,让你能*看见* AI 正在哪里操作。

### 安装

**推荐 —— 通过 [skills.sh](https://skills.sh):**

```bash
npx skills add dxiongya/debug-kit        # 安装到 ./.claude/skills(项目级)
npx skills add -g dxiongya/debug-kit     # 安装到 ~/.claude/skills(全局)
```

**手动 —— git clone:**

```bash
git clone git@github.com:dxiongya/debug-kit.git
bash debug-kit/install.sh                # 软链 → ~/.claude/skills/debug-kit
bash debug-kit/install.sh --copy         # 或拷贝(而非软链)
```

之后在 Claude Code 里,`debug-kit` skill 会在你说"运行 app""测试""截图""点按钮""调试"等时自动触发。`scripts/` 下的脚本也能独立使用。

> **macOS 配置:** 在「系统设置 → 隐私与安全性」给你的终端授予 **辅助功能** + **屏幕录制**,然后**完全退出并重启**终端。

### 它有何不同

- 🖱️ **默认后台 —— 你的光标神圣不可侵犯。** 点击/按键/滚动直达目标 App;系统光标停在原处、焦点不跳。会动真实光标的真实 HID 仅作**手动逃生口**。
- 👻 **每个平台都有虚拟指针。** 一个滑行、点击穿透的软光标(Codex/Operator 风格)显示 AI 点在哪 —— macOS/Tauri/Web/Electron 用屏幕叠加,iOS 用沙窗叠加,Android 用设备原生触摸反馈。
- 🧠 **语义优先,而非猜像素。** 通过 Accessibility 树(macOS/iOS)、CDP DOM(Web/Electron)、uiautomator(Android)、Flutter VM Service 读取结构化 UI,尽量**按元素**而非坐标操作。
- 🧩 **一个路由,九个平台。** `pilot.sh auto <命令>` 自动识别项目并分发到对应控制器。
- ⚡ **零重依赖。** 纯 bash + Node 内置模块 + 少量 Swift/JXA。不需要 Selenium、不需要 Playwright 运行时。

### 支持平台

| 平台 | 驱动方式 | 虚拟指针 |
|------|----------|----------|
| macOS | Accessibility + `CGEventPostToPid` | 软光标(屏幕) |
| iOS | `xcrun simctl` + XCUITest | 沙窗叠加指示器 |
| Android | `adb` + uiautomator | 原生 `show_touches` |
| Web | Chrome + CDP | 软光标(CSS→屏幕) |
| Electron | CDP | 软光标(CSS→屏幕) |
| Flutter | Dart VM Service + 移动/桌面目标 | 移动端原生 / 桌面屏幕 |
| React Native | Metro + 委托 iOS | 经 iOS |
| Tauri | 经 WKWebView 的 Accessibility | 软光标(经 macOS) |
| Chrome 扩展 | 对扩展页面用 CDP | 软光标(经 Web) |

### 快速示例

```bash
P=~/.claude/skills/debug-kit/scripts

# 自动识别项目并驱动
bash $P/pilot.sh auto run                    # 构建 + 启动
bash $P/pilot.sh auto tree                   # 导出语义 UI 树
bash $P/pilot.sh auto tap label "登录"        # 后台 AXPress —— 不动你的光标
bash $P/pilot.sh auto type "hello@example.com"
bash $P/pilot.sh auto screenshot

# 或显式指定平台
MAC_APP=MyApp bash $P/mac-ctl.sh tap label incrementButton
bash $P/android-ctl.sh tap 540 1000          # 设备上显示原生触摸反馈
bash $P/flutter-ctl.sh vm widgets            # 经 Dart VM Service 拿语义 widget 树
```

### 每端最佳测试配方

采集永远走原生/语义;交互保持后台。

| 平台 | 采集 → 交互 → 验证 |
|------|---------------------|
| **macOS** | `tree`/`read` → `tap label`/`type`/`drag`/`scroll` → `read` + `screenshot` |
| **iOS** | `tree`(XCUITest)→ `tap identifier`/`type`(simctl)→ `screenshot` |
| **Android** | `tree`(uiautomator)→ `tap`/`swipe`/`type`(adb)→ `screenshot` |
| **Web / Electron** | `dom`/`eval` → `click "选择器"`/`type` → `screenshot` |
| **Flutter** | `vm widgets` → 移动端 `tap` / `vm call` → `vm widgets` |
| **React Native** | `run`(自动 Metro 端口)→ `tree`/`tap`/`type`(经 iOS)→ `screenshot` |
| **Tauri** | `tree`/`read`(WKWebView AX)→ `tap-bg label`/`type-bg` → `screenshot` |
| **Chrome 扩展** | 经 `web-ctl` 对扩展页面用 CDP |

各平台完整命令见 `references/<平台>.md`。

### 工作原理

debug-kit 跑在 **macOS 宿主**上,用每个平台**原生、专业**的协议驱动它 —— 有真实 API 时绝不截屏猜像素。一个轻量共享服务(`dk-pointer.sh` + Swift 叠加守护)在屏幕空间渲染虚拟光标,由各控制器把动作映射成绝对屏幕坐标后喂给它。**交互保真阶梯**保证一切默认在后台,除非你显式要求真实点击:

- **T1 语义**(默认)—— AX 动作、CDP `click`、uiautomator、VM Service,不动光标。
- **T2 合成** —— `CGEventPostToPid` / `simctl io` / `adb input` 按坐标,不动光标。
- **逃生口** —— `MAC_INPUT=hid` 是**唯一**会移动你真实光标的路径,手动开启。

**开关:** `DK_POINTER=off`(隐藏虚拟指针)、`DK_FIDELITY=semantic|synthetic|real`、`MAC_INPUT=bg|hid`、`MAC_POINTER=on|off`。

### 环境要求

- **macOS** 宿主,终端已授予辅助功能 + 屏幕录制。
- 按需的各平台工具链:Xcode(iOS/macOS)、Android SDK + 模拟器、Node + Chrome(Web/Electron)、Flutter SDK、Rust + Tauri CLI。
- 可选:Swift 工具链(`swiftc`)用于虚拟指针叠加 —— 缺失时优雅降级。

### 致谢

- 虚拟光标的图形与运动参考自 **open‑computer‑use** 项目(对 Codex Computer Use 软光标的逆向),见 `scripts/assets/NOTICE.md`。
- 交互动作模型对齐 **OpenAI computer‑use** 工具规范。

## License

MIT — 见 [LICENSE](./LICENSE)。
