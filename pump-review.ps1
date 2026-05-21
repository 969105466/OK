# OKX signal review / recap -> Telegram
# Run: .\pump-review.ps1
# Today only: .\pump-review.ps1 -Days 1

param(
    [int]$Days = 0,
    [switch]$NoSend
)

. "$PSScriptRoot\hype-telegram.ps1"
. "$PSScriptRoot\pump-history.ps1"

$script:ReviewI18n = Get-Content (Join-Path $PSScriptRoot "pump-review-i18n.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ReviewStateFile = Join-Path $PSScriptRoot "pump-review-state.json"

function Format-PriceLevel {
    param([double]$Price, [double]$RefLast)
    if ($RefLast -ge 1000) { return [Math]::Round($Price, 1) }
    if ($RefLast -ge 100) { return [Math]::Round($Price, 2) }
    if ($RefLast -ge 1) { return [Math]::Round($Price, 4) }
    if ($RefLast -ge 0.1) { return [Math]::Round($Price, 5) }
    return [Math]::Round($Price, 6)
}

function Get-TickerLast {
    param([string]$InstId)
    try {
        $uri = "https://www.okx.com/api/v5/market/ticker?instId=$InstId"
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 12
        if ($r.code -eq "0" -and $r.data -and $r.data.Count -gt 0) {
            return [double]$r.data[0].last
        }
    } catch {}
    return $null
}

function Get-RecordTp {
    param($Rec)
    if ($null -ne $Rec.tp -and [double]$Rec.tp -gt 0) { return [double]$Rec.tp }
    if ($Rec.status -eq 'hit_tp2' -and $null -ne $Rec.tp2) { return [double]$Rec.tp2 }
    if ($null -ne $Rec.tp1) { return [double]$Rec.tp1 }
    return 0
}

function Get-RecordStatus {
    param($Rec)
    if ($Rec.status -eq 'hit_tp1' -or $Rec.status -eq 'hit_tp2') { return 'hit_tp' }
    return $Rec.status
}

function Get-ExitPrice {
    param($Rec)
    switch (Get-RecordStatus -Rec $Rec) {
        'hit_stop' { return [double]$Rec.stop }
        'hit_tp'   { return Get-RecordTp -Rec $Rec }
        default    { return $null }
    }
}

function Get-SignalPnlPct {
    param($Rec, [double]$LastPrice)
    $entry = [double]$Rec.entry
    if ($entry -le 0) { return 0 }
    $exit = Get-ExitPrice -Rec $Rec
    $px = if ($null -ne $exit) { $exit } else { $LastPrice }
    if ($px -le 0) { return 0 }

    if ($Rec.side -eq 'long') {
        return ($px - $entry) / $entry * 100.0
    }
    return ($entry - $px) / $entry * 100.0
}

function Get-SignalsInScope {
    param([int]$DaysBack)
    $store = Get-SignalHistoryStore
    $all = @($store.signals)
    if ($DaysBack -le 0) { return $all }

    $cutoff = (Get-Date).Date
    if ($DaysBack -gt 1) {
        $cutoff = (Get-Date).AddDays(-($DaysBack - 1)).Date
    }
    return @($all | Where-Object {
        try { [datetime]$_.sentAt -ge $cutoff } catch { $false }
    })
}

function Build-PriceMap {
    param($Signals)
    $map = @{}
    $ids = @($Signals | Where-Object { $_.instId } | Select-Object -ExpandProperty instId -Unique)
    foreach ($id in $ids) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        Start-Sleep -Milliseconds 80
        $last = Get-TickerLast -InstId $id
        if ($null -ne $last) { $map[$id] = $last }
    }
    return $map
}

