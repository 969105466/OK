# Paper trading simulation (USDT-margined, leverage, slippage, fees)
# Reset:  .\pump-paper.ps1 -Reset
# Report: .\pump-paper.ps1 -Report

param(
    [string]$PaperFile = $(Join-Path $PSScriptRoot "pump-paper.json"),
    [double]$InitialCapital = 1000,
    [double]$RiskPerTradePct = 2.0,
    [double]$MaxNotionalPct = 60.0,
    [double]$MaxMarginPct = 20.0,
    [int]$DefaultLeverage = 3,
    [int]$MaxOpenPositions = 5,
    [double]$FeePct = 0.05,
    [double]$SlippagePct = 0.08,
    [double]$MinRr = 1.35,
    [string]$PaperLogFile = $(Join-Path $PSScriptRoot "pump-paper.log"),
    [switch]$Reset,
    [switch]$Report
)

. "$PSScriptRoot\hype-telegram.ps1"
. "$PSScriptRoot\pump-5m.ps1"

$script:PaperRejectStats = @{}

function Write-PaperLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $PaperLogFile -Value $line -Encoding UTF8
    Write-Host $line -ForegroundColor DarkYellow
}

function Register-PaperReject {
    param([string]$Reason)
    if (-not $script:PaperRejectStats.ContainsKey($Reason)) {
        $script:PaperRejectStats[$Reason] = 0
    }
    $script:PaperRejectStats[$Reason]++
    Write-PaperLog "开仓过滤: $Reason"
}

function Clear-PaperRejectStats {
    $script:PaperRejectStats = @{}
}

function Get-PaperRejectStats {
    return $script:PaperRejectStats
}

function Initialize-PaperStore {
    return [PSCustomObject]@{
        initialCapital  = $InitialCapital
        balance         = $InitialCapital
        totalFeesUsd    = 0.0
        feePctPerSide   = $FeePct
        slippagePct     = $SlippagePct
        defaultLeverage = $DefaultLeverage
        startedAt       = (Get-Date).ToString('o')
        openPositions   = @()
        closedTrades    = @()
    }
}

function Get-PaperStore {
    if (-not (Test-Path $PaperFile)) {
        return Initialize-PaperStore
    }
    try {
        $raw = Get-Content $PaperFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $raw.openPositions) { $raw | Add-Member -NotePropertyName openPositions -NotePropertyValue @() }
        if ($null -eq $raw.closedTrades) { $raw | Add-Member -NotePropertyName closedTrades -NotePropertyValue @() }
        if ($null -eq $raw.totalFeesUsd) { $raw | Add-Member -NotePropertyName totalFeesUsd -NotePropertyValue 0.0 }
        if ($null -eq $raw.feePctPerSide) { $raw | Add-Member -NotePropertyName feePctPerSide -NotePropertyValue $FeePct }
        if ($null -eq $raw.slippagePct) { $raw | Add-Member -NotePropertyName slippagePct -NotePropertyValue $SlippagePct }
        if ($null -eq $raw.defaultLeverage) { $raw | Add-Member -NotePropertyName defaultLeverage -NotePropertyValue $DefaultLeverage }
        return $raw
    } catch {
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $broken = "$PaperFile.broken.$ts"
        Copy-Item -Path $PaperFile -Destination $broken -Force
        throw "pump-paper.json 读取失败，已备份为 $broken，请人工检查后恢复。错误: $_"
    }
}

function Save-PaperStore {
    param($Store)
    $obj = @{
        initialCapital  = [double]$Store.initialCapital
        balance         = [double]$Store.balance
        totalFeesUsd    = if ($null -ne $Store.totalFeesUsd) { [double]$Store.totalFeesUsd } else { 0 }
        feePctPerSide   = if ($null -ne $Store.feePctPerSide) { [double]$Store.feePctPerSide } else { $FeePct }
        slippagePct     = if ($null -ne $Store.slippagePct) { [double]$Store.slippagePct } else { $SlippagePct }
        defaultLeverage = if ($null -ne $Store.defaultLeverage) { [int]$Store.defaultLeverage } else { $DefaultLeverage }
        startedAt       = $Store.startedAt
        openPositions   = @($Store.openPositions)
        closedTrades    = @($Store.closedTrades)
    }
    $json = $obj | ConvertTo-Json -Depth 10
    $tmp = "$PaperFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $PaperFile -Force
}

function Reset-PaperTrading {
    $store = Initialize-PaperStore
    Save-PaperStore -Store $store
    if (Test-Path $PaperLogFile) { Remove-Item $PaperLogFile -Force }
    Clear-PaperRejectStats
    Write-Host "Paper trading reset: $InitialCapital USDT | ${DefaultLeverage}x | slippage ${SlippagePct}%" -ForegroundColor Green
}

function Get-OkxTickerLast {
    param([string]$InstId)
    try {
        $uri = "https://www.okx.com/api/v5/market/ticker?instId=$InstId"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 12
        if ($r.code -eq '0' -and $r.data -and $r.data.Count -gt 0) {
            return [double]$r.data[0].last
        }
    } catch {
        Write-PaperLog "OKX ticker 失败 $InstId : $_"
    }
    return $null
}

