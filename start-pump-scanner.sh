#!/usr/bin/env bash
# macOS/Linux: start OKX pump scanner (every 10 min)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PWSH="${PWSH:-$HOME/.local/powershell/pwsh}"
PID_FILE="$ROOT/pump-scanner.pid"
OUT_LOG="$ROOT/pump-scanner-out.log"

if [[ ! -x "$PWSH" ]]; then
  echo "pwsh not found. Install: mkdir -p ~/.local/powershell && curl -fsSL -o ~/.local/powershell/pwsh.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.5.2/powershell-7.5.2-osx-arm64.tar.gz && tar -xzf ~/.local/powershell/pwsh.tar.gz -C ~/.local/powershell && chmod +x ~/.local/powershell/pwsh"
  exit 1
fi

if [[ -f "$PID_FILE" ]]; then
  old_pid=$(head -1 "$PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "Pump scanner already running (PID $old_pid)"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

cd "$ROOT"
# caffeinate: 防止合盖/熄屏后 sleep 把 10 分钟定时器挂起
if command -v caffeinate >/dev/null 2>&1; then
  nohup caffeinate -dims "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/pump-scanner.ps1" >>"$OUT_LOG" 2>&1 &
else
  nohup "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/pump-scanner.ps1" >>"$OUT_LOG" 2>&1 &
fi
echo $! >"$PID_FILE"
echo "Pump scanner started PID $(cat "$PID_FILE")"
echo "Log: $OUT_LOG"
echo "Signals: $ROOT/pump-scanner.log"
echo "Stop: $ROOT/stop-pump-scanner.sh"
