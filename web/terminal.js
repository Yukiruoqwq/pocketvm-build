// Terminal emulator for the guest's serial console.
//
// The serial line carries arbitrary bytes, so output crosses the bridge as
// base64 and is written to xterm as a Uint8Array. Decoding to a JavaScript
// string on the way would corrupt anything that is not valid UTF-8 -- which
// includes nearly every escape sequence boundary.

const termBridge = {
  get available() {
    return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pocketvm);
  },
  send(action, payload) {
    if (this.available) {
      window.webkit.messageHandlers.pocketvm.postMessage({ action, payload });
    }
  },
};

let term = null;
let fitAddon = null;
let opened = false;
const terminalReplay = new TerminalReplay();
/// The first write is the one worth reporting: everything before the panel is
/// opened is buffered, so "the console is empty" and "the bytes never reached
/// the page" look identical from here.
let loggedFirstWrite = false;
/// Output that arrived before the panel was ever on screen. The console starts
/// printing at boot, long before anyone opens it, so throwing that away would
/// leave the panel empty exactly when somebody finally looks.
let pending = [];
let pendingBytes = 0;
const PENDING_LIMIT = 4 * 1024 * 1024;

/// The bytes a terminal sends for keys the iPad keyboard does not have.
const KEY_BYTES = {
  escape: "\x1b",
  tab: "\t",
  "shift-tab": "\x1b[Z",
  "ctrl-c": "\x03",
  "ctrl-d": "\x04",
  "ctrl-z": "\x1a",
  "ctrl-l": "\x0c",
  "arrow-up": "\x1b[A",
  "arrow-down": "\x1b[B",
  "arrow-right": "\x1b[C",
  "arrow-left": "\x1b[D",
};

/// Ctrl held for the next key, the way a real keyboard chord works: press ctrl,
/// then a letter, and the guest sees that letter's control code.
let ctrlLatched = false;

