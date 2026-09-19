let promptBusy = false;
let pendingAttachments = [];
// Frontend for PocketVM.
//
// Layout, wording and theme follow the desktop app: the strings come out of its
// own zh-CN bundle (计划 / 输出内容 / 来源 / 终端 / 切换侧边栏 …), the colour
// ramp and type scale come out of its stylesheet, and light/dark follow the
// system setting the way the iPad does.
//
// Inside the app a native bridge named `pocketvm` owns the VM. The same file
// runs in a plain browser for review, where the calls fall back to sample data.

const bridge = {
  get available() {
    return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pocketvm);
  },
  send(action, payload) {
    if (this.available) window.webkit.messageHandlers.pocketvm.postMessage({ action, payload });
  },
};

const preview = !bridge.available;
/// Review only: `?demo=1` fills the panes with sample content. Without it the
/// preview looks exactly like the device — no conversation, no files, nothing
/// that is not there.
const SHOW_DEMO = preview && new URLSearchParams(location.search).has("demo");

// Preview only: the shape is the guest's own answer to `model/list`, filled
// with what a real Codex account reported when it was asked. Nothing here is
// invented — on the device the list arrives from the account, and before it
// does the menu says so instead of offering something made up.
const PREVIEW_MODELS = [
  {
    id: "gpt-5.5",
    displayName: "GPT-5.5",
    description: "Frontier model for complex coding, research, and real-world work.",
    defaultReasoningEffort: "medium",
    supportedReasoningEfforts: [
      { reasoningEffort: "low" },
      { reasoningEffort: "medium" },
      { reasoningEffort: "high" },
      { reasoningEffort: "xhigh" },
    ],
    additionalSpeedTiers: ["fast"],
    isDefault: true,
  },
  {
    id: "gpt-5.4-mini",
    displayName: "GPT-5.4-Mini",
    description: "Small, fast, and cost-efficient model for simpler coding tasks.",
    defaultReasoningEffort: "medium",
    supportedReasoningEfforts: [
      { reasoningEffort: "low" },
      { reasoningEffort: "medium" },
      { reasoningEffort: "high" },
      { reasoningEffort: "xhigh" },
    ],
    additionalSpeedTiers: [],
    isDefault: false,
  },
  {
    id: "codex-auto-review",
    displayName: "Codex Auto Review",
    description: "Automatic approval review model for Codex.",
    defaultReasoningEffort: "medium",
    supportedReasoningEfforts: [
      { reasoningEffort: "low" },
      { reasoningEffort: "medium" },
      { reasoningEffort: "high" },
      { reasoningEffort: "xhigh" },
    ],
    additionalSpeedTiers: [],
    isDefault: false,
  },
];

// ------------------------------------------------------------------- state

// Sample data for the browser preview: the same shape the bridge delivers.
const state = {
  provision: {
    stage: "准备完成",
    busy: false,
    running: true,
    provisioned: true,
    codexReady: true,
    image: "Debian 13 · aarch64",
    imageBytes: 24,
    host: "cloud.debian.org",
    detail: "正在启动 Codex CLI",
    password: "258716",
  },
  auth: { state: "signedIn" },
  // 外观: settings.general.appearance.theme — 浅色 / 深色 / 跟随系统. The
  // last one is the system setting the iPad switches by itself.
  appearance: preview ? localStorage.getItem("pocketvm.appearance") || "system" : "system",
  config: {
    version: 1,
    name: "Debian 13 · aarch64",
    cpuCount: 4,
    memoryMiB: 4096,
    jitCacheMiB: 256,
    forceMulticore: false,
    boot: { mode: "uefi" },
    drives: [
      { path: "efi_vars.fd", interface: "pflash", readOnly: false },
      { path: "Images/debian-13-genericcloud-arm64.qcow2", interface: "virtio", readOnly: false },
    ],
    network: { enabled: true, portForwards: [] },
  },
  messages: SHOW_DEMO
    ? [
        { role: "user", text: "在这台 iPad 上跑一个 Linux 虚拟机，里面装好 Codex。" },
        { role: "tool", text: "正在运行命令 · cloud-init", running: false },
        { role: "status", text: "已处理 3 分 29 秒" },
        { role: "assistant", text: "客户机已就绪：Debian 13 aarch64，24 GiB 磁盘，Codex CLI 0.155.0。" },
      ]
    : [],
  // 计划 — the setup the emulator is performing. It exists while the guest is
  // being installed and not afterwards: a machine that is simply running has no
  // plan, and inventing one is what made this pane look like a demo.
  plan: [],
  // 输出内容 — the files this machine really wrote, listed by the host.
  // The account behind the CLI inside the guest: its address and plan, as the
  // guest's own app server reported them.
  account: null,
  /// The build this page is running inside, as the host reported it.
  version: "",
  // 剩余额度 — whatever the guest's Codex account reported. Null means it has
  // not said anything yet, which is not the same as "no limits left".
  limits: SHOW_DEMO
    ? {
        rateLimits: {
          primary: { usedPercent: 37, windowDurationMins: 10080, resetsAt: Math.floor(Date.now() / 1000) + 3 * 86400 },
          secondary: { usedPercent: 62, windowDurationMins: 300, resetsAt: Math.floor(Date.now() / 1000) + 7200 },
        },
      }
    : null,
  threads: SHOW_DEMO
    ? [
        { title: "虚拟机", active: true },
        { title: "准备 Debian 客户机", running: true },
        { title: "Codex 登录", active: false },
      ]
    : [],
  // 推理 — the composer's model control. The list is never written down here:
  // it is whatever the guest's Codex account answered, so an account with no
  // models yet shows no models.
  model: {
    id: null,
    effort: "medium",
    speed: "standard",
    models: preview ? PREVIEW_MODELS : [],
    loading: false,
    error: null,
  },
  // 定时任务 — the same shape the app's scheduled-task list uses.
  automations: preview
    ? [
        {
          id: "a1",
          title: "每天早上 7:30 生成工作简报",
          cadence: "weekdays",
          time: "07:30",
          status: "active",
          nextRun: "明天 07:30",
        },
        {
          id: "a2",
          title: "监控 PocketVM 构建",
          cadence: "daily",
          time: "22:00",
          status: "paused",
          lastRun: "2026-09-16 22:00",
        },
      ]
    : [],
};

let automationFilter = "all";
let automationDraft = null;
/// Review only: `?gate=…` in the browser preview picks a card to look at.
let forcedGate = null;
/// The gate stays up until the host has said what the machine is doing: the
/// sample state below is the preview's, not the device's.
let provisionKnown = preview;

const settingsPages = [
  { id: "general", title: "常规" },
  { id: "vm", title: "虚拟机" },
  { id: "account", title: "账号" },
  { id: "about", title: "关于" },
];

let activePage = "vm";
let draft = null;

// -------------------------------------------------------------------- util

const $ = (id) => document.getElementById(id);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// ------------------------------------------------------------ provisioning

// The plan section is the setup the emulator actually performs, in order, with
// the step the guest is on right now marked.
const PLAN_STEPS = [
  "下载并校验系统镜像",
  "写入 UEFI 变量存储",
  "扩展虚拟磁盘",
  "启动并等待 cloud-init",
  "安装 Node 与 Codex CLI",
];

function planState(stage, index) {
  if (state.provision.provisioned) return "done";
  const order = ["preparing", "booting", "installing"];
  const reached = order.indexOf(stage);
  if (reached === -1) return index === 0 ? "active" : "";
  if (index < reached) return "done";
  return index === reached ? "active" : "";
}

