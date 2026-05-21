$PidFile = Join-Path $PSScriptRoot "pump-scanner.pid"
if (-not (Test-Path $PidFile)) {
    Write-Host "No PID file - scanner not running?" -ForegroundColor Yellow
    exit 0
}
$pid = [int](Get-Content $PidFile | Select-Object -First 1)
$proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
if ($proc) {
    Stop-Process -Id $pid -Force
    Write-Host "Stopped pump scanner (PID $pid)" -ForegroundColor Green
} else {
    Write-Host "Process $pid not found (already stopped)" -ForegroundColor Yellow
}
Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
