#!/bin/bash
# Put a proxy inside the guest.
#
# iOS allows exactly one active VPN tunnel, and this device needs it for the
# LocalDevVPN that JIT depends on. So the proxying happens one layer deeper: a
# Clash Meta (mihomo) client inside the guest, which the Codex CLI reaches
# through a loopback proxy. The iPad's own tunnel is then never contested.
#
#   bash setup-proxy.sh 'https://…/clashmeta/' [port]
#
# The binary comes from a pinned release rather than from the releases API: the
# API needs a JSON parser, rate-limits unauthenticated callers, and answers with
# a different asset list every time the project publishes a build. Override with
# MIHOMO_VERSION if that tag ever disappears.
set -u

SUB_URL="${1:?usage: setup-proxy.sh <subscription-url> [port]}"
PORT="${2:-7890}"
TTY=/dev/ttyAMA0

say() {
  printf 'POCKETVM: %s\n' "$*" >"$TTY" 2>/dev/null || true
  echo "$*"
}

VERSION="${MIHOMO_VERSION:-v1.19.31}"
say "下载代理内核 $VERSION"
if [ -x /usr/local/bin/mihomo ]; then
  say "内核已存在，跳过下载"
else
  # GitHub from inside a guest on a Chinese network is often reachable and very
  # slow, and an interrupted transfer looks exactly like a hang. The first two
  # addresses are on the local network, where the app's own machine can hold a
  # copy; the last one is the real thing, and a proxy prefix for when it is not.
  sources="
http://192.168.1.24:8770/mihomo.gz
http://10.0.2.2:8474/mihomo.gz
https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/mihomo-linux-arm64-$VERSION.gz
https://ghfast.top/https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/mihomo-linux-arm64-$VERSION.gz"
  got=0
  for source in $sources; do
    [ -n "$source" ] || continue
    say "尝试 $source"
    if curl -fL --retry 1 --connect-timeout 15 --max-time 600 --progress-bar \
        "$source" -o /tmp/mihomo.gz 2>/dev/ttyAMA0 \
        && gzip -dc /tmp/mihomo.gz >/usr/local/bin/mihomo \
        && chmod 0755 /usr/local/bin/mihomo \
        && /usr/local/bin/mihomo -v >/dev/null 2>&1; then
      got=1
      break
    fi
    rm -f /usr/local/bin/mihomo
  done
  if [ "$got" != "1" ]; then
    say "下载代理内核失败：几个来源都没成功"
    exit 1
  fi
fi
say "内核 $(/usr/local/bin/mihomo -v 2>/dev/null | head -n1)"

install -d /etc/mihomo
# The subscription is fetched exactly once and then kept. Some panels issue a
# link that is good for a single request, and re-fetching to "fix" a running
# proxy would spend it for nothing.
if [ -s /etc/mihomo/config.yaml ]; then
  say "已有订阅文件，跳过拉取"
else
  say "拉取订阅"
  # Panels serve the Clash config only to a client they recognise, and some
  # answer a bare curl with an empty 304. Send the user agent mihomo would send.
  curl -fsSL --max-time 120 -A "mihomo" -H 'Cache-Control: no-cache' \
    "$SUB_URL" -o /etc/mihomo/config.yaml 2>/dev/null || true
  if [ ! -s /etc/mihomo/config.yaml ]; then
    rm -f /etc/mihomo/config.yaml
    say "订阅没有返回内容：链接可能已失效或只能用一次，或者面板只对特定客户端返回"
    exit 1
  fi
  if ! grep -qE '^(proxies|proxy-providers):' /etc/mihomo/config.yaml; then
    say "订阅内容不像 Clash 配置，确认链接是 clashmeta/clash 格式"
    exit 1
  fi
fi