function Convert-OkxCandleRow {
    param($Row, [string]$InstId)
    return [PSCustomObject]@{
        instId   = $InstId
        candleTs = [long]$Row[0]
        open     = [double]$Row[1]
        high     = [double]$Row[2]
        low      = [double]$Row[3]
        close    = [double]$Row[4]
        volume   = [double]$Row[5]
    }
}

# 返回最近已完成的 15m K 线（不含当前未收盘的 data[0]）
function Get-Okx15mCandles {
    param([string]$InstId, [int]$Limit = 10)
    try {
        $fetch = [Math]::Max($Limit + 1, 3)
        $uri = "https://www.okx.com/api/v5/market/candles?instId=$InstId&bar=15m&limit=$fetch"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 12
        if ($r.code -ne '0' -or -not $r.data -or $r.data.Count -lt 2) {
            return $null
        }
        $list = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -lt $r.data.Count; $i++) {
            $list.Add((Convert-OkxCandleRow -Row $r.data[$i] -InstId $InstId))
        }
        return $list.ToArray()
    } catch {
        Write-PaperLog "OKX 15m K线失败 $InstId : $_"
        return $null
    }
}

function Get-OkxLatestCompletedCandle {
    param([string]$InstId)
    $candles = Get-Okx15mCandles -InstId $InstId -Limit 2
    if ($candles -and $candles.Count -gt 0) { return $candles[0] }
    return $null
}

function Get-CandleMapForInstIds {
    param([string[]]$InstIds)
    return Get-5mCandleMapForInstIds -InstIds $InstIds -OnFailLog {
        param($id)
        Write-PaperLog "5m K线获取失败 $id，保留持仓、本轮不检测平仓"
    }
}

function Enrich-PriceMapForOpenPositions {
    param($Store, $PriceMap)
    $map = @{}
    foreach ($k in $PriceMap.Keys) { $map[$k] = $PriceMap[$k] }
    foreach ($pos in @($Store.openPositions)) {
        if ([string]::IsNullOrWhiteSpace($pos.instId)) { continue }
        if ($map.ContainsKey($pos.instId)) { continue }
        $last = Get-OkxTickerLast -InstId $pos.instId
        if ($null -ne $last) {
            $map[$pos.instId] = $last
        } else {
            Write-PaperLog "持仓 $($pos.base) 无法获取 ticker，保留持仓"
        }
        Start-Sleep -Milliseconds 80
    }
    return $map
}

