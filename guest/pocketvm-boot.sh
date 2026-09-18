#!/bin/bash
set -u
BASE="${POCKETVM_BASE:-http://10.0.2.2:8474}"
LIB=/usr/local/lib/pocketvm
queue_ssh() {
  ssh-keygen -A || return 1
  systemctl enable ssh.service || return 1
  # bootcmd runs inside cloud-init's network initialization. Waiting here for
  # ssh's After=network.target job prevents that target from being reached.
  systemctl start --no-block ssh.service
}
curl --noproxy '*' -fsS -m 10 -H 'Content-Type: application/json' -d '{"stage":"booting"}' "$BASE/boot" >/dev/null || true
install -d "$LIB" || exit 1
# Port 22 is exposed by the host only when the developer switch is enabled.
if curl --noproxy '*' -fsS -m 20 "$BASE/developer.json" -o /run/pocketvm-developer.json; then
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open("/run/pocketvm-developer.json")).get("ssh") is True else 1)'; then
    # SSH failure must not prevent the Codex relay from starting.
    if queue_ssh; then
      curl --noproxy '*' -fsS -m 10 -H 'Content-Type: application/json' -d '{"state":"queued"}' "$BASE/ssh" >/dev/null || true
    else
      curl --noproxy '*' -fsS -m 10 -H 'Content-Type: application/json' -d '{"ok":false}' "$BASE/ssh" >/dev/null || true
    fi
  fi
fi
fetch() {
  curl --noproxy '*' -fsS -m 60 "$BASE/$1" -o "$2.new" || return 1
  mv "$2.new" "$2"
}
fetch pocketvm-relay.mjs "$LIB/pocketvm-relay.mjs" || exit 1
fetch pocketvm-report.sh /usr/local/sbin/pocketvm-report || exit 1
chmod 0755 /usr/local/sbin/pocketvm-report
cat >"$LIB/run-relay.sh" <<'EOF'
#!/bin/bash
if [ -r /etc/profile.d/pocketvm-proxy.sh ]; then . /etc/profile.d/pocketvm-proxy.sh; fi
exec node /usr/local/lib/pocketvm/pocketvm-relay.mjs
EOF
cat >/etc/systemd/system/pocketvm-relay.service <<EOF
[Unit]
Description=PocketVM persistent Codex protocol connection
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
User=codex
Environment=HOME=/home/codex
Environment=POCKETVM_BASE=$BASE
WorkingDirectory=/home/codex
ExecStart=/bin/bash $LIB/run-relay.sh
Restart=always
RestartSec=3
KillMode=control-group
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/pocketvm-report.service <<'EOF'
[Unit]
Description=PocketVM boot file upload and proxy setup
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pocketvm-report
TimeoutStartSec=1800
[Install]
WantedBy=multi-user.target
EOF
install -d /etc/systemd/system/serial-getty@ttyAMA0.service.d
cat >/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin codex --keep-baud 115200,38400,9600 %I $TERM
EOF
# Remove obsolete services from existing guests without touching their disks.
systemctl disable --now pocketvm-agent.service pocketvm-ready.service >/dev/null 2>&1 || true
systemctl daemon-reload || exit 1
systemctl enable pocketvm-relay.service pocketvm-report.service serial-getty@ttyAMA0.service || exit 1
systemctl start --no-block pocketvm-relay.service pocketvm-report.service serial-getty@ttyAMA0.service || exit 1
if [ -f /usr/local/sbin/pocketvm-provision.sh ]; then
  cat >/etc/systemd/system/pocketvm-repair.service <<'EOF'
[Unit]
Description=Resume incomplete PocketVM installation
After=cloud-final.service network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'test -f /var/lib/pocketvm/install-complete && timeout 30 codex --version >/dev/null 2>&1 && command -v node >/dev/null || /usr/local/sbin/pocketvm-provision.sh'
TimeoutStartSec=1800
EOF
  systemctl daemon-reload
  systemctl start --no-block pocketvm-repair.service
fi