function renderPlan() {
  const list = $("planList");
  list.innerHTML = "";
  // Only while the guest is being installed: the app is behind the gate then,
  // and once it is in front of it the machine is up and there is nothing left
  // to plan.
  if (state.provision.provisioned) return;
  PLAN_STEPS.forEach((text, index) => {
    const row = el("li", planState(state.provision.stage, index), text);
    list.appendChild(row);
  });
}

// ------------------------------------------------------------ 侧边面板

// 计划 — the setup the emulator is performing, and nothing else: the machine's
// own files are not a conversation's outputs, and the image it was built from
// is not one of its sources. Closed unless the user opens it: entering the app
// is a new conversation, and a new conversation has no column beside it.
let sidePanelChoice = null;

const isNarrow = () => window.matchMedia("(max-width: 1100px)").matches;

function sidePanelHasContent() {
  return !state.provision.provisioned;
}

function sidePanelOpen() {
  return isNarrow() ? $("app").classList.contains("panel-open") : !$("app").classList.contains("no-panel");
}

function setSidePanel(open) {
  if (isNarrow()) $("app").classList.toggle("panel-open", open);
  else $("app").classList.toggle("no-panel", !open);
  $("toggleSidePanel").setAttribute("aria-pressed", open ? "true" : "false");
  $("menuSidePanel").checked = open;
}

/// The user's own choice wins. Until there is one, the panel follows its
/// content instead of being permanently on or permanently in the way.
function syncSidePanel() {
  setSidePanel(sidePanelChoice ?? false);
}

// ------------------------------------------------------------- conversation

function renderMessages() {
  const box = $("messages");
  box.innerHTML = "";
  // The app's new-thread page is the composer centred in the middle of the
  // window; it moves to the bottom once the thread has anything in it.
  document.querySelector(".conversation").classList.remove("is-home");
  const column = document.createElement("div");
  column.className = "thread-column";
  for (const message of state.messages) {
    if (message.role === "user") {
      const wrap = el("div", "user-msg");
      wrap.appendChild(el("p", null, message.text));
      column.appendChild(wrap);
      continue;
    }
    if (message.role === "tool") {
      const row = el("div", message.running ? "tool-row running" : "tool-row");
      row.innerHTML = '<svg viewBox="0 0 16 16"><path d="M3.2 8.2l3 3 6.6-6.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
      row.appendChild(el("span", null, message.text));
      column.appendChild(row);
      continue;
    }
    if (message.role === "error") { column.appendChild(el("div", "conversation-error", message.text)); continue; }
    if (message.role === "status") {
      column.appendChild(el("div", "meta-row", message.text));
      continue;
    }
    const wrap = el("div", "assistant-msg");
    wrap.appendChild(el("p", null, message.text));
    column.appendChild(wrap);
  }
  box.appendChild(column);
  box.scrollTop = box.scrollHeight;
}

function appendMessage(message) {
  state.messages.push(message);
  renderMessages();
}

// ------------------------------------------------------------- 推理

// 推理强度 — the labels the app itself uses
// (composer.mode.local.reasoning.<effort>.label).
const EFFORT_LABELS = {
  none: "无",
  minimal: "极低",
  low: "轻度",
  medium: "中",
  high: "高",
  xhigh: "极高",
  max: "最高",
  ultra: "Ultra",
  persistent: "持续",
};

function availableModels() {
  return (state.model.models ?? []).filter((entry) => !entry.hidden);
}

/// The model the menu is describing: the chosen one, or the account's default
/// while nothing has been chosen. Null until the guest has answered.
function selectedModel() {
  const list = availableModels();
  return (
    list.find((entry) => entry.id === state.model.id) ??
    list.find((entry) => entry.isDefault) ??
    list[0] ??
    null
  );
}

function supportedEfforts(model) {
  return (model?.supportedReasoningEfforts ?? []).map((entry) => entry.reasoningEffort ?? entry);
}

/// 快速 (1.5 倍速) is offered by the account per model, so the switch is only
/// there for a model that says it has the tier.
function supportsFast(model) {
  return (model?.additionalSpeedTiers ?? []).some((tier) => tier === "fast" || tier === "priority");
}

function effortLabel(effort) {
  return EFFORT_LABELS[effort] ?? effort ?? "";
}

function renderModelChip() {
  const model = selectedModel();
  // Before the account's models have arrived there is nothing to choose, so the
  // control is not offered at all rather than offering a guess.
  $("modelChip").hidden = false;
  $("modelName").textContent = model ? model.displayName ?? model.id : (state.model.loading ? "获取模型…" : "选择模型");
  $("modelEffort").textContent = model ? effortLabel(state.model.effort) : "";
}

function sendModelSelection() {
  bridge.send("setModel", {
    model: state.model.id,
    effort: state.model.effort,
    speed: state.model.speed,
  });
}

function renderModelMenu() {
  const model = selectedModel();
  const list = $("modelList");
  list.innerHTML = "";
  const entries = availableModels();
  if (!entries.length) {
    // Nothing is invented here: until the guest's Codex has answered with the
    // models this account can use, the menu says exactly that.
    const message = state.model.loading
      ? "正在获取模型…"
      : state.model.error || "未登录";
    list.appendChild(el("li", "model-menu-empty", message));
  }
  for (const entry of entries) {
    const row = el("li");
    const current = entry.id === (state.model.id ?? model?.id);
    row.setAttribute("aria-selected", current ? "true" : "false");
    const text = el("span", "model-row-text");
    text.appendChild(el("span", "model-row-title", entry.displayName ?? entry.id));
    row.title = entry.description ?? "";
    row.tabIndex = 0; row.setAttribute("role", "option");
    row.addEventListener("keydown", (event) => { if (["Enter", " "].includes(event.key)) { event.preventDefault(); chooseModel(entry.id); } });
    row.appendChild(text);
    if (current) row.appendChild(el("span", "menu-desc", "✓"));
    row.addEventListener("click", () => chooseModel(entry.id));
    list.appendChild(row);
  }

  const efforts = $("effortList");
  efforts.innerHTML = "";
  for (const effort of supportedEfforts(model)) {
    const option = el("option", null, effortLabel(effort));
    option.value = effort; option.selected = effort === state.model.effort;
    efforts.appendChild(option);
  }
  efforts.disabled = !efforts.options.length;

  // 速度 — 标准 / 快速 (1.5 倍速), the account's own service tier.
  const speedRow = $("speedRow");
  speedRow.hidden = !supportsFast(model);
  $("speedToggle").checked = state.model.speed === "fast";
}

function chooseModel(id) {
  state.model.id = id;
  const model = selectedModel();
  // The reasoning levels belong to the model, so a level the new one does not
  // offer cannot stay selected.
  const supported = supportedEfforts(model);
  if (supported.length && !supported.includes(state.model.effort)) {
    state.model.effort = model.defaultReasoningEffort ?? supported[0];
  }
  if (!supportsFast(model)) state.model.speed = "standard";
  sendModelSelection();
  renderModelChip();
  renderModelMenu();
}

