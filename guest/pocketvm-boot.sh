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

# The console the app shows. The serial line is a terminal only once something
# is reading it and printing to it, and a stock cloud image leaves ttyAMA0
# unattended — which is why the panel used to be empty.
AUTOLOGIN=/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf
if [ ! -f "$AUTOLOGIN" ]; then
  install -d "$(dirname "$AUTOLOGIN")" 2>/dev/null || true
  cat >"$AUTOLOGIN" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin codex --keep-baud 115200,38400,9600 %I $TERM
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
serial=0
if systemctl enable --now serial-getty@ttyAMA0.service >/dev/null 2>&1; then
  serial=1
fi

# A login prompt on the picture as well, so the 画面 tab shows a live machine
# instead of the boot loader's last frame.
systemctl enable --now getty@tty1.service >/dev/null 2>&1 || true

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
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
systemctl enable pocketvm-report.service >/dev/null 2>&1 || true

# What this run managed, so the host log answers "did the guest pick it up"
# without anyone having to look at the screen.
post console "{\"serial\":$serial,\"helpers\":$helpers}"
