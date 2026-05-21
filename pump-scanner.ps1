# OKX pump scanner - every 10 min, Telegram actionable LONG/SHORT with levels
# Run: cd D:\code\OK; .\pump-scanner.ps1
# Test once: .\pump-scanner.ps1 -Once

param(
    [int]$IntervalMin = 10,
    [int]$TopN = 5,
    [double]$MinChg24hPct = 3.0,
    [double]$MaxChg24hPct = 32.0,
    [double]$MinVolUsd24h = 8000000,
    [double]$MinOi15mPct = 1.2,
    [double]$MinPx15mPct = 0.5,
    [double]$MinScore = 14.0,
    [int]$DeepScanTop = 28,
    [double]$MinRrTp1 = 1.25,
    [double]$MaxStopPctLong = 1.4,
    [double]$MaxStopPctShort = 1.25,
    [double]$MinTpPctLong = 2.5,
    [double]$MinTpPctShort = 3.0,
    [int]$ReviewEveryHours = 6,
    [string]$LogFile = "$PSScriptRoot\pump-scanner.log",
    [switch]$Once
)

. "$PSScriptRoot\hype-telegram.ps1"
. "$PSScriptRoot\pump-history.ps1"
. "$PSScriptRoot\pump-review.ps1"
. "$PSScriptRoot\pump-5m.ps1"
. "$PSScriptRoot\pump-paper.ps1"
$script:ScannerLogFile = $LogFile

$script:I18n = Get-Content (Join-Path $PSScriptRoot "pump-i18n.json") -Raw -Encoding UTF8 | ConvertFrom-Json

$script:ExcludeBases = @(
    'BTC', 'ETH', 'SOL', 'DOGE', 'XRP', 'BNB', 'TRX', 'ADA', 'LTC',
    'LINK', 'AVAX', 'DOT', 'BCH', 'ETC', 'FIL', 'UNI', 'AAVE', 'ATOM',
    'XAU', 'XAG', 'OKB', 'USDC', 'USDT', 'DAI',
    'XAUT', 'STETH', 'WBTC', 'TON', 'NEAR', 'APT', 'ARB', 'OP',
    'MU', 'AMD', 'INTC', 'SNDK', 'CL', 'XPD', 'XPT', 'SPX', 'SPACEX'
)

function Get-BaseFromInstId {
    param([string]$InstId)
    if ($InstId -match '^(.+)-USDT-SWAP$') { return $matches[1] }
    return $InstId
}

function Test-IsExcluded {
    param([string]$InstId)
    $base = Get-BaseFromInstId -InstId $InstId
    return $script:ExcludeBases -contains $base
}

function Format-PriceLevel {
    param([double]$Price, [double]$RefLast)
    if ($RefLast -ge 1000) { return [Math]::Round($Price, 1) }
    if ($RefLast -ge 100) { return [Math]::Round($Price, 2) }
    if ($RefLast -ge 1) { return [Math]::Round($Price, 4) }
    if ($RefLast -ge 0.1) { return [Math]::Round($Price, 5) }
    return [Math]::Round($Price, 6)
}

function Get-AllSwapTickers {
    $uri = "https://www.okx.com/api/v5/market/tickers?instType=SWAP"
    $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 30
    if ($r.code -ne "0") { throw "tickers error: $($r.msg)" }
    return @($r.data | Where-Object { $_.instId -match '-USDT-SWAP$' })
}

function Get-OiDelta15m {
    param([string]$InstId)
    try {
        $uri = "https://www.okx.com/api/v5/rubik/stat/contracts/open-interest-history?instId=$InstId&period=15m"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 12
        if ($r.code -ne "0" -or -not $r.data -or $r.data.Count -lt 2) { return $null }
        $cur = [double]$r.data[0][3]
        $prev = [double]$r.data[1][3]
        if ($prev -le 0) { return $null }
        return [PSCustomObject]@{
            OiUsd    = $cur
            DeltaPct = ($cur - $prev) / $prev * 100.0
        }
    } catch { return $null }
}

function Get-PxDelta15m {
    param([string]$InstId)
    try {
        $uri = "https://www.okx.com/api/v5/market/candles?instId=$InstId&bar=15m&limit=3"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 12
        if ($r.code -ne "0" -or -not $r.data -or $r.data.Count -lt 2) { return $null }
        $c0 = [double]$r.data[0][4]
        $c1 = [double]$r.data[1][4]
        if ($c1 -le 0) { return $null }
        return ($c0 - $c1) / $c1 * 100.0
    } catch { return $null }
}

