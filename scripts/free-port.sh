#!/usr/bin/env bash
# Gracefully frees a local TCP port before a dev server binds to it: SIGTERM,
# wait briefly, SIGKILL any stragglers. No-op if the port is already free.
set -euo pipefail

PORT="${1:?Usage: free-port.sh <port>}"

pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)
[[ -z "$pids" ]] && exit 0

echo "Port $PORT is in use (pid(s): $pids) — stopping it before starting."
kill $pids 2>/dev/null || true

for _ in $(seq 1 10); do
  pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)
  [[ -z "$pids" ]] && exit 0
  sleep 0.5
done

pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)
if [[ -n "$pids" ]]; then
  echo "Port $PORT still in use after SIGTERM — sending SIGKILL."
  kill -9 $pids 2>/dev/null || true
fi
