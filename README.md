# PocketVM

An independent iOS app that runs a QEMU virtual machine. Built for the M4 iPad
so that a future frontend can drive the VM configuration, with no dependency on
the UTM app.

## Why this exists

UTM proved the platform limits on this device: no hardware virtualization
(`com.apple.private.hypervisor` is Apple-private), no JIT entitlement, and no
app-group entitlement on a sideloaded build. We measured all three. What is
left is a software-emulated ARM64 guest, which is slow for a desktop but
adequate for a headless Linux environment driven by an agent.

The goal here is not to recreate UTM. It is a small app whose entire job is:

1. Acquire JIT so QEMU's translator can emit code.
2. Run a QEMU system emulator in-process.
3. Describe the VM in a plain, versioned config file.
4. Expose the console.

Step 3 is the interface the frontend will use later: edit the config, restart
the VM, the change takes effect.

## Dependency on UTM's source

Upstream QEMU does not build for iOS. We use the `utmapp/qemu` fork, which adds
the shared-library build and the iOS patches, together with UTM's dependency
build script for the sysroot. Both are GPLv3. This app is therefore GPLv3 and
stays that way.

That is a dependency on UTM's *sources*, not on the UTM app. Nothing here needs
UTM installed, and the VM format, config, and UI are ours.

## Integration contract

QEMU is loaded as a dynamic library, exactly as the fork is built to allow:

| Item | Value |
| --- | --- |
| Library | `Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu` |
| Entry points | `qemu_init`, `qemu_main_loop`, `qemu_cleanup` |
| Firmware | `qemu/edk2-aarch64-code.fd`, `qemu/edk2-aarch64-vars.fd` |
| Install names | rewritten to `@rpath/<name>.framework/<name>` |

The library is `dlopen`ed and the loop runs on a dedicated thread, because
`qemu_main_loop` does not return until the guest shuts down.

## Milestones

**M1 - headless serial console.** The app starts, confirms JIT, loads the QEMU
library, boots the Debian guest with `-display none`, and presents the guest
console. No graphics. This is the whole product for the agent use case, and it
is the milestone being built now.

**M2 - configuration.** The config file becomes editable, and a restart applies
it: CPU count, memory, JIT cache size, added drives, port forwards. This is what
the future frontend drives.

**M3 - graphics.** virtio-gpu plus a Metal renderer, only if a graphical guest
still looks worth having after M1 and M2 are in real use.

## Configuration format

`Documents/pocketvm.json`. Versioned, so the frontend can migrate it. Written
by hand or by the frontend; read at VM start.

```json
{
  "version": 1,
  "name": "Debian",
  "cpuCount": 4,
  "memoryMiB": 4096,
  "jitCacheMiB": 512,
  "forceMulticore": true,
  "boot": { "mode": "uefi" },
  "drives": [
    { "path": "efi_vars.fd", "interface": "pflash", "readOnly": false },
    { "path": "debian.qcow2", "interface": "virtio", "readOnly": false }
  ],
  "network": { "enabled": true, "portForwards": [] }
}
```

Drive paths are relative to `Documents/`.

## JIT

QEMU's translator needs writable, executable memory, which iOS refuses without
the `dynamic-codesigning` entitlement. A sideloaded build cannot carry it, so
the app relies on a debugger being attached: `csops` reports `CS_DEBUGGED` and
the kernel then permits the allocation. StikDebug provides that attach.

The app checks the flag and refuses to start the VM without it, because running
an emulator that cannot translate is worse than refusing: it produces
misleading failures.

## Provisioning

The app ships no disk image. On first start it:

1. downloads Debian's aarch64 cloud image (~320 MB) and checks the published
   SHA-512 before using it;
2. starts a small HTTP server on loopback and points cloud-init at it with
   `-smbios type=1,serial=ds=nocloud-net;s=http://10.0.2.2:PORT/` — QEMU's
   user-mode networking makes `10.0.2.2` the host, so the guest fetches its seed
   with no port forwarding;
3. grows the qcow2 to the configured size through the emulator's monitor before
   the guest reads its partition table;
4. boots once, with cloud-init setting up an account, a serial console that
   logs in by itself, and a script that installs Node and the Codex CLI, then
   reports progress on the serial line the app is already reading.

Boot two and later are a plain boot of the same disk. The seed arguments stay in
the boot profile all the same, so a failed first boot can be retried without a
second code path.

## Signing in to Codex

The guest is headless, so the CLI's device-code flow is the only one that fits.
The app sends `pocketvm-auth start` over the serial console, reads the URL and
the one-time code out of the guest's output, and shows them in the frontend with
a button that hands the URL to Safari. Polling is done by the same script, which
prints one fixed status line per poll — the app never has to interpret a TUI.

## Building

GitHub Actions, macOS runner, driven from the public mirror of this repository
(`scripts/publish_build_repo.ps1`). The QEMU runtime is fetched from a release
asset built out of UTM's own dependency build, so an app-only change builds in
minutes instead of rebuilding the emulator.

The mirror is public because GitHub does not bill standard runners for public
repositories and bills macOS runners at ten times the normal rate for private
ones. It carries no history and only the directories the build reads, so the
reference material this repository keeps for design comparison never lands in
it.

The mirror is disposable and has been deleted once already. To rebuild it:

```powershell
gh repo create <owner>/pocketvm-build --public
powershell -File scripts/publish_build_repo.ps1 -Remote https://github.com/<owner>/pocketvm-build.git
gh release create runtime-1 ..\pocketvm-runtime-ios-arm64.tar.gz --repo <owner>/pocketvm-build
```

`pocketvm-runtime-ios-arm64.tar.gz` is the aarch64 runtime this repository's own
`scripts/slim_runtime.mjs` produced from UTM's iOS dependency build; keep a copy
outside the repository (it is 17 MB, and the workflow's `RUNTIME_URL` expects it
as a release asset).

Locally, on a Mac with Xcode:

```sh
node scripts/slim_runtime.mjs /path/to/UTM.app            # or use POCKETVM_SYSROOT
bash scripts/build_local.sh path/to/UTM.ipa
```

## Status

The first boot, the serial console and the guest provisioning have all run on
the device: cloud-init sets the guest up, the host reads the same console the
terminal shows, and `provision.json` ends up marked complete. `docs/ON-DEVICE.md`
is the checklist, including what the gate is waiting for on every later boot.
