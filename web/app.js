// Frontend for PocketVM.
//
// The layout and tokens follow the desktop app's own stylesheet, but nothing
// here is copied from its bundle: the desktop renderer is closed source and is
// wired to Electron IPC that does not exist on iOS.
//
// Two runtimes are supported. Inside the app a native bridge named `pocketvm`
// owns the VM configuration. Opened directly in a browser the same calls fall
// back to localStorage so the UI can be worked on without a device.

const bridge = {
  get available() {
    return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pocketvm);
  },
  send(action, payload) {
    if (this.available) {
      window.webkit.messageHandlers.pocketvm.postMessage({ action, payload });
      return null;
    }
    return null;
  },
};

// Answers arriving from native land here.
window.pocketvmReceive = function (message) {
  if (!message || typeof message !== "object") return;
  if (message.action === "config") {
    applyConfig(message.payload);
  } else if (message.action === "status") {
    setStatus(message.payload);
  } else if (message.action === "messages") {
    renderMessages(message.payload || []);
  } else if (message.action === "terminalOutput") {
    terminalReceive(message.payload);
  } else if (message.action === "terminalState") {
    setTerminalState(message.payload && message.payload.text);
  } else if (message.action === "provisionState") {
    renderProvisionState(message.payload || {});
  } else if (message.action === "authState") {
    renderAuthState(message.payload || {});
  }
};

const DEFAULT_CONFIG = {
  version: 1,
  name: "Debian",
  cpuCount: 4,
  memoryMiB: 4096,
  jitCacheMiB: 256,
  forceMulticore: false,
  boot: { mode: "uefi" },
  drives: [
    { path: "efi_vars.fd", interface: "pflash", readOnly: false },
    { path: "debian.qcow2", interface: "virtio", readOnly: false },
  ],
  network: { enabled: true, portForwards: [] },
};

let currentConfig = structuredClone(DEFAULT_CONFIG);
let pendingConfig = null;

// ------------------------------------------------------------------ threads

const THREADS = [
  { title: "虚拟机", active: true },
  { title: "安装 Debian", active: false },
  { title: "配置网络", active: false },
];

function renderThreads() {
  const list = document.getElementById("threadList");
  list.innerHTML = "";
  for (const t of THREADS) {
    const li = document.createElement("li");
    li.textContent = t.title;
    if (t.active) li.classList.add("active");
    li.addEventListener("click", () => {
      document.getElementById("threadTitle").textContent = t.title;
      document.getElementById("tabLabel").textContent = t.title;
    });
    list.appendChild(li);
  }
}

// ----------------------------------------------------------------- messages

function icon(name) {
  const paths = {
    tool: '<path d="M3.2 8.2l3 3 6.6-6.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>',
    info: '<circle cx="8" cy="8" r="5.6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M8 7.2v3.4M8 5.2v.1" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>',
  };
  return `<svg viewBox="0 0 16 16">${paths[name] || ""}</svg>`;
}

function renderMessages(messages) {
  const box = document.getElementById("messages");
  box.innerHTML = "";

  if (!messages.length) {
    const empty = document.createElement("div");
    empty.className = "status-row";
    empty.textContent = "还没有消息。启动虚拟机后这里会显示运行状态。";
    box.appendChild(empty);
    return;
  }

  for (const m of messages) {
    if (m.role === "user") {
      const el = document.createElement("div");
      el.className = "user-msg";
      el.innerHTML = `<p>${escapeHTML(m.text)}</p>`;
      box.appendChild(el);
    } else if (m.role === "tool") {
      const el = document.createElement("div");
      el.className = "tool-row";
      el.innerHTML = `${icon("tool")}<span>${escapeHTML(m.text)}</span>`;
      box.appendChild(el);
    } else if (m.role === "status") {
      const el = document.createElement("div");
      el.className = "status-row";
      el.textContent = m.text;
      box.appendChild(el);
    } else {
      const el = document.createElement("div");
      el.className = "assistant-msg";
      el.innerHTML = `<p>${escapeHTML(m.text)}</p>`;
      box.appendChild(el);
    }
  }
  box.scrollTop = box.scrollHeight;
}

function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function setStatus(status) {
  const box = document.getElementById("messages");
  const el = document.createElement("div");
  el.className = "status-row";
  el.textContent = status;
  box.appendChild(el);
  box.scrollTop = box.scrollHeight;
  document.getElementById("modelName").textContent = status.running === false ? "已停止" : "运行中";
}

