#!/usr/bin/env node
//
// Ask the guest's own Codex app server for what the frontend shows.
//
// Everything the app displays about the account comes from here — the models
// this account can use, its usage limits, and its conversation list — because
// all three belong to the account and none of them can be written down in
// advance. The desktop app asks the same server the same questions.
//
//   node pocketvm-app.mjs                 # all of it, one JSON object
//   node pocketvm-app.mjs model/list      # just one method
//
// The host fetches this file over its own helper server; nothing is installed
// on the guest by hand.

import { spawn } from "node:child_process";

const METHODS = {
  models: "model/list",
  limits: "account/rateLimits/read",
  account: "account/read",
  threads: "thread/list",
};

/// Everything the picker draws, and nothing else: raw model entries carry
/// upgrade blurbs and tool definitions that would triple the payload.
const MODEL_FIELDS = [
  "id",
  "displayName",
  "description",
  "defaultReasoningEffort",
  "supportedReasoningEfforts",
  "additionalSpeedTiers",
  "hidden",
  "isDefault",
];

const only = process.argv[2] ?? "";
const wanted = Object.entries(METHODS).filter(([, method]) => !only || method === only);
const results = {};

let pending = null;
let pendingId = null;
let nextRequestId = 200;
let index = 0;
let done = false;

const child = spawn("codex", ["app-server"], { stdio: ["pipe", "pipe", "pipe"] });
let buffer = "";
let stderr = "";

// A report runs during boot and must never hold provisioning hostage. Account
// data can be refreshed later through the command agent after sign-in.
const timer = setTimeout(() => finish(), 60000);

function finish() {
  if (done) return;
  done = true;
  clearTimeout(timer);
  const payload = only ? results[wanted[0]?.[0]] ?? { error: results.error ?? "未收到 app-server 响应" } : results;
  process.stdout.write(`${JSON.stringify(payload)}\n`);
  try {
    child.kill("SIGKILL");
  } catch {
    /* already gone */
  }
}

function send(message) {
  if (child.stdin.writable) child.stdin.write(`${JSON.stringify(message)}\n`);
}

function ask() {
  if (index >= wanted.length) {
    finish();
    return;
  }
  const [key, method] = wanted[index];
  index += 1;
  pending = key;
  const params =
    method === "model/list"
      ? { includeHidden: true, cursor: null, limit: 100 }
      : method === "thread/list"
        ? { limit: 20 }
        : undefined;
  pendingId = nextRequestId++;
  send({ jsonrpc: "2.0", id: pendingId, method, params });
}

child.on("error", () => finish());
child.on("exit", () => finish());
child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString();
  let newline;
  while ((newline = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      continue;
    }
    if (message.id === 1) {
      if (message.error) {
        results.error = message.error.message ?? "app-server 初始化失败";
        finish();
        continue;
      }
      send({ jsonrpc: "2.0", method: "initialized" });
      ask();
      continue;
    }
    if (message.id !== pendingId || !pending) continue;
    const key = pending;
    pending = null;
    if (message.error) {
      results[key] = { error: message.error.message ?? "请求被拒绝" };
    } else if (key === "models") {
      results[key] = (message.result?.data ?? []).map((entry) =>
        Object.fromEntries(MODEL_FIELDS.filter((field) => entry[field] !== undefined).map((field) => [field, entry[field]])),
      );
    } else if (key === "threads") {
      // The turns themselves are the conversation, not the list of them, and
      // they are the part that would make this payload unbounded.
      results[key] = (message.result?.data ?? []).map(({ turns, ...rest }) => rest);
    } else {
      results[key] = message.result ?? null;
    }
    ask();
  }
});

send({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: { clientInfo: { name: "pocketvm", title: "PocketVM", version: "0.2" } },
});
