#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$ROOT/pump-scanner.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "No PID file - scanner not running?"
  exit 0
fi

pid=$(head -1 "$PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  echo "Stopped pump scanner (PID $pid)"
else
  echo "Process $pid not found (already stopped)"
fi
rm -f "$PID_FILE"