function Enrich-CandleMapForOpenPositions {
    param($Store, $CandleMap)
    $map = @{}
    if ($CandleMap) {
        foreach ($k in $CandleMap.Keys) { $map[$k] = $CandleMap[$k] }
    }
    $ids = @($Store.openPositions | ForEach-Object { $_.instId } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($id in $ids) {
        if ($map.ContainsKey($id) -and $map[$id]) { continue }
        $one = Get-5mCandleMapForInstIds -InstIds @($id)
        foreach ($k in $one.Keys) { $map[$k] = $one[$k] }
    }
    return $map
}

function Enrich-MarketDataForOpenPositions {
    param($Store, $PriceMap, $CandleMap)
    return @{
        PriceMap  = (Enrich-PriceMapForOpenPositions -Store $Store -PriceMap $PriceMap)
        CandleMap = (Enrich-CandleMapForOpenPositions -Store $Store -CandleMap $CandleMap)
    }
}

function Format-CandleTsText {
    param([long]$Ts)
    try {
        return [DateTimeOffset]::FromUnixTimeMilliseconds($Ts).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
    } catch {
        return [string]$Ts
    }
}

function Get-PositionEntry5mTs {
    param($Pos)
    if ($null -ne $Pos.entry5mCandleTs -and [long]$Pos.entry5mCandleTs -gt 0) {
        return [long]$Pos.entry5mCandleTs
    }
    if ($null -ne $Pos.entryCandleTs) { return [long]$Pos.entryCandleTs }
    return [long]0
}

function Get-EligibleCandlesForPosition {
    param($Pos, $Candles)
    if (-not $Candles) { return @() }
    $entryTs = Get-PositionEntry5mTs -Pos $Pos
    return @($Candles | Where-Object { [long]$_.candleTs -gt $entryTs } | Sort-Object { [long]$_.candleTs })
}

function Get-FillEntryPrice {
    param([string]$Side, [double]$RawEntry, [double]$SlippagePct)
    $s = $SlippagePct / 100.0
    if ($Side -eq 'long') { return $RawEntry * (1.0 + $s) }
    return $RawEntry * (1.0 - $s)
}

function Get-FillExitPrice {
    param([string]$Side, [double]$RawExit, [double]$SlippagePct)
    $s = $SlippagePct / 100.0
    if ($Side -eq 'long') { return $RawExit * (1.0 - $s) }
    return $RawExit * (1.0 + $s)
}

function Get-SignalRr {
    param([string]$Side, [double]$Entry, [double]$Stop, [double]$Tp)
    if ($Entry -le 0) { return 0 }
    if ($Side -eq 'long') {
        $risk = $Entry - $Stop
        $reward = $Tp - $Entry
    } else {
        $risk = $Stop - $Entry
        $reward = $Entry - $Tp
    }
    if ($risk -le 0 -or $reward -le 0) { return 0 }
    return [Math]::Round($reward / $risk, 2)
}

function Test-ValidSignal {
    param($Item, [double]$MinRrRatio = $MinRr)

    $entry = [double]$Item.Entry
    $stop = [double]$Item.Stop
    $tp = [double]$Item.Tp
    $side = [string]$Item.Side

    if ($entry -le 0 -or $stop -le 0 -or $tp -le 0) {
        Register-PaperReject -Reason '价格无效(entry/stop/tp<=0)'
        return $false
    }
    if ($side -ne 'long' -and $side -ne 'short') {
        Register-PaperReject -Reason "方向无效($side)"
        return $false
    }
    if ($side -eq 'long') {
        if (-not ($stop -lt $entry -and $tp -gt $entry)) {
            Register-PaperReject -Reason '多单止损/止盈位置不合法'
            return $false
        }
    } else {
        if (-not ($stop -gt $entry -and $tp -lt $entry)) {
            Register-PaperReject -Reason '空单止损/止盈位置不合法'
            return $false
        }
    }
    $rr = Get-SignalRr -Side $side -Entry $entry -Stop $stop -Tp $tp
    if ($rr -lt $MinRrRatio) {
        Register-PaperReject -Reason "盈亏比不足($rr < $MinRrRatio)"
        return $false
    }
    return $true
}

function Get-StopDistancePct {
    param([double]$Entry, [double]$Stop)
    if ($Entry -le 0) { return 1.0 }
    return [Math]::Max(0.3, [Math]::Abs($Entry - $Stop) / $Entry * 100.0)
}

function Get-OpenFeeUsd {
    param([double]$NotionalUsd, [double]$FeePct)
    return [Math]::Round($NotionalUsd * ($FeePct / 100.0), 4)
}

function Get-CloseFeeUsd {
    param([double]$FillEntry, [double]$FillExit, [double]$NotionalUsd, [double]$FeePct)
    if ($FillEntry -le 0 -or $NotionalUsd -le 0) { return 0 }
    $qty = $NotionalUsd / $FillEntry
    $exitNotional = $qty * $FillExit
    return [Math]::Round($exitNotional * ($FeePct / 100.0), 4)
}

function Get-PositionFillEntry {
    param($Pos)
    if ($null -ne $Pos.fillEntry -and [double]$Pos.fillEntry -gt 0) { return [double]$Pos.fillEntry }
    return [double]$Pos.entry
}

function Get-PositionGrossPnlUsd {
    param($Pos, [double]$MarkPrice)
    $entry = Get-PositionFillEntry -Pos $Pos
    $notional = [double]$Pos.notionalUsd
    if ($entry -le 0 -or $notional -le 0) { return 0 }
    $qty = $notional / $entry
    if ($Pos.side -eq 'long') {
        return ($MarkPrice - $entry) * $qty
    }
    return ($entry - $MarkPrice) * $qty
}

function Get-PositionOpenFeeUsd {
    param($Pos, [double]$FeePct)
    if ($null -ne $Pos.openFeeUsd -and [double]$Pos.openFeeUsd -gt 0) {
        return [double]$Pos.openFeeUsd
    }
    return Get-OpenFeeUsd -NotionalUsd ([double]$Pos.notionalUsd) -FeePct $FeePct
}

function Get-PositionNetPnlUsd {
    param($Pos, [double]$MarkPrice, [double]$FeePct)
    $fillEntry = Get-PositionFillEntry -Pos $Pos
    $gross = Get-PositionGrossPnlUsd -Pos $Pos -MarkPrice $MarkPrice
    $closeFee = Get-CloseFeeUsd -FillEntry $fillEntry -FillExit $MarkPrice `
        -NotionalUsd ([double]$Pos.notionalUsd) -FeePct $FeePct
    return [Math]::Round($gross - $closeFee, 4)
}

function Get-SlippageUsd {
    param([double]$Qty, [double]$RawPx, [double]$FillPx)
    return [Math]::Round([Math]::Abs($FillPx - $RawPx) * $Qty, 4)
}

function Test-ShouldOpenPaper {
    param($Store, [string]$InstId)
    if (@($Store.openPositions).Count -ge $MaxOpenPositions) {
        Register-PaperReject -Reason '已达最大持仓数'
        return $false
    }
    $exists = @($Store.openPositions | Where-Object { $_.instId -eq $InstId })
    if ($exists.Count -gt 0) {
        Register-PaperReject -Reason '同合约已有持仓'
        return $false
    }
    return $true
}

function Open-PaperPosition {
    param($Store, $Item, $PriceMap)

    if (-not (Test-ValidSignal -Item $Item)) { return $null }
    if (-not (Test-ShouldOpenPaper -Store $Store -InstId $Item.InstId)) { return $null }

    $lev = if ($null -ne $Store.defaultLeverage) { [int]$Store.defaultLeverage } else { $DefaultLeverage }
    $slipPct = if ($null -ne $Store.slippagePct) { [double]$Store.slippagePct } else { $SlippagePct }
    $feeRate = Get-PaperFeePct -Store $Store

    $equity = Get-PaperEquity -Store $Store -PriceMap $PriceMap -FeePct $feeRate
    $rawEntry = [double]$Item.Entry
    $stop = [double]$Item.Stop
    $tp = [double]$Item.Tp
    $stopDistPct = Get-StopDistancePct -Entry $rawEntry -Stop $stop
    $riskUsd = $equity * ($RiskPerTradePct / 100.0)
    $theoreticalNotional = $riskUsd / ($stopDistPct / 100.0)
    $maxNotional = $equity * ($MaxNotionalPct / 100.0)
    $maxMarginNotional = $equity * ($MaxMarginPct / 100.0) * $lev
    $finalNotional = [Math]::Min([Math]::Min($theoreticalNotional, $maxNotional), $maxMarginNotional)
    $finalNotional = [Math]::Round($finalNotional, 2)

    if ($finalNotional -lt 10) {
        Register-PaperReject -Reason '名义价值过小(<10U)'
        return $null
    }

    $fillEntry = [Math]::Round((Get-FillEntryPrice -Side $Item.Side -RawEntry $rawEntry -SlippagePct $slipPct), 8)
    $marginUsd = [Math]::Round($finalNotional / $lev, 2)
    $openFee = Get-OpenFeeUsd -NotionalUsd $finalNotional -FeePct $feeRate
    $actualRiskUsd = [Math]::Round($finalNotional * ($stopDistPct / 100.0), 2)
    $rr = Get-SignalRr -Side $Item.Side -Entry $rawEntry -Stop $stop -Tp $tp
    $qty = $finalNotional / $fillEntry
    $slipUsd = Get-SlippageUsd -Qty $qty -RawPx $rawEntry -FillPx $fillEntry

    $anchor5 = Get-OkxLatestCompleted5mCandle -InstId $Item.InstId
    $entry5mTs = if ($anchor5) { [long]$anchor5.candleTs } else {
        Write-PaperLog "开仓 $($Item.Base) 无法获取锚定5m K线，entry5mCandleTs=0"
        [long]0
    }

    $required = $marginUsd + $openFee
    if ([double]$Store.balance -lt $required) {
        Register-PaperReject -Reason "余额不足(需 $([Math]::Round($required,2)) U)"
        return $null
    }

    $pos = [PSCustomObject]@{
        id                 = [guid]::NewGuid().ToString('N').Substring(0, 10)
        openedAt           = (Get-Date).ToString('o')
        base               = $Item.Base
        instId             = $Item.InstId
        side               = $Item.Side
        rawEntry           = $rawEntry
        fillEntry          = $fillEntry
        entry              = $fillEntry
        stop               = $stop
        tp                 = $tp
        notionalUsd        = $finalNotional
        leverage           = $lev
        marginUsd          = $marginUsd
        theoreticalRiskUsd = [Math]::Round($riskUsd, 2)
        actualRiskUsd      = $actualRiskUsd
        rr                 = $rr
        openFeeUsd         = $openFee
        slippageUsd        = $slipUsd
        entry5mCandleTs    = $entry5mTs
        entryCandleTs      = $entry5mTs
        signalId           = $Item.InstId
    }

    $Store.balance = [Math]::Round([double]$Store.balance - $marginUsd - $openFee, 2)
    if ($null -eq $Store.totalFeesUsd) { $Store | Add-Member -NotePropertyName totalFeesUsd -NotePropertyValue 0.0 -Force }
    $Store.totalFeesUsd = [Math]::Round([double]$Store.totalFeesUsd + $openFee, 4)
    Write-PaperLog "开仓 $($Item.Base) $($Item.Side) 名义 $finalNotional U 杠杆 ${lev}x 保证金 $marginUsd U RR $rr"
    return $pos
}

function Test-CandleExit {
    param($Pos, $Candle)
    $hi = [double]$Candle.high
    $lo = [double]$Candle.low
    $stop = [double]$Pos.stop
    $tp = [double]$Pos.tp

    if ($Pos.side -eq 'long') {
        $hitStop = ($lo -le $stop)
        $hitTp = ($hi -ge $tp)
    } else {
        $hitStop = ($hi -ge $stop)
        $hitTp = ($lo -le $tp)
    }

    if ($hitStop -and $hitTp) {
        return @{
            Reason      = 'stop'
            ExitTrigger = 'SL'
            ExitBy      = '5m_candle'
            RawExit     = $stop
            BothHit     = $true
            Candle      = $Candle
        }
    }
    if ($hitStop) {
        return @{
            Reason      = 'stop'
            ExitTrigger = 'SL'
            ExitBy      = '5m_candle'
            RawExit     = $stop
            BothHit     = $false
            Candle      = $Candle
        }
    }
    if ($hitTp) {
        return @{
            Reason      = 'tp'
            ExitTrigger = 'TP'
            ExitBy      = '5m_candle'
            RawExit     = $tp
            BothHit     = $false
            Candle      = $Candle
        }
    }
    return $null
}

function Resolve-ExitFromCandles {
    param($Pos, $Candles)
    $eligible = Get-EligibleCandlesForPosition -Pos $Pos -Candles $Candles
    foreach ($c in $eligible) {
        $hit = Test-CandleExit -Pos $Pos -Candle $c
        if ($hit) { return $hit }
    }
    return $null
}

function Close-PaperPosition {
    param($Store, $Pos, $Exit, [double]$FeePct)
    $slipPct = if ($null -ne $Store.slippagePct) { [double]$Store.slippagePct } else { $SlippagePct }
    $rawExit = [double]$Exit.RawExit
    $fillExit = [Math]::Round((Get-FillExitPrice -Side $Pos.side -RawExit $rawExit -SlippagePct $slipPct), 8)
    $fillEntry = Get-PositionFillEntry -Pos $Pos
    $qty = [double]$Pos.notionalUsd / $fillEntry

    $gross = if ($Pos.side -eq 'long') {
        ($fillExit - $fillEntry) * $qty
    } else {
        ($fillEntry - $fillExit) * $qty
    }
    $gross = [Math]::Round($gross, 4)

    $openFee = Get-PositionOpenFeeUsd -Pos $Pos -FeePct $FeePct
    $closeFee = Get-CloseFeeUsd -FillEntry $fillEntry -FillExit $fillExit `
        -NotionalUsd ([double]$Pos.notionalUsd) -FeePct $FeePct
    $slipClose = Get-SlippageUsd -Qty $qty -RawPx $rawExit -FillPx $fillExit
    $slipTotal = [Math]::Round([double]$Pos.slippageUsd + $slipClose, 4)
    $net = [Math]::Round($gross - $closeFee, 2)
    $feeTotal = [Math]::Round($openFee + $closeFee, 4)
    $marginUsd = [double]$Pos.marginUsd

    if ($null -eq $Store.totalFeesUsd) { $Store | Add-Member -NotePropertyName totalFeesUsd -NotePropertyValue 0.0 -Force }
    $Store.totalFeesUsd = [Math]::Round([double]$Store.totalFeesUsd + $closeFee, 4)
    $Store.balance = [Math]::Round([double]$Store.balance + $marginUsd + $net, 2)

    $candle = $Exit.Candle
    $exitTs = if ($candle) { [long]$candle.candleTs } else { [long]0 }
    $cHi = if ($candle) { [double]$candle.high } else { 0 }
    $cLo = if ($candle) { [double]$candle.low } else { 0 }
    $trigger = if ($Exit.ExitTrigger) { $Exit.ExitTrigger } else { if ($Exit.Reason -eq 'tp') { 'TP' } else { 'SL' } }

    $exitBy = if ($Exit.ExitBy) { $Exit.ExitBy } else { '5m_candle' }

    if ($Exit.BothHit) {
        Write-PaperLog "平仓 $($Pos.base) 5m K线同时触达TP/SL (ts=$exitTs)，保守按止损"
    }

    $trade = [PSCustomObject]@{
        id                 = $Pos.id
        closedAt           = (Get-Date).ToString('o')
        base               = $Pos.base
        instId             = $Pos.instId
        side               = $Pos.side
        rawEntry           = if ($null -ne $Pos.rawEntry) { [double]$Pos.rawEntry } else { [double]$Pos.entry }
        fillEntry          = $fillEntry
        entry              = $fillEntry
        rawExit            = $rawExit
        rawExitPrice       = $rawExit
        fillExit           = $fillExit
        fillExitPrice      = $fillExit
        exit               = $fillExit
        exitCandleTs       = $exitTs
        exitTrigger        = $trigger
        exitBy             = $exitBy
        candleHigh         = $cHi
        candleLow          = $cLo
        notionalUsd        = [double]$Pos.notionalUsd
        leverage           = if ($null -ne $Pos.leverage) { [int]$Pos.leverage } else { $DefaultLeverage }
        marginUsd          = $marginUsd
        theoreticalRiskUsd = if ($null -ne $Pos.theoreticalRiskUsd) { [double]$Pos.theoreticalRiskUsd } else { 0 }
        actualRiskUsd      = if ($null -ne $Pos.actualRiskUsd) { [double]$Pos.actualRiskUsd } else { 0 }
        rr                 = if ($null -ne $Pos.rr) { [double]$Pos.rr } else { 0 }
        grossPnlUsd        = [Math]::Round($gross, 2)
        openFeeUsd         = [Math]::Round($openFee, 4)
        closeFeeUsd        = [Math]::Round($closeFee, 4)
        feeUsd             = $feeTotal
        slippageUsd        = $slipTotal
        pnlUsd             = $net
        reason             = $Exit.Reason
        openedAt           = $Pos.openedAt
        entry5mCandleTs    = Get-PositionEntry5mTs -Pos $Pos
        entryCandleTs      = Get-PositionEntry5mTs -Pos $Pos
    }
    Write-PaperLog "平仓 $($Pos.base) $trigger 5m K线$(Format-CandleTsText -Ts $exitTs) 净 $net U"
    return $trade
}

function Update-PaperPositions {
    param($Store, $PriceMap, $CandleMap, [double]$FeePct)

    $enriched = Enrich-MarketDataForOpenPositions -Store $Store -PriceMap $PriceMap -CandleMap $CandleMap
    $priceMap = $enriched.PriceMap
    $candleMap = $enriched.CandleMap

    $stillOpen = New-Object System.Collections.Generic.List[object]
    $closed = New-Object System.Collections.Generic.List[object]

    foreach ($pos in $Store.openPositions) {
        if (-not $candleMap.ContainsKey($pos.instId) -or -not $candleMap[$pos.instId]) {
            Write-PaperLog "持仓 $($pos.base) 无5m K线，保留持仓、不检测平仓"
            $stillOpen.Add($pos)
            continue
        }

        $exit = Resolve-ExitFromCandles -Pos $pos -Candles $candleMap[$pos.instId]
        if ($exit) {
            $closed.Add((Close-PaperPosition -Store $Store -Pos $pos -Exit $exit -FeePct $FeePct))
        } else {
            $stillOpen.Add($pos)
        }
    }

    $Store.openPositions = $stillOpen.ToArray()
    if ($closed.Count -gt 0) {
        $list = [System.Collections.Generic.List[object]]::new()
        $list.AddRange(@($Store.closedTrades))
        $list.AddRange($closed)
        $Store.closedTrades = $list.ToArray()
    }
    return @{ Closed = $closed; PriceMap = $priceMap; CandleMap = $candleMap }
}

function Get-PaperEquity {
    param($Store, $PriceMap, [double]$FeePct)
    $eq = [double]$Store.balance
    foreach ($pos in $Store.openPositions) {
        $eq += [double]$pos.marginUsd
        if ($PriceMap.ContainsKey($pos.instId)) {
            $eq += Get-PositionNetPnlUsd -Pos $pos -MarkPrice ([double]$PriceMap[$pos.instId]) -FeePct $FeePct
        }
    }
    return [Math]::Round($eq, 2)
}

function Get-PaperFeePct {
    param($Store)
    if ($null -ne $Store.feePctPerSide) { return [double]$Store.feePctPerSide }
    return $FeePct
}

function Get-PaperTotalFeesUsd {
    param($Store, [double]$FeePct)
    if ($null -ne $Store.totalFeesUsd -and [double]$Store.totalFeesUsd -gt 0) {
        return [Math]::Round([double]$Store.totalFeesUsd, 2)
    }
    $sum = 0.0
    foreach ($t in @($Store.closedTrades)) {
        if ($null -ne $t.feeUsd) { $sum += [double]$t.feeUsd }
    }
    foreach ($p in @($Store.openPositions)) {
        $sum += Get-PositionOpenFeeUsd -Pos $p -FeePct $FeePct
    }
    return [Math]::Round($sum, 2)
}

function Get-PaperStats {
    param($Store, [double]$FeePct)
    $closed = @($Store.closedTrades)
    $wins = @($closed | Where-Object { [double]$_.pnlUsd -gt 0 }).Count
    $losses = @($closed | Where-Object { [double]$_.pnlUsd -le 0 }).Count
    $sumPnl = ($closed | ForEach-Object { [double]$_.pnlUsd } | Measure-Object -Sum).Sum
    if (-not $sumPnl) { $sumPnl = 0 }
    return @{
        Wins      = $wins
        Losses    = $losses
        SumPnl    = [Math]::Round($sumPnl, 2)
        TotalFees = Get-PaperTotalFeesUsd -Store $Store -FeePct $FeePct
        Total     = $closed.Count
    }
}

function Get-DistPctToLevel {
    param([string]$Side, [double]$Mark, [double]$Entry, [double]$Level)
    if ($Entry -le 0) { return "" }
    if ($Side -eq 'long') {
        $pct = ($Level - $Mark) / $Entry * 100.0
    } else {
        $pct = ($Mark - $Level) / $Entry * 100.0
    }
    $v = [Math]::Round($pct, 2)
    if ($v -gt 0) { return "+" + $v + "%" }
    if ($v -lt 0) { return [string]$v + "%" }
    return "0%"
}

function Format-PositionDetailLines {
    param($Pos, [double]$FeeRate, [double]$SlipPct)
    $lev = if ($null -ne $Pos.leverage) { $Pos.leverage } else { $DefaultLeverage }
    $m = if ($null -ne $Pos.marginUsd) { [double]$Pos.marginUsd } else { 0 }
    $thr = if ($null -ne $Pos.theoreticalRiskUsd) { [double]$Pos.theoreticalRiskUsd } else { 0 }
    $ar = if ($null -ne $Pos.actualRiskUsd) { [double]$Pos.actualRiskUsd } else { 0 }
    $rr = if ($null -ne $Pos.rr) { $Pos.rr } else { '-' }
    $slip = if ($null -ne $Pos.slippageUsd) { [double]$Pos.slippageUsd } else { 0 }
    @(
        "杠杆 <code>${lev}x</code> | 保证金 <code>$m</code> U | 滑点 <code>$slip</code> U"
        "理论风险 <code>$thr</code> U | 实际风险 <code>$ar</code> U | 盈亏比 <code>$rr</code>"
    )
}

function Format-PaperRejectHtml {
    param($RejectStats)
    if (-not $RejectStats -or $RejectStats.Count -eq 0) { return "" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("<b>⛔ 本轮开仓被拒</b>")
    foreach ($kv in ($RejectStats.GetEnumerator() | Sort-Object Name)) {
        $lines.Add("$($kv.Key): <code>$($kv.Value)</code>")
    }
    return ($lines -join "`n")
}

function Format-PaperAccountHtml {
    param(
        $Store,
        $PriceMap,
        $Opened,
        $Closed,
        $RejectStats = @{},
        [double]$FeePct = 0.05
    )

    $feeRate = Get-PaperFeePct -Store $Store
    $slipPct = if ($null -ne $Store.slippagePct) { [double]$Store.slippagePct } else { $SlippagePct }
    $lev = if ($null -ne $Store.defaultLeverage) { [int]$Store.defaultLeverage } else { $DefaultLeverage }
    $eq = Get-PaperEquity -Store $Store -PriceMap $PriceMap -FeePct $feeRate
    $stats = Get-PaperStats -Store $Store -FeePct $feeRate
    $pnlTotal = [Math]::Round($eq - [double]$Store.initialCapital, 2)
    $pnlPct = if ([double]$Store.initialCapital -gt 0) {
        [Math]::Round($pnlTotal / [double]$Store.initialCapital * 100, 2)
    } else { 0 }
    $pnlS = if ($pnlTotal -ge 0) { "+" + $pnlTotal } else { [string]$pnlTotal }
    $wr = if ($stats.Total -gt 0) { [Math]::Round($stats.Wins / $stats.Total * 100, 1) } else { 0 }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("<b>💰 模拟账户</b>")
    $lines.Add("本金 <code>$([Math]::Round([double]$Store.initialCapital, 2))</code> U | 余额 <code>$([Math]::Round([double]$Store.balance, 2))</code> U")
    $lines.Add("净值 <code>$eq</code> U（较本金 <b>$pnlS U / $pnlPct%</b>，含费+滑点）")
    $lines.Add("杠杆 <code>${lev}x</code> | 手续费单边 <code>$feeRate%</code> | 滑点 <code>$slipPct%</code> | 累计手续费 <code>$($stats.TotalFees)</code> U")
    $lines.Add("累计平仓 <code>$($stats.Total)</code> 笔，胜率 <code>$wr%</code>")

    $rejectHtml = Format-PaperRejectHtml -RejectStats $RejectStats
    if ($rejectHtml) { $lines.Add($rejectHtml) }

    if ($Closed -and $Closed.Count -gt 0) {
        $lines.Add("")
        $lines.Add("<b>📤 本轮平仓</b>")
        foreach ($t in $Closed) {
            $side = if ($t.side -eq 'long') { '多' } else { '空' }
            $pnl = [double]$t.pnlUsd
            $ps = if ($pnl -ge 0) { "+" + $pnl } else { [string]$pnl }
            $fee = if ($null -ne $t.feeUsd) { [Math]::Round([double]$t.feeUsd, 2) } else { 0 }
            $trigger = if ($t.exitTrigger) { $t.exitTrigger } else { if ($t.reason -eq 'tp') { 'TP' } else { 'SL' } }
            $rs = if ($trigger -eq 'TP') { '止盈' } else { '止损' }
            $rawX = if ($null -ne $t.rawExitPrice) { $t.rawExitPrice } elseif ($null -ne $t.rawExit) { $t.rawExit } else { $t.exit }
            $fillX = if ($null -ne $t.fillExitPrice) { $t.fillExitPrice } else { $t.fillExit }
            $kTs = if ($t.exitCandleTs) { Format-CandleTsText -Ts ([long]$t.exitCandleTs) } else { '?' }
            $kHi = if ($null -ne $t.candleHigh) { $t.candleHigh } else { '-' }
            $kLo = if ($null -ne $t.candleLow) { $t.candleLow } else { '-' }
            $exitByLbl = if ($t.exitBy -eq '5m_candle') { '5m K线' } else { ($t.exitBy) }
            $lines.Add("$side <b>$($t.base)</b> 触发 <b>$rs ($trigger)</b>")
            $lines.Add("  出场依据 <b>$exitByLbl</b> | K线 <code>$kTs</code>")
            $lines.Add("  K线最高 <code>$kHi</code> | K线最低 <code>$kLo</code>")
            $lines.Add("  原始出场 <code>$rawX</code> → 滑点后 <code>$fillX</code> | 实际盈亏 <b>$ps U</b>")
            $lines.Add("  开仓成交 <code>$($t.fillEntry)</code> | 费 <code>$fee</code> | 滑点 <code>$([double]$t.slippageUsd)</code> U")
            foreach ($dl in (Format-PositionDetailLines -Pos $t -FeeRate $feeRate -SlipPct $slipPct)) {
                $lines.Add("  $dl")
            }
        }
    }

    if ($Opened -and $Opened.Count -gt 0) {
        $lines.Add("")
        $lines.Add("<b>📥 本轮新开仓</b>")
        foreach ($p in $Opened) {
            $side = if ($p.side -eq 'long') { '多' } else { '空' }
            $rawE = if ($null -ne $p.rawEntry) { $p.rawEntry } else { $p.entry }
            $lines.Add("$side <b>$($p.base)</b> 名义 <code>$([double]$p.notionalUsd)</code> U")
            $lines.Add("  信号价 <code>$rawE</code> → 成交价 <code>$([double]$p.fillEntry)</code>")
            $lines.Add("  止损 <code>$([double]$p.stop)</code> | 止盈 <code>$([double]$p.tp)</code> | 开仓费 <code>$([Math]::Round([double]$p.openFeeUsd, 2))</code> U")
            foreach ($dl in (Format-PositionDetailLines -Pos $p -FeeRate $feeRate -SlipPct $slipPct)) {
                $lines.Add("  $dl")
            }
        }
    }

    if ($Store.openPositions -and $Store.openPositions.Count -gt 0) {
        $lines.Add("")
        $lines.Add("<b>📌 当前持仓（共 $($Store.openPositions.Count) 笔）</b>")
        $n = 1
        foreach ($pos in $Store.openPositions) {
            $side = if ($pos.side -eq 'long') { '多' } else { '空' }
            $mark = if ($PriceMap.ContainsKey($pos.instId)) { [double]$PriceMap[$pos.instId] } else { Get-PositionFillEntry -Pos $pos }
            $fillEntry = Get-PositionFillEntry -Pos $pos
            $upnl = [Math]::Round((Get-PositionNetPnlUsd -Pos $pos -MarkPrice $mark -FeePct $feeRate), 2)
            $us = if ($upnl -ge 0) { "+" + $upnl } else { [string]$upnl }
            try { $tOpen = ([datetime]$pos.openedAt).ToString('MM-dd HH:mm') } catch { $tOpen = "?" }
            $toStop = Get-DistPctToLevel -Side $pos.side -Mark $mark -Entry $fillEntry -Level ([double]$pos.stop)
            $toTp = Get-DistPctToLevel -Side $pos.side -Mark $mark -Entry $fillEntry -Level ([double]$pos.tp)
            $lines.Add("<b>$n. $side $($pos.base)</b> 【持仓中】 $tOpen")
            $lines.Add("成交进 <code>$fillEntry</code> 现 <code>$mark</code> | 浮盈(扣费后) <b>$us U</b>")
            $lines.Add("止损 <code>$([double]$pos.stop)</code> ($toStop) | 止盈 <code>$([double]$pos.tp)</code> ($toTp)")
            foreach ($dl in (Format-PositionDetailLines -Pos $pos -FeeRate $feeRate -SlipPct $slipPct)) {
                $lines.Add($dl)
            }
            $n++
        }
    } else {
        $lines.Add("")
        $lines.Add("<i>当前无持仓</i>")
    }

    return ($lines -join "`n")
}

function Format-PaperTelegramHtml {
    param($Store, $PriceMap, $Opened, $Closed, $RejectStats = @{}, [double]$FeePct)
    return Format-PaperAccountHtml -Store $Store -PriceMap $PriceMap -Opened $Opened -Closed $Closed `
        -RejectStats $RejectStats -FeePct $FeePct
}

function Invoke-PaperTradingCycle {
    param(
        $NewItems,
        $Tickers,
        [bool]$SendTelegram = $false,
        [bool]$AppendToMessage = $true,
        [bool]$Quiet = $false
    )

    Clear-PaperRejectStats
    $store = Get-PaperStore
    $priceMap = @{}
    foreach ($t in $Tickers) { $priceMap[$t.instId] = [double]$t.last }

    $upd = Update-PaperPositions -Store $store -PriceMap $priceMap -CandleMap @{} -FeePct $FeePct
    $priceMap = $upd.PriceMap
    $candleMap = $upd.CandleMap
    $closed = $upd.Closed

    $opened = New-Object System.Collections.Generic.List[object]
    if ($NewItems) {
        foreach ($it in $NewItems) {
            $pos = Open-PaperPosition -Store $store -Item $it -PriceMap $priceMap
            if ($pos) {
                $opened.Add($pos)
                $olist = [System.Collections.Generic.List[object]]::new()
                $olist.AddRange(@($store.openPositions))
                $olist.Add($pos)
                $store.openPositions = $olist.ToArray()
            }
        }
    }

    $priceMap = Enrich-PriceMapForOpenPositions -Store $store -PriceMap $priceMap
    Save-PaperStore -Store $store

    $rejectStats = Get-PaperRejectStats
    $html = Format-PaperAccountHtml -Store $store -PriceMap $priceMap -Opened $opened -Closed $closed `
        -RejectStats $rejectStats -FeePct $FeePct
    if (-not $Quiet) {
        $plain = $html -replace '<[^>]+>', '' -replace '&gt;', '>' -replace '&lt;', '<'
        Add-Content -Path $PaperLogFile -Value ("`n==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====`n" + $plain) -Encoding UTF8
        Write-Host $plain -ForegroundColor Cyan
    }

    if ($SendTelegram -and $html -and (Initialize-TelegramConfig)) {
        if ($closed.Count -gt 0 -or $opened.Count -gt 0) {
            Send-TelegramMessage -Text $html | Out-Null
        }
    }

    return @{
        Html         = $html
        Store        = $store
        Opened       = $opened
        Closed       = $closed
        RejectStats  = $rejectStats
        PriceMap     = $priceMap
    }
}

function Show-PaperReport {
    $store = Get-PaperStore
    $md = Enrich-MarketDataForOpenPositions -Store $store -PriceMap @{} -CandleMap @{}
    $priceMap = $md.PriceMap
    $html = Format-PaperTelegramHtml -Store $store -PriceMap $priceMap -Opened @() -Closed @() -FeePct $FeePct
    Write-Host ($html -replace '<[^>]+>', '' -replace '&gt;', '>' -replace '&lt;', '<')
    if (Initialize-TelegramConfig) {
        Send-TelegramMessage -Text $html
        Write-Host "Report sent." -ForegroundColor Green
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Reset) {
        Reset-PaperTrading
        exit 0
    }
    if ($Report) {
        Show-PaperReport
        exit 0
    }
}
