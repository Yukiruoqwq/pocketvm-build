#!/bin/bash
# Tell the host that this boot is up.
#
# The serial console is a terminal, not a protocol: it echoes what is typed into
# it, ends its lines with CR LF, and wraps. Everything the host needs to know
# arrives here instead — a POST with a JSON body to the host's own helper
# server, which QEMU's user-mode networking exposes as 10.0.2.2.
#
#   bash pocketvm-report.sh --install   # put this on the guest, enable at boot
#   bash pocketvm-report.sh             # report now (what the unit runs)
set -u

HOST="${POCKETVM_HOST:-10.0.2.2}"
PORT="${POCKETVM_PORT:-8474}"
BASE="http://$HOST:$PORT"
LIB=/usr/local/lib/pocketvm

post() { # path, body
  curl -fsS -m 30 -H 'Content-Type: application/json' -X POST "$BASE/$1" -d "$2" >/dev/null 2>&1 || true
}

install_self() {
  command -v curl >/dev/null 2>&1 || return 1
  install -d "$LIB" || return 1
  curl -fsS -m 60 "$BASE/pocketvm-report.sh" -o /usr/local/sbin/pocketvm-report || return 1
  curl -fsS -m 60 "$BASE/pocketvm-app.mjs" -o "$LIB/pocketvm-app.mjs" || true
  chmod 0755 /usr/local/sbin/pocketvm-report
  cat >/etc/systemd/system/pocketvm-report.service <<'EOF'
[Unit]
Description=PocketVM boot report
Documentation=https://github.com/abasbdjasdl/pocketvm-build
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
  systemctl enable pocketvm-report.service >/dev/null 2>&1 || true
}

report() {
  # The system is up; the CLI inside it is what the host's next line is about.
  # pocketvm-boot.sh sends this earlier in the boot, and this is the fallback for
  # a guest that has not picked that script up yet.
  post boot '{"stage":"booting"}'
  command -v codex >/dev/null 2>&1 || return 0
  version="$(codex --version 2>/dev/null | head -n1 | tr -d '\r\"')"
  post ready "{\"stage\":\"ready\",\"version\":\"${version:-unknown}\"}"
  # One app-server session answers all of it: models, usage limits and the
  # conversation list. Starting the server three times would cost more in the
  # emulated guest than the answers do.
  if [ -f "$LIB/pocketvm-app.mjs" ] && command -v node >/dev/null 2>&1; then
    node "$LIB/pocketvm-app.mjs" > /tmp/pocketvm-report.json 2>/dev/null || true
    if [ -s /tmp/pocketvm-report.json ]; then
      post report "$(cat /tmp/pocketvm-report.json)"
    fi
  fi
}

case "${1:---boot}" in
  --install)
    install_self
    report
    ;;
  *)
    report
    ;;
esac
