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

# Hand the app the two files it boots next time, so that from the next start on
# the firmware and the boot loader never run: nothing can stop at a menu and wait
# for a key, and the console is printing a second after power-on.
#
# They are this machine's own kernel and the initrd built for it, so
# /lib/modules always matches. The marker holds the version that was sent: a
# kernel upgrade makes the next boot send the new pair.
upload_boot_files() {
  kernel="$(uname -r)"
  marker=/var/lib/pocketvm/boot-files-sent
  [ -r "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$kernel" ] && return 0
  vmlinuz="/boot/vmlinuz-$kernel"
  initrd="/boot/initrd.img-$kernel"
  [ -f "$vmlinuz" ] && [ -f "$initrd" ] || return 0
  # The proxy profile inside the guest is for the outside world; this is the
  # host on the other end of the emulated network.
  # No 100-continue: this listener answers once, when it has the whole body.
  curl -fsS -m 600 --noproxy '*' -H 'Expect:' -T "$vmlinuz" "$BASE/upload/vmlinuz" >/dev/null 2>&1 || return 0
  curl -fsS -m 600 --noproxy '*' -H 'Expect:' -T "$initrd" "$BASE/upload/initrd" >/dev/null 2>&1 || return 0
  install -d "$(dirname "$marker")" 2>/dev/null || true
  echo "$kernel" >"$marker"
  post bootfiles "{\"kernel\":\"$kernel\"}"
}

# Install the guest's own proxy, once, from the app.
#
# The subscription belongs to the person holding the tablet: it is kept in
# Documents/proxy.txt on the device and served to the guest over the emulated
# network, so it is never part of a build anyone can download. No URL means no
# proxy, which is the right answer for a machine whose owner did not ask for one.
setup_proxy() {
  marker=/var/lib/pocketvm/proxy-ready
  [ -f "$marker" ] && return 0
  url="$(curl -fsS -m 20 --noproxy '*' "$BASE/proxy-url.txt" 2>/dev/null | head -n1 || true)"
  case "$url" in
    http*) ;;
    *) return 0 ;;
  esac
  script=/tmp/pocketvm-setup-proxy.sh
  curl -fsS -m 60 --noproxy '*' "$BASE/setup-proxy.sh" -o "$script" 2>/dev/null || return 0
  head -n1 "$script" | grep -q '^#!' || return 0
  bash "$script" "$url" >/tmp/pocketvm-proxy.log 2>&1
  if [ $? -eq 0 ]; then
    install -d "$(dirname "$marker")" 2>/dev/null || true
    echo "$url" >"$marker"
    post proxy '{"ok":true}'
  else
    # Left unmarked on purpose: the next boot tries again.
    post proxy '{"ok":false}'
  fi
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
  # The proxy must be ready before app-server is contacted. The service runs as
  # root, while the authenticated CLI state belongs to codex; querying as root
  # made every installation look signed out and returned an empty thread list.
  setup_proxy
  # One app-server session answers all of it: models, usage limits and the
  # conversation list. Starting the server three times would cost more in the
  # emulated guest than the answers do.
  if [ -f "$LIB/pocketvm-app.mjs" ] && command -v node >/dev/null 2>&1; then
    export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
    export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
    export ALL_PROXY="${ALL_PROXY:-socks5://127.0.0.1:7890}"
    export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,10.0.2.2}"
    if id codex >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
      runuser -u codex -- env HOME=/home/codex HTTPS_PROXY="$HTTPS_PROXY" HTTP_PROXY="$HTTP_PROXY" ALL_PROXY="$ALL_PROXY" NO_PROXY="$NO_PROXY" \
        node "$LIB/pocketvm-app.mjs" > /tmp/pocketvm-report.json 2>/dev/null || true
    elif id codex >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
      sudo -u codex -H env HTTPS_PROXY="$HTTPS_PROXY" HTTP_PROXY="$HTTP_PROXY" ALL_PROXY="$ALL_PROXY" NO_PROXY="$NO_PROXY" \
        node "$LIB/pocketvm-app.mjs" > /tmp/pocketvm-report.json 2>/dev/null || true
    else
      node "$LIB/pocketvm-app.mjs" > /tmp/pocketvm-report.json 2>/dev/null || true
    fi
    if [ -s /tmp/pocketvm-report.json ]; then
      post report "$(cat /tmp/pocketvm-report.json)"
    fi
  fi
  upload_boot_files
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
