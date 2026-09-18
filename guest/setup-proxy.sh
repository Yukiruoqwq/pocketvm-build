#!/bin/bash
# Put a proxy inside the guest.
#
# iOS allows exactly one active VPN tunnel, and this device needs it for the
# LocalDevVPN that JIT depends on. So the proxying has to happen one layer
# deeper: a Clash Meta (mihomo) client inside the guest, which the Codex CLI
# reaches through a loopback proxy. The iPad's tunnel is then never contested.
#
# Usage (inside the guest, as any user with sudo):
#   bash setup-proxy.sh 'https://…/clashmeta/' [port]

set -euo pipefail

SUB_URL="${1:?usage: setup-proxy.sh <subscription-url> [port]}"
PORT="${2:-7890}"
TTY=/dev/ttyAMA0

say() {
  printf 'POCKETVM: %s\n' "$*" >"$TTY" 2>/dev/null || true
  echo "$*"
}

say "下载代理内核"
release="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
asset="$(curl -fsSL "$release" | jq -r '.assets[].browser_download_url' \
  | grep -E 'mihomo-linux-arm64-v[0-9.]+\.gz$' | head -n1 || true)"
if [ -z "$asset" ]; then
  say "没有找到 arm64 包，检查客户机能不能访问 GitHub"
  exit 1
fi
curl -fsSL "$asset" | gzip -d >/usr/local/bin/mihomo
chmod 0755 /usr/local/bin/mihomo
say "内核 $(/usr/local/bin/mihomo -v | head -n1)"

say "拉取订阅"
mkdir -p /etc/mihomo
# Panels serve the Clash config only to a client they recognise, and some answer
# a bare curl with an empty 304. Send the user agent mihomo itself would send.
curl -fsSL -A "mihomo/$( /usr/local/bin/mihomo -v | awk '{print $3}' )" \
  -H 'Cache-Control: no-cache' "$SUB_URL" -o /etc/mihomo/config.yaml || true
if [ ! -s /etc/mihomo/config.yaml ]; then
  say "订阅没有返回内容（面板需要对客户端返回，链接可能已失效）"
  say "在 Clash Verge 里重新复制一次订阅链接再来一遍"
  exit 1
fi
if ! grep -qE '^(proxies|proxy-providers):' /etc/mihomo/config.yaml; then
  say "订阅内容不像 Clash 配置，检查链接是不是 clashmeta/clash 格式"
  exit 1
fi
# The subscription owns the proxy list; the listening ports and the controller
# are ours, and appending them last wins over anything the subscription set.
sed -i '/^mixed-port:/d;/^socks-port:/d;/^port:/d;/^allow-lan:/d;/^external-controller:/d;/^log-level:/d' \
  /etc/mihomo/config.yaml
cat >>/etc/mihomo/config.yaml <<EOF

mixed-port: $PORT
allow-lan: false
external-controller: 127.0.0.1:9090
log-level: warning
EOF

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
systemctl daemon-reload
systemctl enable --now mihomo >/dev/null 2>&1

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
  say "代理没起来，看 journalctl -u mihomo -n 40"
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

# auth.openai.com is the host the device-code flow polls, and the one that
# answers 403 from a blocked region. Anything else means the request reached
# OpenAI, which is what the proxy has to achieve.
status="$(curl -s -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' --max-time 12 https://auth.openai.com/ || true)"
say "auth.openai.com 经代理返回 $status（403 表示仍被区域拦截，其余表示已能访问）"
say "代理就绪，重新点『登录 Codex』即可"
