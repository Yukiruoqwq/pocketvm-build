#!/usr/bin/env node
//
// Print the models this guest's Codex account can use, as one line the host
// reads off the serial console.
//
// Nothing about the list is written down here. It comes from the same app
// server the desktop app talks to — `initialize`, then `model/list` — so what
// the frontend offers is what the account actually has, including the reasoning
// levels each model supports and whether it has a faster service tier.
//
// Run from the host with the guest's own node:
//   curl -fsS "$POCKETVM_HELPER/pocketvm-models.mjs" -o /tmp/pocketvm-models.mjs \
//     && node /tmp/pocketvm-models.mjs

import { spawn } from "node:child_process";

const TIMEOUT_MS = 120000;
/// Everything the picker draws, and nothing else: the raw entries carry upgrade
/// blurbs and tool definitions that would triple the line the host has to read.
const KEEP = [
  "id",
  "displayName",
  "description",
  "defaultReasoningEffort",
  "supportedReasoningEfforts",
  "additionalSpeedTiers",
  "hidden",
  "isDefault",
];

const child = spawn("codex", ["app-server"], { stdio: ["pipe", "pipe", "pipe"] });

let buffer = "";
let done = false;
let stderr = "";

const timer = setTimeout(() => finish(`POCKETVM_MODELS_FAILED 超时：codex app-server 没有回答`), TIMEOUT_MS);

function finish(line) {
  if (done) return;
  done = true;
  clearTimeout(timer);
  process.stdout.write(`${line}\n`);
  try {
    child.kill("SIGKILL");
  } catch {
    /* already gone */
  }
}

function send(message) {
  if (child.stdin.writable) child.stdin.write(`${JSON.stringify(message)}\n`);
}

child.on("error", (error) => finish(`POCKETVM_MODELS_FAILED ${error.message}`));
child.on("exit", () => {
  const detail = stderr.trim().split("\n").slice(-1)[0] ?? "";
  finish(`POCKETVM_MODELS_FAILED codex app-server 退出了 ${detail}`.trim());
});
child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString();
  let index;
  while ((index = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      continue;
    }
    if (message.id === 1) {
      send({ jsonrpc: "2.0", method: "initialized" });
      send({
        jsonrpc: "2.0",
        id: 2,
        method: "model/list",
        params: { includeHidden: true, cursor: null, limit: 100 },
      });
      continue;
    }
    if (message.id !== 2) continue;
    if (message.error) {
      finish(`POCKETVM_MODELS_FAILED ${message.error.message ?? "模型列表被拒绝"}`);
      return;
    }
    const models = (message.result?.data ?? []).map((entry) =>
      Object.fromEntries(KEEP.filter((key) => entry[key] !== undefined).map((key) => [key, entry[key]])),
    );
    finish(`POCKETVM_MODELS ${JSON.stringify(models)}`);
    return;
  }
});

send({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: { clientInfo: { name: "pocketvm", title: "PocketVM", version: "0.2" } },
});