function base64ToBytes(b64) {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

/// Applies a latched Ctrl to the next printable key, and to nothing else.
function applyCtrl(data) {
  if (!ctrlLatched || data.length !== 1) return data;
  const code = data.toLowerCase().charCodeAt(0);
  if (code < 97 || code > 122) return data;
  ctrlLatched = false;
  updateCtrlKey();
  return String.fromCharCode(code - 96);
}

function updateCtrlKey() {
  const button = document.getElementById("ctrlKey");
  if (button) button.setAttribute("aria-pressed", ctrlLatched ? "true" : "false");
}

/// One of the extra keys: a fixed byte sequence, or the Ctrl latch.
function sendKey(name) {
  if (terminalReplay.active) return;
  if (name === "ctrl") {
    ctrlLatched = !ctrlLatched;
    updateCtrlKey();
    return;
  }
  const data = KEY_BYTES[name];
  if (data === undefined) return;
  // A chord button is a complete keystroke, so it clears a pending Ctrl.
  if (ctrlLatched) {
    ctrlLatched = false;
    updateCtrlKey();
  }
  termBridge.send("terminalInput", { data: bytesToBase64(data) });
}

function wireKeyRow() {
  if (wireKeyRow.done) return;
  wireKeyRow.done = true;
  const row = document.getElementById("keyRow");
  if (!row) return;
  row.addEventListener("click", (event) => {
    const key = event.target.closest(".key");
    if (key) sendKey(key.dataset.key);
  });
  updateCtrlKey();
}

/// Builds the emulator. It is not attached to the page here: a terminal opened
/// into a hidden panel measures zero, and its size is what decides how many
/// rows are drawn, so it is opened the first time it is actually visible.
function ensureTerminal() {
  if (term) return term;
  term = new Terminal({
    convertEol: false,
    cursorBlink: true,
    scrollback: 5000,
    fontFamily: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
    fontSize: 13,
    theme: {
      background: "#0d0d0d",
      foreground: "#ececec",
      cursor: "#ececec",
      selectionBackground: "#3a3a3a",
      black: "#1b1b1b",
      red: "#ff5f57",
      green: "#3ecf8e",
      yellow: "#f2c14e",
      blue: "#5aa9e6",
      magenta: "#c792ea",
      cyan: "#5ad4e6",
      white: "#ececec",
    },
  });

  if (window.FitAddon) {
    fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
  }

  // Keystrokes go to the guest as raw bytes.
  term.onData((data) => {
    if (terminalReplay.active) return;
    termBridge.send("terminalInput", { data: bytesToBase64(applyCtrl(data)) });
  });

  return term;
}

/// Attaches the emulator to the panel and hands it everything that arrived
/// while it was closed. Called when the bottom panel is shown.
function openTerminal() {
  const host = document.getElementById("terminalHost");
  if (!host) return null;

  // A terminal that could not be built looks exactly like a guest that said
  // nothing: an empty panel. Saying so, here and in the host's log, is the
  // difference between a bug report and a diagnosis, so the whole of the
  // mounting is guarded rather than only the constructor.
  try {
    return mountTerminal(host);
  } catch (error) {
    if (!host.dataset.failed) {
      host.dataset.failed = "1";
      host.textContent = `终端不可用：${error}`;
      pageError = `终端不可用：${error}`;
      refreshTerminalState();
      termBridge.send("note", { text: `终端不可用：${error}` });
    }
    return null;
  }
}

function mountTerminal(host) {
  const terminal = ensureTerminal();

  if (!opened) {
    terminal.open(host);
    opened = true;
    if (termBridge.available) {
      termBridge.send("terminalReady", { cols: terminal.cols, rows: terminal.rows });
      // The host logs this: it is the only way to tell "the panel never opened"
      // apart from "the console bytes never arrived".
      termBridge.send("terminalOpened", {
        cols: terminal.cols,
        rows: terminal.rows,
        pending: pending.length,
      });
      refreshTerminalState();
    } else {
      // Browser preview: something to look at so the emulator itself can be
      // checked.
      terminal.writeln("\x1b[2mPocketVM 预览\x1b[0m");
      terminal.writeln("\x1b[32mcodex@pocketvm\x1b[0m:\x1b[34m~\x1b[0m$ df -h /");
      terminal.writeln("Filesystem      Size  Used Avail Use% Mounted on");
      terminal.writeln("/dev/vda1        24G  1.2G   22G   5% /");
    }
    window.addEventListener("resize", () => {
      if (fitAddon) fitAddon.fit();
      terminal.refresh(0, terminal.rows - 1);
    });
    // The panel is shown, then the emulator is opened. On a layout that has not
    // settled the first measurement can still be zero rows — which draws
    // nothing at all and looks exactly like a console with no output. Measuring
    // again once the frame is up costs nothing.
    window.setTimeout(() => {
      try {
        if (fitAddon) fitAddon.fit();
        terminal.refresh(0, Math.max(0, terminal.rows - 1));
      } catch (error) {
        pageError = `终端尺寸测量失败：${error}`;
      }
      refreshTerminalState();
    }, 250);
  }

  terminalReplay.write(terminal, pending);
  pending = [];
  pendingBytes = 0;
  if (fitAddon) fitAddon.fit();
  terminal.refresh(0, terminal.rows - 1);
  refreshTerminalState();
  return terminal;
}

/// Called by the native bridge with serial output.
function terminalReceive(payload) {
  if (!payload) return;
  if (typeof payload.base64 !== "string") return;
  const bytes = base64ToBytes(payload.base64);
  receivedBytes += bytes.length;
  if (!opened) {
    // Keep the tail until somebody opens the panel.
    pending.push(bytes);
    pendingBytes += bytes.length;
    refreshTerminalState();
    while (pendingBytes > PENDING_LIMIT && pending.length > 1) {
      pendingBytes -= pending.shift().length;
    }
    return;
  }
  refreshTerminalState();
  if (!loggedFirstWrite) {
    loggedFirstWrite = true;
    termBridge.send("note", {
      text: `terminal first write ${bytes.length} bytes at ${term.cols}x${term.rows}`,
    });
  }
  term.write(bytes);
}

// Anything the page throws is otherwise invisible from the host: the panel just
// stays blank and there is nothing to read afterwards.
window.addEventListener("error", (event) => {
  pageError = `页面错误：${event.message}`;
  refreshTerminalState();
  termBridge.send("note", {
    text: `page error ${event.message} @ ${event.filename}:${event.lineno}`,
  });
});
window.addEventListener("unhandledrejection", (event) => {
  termBridge.send("note", { text: `page rejection ${event.reason}` });
});

function setTerminalState(text) {
  const el = document.getElementById("terminalState");
  if (el) el.textContent = text;
}

/// Everything the console can say about itself, on one line.
///
/// It is the only place the *page* can be asked a question the host cannot
/// answer from outside: whether the bytes arrived and were drawn, or never
/// arrived at all. Two numbers do that — bytes received, and the size the
/// emulator was given.
let receivedBytes = 0;
let pageError = "";

// The terminal is a real work surface, not a status strip. Keep its height in
// one CSS variable so xterm, the key row and the iPad keyboard all participate
// in the same layout calculation.
let terminalPanelWired = false;
let terminalPanelMaximized = false;

function fitTerminalViewport() {
  if (!term || !opened) return;
  try {
    if (fitAddon) fitAddon.fit();
    term.refresh(0, Math.max(0, term.rows - 1));
    refreshTerminalState();
  } catch (error) {
    pageError = `终端尺寸测量失败：${error}`;
    refreshTerminalState();
  }
}

function updateKeyboardInset() {
  const viewport = window.visualViewport;
  if (!viewport) return;
  document.documentElement.style.setProperty("--terminal-available-height", `${Math.max(0, viewport.height - 52)}px`);
  const inset = Math.max(0, Math.round(window.innerHeight - viewport.height - viewport.offsetTop));
  document.documentElement.style.setProperty("--keyboard-offset", `${inset}px`);
  window.requestAnimationFrame(fitTerminalViewport);
}

function wireTerminalPanel() {
  if (terminalPanelWired) return;
  terminalPanelWired = true;
  const panel = document.getElementById("bottomPanel");
  const handle = document.getElementById("terminalResizeHandle");
  const fit = document.getElementById("terminalFit");
  const maximize = document.getElementById("terminalMaximize");
  if (!panel || !handle) return;

  let saved = NaN;
  try { saved = Number.parseInt(localStorage.getItem("pocketvm.terminalHeight"), 10); } catch (_) { /* private browsing */ }
  if (Number.isFinite(saved)) document.documentElement.style.setProperty("--terminal-height", `${Math.max(190, Math.min(saved, window.innerHeight - 64))}px`);

  let startY = 0;
  let startHeight = 0;
  handle.addEventListener("pointerdown", (event) => {
    if (terminalPanelMaximized) return;
    startY = event.clientY;
    startHeight = panel.getBoundingClientRect().height;
    handle.setPointerCapture(event.pointerId);
    document.body.classList.add("resizing-terminal");
  });
  handle.addEventListener("pointermove", (event) => {
    if (!handle.hasPointerCapture(event.pointerId)) return;
    const next = Math.max(190, Math.min(window.innerHeight - 64, startHeight + startY - event.clientY));
    document.documentElement.style.setProperty("--terminal-height", `${Math.round(next)}px`);
    fitTerminalViewport();
  });
  handle.addEventListener("pointercancel", () => document.body.classList.remove("resizing-terminal"));
  handle.addEventListener("pointerup", (event) => {
    if (handle.hasPointerCapture(event.pointerId)) handle.releasePointerCapture(event.pointerId);
    document.body.classList.remove("resizing-terminal");
    const height = Math.round(panel.getBoundingClientRect().height);
    try { localStorage.setItem("pocketvm.terminalHeight", String(height)); } catch (_) { /* private browsing */ }
  });
  handle.addEventListener("keydown", (event) => {
    if (!["ArrowUp", "ArrowDown"].includes(event.key)) return;
    event.preventDefault();
    const current = panel.getBoundingClientRect().height;
    const delta = event.key === "ArrowUp" ? 48 : -48;
    const next = Math.max(190, Math.min(window.innerHeight - 64, current + delta));
    document.documentElement.style.setProperty("--terminal-height", `${Math.round(next)}px`);
    fitTerminalViewport();
  });
  fit?.addEventListener("click", fitTerminalViewport);
  maximize?.addEventListener("click", () => {
    terminalPanelMaximized = !terminalPanelMaximized;
    panel.classList.toggle("maximized", terminalPanelMaximized);
    maximize.setAttribute("aria-pressed", terminalPanelMaximized ? "true" : "false");
    window.requestAnimationFrame(fitTerminalViewport);
  });
  const viewport = window.visualViewport;
  viewport?.addEventListener("resize", updateKeyboardInset);
  viewport?.addEventListener("scroll", updateKeyboardInset);
  window.addEventListener("resize", updateKeyboardInset);
  updateKeyboardInset();
}

function formatBytes(count) {
  if (count < 1024) return `${count} 字节`;
  if (count < 1024 * 1024) return `${(count / 1024).toFixed(1)} KB`;
  return `${(count / (1024 * 1024)).toFixed(1)} MB`;
}

function refreshTerminalState() {
  const el = document.getElementById("terminalState");
  if (!el) return;
  if (pageError) {
    el.textContent = pageError;
    return;
  }
  if (!opened) {
    el.textContent = receivedBytes ? `未连接 · 已缓存 ${formatBytes(receivedBytes)}` : "未连接";
    return;
  }
  const size = term ? `${term.cols}×${term.rows}` : "?";
  if (term && term.rows < 2) {
    el.textContent = `终端尺寸为 0（${size}）· 收到 ${formatBytes(receivedBytes)}`;
    return;
  }
  el.textContent = `已连接 ${size} · 收到 ${formatBytes(receivedBytes)}`;
}
