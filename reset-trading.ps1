# 清除信号历史 + 模拟盘，从 1000 USDT 重新开始
# Run: .\reset-trading.ps1

$Root = $PSScriptRoot

@(
    (Join-Path $Root "pump-signal-history.json"),
    (Join-Path $Root "pump-review-state.json"),
    (Join-Path $Root "pump-review.log"),
    (Join-Path $Root "pump-paper.log")
) | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Force }
}

Set-Content -Path (Join-Path $Root "pump-signal-history.json") -Value '{"signals":[]}' -Encoding UTF8

& (Join-Path $Root "pump-paper.ps1") -Reset

Write-Host "Done: signal history cleared, paper account 1000 USDT." -ForegroundColor Green
