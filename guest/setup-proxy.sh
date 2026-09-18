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
asset="https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/mihomo-linux-arm64-$VERSION.gz"
if [ -x /usr/local/bin/mihomo ]; then
  say "内核已存在，跳过下载"
else
  if ! curl -fsSL --retry 2 --max-time 300 "$asset" | gzip -dc >/usr/local/bin/mihomo; then
    say "下载代理内核失败：客户机连不上 GitHub，或者这个版本号已经下架"
    exit 1
  fi
  chmod 0755 /usr/local/bin/mihomo
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
# are ours, and appending them last wins over anything the subscription set.
if ! grep -q '^# pocketvm-port' /etc/mihomo/config.yaml; then
  sed -i '/^mixed-port:/d;/^socks-port:/d;/^port:/d;/^allow-lan:/d;/^external-controller:/d;/^log-level:/d' \
    /etc/mihomo/config.yaml
  cat >>/etc/mihomo/config.yaml <<EOF

# pocketvm-port
mixed-port: $PORT
allow-lan: false
external-controller: 127.0.0.1:9090
log-level: warning
EOF
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
  say "代理进程起来了但连不通，看 journalctl -u mihomo -n 40"
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
