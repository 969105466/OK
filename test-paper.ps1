# 5m 模拟盘出场测试（mock K线，不调用 OKX）
# 用法: .\test-paper.ps1 -Case LongTp|LongSl|ShortTp|ShortSl|Both|FailKeep

param(
    [ValidateSet('LongTp', 'LongSl', 'ShortTp', 'ShortSl', 'Both', 'FailKeep', 'Open')]
    [string]$Case = 'LongTp'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\pump-paper.ps1"

function New-TestItem {
    param(
        [string]$Side = 'long',
        [double]$Entry = 100,
        [double]$Stop = 98,
        [double]$Tp = 104,
        [string]$Base = 'TEST',
        [string]$InstId = 'TEST-USDT-SWAP'
    )
    [PSCustomObject]@{
        InstId = $InstId; Base = $Base; Side = $Side
        Entry = $Entry; Stop = $Stop; Tp = $Tp; Last = $Entry
    }
}

function New-Mock5mCandle {
    param([long]$Ts, [double]$High, [double]$Low, [double]$Close = 100, [double]$Open = 100)
    [PSCustomObject]@{
        instId = 'TEST-USDT-SWAP'; candleTs = $Ts
        open = $Open; high = $High; low = $Low; close = $Close; volume = 1000
    }
}

function Ensure-OpenPosition {
    param($Store, [string]$Side)
    $item = if ($Side -eq 'long') {
        New-TestItem -Side long -Entry 100 -Stop 98 -Tp 104
    } else {
        New-TestItem -Side short -Entry 100 -Stop 102 -Tp 94
    }
    $pm = @{ 'TEST-USDT-SWAP' = 100.0 }
    $pos = Open-PaperPosition -Store $Store -Item $item -PriceMap $pm
    if (-not $pos) { throw "开仓失败 $Side" }
    $pos.entry5mCandleTs = [long]1000
    $pos.entryCandleTs = [long]1000
    $Store.openPositions = @($pos)
    return $pos
}

$store = Get-PaperStore
$inst = 'TEST-USDT-SWAP'
$pm = @{ $inst = 100.0 }

switch ($Case) {
    'Open' {
        Ensure-OpenPosition -Store $store -Side long
        Save-PaperStore -Store $store
        Write-Host 'OK 已开多仓 entry5mCandleTs=1000' -ForegroundColor Green
    }
    'LongTp' {
        $pos = Ensure-OpenPosition -Store $store -Side long
        $c = New-Mock5mCandle -Ts 2000 -High ($pos.tp + 1) -Low ($pos.stop + 0.5)
        $upd = Update-PaperPositions -Store $store -PriceMap $pm -CandleMap @{ $inst = @($c) }
        if ($upd.Closed.Count -ne 1 -or $upd.Closed[0].exitTrigger -ne 'TP') { throw '多单5m止盈失败' }
        Save-PaperStore -Store $store
        Write-Host "OK 多单5m止盈 pnl=$($upd.Closed[0].pnlUsd) exitBy=$($upd.Closed[0].exitBy)" -ForegroundColor Green
    }
    'LongSl' {
        $store = Get-PaperStore
        if ($store.openPositions.Count -eq 0) { $store = Get-PaperStore; Ensure-OpenPosition -Store $store -Side long | Out-Null }
        $pos = $store.openPositions[0]
        if ($pos.side -ne 'long') { $pos = Ensure-OpenPosition -Store $store -Side long }
        $c = New-Mock5mCandle -Ts 2000 -High ($pos.fillEntry + 1) -Low ($pos.stop - 0.5)
        $upd = Update-PaperPositions -Store $store -PriceMap $pm -CandleMap @{ $inst = @($c) }
        if ($upd.Closed.Count -ne 1 -or $upd.Closed[0].exitTrigger -ne 'SL') { throw '多单5m止损失败' }
        Save-PaperStore -Store $store
        Write-Host "OK 多单5m止损 pnl=$($upd.Closed[0].pnlUsd)" -ForegroundColor Green
    }
    'ShortTp' {
        & "$PSScriptRoot\pump-paper.ps1" -Reset | Out-Null
        $store = Get-PaperStore
        $pos = Ensure-OpenPosition -Store $store -Side short
        $c = New-Mock5mCandle -Ts 2000 -High ($pos.stop - 0.5) -Low ($pos.tp - 1)
        $upd = Update-PaperPositions -Store $store -PriceMap $pm -CandleMap @{ $inst = @($c) }
        if ($upd.Closed.Count -ne 1 -or $upd.Closed[0].exitTrigger -ne 'TP') { throw '空单5m止盈失败' }
        Save-PaperStore -Store $store
        Write-Host "OK 空单5m止盈 pnl=$($upd.Closed[0].pnlUsd)" -ForegroundColor Green
    }
    'ShortSl' {
        & "$PSScriptRoot\pump-paper.ps1" -Reset | Out-Null
        $store = Get-PaperStore
        $pos = Ensure-OpenPosition -Store $store -Side short
        $c = New-Mock5mCandle -Ts 2000 -High ($pos.stop + 0.5) -Low ($pos.fillEntry + 0.5)
        $upd = Update-PaperPositions -Store $store -PriceMap $pm -CandleMap @{ $inst = @($c) }
        if ($upd.Closed.Count -ne 1 -or $upd.Closed[0].exitTrigger -ne 'SL') { throw '空单5m止损失败' }
        Save-PaperStore -Store $store
        Write-Host "OK 空单5m止损 pnl=$($upd.Closed[0].pnlUsd)" -ForegroundColor Green
    }
    'Both' {
        & "$PSScriptRoot\pump-paper.ps1" -Reset | Out-Null
        $store = Get-PaperStore
        $pos = Ensure-OpenPosition -Store $store -Side long
        $c = New-Mock5mCandle -Ts 2000 -High ($pos.tp + 2) -Low ($pos.stop - 2)
        $upd = Update-PaperPositions -Store $store -PriceMap $pm -CandleMap @{ $inst = @($c) }
        if ($upd.Closed[0].exitTrigger -ne 'SL') { throw '同5m K线应保守止损' }
        Save-PaperStore -Store $store
        Write-Host 'OK 同5m K线 TP+SL 按 SL' -ForegroundColor Green
    }
    'FailKeep' {
        & "$PSScriptRoot\pump-paper.ps1" -Reset | Out-Null
        $store = Get-PaperStore
        Ensure-OpenPosition -Store $store -Side long | Out-Null
        $upd = Update-PaperPositions -Store $store -PriceMap $pm -CandleMap @{}
        if ($upd.Closed.Count -gt 0) { throw '5m失败不应平仓' }
        if ($store.openPositions.Count -ne 1) { throw '5m失败应保留持仓' }
        Save-PaperStore -Store $store
        Write-Host 'OK 5m接口失败：保留持仓、未平仓' -ForegroundColor Green
    }
}

$html = Format-PaperAccountHtml -Store $store -PriceMap $pm -Opened @() `
    -Closed @($store.closedTrades | Select-Object -Last 2)
Write-Host "`n--- 摘要 ---"
Write-Host ($html -replace '<[^>]+>', '' -replace '&gt;', '>' -replace '&lt;', '<')
