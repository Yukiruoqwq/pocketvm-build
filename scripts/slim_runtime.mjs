#!/usr/bin/env node
//
// Assemble the QEMU runtime PocketVM embeds from a UTM application bundle.
//
// UTM ships every architecture it can emulate, which is why its own IPA is
// large. PocketVM hosts exactly one guest architecture, so this keeps the
// aarch64 system emulator, the frameworks it actually links against, and the
// aarch64 firmware. Everything else is dropped.
//
// The dependency list is read from the Mach-O load commands rather than
// hard-coded: a UTM update that links one more library would otherwise produce
// an app that fails at dlopen() with no useful message.
//
// Usage: node scripts/slim_runtime.mjs <UTM.app directory> [output directory]

import fs from "node:fs";
import path from "node:path";

const LC_LOAD_DYLIB = 0x0c;
const LC_LOAD_WEAK_DYLIB = 0x80000018;
const LC_REEXPORT_DYLIB = 0x8000001f;
const LC_ID_DYLIB = 0x0d;
const DYLIB_COMMANDS = new Set([LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB]);

const MH_MAGIC = 0xfeedface;
const MH_MAGIC_64 = 0xfeedfacf;
const FAT_MAGIC = 0xcafebabe;
const FAT_CIGAM = 0xbebafeca;

/** Names of the libraries a Mach-O file links against. */
function dependencies(file) {
  const buffer = fs.readFileSync(file);
  const names = new Set();
  for (const offset of archSlices(buffer)) {
    for (const name of sliceDependencies(buffer, offset)) names.add(name);
  }
  return [...names];
}

function archSlices(buffer) {
  const magic = buffer.readUInt32BE(0);
  if (magic !== FAT_MAGIC && magic !== FAT_CIGAM) return [0];
  const count = buffer.readUInt32BE(4);
  const offsets = [];
  for (let index = 0; index < count; index += 1) {
    offsets.push(buffer.readUInt32BE(8 + index * 20 + 8));
  }
  return offsets;
}

function sliceDependencies(buffer, offset) {
  const magic = buffer.readUInt32LE(offset);
  const is64 = magic === MH_MAGIC_64;
  if (magic !== MH_MAGIC && magic !== MH_MAGIC_64) return [];
  const commandCount = buffer.readUInt32LE(offset + 16);
  let cursor = offset + (is64 ? 32 : 28);
  const result = [];
  for (let index = 0; index < commandCount; index += 1) {
    if (cursor + 8 > buffer.length) break;
    const command = buffer.readUInt32LE(cursor);
    const size = buffer.readUInt32LE(cursor + 4);
    if (size < 8) break;
    if (DYLIB_COMMANDS.has(command) && command !== LC_ID_DYLIB) {
      const nameOffset = buffer.readUInt32LE(cursor + 8);
      let start = cursor + nameOffset;
      let end = start;
      while (end < buffer.length && buffer[end] !== 0) end += 1;
      result.push(buffer.toString("utf8", start, end));
    }
    cursor += size;
  }
  return result;
}

