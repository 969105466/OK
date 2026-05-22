$PidFile = Join-Path $PSScriptRoot '.market-watch.pid'
if (-not (Test-Path $PidFile)) {
    Write-Host 'No PID file.'
    exit 0
}
$id = (Get-Content $PidFile -Raw).Trim()
Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
    Stop-Process -Id $id -Force
    Write-Host "Stopped PID $id"
} else {
    Write-Host "Process $id not found"
}
