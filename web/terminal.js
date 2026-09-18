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
    termBridge.send("terminalInput", { data: bytesToBase64(applyCtrl(data)) });
  });

  return term;
}

/// Attaches the emulator to the panel and hands it everything that arrived
/// while it was closed. Called when the bottom panel is shown.
function openTerminal() {
  const host = document.getElementById("terminalHost");
  const terminal = ensureTerminal();
  if (!host) return terminal;

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
      setTerminalState("已连接");
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
  }

  for (const chunk of pending) terminal.write(chunk);
  pending = [];
  pendingBytes = 0;
  if (fitAddon) fitAddon.fit();
  terminal.refresh(0, terminal.rows - 1);
  return terminal;
}

/// Called by the native bridge with serial output.
function terminalReceive(payload) {
  if (!payload) return;
  if (typeof payload.base64 !== "string") return;
  const bytes = base64ToBytes(payload.base64);
  if (!opened) {
    // Keep the tail until somebody opens the panel.
    pending.push(bytes);
    pendingBytes += bytes.length;
    while (pendingBytes > PENDING_LIMIT && pending.length > 1) {
      pendingBytes -= pending.shift().length;
    }
    return;
  }
  term.write(bytes);
}

function setTerminalState(text) {
  const el = document.getElementById("terminalState");
  if (el) el.textContent = text;
}