/// The guest's answer to `model/list`.
function applyModels(payload) {
  state.model.models = payload?.models ?? [];
  state.model.error = payload?.error ?? null;
  state.model.loading = payload?.loading === true;
  if (state.model.id && !availableModels().some(entry => entry.id === state.model.id)) state.model.id = null;
  const model = selectedModel();
  if (model) {
    const supported = supportedEfforts(model);
    state.model.effort = supported.includes(state.model.effort)
      ? state.model.effort
      : model.defaultReasoningEffort ?? supported[0] ?? state.model.effort;
  }
  if (model && !state.model.loading) {
    state.model.id = model.id;
    if (!supportsFast(model)) state.model.speed = "standard";
    sendModelSelection();
  }
  renderModelChip();
  if (!$("modelMenu").hidden) { renderModelMenu(); positionModelMenu(); }
  if (!$("settings").hidden) renderSettings();
}

function closeModelMenu() {
  $("modelMenu").hidden = true;
  $("modelChip").setAttribute("aria-expanded", "false");
}

function positionModelMenu() {
  const menu = $("modelMenu");
  if (menu.hidden) return;
  const v = window.visualViewport;
  const left = v?.offsetLeft ?? 0, top = v?.offsetTop ?? 0;
  const width = v?.width ?? innerWidth, height = v?.height ?? innerHeight;
  const box = $("modelChip").getBoundingClientRect();
  const above = Math.max(0, Math.min(box.top, top + height) - top - 20);
  const below = Math.max(0, top + height - Math.max(box.bottom, top) - 20);
  const useAbove = above >= Math.min(260, height * .6) || above >= below;
  menu.style.width = `${Math.min(280, width - 24)}px`;
  menu.style.maxHeight = `${Math.max(0, useAbove ? above : below)}px`;
  menu.style.right = "auto"; menu.style.bottom = "auto";
  menu.style.left = `${Math.max(left + 12, Math.min(box.right - Math.min(280, width - 24), left + width - Math.min(280, width - 24) - 12))}px`;
  menu.style.top = `${useAbove ? Math.min(box.top - 8, top + height - 12) - menu.offsetHeight : Math.max(top + 12, box.bottom + 8)}px`;
}

function wireModelMenu() {
  const menu = $("modelMenu");
  const chip = $("modelChip");
  $("effortList").addEventListener("change", event => { state.model.effort = event.target.value; sendModelSelection(); renderModelChip(); });
  window.addEventListener("resize", positionModelMenu);
  window.visualViewport?.addEventListener("resize", positionModelMenu);
  window.visualViewport?.addEventListener("scroll", positionModelMenu);
  document.addEventListener("keydown", event => { if (event.key === "Escape") closeModelMenu(); });
  $("speedToggle").addEventListener("change", (event) => {
    state.model.speed = event.target.checked ? "fast" : "standard";
    sendModelSelection();
  });
  chip.addEventListener("click", (event) => {
    event.stopPropagation();
    const open = menu.hidden;
    menu.hidden = !open;
    chip.setAttribute("aria-expanded", open ? "true" : "false");
    if (!open) return;
    if (!availableModels().length && !state.model.loading) bridge.send("getModels");
    renderModelMenu();
    positionModelMenu();
  });
  document.addEventListener("click", (event) => {
    if (menu.hidden || menu.contains(event.target)) return;
    closeModelMenu();
  });
}

// 最近 — the conversation list, as the guest's Codex last reported it. The host
// caches it, so it is on screen while the machine is still booting and gets
// replaced the moment the guest answers again.
function threadTitle(thread) {
  return thread.name || thread.title || thread.preview || String(thread.id ?? "").slice(0, 8) || "未命名对话";
}

function relativeTime(stamp) {
  const raw = Number(stamp);
  if (!Number.isFinite(raw) || raw <= 0) return "";
  const ms = raw > 1e12 ? raw : raw * 1000;
  const diff = Date.now() - ms;
  if (diff < 60_000) return "刚刚";
  if (diff < 3_600_000) return `${Math.round(diff / 60_000)} 分钟前`;
  if (diff < 86_400_000) return `${Math.round(diff / 3_600_000)} 小时前`;
  return new Date(ms).toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
}

function renderThreads() {
  const list = $("threadList");
  list.innerHTML = "";
  for (const thread of state.threads) {
    const row = el("li", thread.active ? "active" : "");
    row.appendChild(el("span", "thread-title", threadTitle(thread)));
    const stamp = relativeTime(thread.updatedAt ?? thread.recencyAt ?? thread.createdAt);
    if (stamp) row.appendChild(el("span", "thread-time", stamp));
    row.addEventListener("click", () => {
      for (const other of list.querySelectorAll("li")) other.classList.remove("active");
      row.classList.add("active");
      $("threadTitle").textContent = threadTitle(thread);
      bridge.send("selectThread", { id: thread.id });
    });
    list.appendChild(row);
  }
}

// ----------------------------------------------------------------- sidebar

function renderAccount() {
  const signedIn = state.auth.state === "signedIn";
  const label = $("accountState");
  label.textContent = signedIn ? "已登录" : state.auth.state === "awaiting" ? "等待确认" : "未登录";
  label.classList.toggle("online", signedIn);

  const menuState = $("accountMenuState");
  menuState.textContent = label.textContent;
  menuState.classList.toggle("online", signedIn);
  const account = state.account ?? {};
  $("accountMenuName").textContent = account.email || account.account?.email || "PocketVM";
  renderUsage();
}

// 剩余额度 — the account's own windows, drawn as they were reported.

/// The label the app itself uses for a window: 5 小时 / 每周 / 每日 / 每月.
function windowLabel(minutes) {
  if (minutes === 300) return "5 小时使用限额";
  if (minutes === 1440) return "每日使用限额";
  if (minutes === 10080) return "每周使用限额";
  if (minutes >= 43200) return "每月使用限额";
  return "使用限额";
}

/// Every window the server actually sent, biggest first. A window that is null
/// or missing is left out: the app treats a missing number as unavailable, not
/// as a full quota.
function usageWindows() {
  const limits = state.limits;
  if (!limits || typeof limits !== "object") return [];
  const windows = [];
  const seen = new Set();
  const add = (bucket) => {
    if (!bucket || typeof bucket !== "object") return;
    const used = Number(bucket.usedPercent);
    const minutes = Number(bucket.windowDurationMins);
    if (!Number.isFinite(used)) return;
    const key = Number.isFinite(minutes) ? minutes : "unknown";
    if (seen.has(key)) return;
    seen.add(key);
    windows.push({
      label: windowLabel(minutes),
      minutes: Number.isFinite(minutes) ? minutes : 0,
      remaining: Math.max(0, Math.min(100, Math.round(100 - used))),
      used,
      resetsAt: Number(bucket.resetsAt) || null,
    });
  };
  const legacy = limits.rateLimits;
  if (legacy) {
    add(legacy.primary);
    add(legacy.secondary);
  }
  const byLimit = limits.rateLimitsByLimitId;
  if (byLimit && typeof byLimit === "object") {
    for (const entry of Object.values(byLimit)) {
      if (!entry || typeof entry !== "object") continue;
      add(entry.primary);
      add(entry.secondary);
    }
  }
  // Longest window first, the way the app lists them: weekly above 5-hour.
  return windows.sort((a, b) => b.minutes - a.minutes);
}

function renderUsage() {
  const box = $("accountMenuUsage");
  const windows = usageWindows();
  box.innerHTML = "";
  // Before the account has reported anything — including before signing in —
  // there is no usage block at all, weekly or 5-hour.
  box.hidden = windows.length === 0;
  if (!windows.length) return;
  for (const window of windows) {
    const row = el("div", "usage-row");
    const head = el("div", "usage-head");
    head.appendChild(el("span", "usage-label", window.label));
    head.appendChild(el("span", "usage-remaining", `剩余 ${window.remaining}% 使用量`));
    row.appendChild(head);
    const bar = el("div", "usage-bar");
    const fill = el("span");
    fill.style.width = `${Math.max(2, Math.min(100, Math.round(window.used)))}%`;
    bar.appendChild(fill);
    row.appendChild(bar);
    if (window.resetsAt) {
      const when = new Date(window.resetsAt * 1000);
      row.appendChild(
        el("div", "usage-reset", `将于 ${when.toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })} 重置`),
      );
    }
    box.appendChild(row);
  }
}

