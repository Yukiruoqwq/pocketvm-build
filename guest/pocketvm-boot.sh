#!/bin/bash
# Runs inside the guest on every boot.
#
# cloud-init's bootcmd fetches this from the app's own helper server and runs it
# before multi-user. That is the only channel that can change anything inside a
# guest that is already installed: the disk image is tens of gigabytes and there
# is no shell on the device to type into until this has run once.
#
#   bootcmd: [ bash, -c, "curl …/pocketvm-boot.sh | POCKETVM_BASE=… bash" ]
#
# Everything here is idempotent and every failure is swallowed: a slow link or a
# missing unit must not keep the machine from booting.
set -u

BASE="${POCKETVM_BASE:-http://10.0.2.2:8474}"
LIB=/usr/local/lib/pocketvm

post() { # path, body
  curl -fsS -m 20 -H 'Content-Type: application/json' -X POST "$BASE/$1" -d "$2" >/dev/null 2>&1 || true
}

# The host's 正在启动 Codex CLI line hangs off this: the guest's own system is up
# and the CLI is what is still coming.
post boot '{"stage":"booting"}'

fetch() { # remote path, destination
  curl -fsS -m 60 "$BASE/$1" -o "$2.new" 2>/dev/null || { rm -f "$2.new"; return 1; }
  mv "$2.new" "$2"
}

install -d "$LIB" 2>/dev/null || true
helpers=0
if fetch pocketvm-report.sh /usr/local/sbin/pocketvm-report; then
  chmod 0755 /usr/local/sbin/pocketvm-report
  helpers=1
fi
fetch pocketvm-app.mjs "$LIB/pocketvm-app.mjs" || true

# The sign-in helper is where the app can find it. cloud-init writes it to
# /usr/local/sbin for a machine installed by this build's earlier versions, and
# the console logs in as `codex`: a normal user's PATH has no sbin directories,
# so a bare `pocketvm-auth` typed at that shell is "command not found".
if [ -x /usr/local/sbin/pocketvm-auth ] && [ ! -e /usr/local/bin/pocketvm-auth ]; then
  ln -sf /usr/local/sbin/pocketvm-auth /usr/local/bin/pocketvm-auth 2>/dev/null || true
fi

# The app boots this kernel directly, so the boot loader is normally not in the
# path at all. It is still cleared here: a machine that was killed leaves GRUB's
# recordfail set, and if anything ever boots through it again — an older build,
# a missing kernel file — Debian's boot loader would stop at its menu and wait
# for a key that nothing on a tablet can press.
if command -v grub-editenv >/dev/null 2>&1 && [ -f /boot/grub/grubenv ]; then
  grub-editenv /boot/grub/grubenv unset recordfail >/dev/null 2>&1 || true
fi

# The console the app shows. The serial line is a terminal only once something
# is reading it and printing to it, and a stock cloud image leaves ttyAMA0
# unattended — which is why the panel used to be empty.
#
# All of it runs detached, and every systemd call is bounded. This script is
# cloud-init's bootcmd, which runs in the init stage: a start job that cannot
# complete there waits for ever and holds the whole boot with it — which is
# exactly what happened the first time a fresh install ran this script. The
# machine now boots whether or not its console comes up with it.
install_console() {
  AUTOLOGIN=/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf
  if [ ! -f "$AUTOLOGIN" ]; then
    install -d "$(dirname "$AUTOLOGIN")" 2>/dev/null || true
    cat >"$AUTOLOGIN" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin codex --keep-baud 115200,38400,9600 %I $TERM
EOF
    timeout 20 systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  serial=0
  timeout 20 systemctl enable serial-getty@ttyAMA0.service >/dev/null 2>&1 || true
  if timeout 20 systemctl start serial-getty@ttyAMA0.service >/dev/null 2>&1; then
    serial=1
  fi

  # The boot report. Written here as well as at install time so that a guest set
  # up by an older build gets it without being reinstalled.
  UNIT=/etc/systemd/system/pocketvm-report.service
  if [ ! -f "$UNIT" ]; then
    cat >"$UNIT" <<'EOF'
[Unit]
Description=PocketVM boot report
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pocketvm-report

[Install]
WantedBy=multi-user.target
EOF
    timeout 20 systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  timeout 20 systemctl enable pocketvm-report.service >/dev/null 2>&1 || true

  # What this run managed, so the host log answers "did the guest pick it up"
  # without anyone having to look at the screen.
  post console "{\"serial\":$serial,\"helpers\":$helpers}"
}

install_console >/dev/null 2>&1 &