function Get-ReviewStats {
    param($Signals, $PriceMap)

    $closed = @($Signals | Where-Object { $_.status -ne 'open' })
    $open = @($Signals | Where-Object { $_.status -eq 'open' })

    $wins = @($closed | Where-Object { (Get-RecordStatus -Rec $_) -eq 'hit_tp' })
    $losses = @($closed | Where-Object { (Get-RecordStatus -Rec $_) -eq 'hit_stop' })

    $pnlList = @()
    foreach ($s in $closed) {
        if (-not $s -or -not $s.instId) { continue }
        $last = if ($PriceMap.ContainsKey($s.instId)) { $PriceMap[$s.instId] } else { $s.entry }
        $pnlList += Get-SignalPnlPct -Rec $s -LastPrice $last
    }

    $openPnlList = @()
    foreach ($s in $open) {
        if (-not $s -or -not $s.instId) { continue }
        $last = if ($PriceMap.ContainsKey($s.instId)) { $PriceMap[$s.instId] } else { $s.entry }
        $openPnlList += Get-SignalPnlPct -Rec $s -LastPrice $last
    }

    $winRate = if ($closed.Count -gt 0) {
        [Math]::Round($wins.Count / $closed.Count * 100, 1)
    } else { 0 }

    $avgPnl = if ($pnlList.Count -gt 0) {
        [Math]::Round(($pnlList | Measure-Object -Average).Average, 2)
    } else { 0 }

    $sumPnl = if ($pnlList.Count -gt 0) {
        [Math]::Round(($pnlList | Measure-Object -Sum).Sum, 2)
    } else { 0 }

    $openSum = if ($openPnlList.Count -gt 0) {
        [Math]::Round(($openPnlList | Measure-Object -Sum).Sum, 2)
    } else { 0 }

    $bySide = @{}
    foreach ($side in @('long', 'short')) {
        $sub = @($closed | Where-Object { $_.side -eq $side })
        if ($sub.Count -eq 0) {
            $bySide[$side] = @{ Count = 0; WinRate = 0; AvgPnl = 0 }
            continue
        }
        $w = @($sub | Where-Object { (Get-RecordStatus -Rec $_) -eq 'hit_tp' }).Count
        $pnls = @()
        foreach ($s in $sub) {
            if (-not $s -or -not $s.instId) { continue }
            $last = if ($PriceMap.ContainsKey($s.instId)) { $PriceMap[$s.instId] } else { $s.entry }
            $pnls += Get-SignalPnlPct -Rec $s -LastPrice $last
        }
        $bySide[$side] = @{
            Count   = $sub.Count
            WinRate = [Math]::Round($w / $sub.Count * 100, 1)
            AvgPnl  = [Math]::Round(($pnls | Measure-Object -Average).Average, 2)
        }
    }

    $best = $null
    $worst = $null
    foreach ($s in $closed) {
        if (-not $s -or -not $s.instId) { continue }
        $last = if ($PriceMap.ContainsKey($s.instId)) { $PriceMap[$s.instId] } else { $s.entry }
        $p = Get-SignalPnlPct -Rec $s -LastPrice $last
        $obj = @{ Rec = $s; Pnl = $p }
        if (-not $best -or $p -gt $best.Pnl) { $best = $obj }
        if (-not $worst -or $p -lt $worst.Pnl) { $worst = $obj }
    }

    return @{
        Total      = $Signals.Count
        Closed     = $closed.Count
        Open       = $open.Count
        Wins       = $wins.Count
        Losses     = $losses.Count
        WinRate    = $winRate
        AvgPnl     = $avgPnl
        SumPnl     = $sumPnl
        OpenSum    = $openSum
        BySide     = $bySide
        ClosedList = $closed
        OpenList   = $open
        Best       = $best
        Worst      = $worst
        PriceMap   = $PriceMap
    }
}

function Get-StatusLabel {
    param($Rec, $I18n)
    switch (Get-RecordStatus -Rec $Rec) {
        'hit_stop' { return $I18n.statusStop }
        'hit_tp'   { return $I18n.statusTp }
        default    { return $I18n.statusOpen }
    }
}