// ---------------------------------------------------------------- composer

function wireComposer() {
  const input = document.getElementById("composerInput");
  const send = document.getElementById("sendBtn");

  const autosize = () => {
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 140) + "px";
  };
  input.addEventListener("input", autosize);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  });
  send.addEventListener("click", submit);

  function submit() {
    const text = input.value.trim();
    if (!text) return;
    appendLocal({ role: "user", text });
    input.value = "";
    autosize();
    bridge.send("prompt", { text });
  }
}

function appendLocal(message) {
  const box = document.getElementById("messages");
  if (box.querySelector(".status-row") && box.children.length === 1) box.innerHTML = "";
  const el = document.createElement("div");
  el.className = message.role === "user" ? "user-msg" : "assistant-msg";
  el.innerHTML = `<p>${escapeHTML(message.text)}</p>`;
  box.appendChild(el);
  box.scrollTop = box.scrollHeight;
}

// ---------------------------------------------------------------- settings

function openSettings() {
  pendingConfig = structuredClone(currentConfig);
  applyConfigToForm(pendingConfig);
  document.getElementById("settingsSheet").hidden = false;
}

function closeSettings() {
  document.getElementById("settingsSheet").hidden = true;
  pendingConfig = null;
}

function applyConfig(cfg) {
  currentConfig = Object.assign(structuredClone(DEFAULT_CONFIG), cfg || {});
  document.getElementById("tabLabel").textContent = currentConfig.name || "虚拟机";
  document.getElementById("threadTitle").textContent = currentConfig.name || "虚拟机";
  if (pendingConfig) {
    pendingConfig = structuredClone(currentConfig);
    applyConfigToForm(pendingConfig);
  }
}

function applyConfigToForm(cfg) {
  document.getElementById("cfgName").value = cfg.name ?? "";
  document.getElementById("cfgCpu").value = cfg.cpuCount ?? 4;
  document.getElementById("cfgMem").value = cfg.memoryMiB ?? 4096;
  document.getElementById("cfgJit").value = cfg.jitCacheMiB ?? 512;
  document.getElementById("cfgMulti").checked = cfg.forceMulticore !== false;

  const drives = document.getElementById("cfgDrives");
  drives.innerHTML = "";
  for (const d of cfg.drives || []) {
    const row = document.createElement("div");
    row.className = "drive";
    row.innerHTML = `<span class="path">${escapeHTML(d.path)}</span><span class="kind">${escapeHTML(d.interface)}</span>`;
    drives.appendChild(row);
  }
  if (!(cfg.drives || []).length) {
    drives.innerHTML = '<div class="drive"><span class="path">未添加磁盘</span></div>';
  }
}

function collectForm() {
  const cfg = structuredClone(pendingConfig || currentConfig);
  cfg.name = document.getElementById("cfgName").value.trim() || "虚拟机";
  cfg.cpuCount = clamp(parseInt(document.getElementById("cfgCpu").value, 10), 1, 16, 4);
  cfg.memoryMiB = clamp(parseInt(document.getElementById("cfgMem").value, 10), 128, 16384, 4096);
  cfg.jitCacheMiB = clamp(parseInt(document.getElementById("cfgJit").value, 10), 16, 4096, 512);
  cfg.forceMulticore = document.getElementById("cfgMulti").checked;
  return cfg;
}

function clamp(value, lo, hi, fallback) {
  if (Number.isNaN(value)) return fallback;
  return Math.min(Math.max(value, lo), hi);
}

// --------------------------------------------------------------- run state
//
// The native side owns both state machines and pushes them here. Nothing in
// this file decides what the VM is doing; it only shows it and asks for
// transitions, which keeps one author of truth for anything that touches the
// emulator.