function Get-FundingPct8h {
    param([string]$InstId)
    try {
        $uri = "https://www.okx.com/api/v5/public/funding-rate?instId=$InstId"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
        if ($r.code -eq "0" -and $r.data) {
            return [double]$r.data[0].fundingRate * 100.0
        }
    } catch {}
    return $null
}

function Get-CandleStats {
    param([string]$InstId)
    try {
        $uri = "https://www.okx.com/api/v5/market/candles?instId=$InstId&bar=15m&limit=96"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 12
        if ($r.code -ne "0" -or -not $r.data -or $r.data.Count -lt 8) { return $null }

        $lows = @()
        $highs = @()
        $n = [Math]::Min(96, $r.data.Count)
        for ($i = 0; $i -lt $n; $i++) {
            $lows += [double]$r.data[$i][3]
            $highs += [double]$r.data[$i][2]
        }
        $low4 = ($lows | Select-Object -First 4 | Measure-Object -Minimum).Minimum
        $high4 = ($highs | Select-Object -First 4 | Measure-Object -Maximum).Maximum
        $low24 = ($lows | Measure-Object -Minimum).Minimum
        $high24 = ($highs | Measure-Object -Maximum).Maximum
        $last = [double]$r.data[0][4]

        return [PSCustomObject]@{
            Last   = $last
            Low4   = $low4
            High4  = $high4
            Low24  = $low24
            High24 = $high24
        }
    } catch { return $null }
}

function Get-PlanRr {
    param([string]$Side, [double]$Entry, [double]$Stop, [double]$Tp)
    if ($Entry -le 0) { return 0 }
    if ($Side -eq 'long') {
        $loss = ($Entry - $Stop) / $Entry * 100.0
        $gain = ($Tp - $Entry) / $Entry * 100.0
    } else {
        $loss = ($Stop - $Entry) / $Entry * 100.0
        $gain = ($Entry - $Tp) / $Entry * 100.0
    }
    if ($loss -lt 0.05) { return 99 }
    return $gain / $loss
}

function Finalize-TradePlanLevels {
    param(
        [string]$Side,
        [double]$Entry,
        [double]$Stop,
        [double]$Tp,
        $CandleStats,
        [double]$MinRr,
        [double]$MaxStopPct,
        [double]$MinTpPct
    )

    if ($Side -eq 'long') {
        $stopFloor = $Entry * (1 - $MaxStopPct / 100.0)
        if ($Stop -lt $stopFloor) { $Stop = $stopFloor }
        if ($Stop -ge $Entry) { $Stop = $Entry * 0.988 }

        $risk = $Entry - $Stop
        $tpRr = $Entry + $risk * $MinRr
        $tpPct = $Entry * (1 + $MinTpPct / 100.0)
        if ($Tp -lt $tpRr) { $Tp = $tpRr }
        if ($Tp -lt $tpPct) { $Tp = $tpPct }
        if ($CandleStats -and $CandleStats.High24 -gt $Entry * 1.005) {
            $cap = [Math]::Min($CandleStats.High24, $Entry * 1.045)
            if ($Tp -gt $cap) { $Tp = $cap }
        }
    } else {
        $stopCeiling = $Entry * (1 + $MaxStopPct / 100.0)
        if ($Stop -gt $stopCeiling) { $Stop = $stopCeiling }
        if ($Stop -le $Entry) { $Stop = $Entry * 1.012 }

        $risk = $Stop - $Entry
        $tpRr = $Entry - $risk * $MinRr
        $tpPct = $Entry * (1 - $MinTpPct / 100.0)
        if ($Tp -gt $tpRr) { $Tp = $tpRr }
        if ($Tp -gt $tpPct) { $Tp = $tpPct }
        if ($CandleStats -and $CandleStats.Low4 -lt $Entry * 0.998) {
            $structTp = ($Entry + $CandleStats.Low4) / 2.0
            if ($structTp -lt $Tp -and $structTp -lt $Entry) { $Tp = $structTp }
        }
    }

    return @{ Stop = $Stop; Tp = $Tp }
}