// ---------------------------------------------------------------- settings

// ------------------------------------------------------------------ 外观

const APPEARANCE = [
  { id: "light", label: "浅色" },
  { id: "dark", label: "深色" },
  { id: "system", label: "跟随系统" },
];

/// Review only: `?theme=light|dark` pins one theme on the preview.
let forcedTheme = null;

/// The page follows the choice; with 跟随系统 it follows `color-scheme`, which
/// is the iPad's own setting, so nothing has to poll it.
function applyAppearance() {
  const mode = forcedTheme ?? state.appearance;
  if (mode === "light" || mode === "dark") document.documentElement.dataset.theme = mode;
  else delete document.documentElement.dataset.theme;
}

function setAppearance(mode) {
  state.appearance = mode;
  forcedTheme = null;
  applyAppearance();
  if (preview) localStorage.setItem("pocketvm.appearance", mode);
  else bridge.send("setAppearance", { theme: mode });
  renderSettings();
}

function appearanceControl() {
  const wrap = el("div", "segmented");
  for (const option of APPEARANCE) {
    const node = el("button", state.appearance === option.id ? "active" : "", option.label);
    node.type = "button";
    node.addEventListener("click", () => setAppearance(option.id));
    wrap.appendChild(node);
  }
  return wrap;
}

function rowsFor(page) {
  const cfg = draft ?? state.config;
  if (page === "general") {
    return [
      { group: "外观" },
      { label: "主题", control: appearanceControl },
      { label: "语言", control: () => el("span", "value", "简体中文") },
      { group: "工作空间" },
      { label: "项目", control: () => el("span", "value", "没有项目") },
    ];
  }
  if (page === "vm") {
    const provision = state.provision;
    return [
      {
        group: "虚拟机",
      },
      {
        label: "系统",
        desc: provision.image,
        control: () => el("span", "value", provision.provisioned ? "已就绪" : provision.stage),
      },
      {
        label: "状态",
        desc: provision.running ? "正在运行" : "已停止",
        control: () => el("span", "value", provision.running ? "运行中" : "已停止"),
      },
      {
        label: "CPU 核心",
        desc: "1–16",
        control: () => numberInput("cpuCount", cfg.cpuCount, 1, 16),
      },
      {
        label: "内存",
        desc: "MiB，128–8192。iOS 对单次分配有限制",
        control: () => numberInput("memoryMiB", cfg.memoryMiB, 128, 8192, 128),
      },
      {
        label: "JIT 缓存",
        desc: "MiB。越大越少重译，但占用常驻内存",
        control: () => numberInput("jitCacheMiB", cfg.jitCacheMiB, 16, 4096, 16),
      },
      {
        label: "多线程翻译",
        desc: "iOS 上实验性，默认关闭",
        control: () => switchControl("forceMulticore", cfg.forceMulticore),
      },
      {
        label: "磁盘",
        desc: `${provision.imageBytes} GiB`,
        control: () => button("添加…", "btn", "pickDisk"),
      },
      {
        group: "开发",
      },
      { label: "SSH", desc: "USB · 重启生效", control: () => switchControl("developerSSH", cfg.developerSSH === true) },
      { label: "SSH 端口", control: () => numberInput("developerSSHPort", cfg.developerSSHPort ?? 2222, 1024, 65535) },
      { label: "SSH 用户", control: () => el("span", "value", "codex") },
      {
        group: "操作",
      },
      {
        label: "启动",
        desc: "首次启动会下载镜像并自动完成安装",
        control: () => button("启动", "btn-primary", "start", !provision.running && !provision.busy),
      },
      {
        label: "停止",
        control: () => button("停止", "btn", "stop", provision.running),
      },
      {
        label: "重新准备客户机",
        desc: "清除安装标记，下次启动重新配置客户机",
        control: () => button("重新准备", "btn", "resetProvision"),
      },
      {
        label: "登录口令",
        desc: "客户机账号 codex 的密码",
        control: () => el("span", "value", provision.password),
      },
      {
        label: "保存",
        desc: "修改后需要重启虚拟机生效",
        control: () => button("保存", "btn-primary", "saveConfig", draft !== null),
      },
    ];
  }
  if (page === "account") {
    const auth = state.auth;
    const model = selectedModel();
    const running = state.provision.running;
    const account = state.account ?? {};
    const who = account.email || account.account?.email || "";
    const rows = [
      { group: "Codex" },
      {
        label: "账号",
        // Straight from the guest's own app server, so it is the account the
        // CLI inside this machine is actually using.
        desc: who,
        control: () => el("span", "value", account.planType || account.account?.planType || ""),
      },
      {
        label: "登录状态",
        desc: auth.state === "failed" ? auth.reason || "获取登录代码失败" : "",
        control: () =>
          el(
            "span",
            "value",
            auth.state === "signedIn"
              ? "已登录"
              : auth.state === "awaiting"
                ? "等待确认"
                : auth.state === "starting"
                  ? "获取代码中"
                  : auth.state === "failed"
                    ? "失败"
                    : "未登录"
          ),
      },
      {
        label: "登录",
        // The CLI runs inside the guest, so there is nothing to log in to until
        // the guest is up. Saying so beats a button that does nothing.
        desc: running ? "" : "虚拟机未运行",
        control: () =>
          running
            ? button("登录 Codex", "btn-primary", "codexLogin")
            : button("启动", "btn-primary", "start"),
      },
      {
        label: "登录输出",
        desc: "",
        control: () => el("div", "value-block", (auth.trace || []).slice(-16).join("\n") || "暂无输出"),
      },
      {
        label: "模型",
        // The list comes from the account, so this is a fetch, not a setting.
        desc: state.model.error || (model ? `${availableModels().length} 个可用模型` : "登录后从客户机的 Codex 获取"),
        control: () => button("获取模型", "btn", "getModels"),
      },
    ];
    if (auth.state === "awaiting") {
      rows.push({
        label: "一次性代码",
        desc: "",
        control: () => {
          const copy = el("button", "btn", auth.code || "");
          copy.addEventListener("click", () => bridge.send("copy", { text: auth.code }));
          return copy;
        },
      });
      rows.push({
        label: "确认链接",
        control: () => {
          const wrap = el("div", "row-buttons");
          const open = el("button", "btn", "在 iPad 打开");
          open.addEventListener("click", () => bridge.send("openURL", { url: auth.url }));
          const copy = el("button", "btn", "复制链接");
          copy.addEventListener("click", () => bridge.send("copy", { text: auth.url }));
          wrap.appendChild(open);
          wrap.appendChild(copy);
          return wrap;
        },
      });
    }
    return rows;
  }
  return [
    { group: "关于" },
    {
      label: "PocketVM",
      desc: "在 iPad 上运行一台 QEMU 虚拟机",
      control: () => el("span", "value", state.version || ""),
    },
    { label: "模拟器", desc: "utmapp/qemu 10.0.12", control: () => el("span", "value", "GPL-2.0") },
    { label: "本应用", control: () => el("span", "value", "GPL-3.0") },
    { label: "系统镜像", desc: "cloud.debian.org · genericcloud aarch64", control: () => el("span", "value", "Debian") },
  ];
}