function renderProvisionState(state) {
  const vmState = document.getElementById("vmState");
  vmState.textContent = state.running ? "运行中" : state.busy ? "准备中" : "已停止";
  vmState.classList.toggle("live", !!state.running);

  document.getElementById("vmImage").textContent =
    `${state.image || "Debian"} · ${state.imageBytes || 0} GiB 磁盘`;
  document.getElementById("vmProvision").textContent = state.stage || "未准备";
  document.getElementById("vmPassword").textContent = state.password || "—";

  const progress = document.getElementById("vmProgress");
  const bar = document.getElementById("vmProgressBar");
  if (typeof state.fraction === "number") {
    progress.hidden = false;
    bar.style.width = Math.round(Math.min(Math.max(state.fraction, 0), 1) * 100) + "%";
  } else {
    progress.hidden = true;
  }

  document.getElementById("vmStart").disabled = !!state.running || !!state.busy;
  document.getElementById("vmRestart").disabled = !state.running;
  document.getElementById("vmStop").disabled = !state.running;
  document.getElementById("modelName").textContent = state.running ? "运行中" : "已停止";
}

function renderAuthState(state) {
  const label = document.getElementById("authState");
  const hint = document.getElementById("authHint");
  const device = document.getElementById("authDevice");
  const url = document.getElementById("authURL");
  const code = document.getElementById("authCodeValue");

  const labels = {
    unknown: "未知",
    signedOut: "未登录",
    starting: "请求中",
    awaiting: "等待确认",
    signedIn: "已登录",
    failed: "失败",
  };
  label.textContent = labels[state.state] || "未知";
  label.classList.toggle("live", state.state === "signedIn");

  if (state.state === "awaiting" && state.url && state.code) {
    device.hidden = false;
    url.textContent = state.url;
    url.dataset.url = state.url;
    code.textContent = state.code;
    hint.textContent = "在浏览器里确认后，客户机里的 Codex 会自动完成登录。";
    return;
  }

  device.hidden = true;
  const hints = {
    signedIn: "客户机里的 Codex 已经登录，可以直接使用。",
    signedOut: "客户机里的 Codex 尚未登录。",
    starting: "正在向客户机请求设备代码…",
    failed: state.reason || "登录失败。",
  };
  hint.textContent = hints[state.state] || "登录在客户机内的 Codex CLI 上完成，这里负责把代码和链接显示出来。";
}

// --------------------------------------------------------------- bootstrap

function main() {
  renderThreads();
  wireComposer();
  applyConfig(currentConfig);

  document.getElementById("openSettings").addEventListener("click", openSettings);
  document.getElementById("closeSettings").addEventListener("click", closeSettings);
  document.getElementById("revertConfig").addEventListener("click", () => {
    pendingConfig = structuredClone(currentConfig);
    applyConfigToForm(pendingConfig);
  });
  document.getElementById("saveConfig").addEventListener("click", () => {
    const cfg = collectForm();
    currentConfig = cfg;
    bridge.send("saveConfig", cfg);
    // The VM must be restarted for the new shape to take effect; the native
    // side owns that decision because only it knows whether a guest is live.
    appendLocal({ role: "status", text: "配置已保存，重启虚拟机后生效。" });
    closeSettings();
  });
  document.getElementById("newThread").addEventListener("click", () => {
    appendLocal({ role: "status", text: "新对话。" });
  });
  document.getElementById("openTerminal").addEventListener("click", openTerminal);
  document.getElementById("closeTerminal").addEventListener("click", closeTerminal);

  document.getElementById("vmStart").addEventListener("click", () => bridge.send("start"));
  document.getElementById("vmStop").addEventListener("click", () => bridge.send("stop"));
  document.getElementById("vmRestart").addEventListener("click", () => bridge.send("restart"));
  document.getElementById("authLogin").addEventListener("click", () => bridge.send("codexLogin"));
  document.getElementById("authRefresh").addEventListener("click", () => bridge.send("codexLoginStatus"));
  document.getElementById("authURL").addEventListener("click", (event) => {
    const target = event.currentTarget.dataset.url;
    if (target) bridge.send("openURL", { url: target });
  });
  document.getElementById("resetProvision").addEventListener("click", () => {
    bridge.send("resetProvision");
    closeSettings();
  });

  // Ask native for the authoritative config. In a browser this falls through
  // and the built-in defaults stay on screen.
  if (bridge.available) {
    bridge.send("getConfig");
    bridge.send("getMessages");
    bridge.send("getProvisionState");
  } else {
    renderMessages([{ role: "status", text: "浏览器预览模式：配置存在本机内存中。" }]);
    renderProvisionState({ image: "Debian 13 · aarch64", imageBytes: 24, stage: "未准备", password: "000000" });
    renderAuthState({ state: "signedOut" });
  }
}

document.addEventListener("DOMContentLoaded", main);