function Get-TradePlan {
    param(
        [double]$Last,
        [double]$Chg24h,
        [double]$Oi15m,
        [double]$Px15m,
        [double]$FundPct,
        $CandleStats
    )

    $r = $script:I18n.reasons
    if (-not $CandleStats) { return $null }

    $low4 = $CandleStats.Low4
    $high4 = $CandleStats.High4
    $high24 = $CandleStats.High24
    $low24 = $CandleStats.Low24
    $distHighPct = if ($high24 -gt 0) { ($high24 - $Last) / $high24 * 100.0 } else { 100 }

    # --- LONG: momentum continuation (avoid shorting same setup) ---
    $longOk = $false
    $longReason = $r.longMomentum
    if ($Px15m -ge $MinPx15mPct -and $Oi15m -ge $MinOi15mPct -and $Chg24h -ge 4 -and $Chg24h -le 26) {
        if ($distHighPct -ge 0.8 -and $Px15m -gt 0) {
            $longOk = $true
        }
    }
    if (-not $longOk -and $Px15m -ge 0.75 -and $Oi15m -ge 1.8 -and $Chg24h -ge 8 -and $Chg24h -le 24 -and $distHighPct -le 1.5) {
        $longOk = $true
        $longReason = $r.longBreakout
    }
    if (-not $longOk -and $FundPct -lt -0.012 -and $Px15m -ge 0.4 -and $Oi15m -ge 1.2 -and $Chg24h -ge 3 -and $Chg24h -le 22) {
        $longOk = $true
        $longReason = $r.longSqueeze
    }

    if ($longOk) {
        $entry = $Last
        $stopRaw = [Math]::Max($low4, $entry * (1 - $MaxStopPctLong / 100.0))
        if ($stopRaw -ge $entry) { $stopRaw = $entry * 0.988 }
        $tpRaw = if ($high4 -gt $entry * 1.006) {
            ($entry + $high4) / 2.0
        } else { $entry * (1 + $MinTpPctLong / 100.0) }

        $lv = Finalize-TradePlanLevels -Side 'long' -Entry $entry -Stop $stopRaw -Tp $tpRaw `
            -CandleStats $CandleStats -MinRr $MinRrTp1 -MaxStopPct $MaxStopPctLong `
            -MinTpPct $MinTpPctLong
        $rr = Get-PlanRr -Side 'long' -Entry $entry -Stop $lv.Stop -Tp $lv.Tp
        if ($rr -lt $MinRrTp1) { return $null }

        $plan = [PSCustomObject]@{
            Side    = 'long'
            Entry   = Format-PriceLevel -Price $entry -RefLast $Last
            Stop    = Format-PriceLevel -Price $lv.Stop -RefLast $Last
            Tp      = Format-PriceLevel -Price $lv.Tp -RefLast $Last
            Reason  = $longReason
            Score   = $Px15m * 2.5 + $Oi15m * 2 + [Math]::Min($Chg24h, 18) + $rr * 4 + $(if ($FundPct -lt 0) { 3 } else { 0 })
        }
        if (Test-ValidPlanLevels -Plan $plan) { return $plan }
        return $null
    }

    # --- SHORT: only at 24h high + clear 15m exhaustion (no dip-buying in parabolic) ---
    if ($Px15m -gt -0.4 -and $Chg24h -ge 12) { return $null }
    if ($Px15m -gt 0 -and $Oi15m -gt 0.8 -and $Chg24h -ge 8) { return $null }
    if ($distHighPct -gt 2.5) { return $null }

    $shortOk = $false
    $shortReason = $r.shortFade
    if ($Chg24h -ge 10 -and $Chg24h -le 30 -and $Px15m -le -0.7 -and $distHighPct -le 2) {
        if ($Oi15m -le 1.2 -or ($Px15m -le -1 -and $Oi15m -le 2.5)) {
            $shortOk = $true
        }
    }
    if (-not $shortOk -and $Chg24h -ge 20 -and $Px15m -le -1.1 -and $Oi15m -le 0.5 -and $distHighPct -le 1.8) {
        $shortOk = $true
        $shortReason = $r.shortFade
    }
    if (-not $shortOk -and $Px15m -le -1.15 -and $Oi15m -le -1 -and $Chg24h -ge 6) {
        $shortOk = $true
        $shortReason = $r.shortDump
    }
    if (-not $shortOk -and $Chg24h -ge 14 -and $Chg24h -le 28 -and $FundPct -ge 0.025 -and $Px15m -le -0.55 -and $Oi15m -le 0.8 -and $distHighPct -le 2) {
        $shortOk = $true
        $shortReason = $r.shortCrowd
    }

    if ($shortOk) {
        $entry = $Last
        $stopRaw = [Math]::Min($high4, $entry * (1 + $MaxStopPctShort / 100.0))
        if ($stopRaw -le $entry) { $stopRaw = $entry * 1.012 }
        $tpRaw = if ($low4 -lt $entry * 0.998) {
            ($entry + $low4) / 2.0
        } else { $entry * (1 - $MinTpPctShort / 100.0) }

        $lv = Finalize-TradePlanLevels -Side 'short' -Entry $entry -Stop $stopRaw -Tp $tpRaw `
            -CandleStats $CandleStats -MinRr $MinRrTp1 -MaxStopPct $MaxStopPctShort `
            -MinTpPct $MinTpPctShort
        $rr = Get-PlanRr -Side 'short' -Entry $entry -Stop $lv.Stop -Tp $lv.Tp
        if ($rr -lt $MinRrTp1) { return $null }

        $shortScore = [Math]::Abs($Px15m) * 3 + [Math]::Min($Chg24h, 18) + $rr * 4
        if ($Oi15m -le 0) { $shortScore += 4 }
        if ($Px15m -le -1) { $shortScore += 3 }
        if ($FundPct -ge 0.025) { $shortScore += 2 }
        if ($distHighPct -le 1.2) { $shortScore += 2 }

        $plan = [PSCustomObject]@{
            Side    = 'short'
            Entry   = Format-PriceLevel -Price $entry -RefLast $Last
            Stop    = Format-PriceLevel -Price $lv.Stop -RefLast $Last
            Tp      = Format-PriceLevel -Price $lv.Tp -RefLast $Last
            Reason  = $shortReason
            Score   = $shortScore
        }
        if (Test-ValidPlanLevels -Plan $plan) { return $plan }
        return $null
    }

    return $null
}

