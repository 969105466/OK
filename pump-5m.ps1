# 5m K线：辅助确认（扫描器）+ 模拟盘止盈止损（不替代15m主信号）
# Dot-source: . "$PSScriptRoot\pump-5m.ps1"

$script:StrongLongScoreExtra = 8
$script:StrongShortScoreExtra = 8

function Convert-OkxCandleRow5m {
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

function Get-Okx5mCandles {
    param([string]$InstId, [int]$Limit = 12)
    try {
        $fetch = [Math]::Max($Limit + 1, 4)
        $uri = "https://www.okx.com/api/v5/market/candles?instId=$InstId&bar=5m&limit=$fetch"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 12
        if ($r.code -ne '0' -or -not $r.data -or $r.data.Count -lt 2) {
            return $null
        }
        $list = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -lt $r.data.Count; $i++) {
            $list.Add((Convert-OkxCandleRow5m -Row $r.data[$i] -InstId $InstId))
        }
        return $list.ToArray()
    } catch {
        return $null
    }
}

function Get-OkxLatestCompleted5mCandle {
    param([string]$InstId)
    $c = Get-Okx5mCandles -InstId $InstId -Limit 2
    if ($c -and $c.Count -gt 0) { return $c[0] }
    return $null
}

function Get-5mCandleMapForInstIds {
    param([string[]]$InstIds, [scriptblock]$OnFailLog)
    $map = @{}
    foreach ($id in @($InstIds | Where-Object { $_ } | Select-Object -Unique)) {
        $candles = Get-Okx5mCandles -InstId $id -Limit 24
        if ($candles -and $candles.Count -gt 0) {
            $map[$id] = $candles
        } elseif ($OnFailLog) {
            & $OnFailLog $id
        }
        Start-Sleep -Milliseconds 70
    }
    return $map
}

function Get-BarChgPct {
    param($Candle)
    if ($Candle.open -le 0) { return 0 }
    return ($Candle.close - $Candle.open) / $Candle.open * 100.0
}

function Get-UpperWickPct {
    param($Candle)
    if ($Candle.open -le 0) { return 0 }
    $top = [Math]::Max($Candle.open, $Candle.close)
    return ($Candle.high - $top) / $Candle.open * 100.0
}