function numberInput(key, value, min, max, step) {
  const input = document.createElement("input");
  input.type = "number";
  input.min = min;
  input.max = max;
  if (step) input.step = step;
  input.value = value;
  input.addEventListener("change", () => {
    const parsed = Number.parseInt(input.value, 10);
    draft = { ...(draft ?? state.config) };
    draft[key] = Math.min(Math.max(Number.isNaN(parsed) ? value : parsed, min), max);
    renderSettings();
  });
  return input;
}

function switchControl(key, value) {
  const label = el("label", "switch");
  const input = document.createElement("input");
  input.type = "checkbox";
  input.checked = !!value;
  input.addEventListener("change", () => {
    draft = { ...(draft ?? state.config) };
    draft[key] = input.checked;
    renderSettings();
  });
  label.appendChild(input);
  label.appendChild(el("span"));
  return label;
}

function button(label, className, action, enabled = true) {
  const node = el("button", className, label);
  node.type = "button";
  node.disabled = !enabled;
  node.addEventListener("click", () => {
    if (action === "saveConfig" && draft) {
      const payload = { ...draft };
      bridge.send("saveConfig", payload);
      state.config = payload;
      draft = null;
      renderSettings();
      return;
    }
    bridge.send(action);
  });
  return node;
}

function renderSettingsNav() {
  const nav = $("settingsNav");
  nav.innerHTML = "";
  for (const page of settingsPages) {
    const node = el("button", page.id === activePage ? "active" : "", page.title);
    node.type = "button";
    node.addEventListener("click", () => {
      activePage = page.id;
      renderSettings();
    });
    nav.appendChild(node);
  }
}

function renderSettings() {
  renderSettingsNav();
  const content = $("settingsContent");
  content.innerHTML = "";
  const page = settingsPages.find((entry) => entry.id === activePage);
  content.appendChild(el("h2", null, page.title));

  for (const row of rowsFor(activePage)) {
    if (row.group) {
      content.appendChild(el("div", "group-title", row.group));
      continue;
    }
    const line = el("div", "row");
    const text = el("div", "row-text");
    text.appendChild(el("span", "row-label", row.label));
    if (row.desc) text.appendChild(el("span", "row-desc", row.desc));
    line.appendChild(text);
    const control = el("div", "row-control");
    control.appendChild(row.control ? row.control() : el("span"));
    line.appendChild(control);
    content.appendChild(line);
  }
}

function openSettings() {
  draft = null;
  $("settings").hidden = false;
  renderSettings();
}

function closeSettings() {
  $("settings").hidden = true;
  draft = null;
}

// ------------------------------------------------------------- 启动遮罩

// Everything before the guest can answer stays behind glass: a machine that is
// uninstalled, stopped or still booting has no conversation to show, and a
// half-started screen that can be tapped is worse than one that explains
// itself and waits.
const GATE_ICON_DOWNLOAD =
  '<svg viewBox="0 0 20 20" fill="none"><path d="M10 3v9m0 0 3.2-3.2M10 12 6.8 8.8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 14.5v1A1.5 1.5 0 0 0 5.5 17h9a1.5 1.5 0 0 0 1.5-1.5v-1" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';
const GATE_ICON_POWER =
  '<svg viewBox="0 0 20 20" fill="none"><path d="M10 3.2v6.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><path d="M5.6 5.9a6.4 6.4 0 1 0 8.8 0" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';

// The steps the emulator itself walks on a first run, in the order the host
// reports them. The wording is the host's own, so the counter and the line
// under it can never disagree.
const GATE_STEPS = ["downloading", "verifying", "preparing", "booting", "installing"];

function gateStep() {
  const index = GATE_STEPS.indexOf(state.provision.stageCode);
  return `${(index === -1 ? GATE_STEPS.length : index + 1)} / ${GATE_STEPS.length}`;
}

/// Which card the gate shows. `ready` is not a card: it is the hand-off into
/// the app, and it only happens once the guest's Codex CLI has answered.
function gatePhase() {
  if (preview && forcedGate) return forcedGate === "entered" ? "ready" : forcedGate;
  if (!provisionKnown) return "waiting";
  const provision = state.provision;
  if (!provision.provisioned) return provision.busy ? "installing" : "install";
  if (provision.starting) return "starting";
  if (provision.running) return provision.codexReady ? "ready" : "starting";
  return "stopped";
}

function gateCard(phase) {
  const provision = state.provision;
  const config = state.config ?? {};
  const memory = config.memoryMiB ? `${Math.round((config.memoryMiB / 1024) * 10) / 10} GiB` : "";
  if (phase === "install") {
    return {
      icon: GATE_ICON_DOWNLOAD,
      title: "未安装",
      // A failed run keeps the host's own line: without it the card would claim
      // the machine simply is not installed yet.
      body: provision.stageCode === "failed"
        ? provision.stage
        : "需要先下载客户机系统",
      facts: [provision.image, provision.host, `${provision.imageBytes} GiB`],
      actions: [{ label: "安装", kind: "primary", action: () => bridge.send("start") }],
    };
  }
  if (phase === "installing") {
    return {
      icon: GATE_ICON_DOWNLOAD,
      title: "安装中",
      // The host's stage line first: while the guest is installing, that is the
      // guest's own progress ("POCKETVM: 安装基础软件"), and the boot-phase
      // label the probe writes is about a boot that has not happened yet.
      facts: [provision.stage || provision.detail, gateStep()],
      progress: typeof provision.fraction === "number" ? provision.fraction : null,
      actions: [{ label: "安装中", kind: "status" }],
    };
  }
  if (phase === "starting") {
    return {
      icon: GATE_ICON_POWER,
      title: provision.executionMode === "interpreter" ? "启动中(慢速模式)" : "启动中",
      facts: [provision.image, provision.detail || "正在启动 QEMU"],
      progress: null,
      actions: [{ label: "启动中", kind: "status" }],
    };
  }
  return {
    icon: GATE_ICON_POWER,
    title: "未运行",
    facts: [
      provision.image,
      config.cpuCount && memory ? `${config.cpuCount} 核 · ${memory} 内存` : "",
      `${provision.imageBytes} GiB 磁盘`,
    ].filter(Boolean),
    actions: [
      { label: "设置", kind: "ghost", action: openSettings },
      { label: "启动", kind: "primary", action: () => bridge.send("start") },
    ],
  };
}

let gateEntered = false;
let gateHideTimer = null;