/** `/path/X.framework/X` and `@rpath/X.framework/X` both map to X.framework. */
function frameworkOf(loadPath) {
  const match = loadPath.match(/(?:@rpath\/|\/)([^/]+\.framework)\//);
  return match ? match[1] : null;
}

/** `@rpath/libfoo.dylib` maps to libfoo.dylib. */
function dylibOf(loadPath) {
  if (loadPath.includes(".framework/")) return null;
  const match = loadPath.match(/(?:@rpath\/|\/)([^/]+\.dylib)$/);
  return match ? match[1] : null;
}

/** Frameworks carry a versioned directory name; the bundle name is not it. */
function resolveFramework(frameworksDirectory, name) {
  const direct = path.join(frameworksDirectory, name);
  if (fs.existsSync(direct)) return direct;
  const wanted = name.replace(/\.framework$/, "");
  const entries = fs.readdirSync(frameworksDirectory).filter((e) => e.endsWith(".framework"));
  for (const entry of entries) {
    const base = entry.replace(/\.framework$/, "").replace(/\.\d+.*$/, "");
    if (base === wanted.replace(/\.\d+.*$/, "")) return path.join(frameworksDirectory, entry);
  }
  return null;
}

function executableIn(frameworkDirectory) {
  const name = path.basename(frameworkDirectory, ".framework");
  const direct = path.join(frameworkDirectory, name);
  if (fs.existsSync(direct)) return direct;
  // Versioned frameworks keep the binary under Versions/A/.
  const versioned = path.join(frameworkDirectory, "Versions", "A", name);
  if (fs.existsSync(versioned)) return versioned;
  const candidates = fs
    .readdirSync(frameworkDirectory)
    .map((entry) => path.join(frameworkDirectory, entry))
    .filter((entry) => fs.statSync(entry).isFile());
  return candidates[0] ?? null;
}

function directorySize(target) {
  const stats = fs.statSync(target);
  if (!stats.isDirectory()) return stats.size;
  let total = 0;
  for (const entry of fs.readdirSync(target)) total += directorySize(path.join(target, entry));
  return total;
}

function copyTree(from, to) {
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.cpSync(from, to, { recursive: true, dereference: true });
}

function main() {
  const app = process.argv[2];
  const destination = process.argv[3] ?? path.join(process.cwd(), "Dependencies");
  if (!app) {
    console.error("usage: slim_runtime.mjs <UTM.app directory> [output directory]");
    process.exit(2);
  }

  const frameworksSource = path.join(app, "Frameworks");
  const firmwareSource = path.join(app, "qemu");
  const rootName = "qemu-aarch64-softmmu.framework";
  const rootFramework = resolveFramework(frameworksSource, rootName);
  if (!rootFramework) {
    console.error(`error: ${rootName} not found in ${frameworksSource}`);
    process.exit(1);
  }

  // Walk the load-command graph from the system emulator downwards.
  const required = new Set();
  const dylibs = new Set();
  const queue = [rootFramework];
  const visited = new Set();
  while (queue.length > 0) {
    const framework = queue.shift();
    if (visited.has(framework)) continue;
    visited.add(framework);
    required.add(framework);
    const binary = executableIn(framework);
    if (!binary) continue;
    for (const load of dependencies(binary)) {
      const name = frameworkOf(load);
      if (name) {
        const resolved = resolveFramework(frameworksSource, name);
        // Frameworks absent from the bundle are Apple's own and come from the OS.
        if (resolved && !visited.has(resolved)) queue.push(resolved);
        continue;
      }
      const plain = dylibOf(load);
      if (plain) {
        const resolved = path.join(frameworksSource, plain);
        if (fs.existsSync(resolved)) dylibs.add(resolved);
      }
    }
  }

  fs.rmSync(destination, { recursive: true, force: true });
  const frameworksDestination = path.join(destination, "Frameworks");
  fs.mkdirSync(frameworksDestination, { recursive: true });

  for (const framework of required) {
    copyTree(framework, path.join(frameworksDestination, path.basename(framework)));
  }
  for (const dylib of dylibs) {
    copyTree(dylib, path.join(frameworksDestination, path.basename(dylib)));
  }

  // Firmware is looked up by name at device creation, so the filter is about
  // reachability, not size: aarch64 UEFI code plus the ARM variable-store
  // template (UTM uses edk2-arm-vars.fd for aarch64 too). The small option
  // ROMs stay because QEMU resolves them by name; the 67 MB edk2 blobs for
  // other architectures do not.
  const aarch64Firmware = new Set(["edk2-aarch64-code.fd", "edk2-arm-vars.fd"]);
  const firmwareDestination = path.join(destination, "qemu");
  fs.mkdirSync(firmwareDestination, { recursive: true });
  let keptFirmware = 0;
  for (const entry of fs.readdirSync(firmwareSource)) {
    const source = path.join(firmwareSource, entry);
    if (!fs.statSync(source).isFile()) continue;
    const isEdk2 = entry.startsWith("edk2-");
    const keep = isEdk2 ? aarch64Firmware.has(entry) : fs.statSync(source).size <= 1024 * 1024;
    if (!keep) continue;
    fs.copyFileSync(source, path.join(firmwareDestination, entry));
    keptFirmware += 1;
  }

  const megabytes = (target) => (directorySize(target) / 1e6).toFixed(1);
  console.log(`Frameworks: ${fs.readdirSync(frameworksDestination).length} (${megabytes(frameworksDestination)} MB)`);
  console.log(`Firmware:   ${keptFirmware} file(s) (${megabytes(firmwareDestination)} MB)`);
  console.log(`Runtime:    ${megabytes(destination)} MB total`);
}

main();
