#!/bin/bash
set -eu
BASE="${POCKETVM_BASE:-http://10.0.2.2:8474}"
healthy() {
  for package in curl ca-certificates git jq nodejs npm openssh-server; do
    test "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null)" = installed || return 1
  done
  timeout 30 runuser -u codex -- node -e 'process.exit(0)' || return 1
  timeout 30 runuser -u codex -- codex --version >/dev/null 2>&1 || return 1
}
if healthy; then
  # Legacy installers omitted the marker. Require host confirmation as well
  # as package/runtime health before migrating an existing installation.
  if [ ! -f /var/lib/pocketvm/install-complete ]; then
    curl --noproxy '*' -fsS -m 15 "$BASE/installation.json" -o /run/pocketvm-installation.json
    if python3 -c 'import json,sys; sys.exit(0 if json.load(open("/run/pocketvm-installation.json")).get("completed") is True else 1)'; then
      install -d /var/lib/pocketvm
      touch /var/lib/pocketvm/install-complete
    fi
  fi
fi
if ! test -f /var/lib/pocketvm/install-complete || ! healthy; then
  /bin/bash /usr/local/sbin/pocketvm-provision.sh
fi
/bin/bash /usr/local/lib/pocketvm/pocketvm-shared-setup.sh