function renderGate() {
  const slow = state.provision.executionMode === "interpreter";
  $("slowModeBadge").hidden = !slow;
  const gate = $("vmGate");
  if (!gate) return;
  const phase = gatePhase();
  if (phase === "ready") {
    if (gateEntered) return;
    gateEntered = true;
    gate.classList.add("leaving");
    document.body.classList.add("entered");
    // Long enough for the glass to lift, then it is out of the way entirely.
    gateHideTimer = window.setTimeout(() => { gate.hidden = true; }, 520);
    return;
  }
  // A machine that stops again has to bring the glass back, even if it stopped
  // inside the hand-off.
  if (gateHideTimer !== null) {
    window.clearTimeout(gateHideTimer);
    gateHideTimer = null;
  }
  gateEntered = false;
  gate.hidden = false;
  gate.classList.remove("leaving");
  document.body.classList.remove("entered");

  // Nothing to say yet: the glass is up, the card is empty until the host
  // answers. Rendering the preview's sample state here would flash the wrong
  // machine on screen.
  if (phase === "waiting") {
    $("vmGateCard").innerHTML = "";
    return;
  }

  const spec = gateCard(phase);
  const card = $("vmGateCard");
  card.innerHTML = "";
  const icon = el("div", "vm-gate-icon");
  icon.innerHTML = spec.icon;
  card.appendChild(icon);
  const title = el("h1", null, spec.title);
  if (slow && phase === "starting") title.classList.add("slow-boot-title");
  title.id = "vmGateTitle";
  card.appendChild(title);
  if (slow && (phase === "starting" || phase === "installing")) {
    const warning = el("div", "no-jit-warning");
    warning.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5 15 14H1Z" fill="none" stroke="currentColor" stroke-linejoin="round"/><path d="M8 5.5v4" stroke="currentColor" stroke-linecap="round"/><circle cx="8" cy="12" r=".8" fill="currentColor"/></svg>';
    warning.appendChild(el("span", null, "无jit"));
    card.appendChild(warning);
  }
  if (spec.body) card.appendChild(el("p", "vm-gate-body", spec.body));
  const facts = el("dl", "vm-gate-facts");
  for (const fact of spec.facts) {
    const row = el("div");
    row.appendChild(el("dd", null, fact));
    facts.appendChild(row);
  }
  card.appendChild(facts);
  if (spec.progress !== undefined) {
    const determinate = typeof spec.progress === "number";
    const bar = el("div", determinate ? "vm-gate-progress determinate" : "vm-gate-progress indeterminate");
    const fill = el("span");
    if (determinate) fill.style.width = `${Math.max(2, Math.round(spec.progress * 100))}%`;
    bar.appendChild(fill);
    card.appendChild(bar);
  }
  const actions = el("div", "vm-gate-actions");
  for (const action of spec.actions) {
    const node = el("button", `vm-gate-${action.kind}`, action.label);
    node.type = "button";
    if (action.kind === "status") node.setAttribute("aria-disabled", "true");
    else node.addEventListener("click", action.action);
    actions.appendChild(node);
  }
  card.appendChild(actions);
}

// ---------------------------------------------------------------- lifecycle

function applyProvisionState(payload) {
  provisionKnown = true;
  const next = { ...state.provision, ...payload };
  // The host only sends a fraction while a download or a checksum is running.
  // Anything else means the bar goes back to indeterminate instead of freezing
  // at the last number it saw.
  if (payload.fraction === undefined) next.fraction = undefined;
  state.provision = next;
  renderThreads();
  renderPlan();
  renderAccount();
  renderGate();
  renderModelChip();
  if (!$("settings").hidden) renderSettings();
}

function applyAuthState(payload) {
  state.auth = { ...state.auth, ...payload };
  renderAccount();
  if (!$("settings").hidden) renderSettings();
}

window.pocketvmReceive = function (message) {
  if (!message || typeof message !== "object") return;
  const payload = message.payload ?? {};
  switch (message.action) {
    case "provisionState":
      applyProvisionState(message.payload || {});
      break;
    case "authState":
      applyAuthState(message.payload || {});
      break;
    case "appearance":
      state.appearance = message.payload?.theme || "system";
      if (message.payload?.version) state.version = message.payload.version;
      applyAppearance();
      if (!$("settings").hidden) renderSettings();
      break;
    case "attachment":
      pendingAttachments.push(payload); renderAttachments(); break;
    case "promptAccepted":
      pendingAttachments = pendingAttachments.filter(item => !(payload.attachments ?? []).includes(item.id));
      if ($("composerInput").value.trim() === payload.text) $("composerInput").value = "";
      renderAttachments(); resizeComposer(); updateSendButton(); break;
    case "promptState":
      promptBusy = payload.busy === true; updateSendButton();
      $("composerInput").setAttribute("aria-busy", payload.busy ? "true" : "false");
      document.getElementById("replyState").hidden = !payload.busy;
      break;
    case "models":
      applyModels(message.payload || {});
      break;
    case "limits":
      state.limits = message.payload || null;
      renderUsage();
      break;
    case "account":
      state.account = message.payload || null;
      renderAccount();
      break;
    case "threads":
      state.threads = message.payload?.threads ?? [];
      renderThreads();
      break;
    case "config":
      state.config = message.payload || state.config;
      renderGate();
      if (!$("settings").hidden) renderSettings();
      break;
    case "messages":
      state.messages = message.payload || [];
      renderMessages();
      break;
    case "automations":
      state.automations = message.payload?.tasks || [];
      renderAutomations();
      break;
    case "terminalOutput":
      terminalReceive(message.payload);
      break;
    case "terminalState":
      setTerminalState(message.payload?.text ?? "未连接");
      break;
    default:
      break;
  }
};

function renderAttachments() {
  updateSendButton();
  const row = $("attachmentList"); row.replaceChildren();
  for (const item of pendingAttachments) {
    const button = el("button", "attachment-chip", item.name + " ×");
    button.type = "button"; button.setAttribute("aria-label", "移除 " + item.name);
    button.addEventListener("click", () => { pendingAttachments = pendingAttachments.filter(entry => entry.id !== item.id); renderAttachments(); });
    row.appendChild(button);
  }
}

function composerAction() {
  const hasInput = !!$("composerInput").value.trim() || pendingAttachments.length > 0;
  return promptBusy ? (hasInput ? "steer" : "interrupt") : "send";
}
function updateSendButton() {
  const button = $("sendBtn"), action = composerAction();
  const label = {send: "发送", steer: "引导", interrupt: "中断"}[action];
  button.title = label; button.setAttribute("aria-label", label); button.dataset.action = action;
  button.innerHTML = action === "interrupt"
    ? '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="4" width="8" height="8" rx="1" fill="currentColor"/></svg>'
    : '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 12.4V3.6M4.4 7.2L8 3.6l3.6 3.6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>';
}
function resizeComposer() {
  const input = $("composerInput");
  input.style.height = "auto";
  input.style.height = `${Math.max(46, Math.min(input.scrollHeight, 180))}px`;
}
function submitComposer() {
  const action = composerAction();
  if (action === "interrupt") { bridge.send("interruptPrompt"); return; }
  const text = $("composerInput").value.trim();
  if (!text && !pendingAttachments.length) return;
  bridge.send("prompt", {text, attachments: pendingAttachments.map(item => item.id)});
}
function wireComposer() {
  const input = $("composerInput");
  input.addEventListener("input", () => { resizeComposer(); updateSendButton(); });
  input.addEventListener("keydown", event => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      if (composerAction() !== "interrupt") submitComposer();
    }
  });
  $("sendBtn").addEventListener("click", submitComposer);
  updateSendButton();
}