# The subscription owns the proxy list; the listening ports and the controller
# are ours. It also commonly ships a TUN block, which cannot work in this guest:
# there is no usable TUN device, and mihomo exits before it ever opens the mixed
# port. DNS that listens on port 53 can fail the same way under systemd-resolved.
#
# Everything is rewritten on every run, not only the first one: a guest that
# already has the old port marker must still lose a TUN block added by a later
# subscription, or its proxy comes back up dead after an update.
sanitize_config() {
  local conf=/etc/mihomo/config.yaml
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$conf" "$PORT" <<'PY'
import re
import sys

path, port = sys.argv[1], sys.argv[2]
skip = {
    "tun", "dns", "mixed-port", "socks-port", "port", "allow-lan",
    "external-controller", "log-level",
}
out = []
skipping = False
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    match = re.match(r"^([^\s#][^:]*):", line)
    if match:
        key = match.group(1)
        skipping = key in skip
        if skipping:
            continue
    if not skipping:
        out.append(line)
while out and out[-1].strip() in ("", "..."):
    out.pop()
out += [
    "",
    "# pocketvm-port",
    f"mixed-port: {port}",
    "allow-lan: false",
    "external-controller: 127.0.0.1:9090",
    "log-level: warning",
    "tun:",
    "  enable: false",
]
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  else
    # Fallback for a guest without python3: the two blocks that stop mihomo on
    # this image are removed, then the listener settings are appended.
    awk '
      BEGIN { skip = 0 }
      /^[#]/ { print; next }
      /^[^[:space:]#][^:]*:/ {
        key = $0; sub(/:.*/, "", key)
        skip = (key == "tun" || key == "dns" || key == "mixed-port" ||
                key == "socks-port" || key == "port" || key == "allow-lan" ||
                key == "external-controller" || key == "log-level")
        if (skip) next
      }
      !skip { print }
    ' "$conf" >"$conf.tmp" && mv "$conf.tmp" "$conf"
    cat >>"$conf" <<EOF

# pocketvm-port
mixed-port: $PORT
allow-lan: false
external-controller: 127.0.0.1:9090
log-level: warning
tun:
  enable: false
EOF
  fi
}
cp /etc/mihomo/config.yaml /etc/mihomo/config.yaml.bak 2>/dev/null || true
sanitize_config

if ! /usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml -t; then
  say "mihomo 配置测试失败；原订阅文件已备份到 /etc/mihomo/config.yaml.bak"
  exit 1
fi

say "注册服务"
cat >/etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=mihomo proxy for the Codex CLI
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable mihomo >/dev/null 2>&1 || true
systemctl restart mihomo >/dev/null 2>&1 || true

say "等待代理可用"
ready=0
for _ in $(seq 1 30); do
  if curl -fsS -x "http://127.0.0.1:$PORT" --max-time 8 -o /dev/null \
      https://www.gstatic.com/generate_204; then
    ready=1
    break
  fi
  sleep 3
done
if [ "$ready" != "1" ]; then
  say "代理进程起来了但连不通，日志如下"
  journalctl -u mihomo -n 40 --no-pager 2>/dev/ttyAMA0 || true
  exit 1
fi

say "给 codex 账号设置环境变量"
cat >/etc/profile.d/pocketvm-proxy.sh <<EOF
# Written by PocketVM. The guest reaches OpenAI through its own proxy so that
# the iPad's only VPN tunnel stays available to the JIT debugger.
export HTTPS_PROXY=http://127.0.0.1:$PORT
export HTTP_PROXY=http://127.0.0.1:$PORT
export ALL_PROXY=socks5://127.0.0.1:$PORT
export NO_PROXY=localhost,127.0.0.1,10.0.2.2
EOF
chmod 0644 /etc/profile.d/pocketvm-proxy.sh

# auth.openai.com is the host the device-code flow polls. Anything that is not a
# connection failure means the request reached OpenAI, which is the point.
status="$(curl -s -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' --max-time 20 https://auth.openai.com/ || true)"
say "auth.openai.com 经代理返回 ${status:-无响应}"
say "代理就绪"
