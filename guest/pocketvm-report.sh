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
  curl --noproxy '*' -fsS -m 30 -H 'Content-Type: application/json' -X POST "$BASE/$1" -d "$2" >/dev/null 2>&1
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
  batch="$(cat /proc/sys/kernel/random/uuid)"
  marker=/var/lib/pocketvm/boot-files-sent
  # Re-upload each boot: host files may have been lost after a previous report.
  vmlinuz="/boot/vmlinuz-$kernel"
  initrd="/boot/initrd.img-$kernel"
  [ -f "$vmlinuz" ] && [ -f "$initrd" ] || return 1
  # The proxy profile inside the guest is for the outside world; this is the
  # host on the other end of the emulated network.
  # No 100-continue: this listener answers once, when it has the whole body.
  curl -fsS -m 600 --noproxy '*' -H 'Expect:' -T "$vmlinuz" "$BASE/upload/${batch}_vmlinuz" >/dev/null 2>&1 || return 1
  curl -fsS -m 600 --noproxy '*' -H 'Expect:' -T "$initrd" "$BASE/upload/${batch}_initrd" >/dev/null 2>&1 || return 1
  install -d "$(dirname "$marker")" 2>/dev/null || true
  echo "$kernel" >"$marker"
  kernel_hash="$(sha256sum "$vmlinuz" | cut -d ' ' -f1)"
  initrd_hash="$(sha256sum "$initrd" | cut -d ' ' -f1)"
  post bootfiles "{\"batch\":\"$batch\",\"vmlinuz\":\"$kernel_hash\",\"initrd\":\"$initrd_hash\"}"
}

# Install the guest's own proxy, once, from the app.
#
# The subscription belongs to the person holding the tablet: it is kept in
# Documents/proxy.txt on the device and served to the guest over the emulated
# network, so it is never part of a build anyone can download. No URL means no
# proxy, which is the right answer for a machine whose owner did not ask for one.
setup_proxy() {
  marker=/var/lib/pocketvm/proxy-ready
  url="$(curl -fsS -m 20 --noproxy '*' "$BASE/proxy-url.txt" 2>/dev/null | head -n1 || true)"
  case "$url" in
    http://*|https://*) ;;
    *) return 0 ;;
  esac
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$url" ] && systemctl is-active --quiet mihomo; then return 0; fi
  script=/tmp/pocketvm-setup-proxy.sh
  curl -fsS -m 60 --noproxy '*' "$BASE/setup-proxy.sh" -o "$script" 2>/dev/null || return 1
  head -n1 "$script" | grep -q '^#!' || return 1
  bash "$script" "$url" >/tmp/pocketvm-proxy.log 2>&1
  if [ $? -eq 0 ]; then
    install -d "$(dirname "$marker")" 2>/dev/null || true
    echo "$url" >"$marker"
    proxy_changed=1
    post proxy '{"ok":true}'
  else
    # Left unmarked on purpose: the next boot tries again.
    post proxy '{"ok":false}'
  fi
}

install_self() {
  curl --noproxy '*' -fsS -m 60 "$BASE/pocketvm-boot.sh" -o /tmp/pocketvm-install-services.sh || return 1
  bash -n /tmp/pocketvm-install-services.sh || return 1
  POCKETVM_BASE="$BASE" bash /tmp/pocketvm-install-services.sh || return 1
}
report() {
  command -v node >/dev/null 2>&1 || return 1
  command -v codex >/dev/null 2>&1 || return 1
  proxy_changed=0
  setup_proxy || true
  if [ "$proxy_changed" = 1 ]; then systemctl restart --no-block pocketvm-relay.service || return 1; fi
  upload_boot_files
}

case "${1:---boot}" in
  --install)
    install_self || exit 1
    report
    ;;
  *)
    report
    ;;
esac