function wireChrome() {
  const app = $("app");

  // 显示/隐藏侧边面板 — thread.sidePanel.toggle, the right column.
  $("toggleSidePanel").addEventListener("click", () => {
    sidePanelChoice = !sidePanelOpen();
    setSidePanel(sidePanelChoice);
  });

  // 底部面板 — the guest's serial console.
  const setBottomPanel = (open) => {
    $("bottomPanel").hidden = !open;
    $("menuBottomPanel").checked = open;
    if (typeof wireTerminalPanel === "function") wireTerminalPanel();
    // The emulator is attached the first time it is actually visible: opened
    // while hidden it measures zero and draws nothing.
    if (open && typeof openTerminal === "function") requestAnimationFrame(() => openTerminal());
    if (typeof wireKeyRow === "function") wireKeyRow();
  };
  $("toggleBottomPanel").addEventListener("click", () => setBottomPanel($("bottomPanel").hidden));
  $("closeBottomPanel").addEventListener("click", () => setBottomPanel(false));
  $("menuBottomPanel").addEventListener("change", (event) => setBottomPanel(event.target.checked));
  $("menuSidePanel").addEventListener("change", (event) => {
    sidePanelChoice = event.target.checked;
    setSidePanel(sidePanelChoice);
  });

  const headerMenu = $("headerMenuPanel");
  $("headerMenu").addEventListener("click", () => {
    headerMenu.hidden = !headerMenu.hidden;
    $("menuBottomPanel").checked = !$("bottomPanel").hidden;
    $("menuSidePanel").checked = sidePanelOpen();
  });
  document.addEventListener("click", (event) => {
    if (headerMenu.hidden) return;
    if (headerMenu.contains(event.target) || event.target.closest("#headerMenu")) return;
    headerMenu.hidden = true;
  });
  document.addEventListener("click", (event) => {
    if ($("accountMenu").hidden) return;
    if (event.target.closest("#accountMenu") || event.target.closest("#account")) return;
    $("accountMenu").hidden = true;
  });

  $("menuSettings").addEventListener("click", () => {
    headerMenu.hidden = true;
    openSettings();
  });

  wireCommandMenu();
  // 头像 — the account menu: what the account is, what is left of it, and the
  // way into settings.
  $("account").addEventListener("click", (event) => {
    event.stopPropagation();
    const menu = $("accountMenu");
    menu.hidden = !menu.hidden;
    if (menu.hidden) return;
    renderAccount();
    bridge.send("getAccount");
  });
  $("accountMenuSettings").addEventListener("click", () => {
    $("accountMenu").hidden = true;
    openSettings();
  });
  $("newThread").addEventListener("click", startNewThread);
  $("closeSettings").addEventListener("click", closeSettings);
  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      toggleCommandMenu();
      return;
    }
    if (event.key !== "Escape") return;
    closeSettings();
    $("commandMenuPanel").hidden = true;
    $("headerMenuPanel").hidden = true;
    closeModelMenu();
    closeContextMenu();
    closeAutomationEditor();
    $("accountMenu").hidden = true;
  });
}

// 打开命令菜单: a search box over the commands, the way the app's own menu is.
function wireCommandMenu() {
  const panel = $("commandMenuPanel");
  const search = $("commandSearch");
  const list = $("commandList");

  const commands = [
    { title: "设置", action: () => openSettings() },
    { title: "新对话", action: () => startNewThread() },
    { title: "显示/隐藏侧边面板", action: () => $("toggleSidePanel").click() },
    { title: "切换底部面板显示", action: () => $("toggleBottomPanel").click() },
    { title: "登录 Codex", action: () => bridge.send("codexLogin") },
    { title: "重新准备客户机", action: () => bridge.send("resetProvision") },
  ];

  const render = () => {
    const query = search.value.trim();
    list.innerHTML = "";
    for (const command of commands.filter((entry) => !query || entry.title.includes(query))) {
      const row = el("li", null, command.title);
      row.addEventListener("click", () => {
        panel.hidden = true;
        command.action();
      });
      list.appendChild(row);
    }
  };

  search.addEventListener("input", render);
  toggleCommandMenu = () => {
    panel.hidden = !panel.hidden;
    if (panel.hidden) return;
    search.value = "";
    render();
    search.focus();
  };
  render();
  document.addEventListener("click", (event) => {
    if (panel.hidden) return;
    if (panel.contains(event.target)) return;
    panel.hidden = true;
  });
}

// Cmd/Ctrl+K: 搜索命令和过往对话记录。
let toggleCommandMenu = () => {};

function startNewThread() {
  bridge.send("selectThread", {});
  state.messages = [];
  $("threadTitle").textContent = "新对话";
  renderMessages();
  $("composerInput").focus();
}

// ------------------------------------------------------------- 定时任务

const CADENCE_LABEL = { daily: "每天", weekdays: "工作日", weekly: "每周", monthly: "每月" };
const STATUS_LABEL = { active: "已开启", paused: "已暂停", completed: "已完成" };

function automationSummary(task) {
  const parts = [`${CADENCE_LABEL[task.cadence] ?? "每天"} ${task.time}`];
  if (task.status === "paused") return `已暂停 · ${parts[0]}`;
  if (task.status === "completed") return `已完成 · ${parts[0]}`;
  if (task.nextRun) parts.push(`下次运行时间：${task.nextRun}`);
  else if (task.lastRun) parts.push(`上次运行时间：${task.lastRun}`);
  return parts.join(" · ");
}

function renderAutomations() {
  const list = $("automationList");
  list.innerHTML = "";
  const tasks = state.automations.filter((task) => automationFilter === "all" || task.status === automationFilter);
  if (!tasks.length) {
    const empty = el("li", "automation-empty", "无任务");
    list.appendChild(empty);
    return;
  }
  for (const task of tasks) {
    const row = el("li", task.status === "paused" ? "automation-row paused" : "automation-row");
    const main = el("div", "automation-row-main");
    main.appendChild(el("span", "automation-row-title", task.title));
    main.appendChild(el("span", "automation-row-meta", automationSummary(task)));
    row.appendChild(main);

    const actions = el("div", "automation-row-actions");
    const toggle = el("button", "row-action", task.status === "paused" ? "继续" : "暂停");
    toggle.type = "button";
    toggle.title = task.status === "paused" ? `继续 ${task.title}` : `暂停 ${task.title}`;
    toggle.addEventListener("click", () => {
      task.status = task.status === "paused" ? "active" : "paused";
      bridge.send("toggleAutomation", { id: task.id, status: task.status });
      renderAutomations();
    });
    actions.appendChild(toggle);
    if (task.status !== "completed") {
      const runBtn = el("button", "row-action", "运行");
      runBtn.type = "button";
      runBtn.title = `立即运行 ${task.title}`;
      runBtn.addEventListener("click", () => bridge.send("runAutomation", { id: task.id }));
      actions.appendChild(runBtn);
    }
    const edit = el("button", "row-action", "编辑");
    edit.type = "button";
    edit.title = `编辑 ${task.title}`;
    edit.addEventListener("click", () => openAutomationEditor(task));
    actions.appendChild(edit);
    row.appendChild(actions);
    list.appendChild(row);
  }
}

function openAutomationEditor(task) {
  automationDraft = { ...task };
  $("automationEditorTitle").textContent = task.title ? "编辑任务" : "任务";
  $("automationName").value = task.title ?? "";
  $("automationCadence").value = task.cadence ?? "daily";
  $("automationTime").value = task.time ?? "22:00";
  $("automationDelete").hidden = !task.id;
  $("automationEditor").hidden = false;
  $("automationName").focus();
}

function closeAutomationEditor() {
  $("automationEditor").hidden = true;
  automationDraft = null;
}

function saveAutomation() {
  if (!automationDraft) return;
  const draft = automationDraft;
  draft.title = $("automationName").value.trim() || "未命名任务";
  draft.cadence = $("automationCadence").value;
  draft.time = $("automationTime").value || "22:00";
  draft.status = draft.status ?? "active";
  const existing = state.automations.find((task) => task.id === draft.id);
  if (existing) Object.assign(existing, draft);
  else state.automations.unshift(draft);
  bridge.send("saveAutomation", draft);
  closeAutomationEditor();
  renderAutomations();
}