function Format-PumpReviewHtml {
    param($Stats, [string]$PeriodLabel)

    $i = $script:ReviewI18n
    $now = Get-Date -Format "yyyy-MM-dd HH:mm"
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("<b>$($i.title)</b>  $now")
    $lines.Add("<i>$PeriodLabel</i>")
    $lines.Add("")

    $lines.Add("<b>$($i.summary)</b>")
    $lines.Add($($i.total -f $Stats.Total, $Stats.Closed, $Stats.Open))
    if ($Stats.Closed -gt 0) {
        $lines.Add($($i.winRate -f $Stats.WinRate, $Stats.Wins, $Stats.Losses))
        $sumS = if ($Stats.SumPnl -ge 0) { "+" + $Stats.SumPnl } else { [string]$Stats.SumPnl }
        $avgS = if ($Stats.AvgPnl -ge 0) { "+" + $Stats.AvgPnl } else { [string]$Stats.AvgPnl }
        $lines.Add($($i.avgPnl -f $avgS, $sumS))
    }
    if ($Stats.Open -gt 0) {
        $openS = if ($Stats.OpenSum -ge 0) { "+" + $Stats.OpenSum } else { [string]$Stats.OpenSum }
        $lines.Add($($i.openPnl -f $openS, $Stats.Open))
    }
    $lines.Add("")

    $lines.Add("<b>$($i.bySide)</b>")
    foreach ($side in @('long', 'short')) {
        $sd = $Stats.BySide[$side]
        $sideTxt = if ($side -eq 'long') { $i.sideLong } else { $i.sideShort }
        $pnlS = if ($sd.AvgPnl -ge 0) { "+" + $sd.AvgPnl } else { [string]$sd.AvgPnl }
        $lines.Add($($i.sideRow -f $sideTxt, $sd.Count, $sd.WinRate, $pnlS))
    }
    $lines.Add("")

    if ($Stats.Best -or $Stats.Worst) {
        $lines.Add("<b>$($i.bestWorst)</b>")
        if ($Stats.Best) {
            $b = $Stats.Best
            $bpVal = [Math]::Round($b.Pnl, 2)
            $bp = if ($bpVal -ge 0) { "+" + $bpVal } else { [string]$bpVal }
            $bs = if ($b.Rec.side -eq 'long') { $i.sideLong } else { $i.sideShort }
            $lines.Add($($i.best -f $b.Rec.base, $bs, $bp))
        }
        if ($Stats.Worst) {
            $w = $Stats.Worst
            $wpVal = [Math]::Round($w.Pnl, 2)
            $wp = if ($wpVal -ge 0) { "+" + $wpVal } else { [string]$wpVal }
            $ws = if ($w.Rec.side -eq 'long') { $i.sideLong } else { $i.sideShort }
            $lines.Add($($i.worst -f $w.Rec.base, $ws, $wp))
        }
        $lines.Add("")
    }

    $closedShow = @($Stats.ClosedList | Sort-Object {
        try { [datetime]$_.sentAt } catch { Get-Date '2000-01-01' }
    } -Descending | Select-Object -First 10)

    if ($closedShow.Count -gt 0) {
        $lines.Add("<b>$($i.closedList)</b>")
        foreach ($rec in $closedShow) {
            $sideTxt = if ($rec.side -eq 'long') { $i.sideLong } else { $i.sideShort }
            try { $timeTxt = ([datetime]$rec.sentAt).ToString('MM-dd HH:mm') } catch { $timeTxt = "?" }
            if (-not $rec.instId) { continue }
            $last = if ($Stats.PriceMap.ContainsKey($rec.instId)) { $Stats.PriceMap[$rec.instId] } else { $rec.entry }
            $exit = Get-ExitPrice -Rec $rec
            $exitPx = if ($null -ne $exit) { $exit } else { $last }
            $entryFmt = Format-PriceLevel -Price ([double]$rec.entry) -RefLast $last
            $exitFmt = Format-PriceLevel -Price $exitPx -RefLast $last
            $pnl = Get-SignalPnlPct -Rec $rec -LastPrice $last
            $pnlS = if ($pnl -ge 0) { "+" + [Math]::Round($pnl, 2) } else { [string][Math]::Round($pnl, 2) }
            $st = Get-StatusLabel -Rec $rec -I18n $i
            $lines.Add($($i.closedRow -f $rec.base, $sideTxt, $timeTxt, $entryFmt, $exitFmt, "$st $pnlS%"))
        }
        $lines.Add("")
    }

    $openShow = @($Stats.OpenList | Sort-Object {
        try { [datetime]$_.sentAt } catch { Get-Date '2000-01-01' }
    } -Descending | Select-Object -First 8)

    if ($openShow.Count -gt 0) {
        $lines.Add("<b>$($i.openList)</b>")
        foreach ($rec in $openShow) {
            $sideTxt = if ($rec.side -eq 'long') { $i.sideLong } else { $i.sideShort }
            try { $timeTxt = ([datetime]$rec.sentAt).ToString('MM-dd HH:mm') } catch { $timeTxt = "?" }
            if (-not $rec.instId) { continue }
            $last = if ($Stats.PriceMap.ContainsKey($rec.instId)) { $Stats.PriceMap[$rec.instId] } else { $rec.entry }
            $entryFmt = Format-PriceLevel -Price ([double]$rec.entry) -RefLast $last
            $nowFmt = Format-PriceLevel -Price $last -RefLast $last
            $pnl = Get-SignalPnlPct -Rec $rec -LastPrice $last
            $pnlS = if ($pnl -ge 0) { "+" + [Math]::Round($pnl, 2) } else { [string][Math]::Round($pnl, 2) }
            $lines.Add($($i.openRow -f $rec.base, $sideTxt, $timeTxt, $entryFmt, $nowFmt, $pnlS))
        }
        $lines.Add("")
    }

    $lines.Add("<i>$($i.footer)</i>")
    return ($lines -join "`n")
}