function Format-SignedPct {
    param([double]$Pct)
    $v = [Math]::Round($Pct, 2)
    if ($v -gt 0) { return "+" + $v + "%" }
    if ($v -lt 0) { return [string]$v + "%" }
    return "0%"
}

function Get-PlanPctStrings {
    param([string]$Side, [double]$Entry, [double]$Stop, [double]$Tp)
    if ($Entry -le 0) {
        return @{ Stop = ""; Tp = ""; Rr = "n/a" }
    }
    if ($Side -eq 'long') {
        $stopPct = ($Stop - $Entry) / $Entry * 100.0
        $tpPct = ($Tp - $Entry) / $Entry * 100.0
    } else {
        $stopPct = ($Entry - $Stop) / $Entry * 100.0
        $tpPct = ($Entry - $Tp) / $Entry * 100.0
    }
    $loss = [Math]::Abs($stopPct)
    $rr = if ($loss -gt 0.01) { [Math]::Round($tpPct / $loss, 1) } else { "n/a" }
    return @{
        Stop = Format-SignedPct -Pct $stopPct
        Tp   = Format-SignedPct -Pct $tpPct
        Rr   = $rr
    }
}

function Test-ValidPlanLevels {
    param($Plan)
    if ($Plan.Side -eq 'long') {
        return ($Plan.Stop -lt $Plan.Entry -and $Plan.Tp -gt $Plan.Entry)
    }
    return ($Plan.Stop -gt $Plan.Entry -and $Plan.Tp -lt $Plan.Entry)
}

function Get-PumpScore {
    param($Plan)
    return $Plan.Score
}

