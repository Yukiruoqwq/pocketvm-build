# Third-party components

PocketVM's own code is GPL-3.0-or-later (see `LICENSE`). The app embeds or
downloads the following work by others.

## QEMU runtime (embedded in the app bundle)

The system emulator is UTM's QEMU fork, built for iOS by UTM's dependency
script, then reduced to the aarch64 parts by `scripts/slim_runtime.mjs`.

- Source: https://github.com/utmapp/UTM (commit
  `b6f7475be54f9cb542c46b131319454b83489ced`), https://github.com/utmapp/qemu
- Version: QEMU 10.0.12 (utm fork)
- License: GPL-2.0 (QEMU), with the libraries QEMU links against under their own
  terms — GLib/Pixman (LGPL-2.1), libslirp (BSD-3-Clause), OpenSSL (Apache-2.0),
  and others. The framework bundles carry their own licence files.

The runtime is loaded as a separate dynamic library (`dlopen`) exactly as UTM's
own app loads it.

## Firmware (embedded in the app bundle)

- `edk2-aarch64-code.fd`, `edk2-arm-vars.fd` — EDK II / ArmVirtQemu, from the
  QEMU build above. BSD-2-Clause-Patent.
- Assorted option ROMs and device trees from the same build, kept because QEMU
  resolves them by name at device creation.

## Guest operating system (downloaded by the user's device, not distributed)

- Debian 13 "trixie" genericcloud, aarch64 build `20260914-2601`, from
  https://cloud.debian.org/images/cloud/. The app verifies the published
  SHA-512 before first boot. Debian's own licensing applies to the guest.
- Codex CLI (`@openai/codex` from npm) is installed inside the guest by
  cloud-init on first boot, at the user's request, under OpenAI's terms.

## Frontend

- xterm.js 5.5.0 and `@xterm/addon-fit`, MIT — `web/vendor/`.
