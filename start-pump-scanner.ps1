# Start pump-scanner in background (survives closing Cursor terminal)
# Stop: .\stop-pump-scanner.ps1

$Root = $PSScriptRoot
$PidFile = Join-Path $Root "pump-scanner.pid"
$OutLog = Join-Path $Root "pump-scanner-out.log"

if (Test-Path $PidFile) {
    $oldPid = Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        Write-Host "Pump scanner already running (PID $oldPid)" -ForegroundColor Yellow
        exit 0
    }
}

$argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $Root 'pump-scanner.ps1')
)

$p = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList $argList `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $OutLog

$p.Id | Out-File -FilePath $PidFile -Encoding ascii -NoNewline
Write-Host "Pump scanner started PID $($p.Id)" -ForegroundColor Green
Write-Host "Log: $OutLog"
Write-Host "Signals: $Root\pump-scanner.log"
Write-Host "Stop: .\stop-pump-scanner.ps1"