function Scan-TradeCandidates {
    $tickers = Get-AllSwapTickers
    $prelim = @()

    foreach ($t in $tickers) {
        if (Test-IsExcluded -InstId $t.instId) { continue }
        $last = [double]$t.last
        $open = [double]$t.open24h
        if ($open -le 0 -or $last -le 0) { continue }

        $chg24 = ($last - $open) / $open * 100.0
        if ($chg24 -lt $MinChg24hPct -or $chg24 -gt $MaxChg24hPct) { continue }

        $volUsd = [double]$t.volCcy24h * $last
        if ($volUsd -lt $MinVolUsd24h) { continue }

        $prelim += [PSCustomObject]@{
            InstId   = $t.instId
            Base     = Get-BaseFromInstId -InstId $t.instId
            Last     = $last
            Chg24h   = $chg24
            VolUsd   = $volUsd
            PreScore = $chg24 * [Math]::Log10([Math]::Max($volUsd, 1))
        }
    }

    $deep = $prelim | Sort-Object PreScore -Descending | Select-Object -First $DeepScanTop
    $final = @()

    foreach ($p in $deep) {
        Start-Sleep -Milliseconds 150
        $oi = Get-OiDelta15m -InstId $p.InstId
        $px15 = Get-PxDelta15m -InstId $p.InstId
        $fund = Get-FundingPct8h -InstId $p.InstId
        $candles = Get-CandleStats -InstId $p.InstId

        $oiPct = if ($oi) { $oi.DeltaPct } else { 0 }
        $pxPct = if ($null -ne $px15) { $px15 } else { 0 }
        $fundPct = if ($null -ne $fund) { $fund } else { 0 }

        $plan = Get-TradePlan -Last $p.Last -Chg24h $p.Chg24h -Oi15m $oiPct -Px15m $pxPct -FundPct $fundPct -CandleStats $candles
        if (-not $plan) { continue }

        $ctx5 = Get-5mContextForInst -InstId $p.InstId -Side $plan.Side -BaseScore $plan.Score -MinScore $MinScore
        $plan = Apply-5mToPlan -Plan $plan -Ctx $ctx5
        if (-not $plan) { continue }

        if (Test-SignalCooldown -InstId $p.InstId -Side $plan.Side) { continue }
        if ($plan.Score -lt $MinScore) { continue }

        $final += [PSCustomObject]@{
            Base           = $p.Base
            InstId         = $p.InstId
            Last           = $p.Last
            Chg24h         = [Math]::Round($p.Chg24h, 2)
            Px15m          = [Math]::Round($pxPct, 2)
            Oi15m          = [Math]::Round($oiPct, 2)
            Side           = $plan.Side
            Entry          = $plan.Entry
            Stop           = $plan.Stop
            Tp             = $plan.Tp
            Reason         = $plan.Reason
            Score          = $plan.Score
            M5Confirm      = $plan.M5Confirm
            M5Structure    = $plan.M5Structure
            M5FilterReason = $plan.M5FilterReason
        }
    }

    $items = @($final | Sort-Object Score -Descending | Select-Object -First $TopN)
    return [PSCustomObject]@{
        Items   = $items
        Tickers = $tickers
    }
}

function Format-PumpTelegramHtml {
    param(
        $Items,
        [string]$BarLabel,
        [string]$CapitalHtml = "",
        [string]$HistoryHtml = "",
        $NewOpenKeys = @(),
        $OpenKeys = @()
    )

    $i = $script:I18n
    $now = Get-Date -Format "yyyy-MM-dd HH:mm"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("<b>$($i.title)</b>  $now")
    $lines.Add("<i>$($i.meta -f $BarLabel)</i>")
    if ($CapitalHtml) {
        $lines.Add("")
        $lines.Add($CapitalHtml)
    }
    $lines.Add("")

    if (-not $Items -or $Items.Count -eq 0) {
        $lines.Add("<b>$($i.noHit)</b>")
        $lines.Add("<i>$($i.noHitCond)</i>")
        if ($HistoryHtml) { $lines.Add($HistoryHtml) }
        $lines.Add("<i>$($i.footer)</i>")
        return ($lines -join "`n")
    }

    $lines.Add("<b>$($i.hitCount -f $Items.Count)</b>")
    $lines.Add("")

    $rank = 1
    foreach ($it in $Items) {
        $tag = if ($it.Side -eq 'long') { $i.longTag } else { $i.shortTag }
        $key = "$($it.InstId)|$($it.Side)"
        if ($NewOpenKeys -contains $key) {
            $tag = "$tag $($i.tagNewOpen)"
        } elseif ($OpenKeys -contains $key) {
            $tag = "$tag $($i.tagHeld)"
        }
        $pxS = if ($it.Px15m -ge 0) { "+" + $it.Px15m } else { [string]$it.Px15m }
        $oiS = if ($it.Oi15m -ge 0) { "+" + $it.Oi15m } else { [string]$it.Oi15m }
        $chgS = if ($it.Chg24h -ge 0) { "+" + $it.Chg24h } else { [string]$it.Chg24h }

        $pct = Get-PlanPctStrings -Side $it.Side -Entry $it.Entry -Stop $it.Stop -Tp $it.Tp

        $lines.Add("<b>$rank. $($it.Base)</b>  $tag")
        $lines.Add("$($i.entry): <code>$($it.Entry)</code>")
        $lines.Add("<b>$($i.slTpBlock)</b>")
        $lines.Add($($i.stopLine -f $it.Stop, $pct.Stop))
        $lines.Add($($i.tpLine -f $it.Tp, $pct.Tp))
        if ($pct.Rr -ne "n/a") {
            try {
                if ([double]$pct.Rr -ge 1.0) {
                    $lines.Add($($i.rrLine -f $pct.Rr))
                }
            } catch {}
        }
        $lines.Add($($i.context -f $it.Last, $chgS, $pxS, $oiS))
        $lines.Add("$($i.reasonLabel): $($it.Reason)")
        if ($it.M5Confirm) {
            $m5f = if ($it.M5FilterReason) { " | $($it.M5FilterReason)" } else { "" }
            $lines.Add($($i.m5Line -f $it.M5Confirm, $it.M5Structure, $m5f))
        }
        $lines.Add("")
        $rank++
    }

    if ($HistoryHtml) { $lines.Add($HistoryHtml) }
    $lines.Add("<i>$($i.footer)</i>")
    return ($lines -join "`n")
}