function deleteAutomation() {
  if (!automationDraft) return;
  bridge.send("deleteAutomation", { id: automationDraft.id });
  state.automations = state.automations.filter((task) => task.id !== automationDraft.id);
  closeAutomationEditor();
  renderAutomations();
}

function showView(view) {
  const app = $("app");
  const automations = view === "automations";
  app.classList.toggle("view-automations", automations);
  $("automations").hidden = !automations;
  for (const button of document.querySelectorAll(".nav-item")) button.classList.remove("active");
  if (automations) $("navAutomations").classList.add("active");
  else $("newThread").classList.add("active");
  if (automations) renderAutomations();
}

function wireAutomations() {
  $("navAutomations").addEventListener("click", () => showView("automations"));
  $("newThread").addEventListener("click", () => {
    showView("thread");
    startNewThread();
  });
  for (const button of $("automationFilter").querySelectorAll("button")) {
    button.addEventListener("click", () => {
      automationFilter = button.dataset.filter;
      for (const other of $("automationFilter").querySelectorAll("button")) {
        other.classList.toggle("active", other === button);
      }
      renderAutomations();
    });
  }
  $("newAutomation").addEventListener("click", () =>
    openAutomationEditor({ title: "", cadence: "daily", time: "22:00", status: "active" }),
  );
  $("automationEditorClose").addEventListener("click", closeAutomationEditor);
  $("automationCancel").addEventListener("click", closeAutomationEditor);
  $("automationSave").addEventListener("click", saveAutomation);
  $("automationDelete").addEventListener("click", deleteAutomation);
  $("automationEditor").addEventListener("click", (event) => {
    if (event.target === $("automationEditor")) closeAutomationEditor();
  });

  const input = $("automationInput");
  const autosize = () => {
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 140)}px`;
  };
  input.addEventListener("input", autosize);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  });
  $("automationSend").addEventListener("click", submit);

  // 安排任务 — the app hands the sentence to the agent and lets it build the
  // schedule. We do the same, and drop a placeholder row in the meantime.
  function submit() {
    const text = input.value.trim();
    if (!text) return;
    state.automations.unshift({
      id: `draft-${Date.now()}`,
      title: text,
      cadence: "daily",
      time: "22:00",
      status: "active",
    });
    input.value = "";
    autosize();
    bridge.send("scheduleTask", { text });
    renderAutomations();
  }
}

// ------------------------------------------------------- composer + menu

function closeContextMenu() {
  $("ctxMenu").hidden = true;
  $("contextButton").setAttribute("aria-expanded", "false");
}

function wireContextMenu() {
  const menu = $("ctxMenu");
  const button = $("contextButton");
  button.addEventListener("click", (event) => {
    event.stopPropagation();
    const open = menu.hidden;
    menu.hidden = !open;
    button.setAttribute("aria-expanded", open ? "true" : "false");
    if (!open) return;
    const box = button.getBoundingClientRect();
    menu.style.left = `${box.left}px`;
    menu.style.bottom = `${window.innerHeight - box.top + 8}px`;
    menu.style.top = "auto";
    menu.style.right = "auto";
  });
  for (const item of menu.querySelectorAll(".ctx-item")) {
    item.addEventListener("click", () => {
      const kind = item.dataset.ctx;
      closeContextMenu();
      if (kind === "files") bridge.send("pickFiles");
      else if (kind === "photos") bridge.send("pickPhotos");
      else if (kind === "remote") bridge.send("pickRemoteFile");
      else if (kind === "skill") {
        // browserSkills.createChatPrompt, with the $skill-creator mention the
        // app inserts for the skill-creation flow.
        const input = $("composerInput");
        input.value = "使用 $skill-creator 帮我创建技能。保持对话式交流，先询问这个技能要做什么。";
        input.focus();
      }
    });
  }
  document.addEventListener("click", (event) => {
    if (menu.hidden || menu.contains(event.target)) return;
    closeContextMenu();
  });
}

// The tablet keeps its own scale: no pinch zoom, no double-tap zoom.
function blockZoomGestures() {
  for (const type of ["gesturestart", "gesturechange", "gestureend"]) {
    document.addEventListener(type, (event) => event.preventDefault(), { passive: false });
  }
  let lastTouch = 0;
  document.addEventListener(
    "touchend",
    (event) => {
      const now = Date.now();
      if (now - lastTouch <= 300) event.preventDefault();
      lastTouch = now;
    },
    { passive: false },
  );
}

function main() {
  applyAppearance();
  renderModelChip();
  wireModelMenu();
  wireContextMenu();
  wireAutomations();
  blockZoomGestures();
  $("newThread").classList.add("active");
  renderThreads();
  renderMessages();
  renderPlan();
  renderAccount();
  renderGate();
  wireComposer();
  wireChrome();
  ensureTerminal();
  if (typeof wireKeyRow === "function") wireKeyRow();
  // Rotating the tablet changes whether the panel has a column of its own.
  window.addEventListener("resize", () => syncSidePanel());

  if (preview) {
    setTerminalState("预览");
  } else {
    bridge.send("getConfig");
    bridge.send("getMessages");
    bridge.send("getProvisionState");
    bridge.send("getAutomations");
    bridge.send("getAppearance");
    // Cached first: the last conversation list and usage numbers show while the
    // guest is still booting, and are replaced when it reports again.
    bridge.send("getAccount");
  }

  // Review shortcuts: ?panel=1 opens the side panel, ?settings=vm opens that
  // settings page. Useful on a window too narrow for three columns.
  const params = new URLSearchParams(location.search);
  if (preview && params.get("execution") === "interpreter") {
    state.provision.executionMode = "interpreter";
    renderGate();
  }
  if (preview && params.has("busy")) window.pocketvmReceive({action: "promptState", payload: {busy: true}});
  const theme = params.get("theme");
  if (theme === "light" || theme === "dark") {
    forcedTheme = theme;
    applyAppearance();
  }
  // Review only: the preview has no machine to start, so the card is picked
  // with the same state the host would have sent.
  if (preview && params.has("gate")) {
    forcedGate = params.get("gate");
    if (forcedGate === "install") Object.assign(state.provision, { provisioned: false, busy: false });
    if (forcedGate === "installing") {
      Object.assign(state.provision, {
        provisioned: false,
        busy: true,
        running: false,
        stage: "安装 Node 与 Codex CLI",
        detail: "安装 Node 与 Codex CLI",
        fraction: 0.42,
      });
    }
    if (forcedGate === "starting") {
      Object.assign(state.provision, {
        provisioned: true,
        busy: false,
        running: true,
        codexReady: false,
        detail: "正在引导系统",
      });
    }
    if (forcedGate === "stopped") {
      Object.assign(state.provision, { running: false, codexReady: false, busy: false });
    }
    if (forcedGate === "entered") {
      Object.assign(state.provision, { running: true, codexReady: true, busy: false });
    }
    renderGate();
  }
  if (params.has("panel")) $("app").classList.add("panel-open");
  // Review shortcut: ?terminal=1 shows the console panel.
  if (params.has("terminal")) {
    $("toggleBottomPanel").click();
  }
  // Review shortcut: ?models=1 opens the picker so it can be looked at without
  // a mouse.
  if (params.has("models")) $("modelChip").click();
  // Review shortcut: ?account=1 opens the avatar menu.
  if (params.has("account")) $("account").click();
  if (params.has("settings")) {
    const wanted = params.get("settings");
    if (settingsPages.some((page) => page.id === wanted)) activePage = wanted;
    openSettings();
  }
}

document.addEventListener("DOMContentLoaded", main);