function Build-5mContext {
    param($Candles, [string]$Side, [double]$BaseScore, [double]$MinScore = 14)

    $strongTh = $MinScore + $script:StrongLongScoreExtra
    if ($Side -eq 'short') { $strongTh = $MinScore + $script:StrongShortScoreExtra }

    if (-not $Candles -or $Candles.Count -lt 3) {
        return [PSCustomObject]@{
            Ok             = $false
            Side           = $Side
            ScoreDelta     = 0
            Block          = $false
            ConfirmOk      = $false
            StructureLabel = '无数据'
            FilterReason   = '5m K线不足'
            StrongThreshold = $strongTh
        }
    }

    $c = @($Candles | Sort-Object { [long]$_.candleTs } -Descending)
    $c1 = $c[0]
    $c2 = $c[1]
    $c3 = $c[2]

    $chg1 = Get-BarChgPct -Candle $c1
    $wick1 = Get-UpperWickPct -Candle $c1
    $body1 = [Math]::Abs($c1.close - $c1.open)
    $wickLong = ($wick1 -gt 1.0) -or (($body1 -gt 0) -and (($c1.high - [Math]::Max($c1.open, $c1.close)) -gt $body1 * 1.2))

    $closeRise2of3 = 0
    if ($c1.close -ge $c2.close) { $closeRise2of3++ }
    if ($c2.close -ge $c3.close) { $closeRise2of3++ }
    $healthyLong = ($closeRise2of3 -ge 2)

    $open3 = [double]$c3.open
    $sum3Chg = if ($open3 -gt 0) { ($c1.close - $open3) / $open3 * 100.0 } else { 0 }

    $bear2of3 = 0
    if ($c1.close -lt $c1.open) { $bear2of3++ }
    if ($c2.close -lt $c2.open) { $bear2of3++ }
    if ($c3.close -lt $c3.open) { $bear2of3++ }
    $bear2of3 = ($bear2of3 -ge 2)

    $highsNotRising = ($c1.high -le $c2.high) -and ($c2.high -le $c3.high)
    $low3 = [Math]::Min($c1.low, [Math]::Min($c2.low, $c3.low))
    $breakLow3 = ($c1.close -lt $low3)
    $last1Strong = ($chg1 -gt 1.0) -and ($c1.close -gt $c1.open)

    $delta = 0
    $block = $false
    $filter = @()
    $confirmOk = $true
    $structure = '中性'

    if ($Side -eq 'long') {
        if ($healthyLong) { $delta += 2 }
        if ($wickLong) { $delta -= 3; $filter += '5m长上影' }
        if ($chg1 -gt 2.2) { $delta -= 4; $filter += '5m单根涨幅>2.2%' }
        if ($sum3Chg -gt 4.5) { $delta -= 3; $filter += '5m三根急拉>4.5%' }

        if ($chg1 -gt 2.2) { $structure = '急拉' }
        elseif ($wickLong) { $structure = '假突破风险' }
        elseif ($healthyLong) { $structure = '偏强' }
        else { $structure = '转弱' }

        if ($chg1 -gt 2.2 -and ($BaseScore + $delta) -lt $strongTh) {
            $block = $true
            $confirmOk = $false
            $filter += '追高风险拒普通多'
        }
        if ($wickLong -and ($BaseScore + $delta) -lt $strongTh) {
            $block = $true
            $confirmOk = $false
        }
        if ($sum3Chg -gt 4.5 -and ($BaseScore + $delta) -lt $strongTh) {
            $block = $true
            $confirmOk = $false
            $filter += '急拉需强多评分'
        }
        if (-not $block) { $confirmOk = $true }
    } else {
        $shortConfirms = 0
        if ($bear2of3) { $delta += 3; $shortConfirms++ }
        if ($highsNotRising) { $delta += 3; $shortConfirms++ }
        if ($breakLow3) { $delta += 4; $shortConfirms++ }
        if ($last1Strong) { $delta -= 4; $filter += '5m重新收强' }

        if ($bear2of3 -and $highsNotRising) { $structure = '转弱' }
        elseif ($breakLow3) { $structure = '偏强' }
        elseif ($last1Strong) { $structure = '假突破风险' }
        else { $structure = '中性' }

        if ($last1Strong -and ($BaseScore + $delta) -lt $strongTh) {
            $block = $true
            $confirmOk = $false
        }
        if ($shortConfirms -eq 0 -and ($BaseScore + $delta) -lt $strongTh) {
            $block = $true
            $confirmOk = $false
            $filter += '无5m做空确认'
        }
        if (-not $block -and $shortConfirms -gt 0) { $confirmOk = $true }
    }

    return [PSCustomObject]@{
        Ok              = $true
        Side            = $Side
        ScoreDelta      = $delta
        Block           = $block
        ConfirmOk       = $confirmOk
        StructureLabel  = $structure
        FilterReason    = ($filter -join '；')
        StrongThreshold = $strongTh
        Chg1            = [Math]::Round($chg1, 2)
        Sum3Chg         = [Math]::Round($sum3Chg, 2)
    }
}

function Get-5mContextForInst {
    param([string]$InstId, [string]$Side, [double]$BaseScore, [double]$MinScore = 14)
    $candles = Get-Okx5mCandles -InstId $InstId -Limit 6
    return Build-5mContext -Candles $candles -Side $Side -BaseScore $BaseScore -MinScore $MinScore
}

function Apply-5mToPlan {
    param($Plan, $Ctx)
    if (-not $Plan) { return $null }
    if (-not $Ctx -or -not $Ctx.Ok) {
        $Plan | Add-Member -NotePropertyName M5Confirm -NotePropertyValue '未知' -Force
        $Plan | Add-Member -NotePropertyName M5Structure -NotePropertyValue '无5m数据' -Force
        $Plan | Add-Member -NotePropertyName M5FilterReason -NotePropertyValue '' -Force
        return $Plan
    }
    $newScore = $Plan.Score + $Ctx.ScoreDelta
    $Plan.Score = [Math]::Round($newScore, 2)
    $confirmTxt = if ($Ctx.ConfirmOk) { '通过' } else { '未通过' }
    $Plan | Add-Member -NotePropertyName M5Confirm -NotePropertyValue $confirmTxt -Force
    $Plan | Add-Member -NotePropertyName M5Structure -NotePropertyValue $Ctx.StructureLabel -Force
    $Plan | Add-Member -NotePropertyName M5FilterReason -NotePropertyValue $Ctx.FilterReason -Force
    if ($Ctx.Block) { return $null }
    return $Plan
}