function Invoke-ScanAndNotify {
    if (-not (Initialize-TelegramConfig)) {
        throw "telegram.env missing"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Scanning..."
    $scan = Scan-TradeCandidates
    $items = $scan.Items
    $historyHtml = Invoke-HistoryCycle -NewItems $items -Tickers $scan.Tickers -I18n $script:I18n
    $paper = Invoke-PaperTradingCycle -NewItems $items -Tickers $scan.Tickers -Quiet $true
    $priceMap = @{}
    foreach ($t in $scan.Tickers) { $priceMap[$t.instId] = [double]$t.last }
    $priceMap = if ($paper.PriceMap) { $paper.PriceMap } else { $priceMap }
    $capitalHtml = Format-PaperAccountHtml -Store $paper.Store -PriceMap $priceMap -Opened $paper.Opened `
        -Closed $paper.Closed -RejectStats $paper.RejectStats

    $openKeys = @($paper.Store.openPositions | ForEach-Object { "$($_.instId)|$($_.side)" })
    $newOpenKeys = @($paper.Opened | ForEach-Object { "$($_.instId)|$($_.side)" })

    $html = Format-PumpTelegramHtml -Items $items -BarLabel "${IntervalMin}m" `
        -CapitalHtml $capitalHtml -HistoryHtml $historyHtml `
        -NewOpenKeys $newOpenKeys -OpenKeys $openKeys
    $plain = $html -replace '<[^>]+>', '' -replace '&gt;', '>' -replace '&lt;', '<'

    Write-Host $plain
    Add-Content -Path $script:ScannerLogFile -Value ("`n==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====`n" + $plain) -Encoding UTF8

    if (Send-TelegramMessage -Text $html) {
        Write-Host "Telegram sent." -ForegroundColor Green
    } else {
        Write-Host "Telegram failed." -ForegroundColor Red
    }

    if ($ReviewEveryHours -gt 0 -and (Test-ShouldSendScheduledReview -IntervalHours $ReviewEveryHours)) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Running scheduled review..." -ForegroundColor Cyan
        try {
            Invoke-PumpReview -Days 0 -SendTelegram $true -UpdateTriggers $false
        } catch {
            Write-Host "Review error: $_" -ForegroundColor Red
        }
    }
}

if (-not (Initialize-TelegramConfig)) {
    Write-Host "Configure telegram.env first." -ForegroundColor Yellow
    exit 1
}

Write-Host "Trade signal scanner | every ${IntervalMin} min | Top $TopN | min RR 1:$MinRrTp1 | log: $script:ScannerLogFile"
Write-Host "Paper sim: 1000U | 3x | risk 2% | fee 0.05%/side | slip 0.08% | pump-paper.json"
Write-Host "LONG/SHORT 15m信号 + 5m确认/模拟平仓 + history + paper"
Write-Host "Press Ctrl+C to stop"
Write-Host ""

if ($Once) {
    try { Invoke-ScanAndNotify } catch { Write-Host "ERROR: $_" -ForegroundColor Red; exit 1 }
    exit 0
}

while ($true) {
    try {
        Invoke-ScanAndNotify
    } catch {
        $err = "ERROR $(Get-Date -Format 'HH:mm:ss'): $_"
        Write-Host $err -ForegroundColor Red
        Add-Content -Path $script:ScannerLogFile -Value $err -Encoding UTF8
        $errEsc = Escape-TelegramHtml -Text $err
        Send-TelegramMessage -Text "<b>Scanner error</b>`n$errEsc"
    }
    Start-Sleep -Seconds ($IntervalMin * 60)
}