function Test-ShouldSendScheduledReview {
    param([int]$IntervalHours = 6)

    $statePath = $script:ReviewStateFile
    $now = Get-Date
    if (-not (Test-Path $statePath)) {
        return $true
    }
    try {
        $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $state.lastReviewAt) { return $true }
        $last = [datetime]$state.lastReviewAt
        return (($now - $last).TotalHours -ge $IntervalHours)
    } catch {
        return $true
    }
}

function Save-ReviewState {
    $obj = @{ lastReviewAt = (Get-Date).ToString('o') }
    $json = $obj | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($script:ReviewStateFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-PumpReview {
    param(
        [int]$Days = 0,
        [bool]$SendTelegram = $true,
        [bool]$UpdateTriggers = $true
    )

    if ($UpdateTriggers) {
        $store = Get-SignalHistoryStore
        $ids = @($store.signals | Select-Object -ExpandProperty instId -Unique)
        $priceMap = Build-PriceMap -Signals $store.signals
        Update-SignalHistoryTriggers -PriceMap $priceMap
    }

    $signals = @(Get-SignalsInScope -DaysBack $Days | Where-Object { $_ -and $_.instId })
    if ($signals.Count -eq 0) {
        Write-Host "No signal history for review." -ForegroundColor Yellow
        if ($SendTelegram -and (Initialize-TelegramConfig)) {
            . "$PSScriptRoot\pump-paper.ps1"
            $store = Get-PaperStore
            $priceMap = @{}
            foreach ($pos in $store.openPositions) {
                if ($pos.instId) {
                    $last = Get-TickerLast -InstId $pos.instId
                    if ($null -ne $last) { $priceMap[$pos.instId] = $last }
                }
            }
            $html = Format-PaperAccountHtml -Store $store -PriceMap $priceMap -Opened @() -Closed @()
            $msg = "<b>📋 定时复盘</b>  $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n`n信号历史暂无，以下为模拟盘：`n`n$html"
            if (Send-TelegramMessage -Text $msg) {
                Save-ReviewState
                Write-Host "Paper-only review sent." -ForegroundColor Green
                return $true
            }
        }
        return $false
    }

    $priceMap2 = Build-PriceMap -Signals $signals
    $stats = Get-ReviewStats -Signals $signals -PriceMap $priceMap2

    $periodLabel = if ($Days -le 0) { $script:ReviewI18n.periodAll } else { $script:ReviewI18n.periodToday }
    $html = Format-PumpReviewHtml -Stats $stats -PeriodLabel $periodLabel
    $plain = $html -replace '<[^>]+>', '' -replace '&gt;', '>' -replace '&lt;', '<'

    Write-Host $plain
    Add-Content -Path (Join-Path $PSScriptRoot "pump-review.log") -Value ("`n==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $periodLabel ====`n" + $plain) -Encoding UTF8

    if ($SendTelegram -and (Initialize-TelegramConfig)) {
        if (Send-TelegramMessage -Text $html) {
            Write-Host "Review sent to Telegram." -ForegroundColor Green
            Save-ReviewState
            return $true
        }
        Write-Host "Telegram send failed." -ForegroundColor Red
        return $false
    }

    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $NoSend -and -not (Initialize-TelegramConfig)) {
        Write-Host "Configure telegram.env first." -ForegroundColor Yellow
        exit 1
    }
    Invoke-PumpReview -Days $Days -SendTelegram:(-not $NoSend)
}
