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

  term.open(document.getElementById("terminalHost"));
  if (fitAddon) fitAddon.fit();

  // Keystrokes go to the guest as raw bytes.
  term.onData((data) => {
    termBridge.send("terminalInput", { data: bytesToBase64(data) });
  });

  if (termBridge.available) {
    termBridge.send("terminalReady", { cols: term.cols, rows: term.rows });
    setTerminalState("已连接");
  } else {
    // Browser preview: show something so the emulator itself can be checked.
    term.writeln("\x1b[2mPocketVM 预览\x1b[0m");
    term.writeln("\x1b[32mcodex@pocketvm\x1b[0m:\x1b[34m~\x1b[0m$ df -h /");
    term.writeln("Filesystem      Size  Used Avail Use% Mounted on");
    term.writeln("/dev/vda1        24G  1.2G   22G   5% /");
  }

  window.addEventListener("resize", () => {
    if (fitAddon) fitAddon.fit();
  });

  return term;
}

/// Called by the native bridge with serial output.
function terminalReceive(payload) {
  if (!term || !payload) return;
  if (typeof payload.base64 === "string") {
    term.write(base64ToBytes(payload.base64));
  }
}

function setTerminalState(text) {
  const el = document.getElementById("terminalState");
  if (el) el.textContent = text;
}
