#!/bin/bash
# Runs inside the guest and carries the commands the app asks for.
#
# Typing at the serial console only works while a shell happens to be sitting at
# a prompt with the right PATH, and the answer has to be told apart from the
# kernel log, the shell's echo and whatever else is on the line. That is not a
# channel: it is a guess that looks like one.
#
# This is the other half of the channel the guest already uses to report. The
# app leaves a command, this runs it, and the output goes back the same way.
#
# Protocol, plain text on purpose — no parser to get wrong in bash:
#   GET  /command -> "" (nothing waiting) or "<id>\n<script>"
#   POST /result  <- "<id>\n<output>"
set -u

BASE="${POCKETVM_BASE:-http://10.0.2.2:8474}"

while :; do
  reply="$(curl -fsS -m 5 --noproxy '*' "$BASE/command" 2>/dev/null || true)"
  if [ -z "$reply" ]; then
    sleep 2
    continue
  fi
  id="$(printf '%s\n' "$reply" | head -n1)"
  script="$(printf '%s\n' "$reply" | tail -n +2)"
  output="$(bash -c "$script" 2>&1; printf 'EXIT:%d' "$?")"
  curl -fsS -m 30 --noproxy '*' -X POST "$BASE/result" \
    --data-binary "$(printf '%s\n%s' "$id" "$output")" >/dev/null 2>&1 || true
done
