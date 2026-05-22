# Start market:watch (read-only scan + paper signals + Telegram every 10 min)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$PidFile = Join-Path $Root '.market-watch.pid'
$LogFile = Join-Path $Root 'logs\market-watch.log'

if (Test-Path $PidFile) {
    $old = (Get-Content $PidFile -Raw).Trim()
    if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
        Write-Host "Already running PID $old. Run stop-market-watch.ps1 first." -ForegroundColor Yellow
        exit 1
    }
}

if (-not (Test-Path (Join-Path $Root '.env'))) {
    Write-Host 'Missing .env - copy .env.example to .env first.' -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null

$logEsc = $LogFile -replace '\\', '/'
$proc = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList '/c', "npm run market:watch >> `"$LogFile`" 2>&1" `
    -WorkingDirectory $Root -WindowStyle Hidden -PassThru

$proc.Id | Set-Content $PidFile -Encoding ascii
Write-Host "Started market:watch PID=$($proc.Id)"
Write-Host "Log: $LogFile"
Write-Host "Stop: .\stop-market-watch.ps1"
