# Signal history: persist levels, track SL/TP triggers

param(
    [string]$HistoryFile = $(Join-Path $PSScriptRoot "pump-signal-history.json"),
    [int]$HistoryMaxDisplay = 12,
    [int]$HistoryMaxRecords = 80,
    [int]$HistoryDaysKeep = 14,
    [double]$DedupeEntryPct = 2.5,
    [int]$StopCooldownHours = 8
)

function Get-SignalHistoryStore {
    if (-not (Test-Path $HistoryFile)) {
        return @{ signals = @() }
    }
    try {
        $raw = Get-Content $HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $raw.signals) { return @{ signals = @() } }
        $arr = @($raw.signals | Where-Object { $_ -and $_.instId -and $_.base })
        return @{ signals = $arr }
    } catch {
        return @{ signals = @() }
    }
}

function Save-SignalHistoryStore {
    param($Store)
    $json = @{ signals = @($Store.signals) } | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($HistoryFile, $json, [System.Text.UTF8Encoding]::new($false))
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

function Test-ShouldAddSignal {
    param($ExistingSignals, $InstId, $Side, [double]$Entry)
    $openSame = @($ExistingSignals | Where-Object {
        $_.instId -eq $InstId -and $_.side -eq $Side -and (Get-RecordStatus -Rec $_) -eq 'open'
    })
    if ($openSame.Count -eq 0) { return $true }
    $last = $openSame[-1]
    $ref = [double]$last.entry
    if ($ref -le 0) { return $true }
    $diff = [Math]::Abs($Entry - $ref) / $ref * 100.0
    return ($diff -gt $DedupeEntryPct)
}

function Test-SignalCooldown {
    param(
        [string]$InstId,
        [string]$Side,
        [int]$Hours = 8
    )
    $store = Get-SignalHistoryStore
    $cutoff = (Get-Date).AddHours(-$Hours)
    $recentStop = @($store.signals | Where-Object {
        $_.instId -eq $InstId -and $_.side -eq $Side -and (Get-RecordStatus -Rec $_) -eq 'hit_stop' -and
        (try { [datetime]$_.hitStopAt -gt $cutoff } catch { $false })
    })
    return ($recentStop.Count -gt 0)
}

function Add-SignalsFromScan {
    param($NewItems)
    if (-not $NewItems -or $NewItems.Count -eq 0) { return }

    $store = Get-SignalHistoryStore
    $list = [System.Collections.Generic.List[object]]::new()
    $list.AddRange(@($store.signals))

    $now = Get-Date
    foreach ($it in $NewItems) {
        if (-not (Test-ShouldAddSignal -ExistingSignals $list -InstId $it.InstId -Side $it.Side -Entry $it.Entry)) {
            continue
        }
        $list.Add([PSCustomObject]@{
            id        = [guid]::NewGuid().ToString('N').Substring(0, 10)
            sentAt    = $now.ToString('o')
            base      = $it.Base
            instId    = $it.InstId
            side      = $it.Side
            entry     = [double]$it.Entry
            stop      = [double]$it.Stop
            tp        = [double]$it.Tp
            status    = 'open'
            highSince = [double]$it.Last
            lowSince  = [double]$it.Last
            hitStopAt = $null
            hitTpAt   = $null
        })
    }

    $store.signals = $list.ToArray()
    Save-SignalHistoryStore -Store $store
}

function Update-SignalHistoryTriggers {
    param($PriceMap)

    $store = Get-SignalHistoryStore
    if ($store.signals.Count -eq 0) { return }

    $now = Get-Date
    $changed = $false

    foreach ($rec in $store.signals) {
        if (-not $PriceMap.ContainsKey($rec.instId)) { continue }
        $last = [double]$PriceMap[$rec.instId]
        if ($last -le 0) { continue }

        if ([double]$rec.highSince -lt $last) { $rec.highSince = $last; $changed = $true }
        if ([double]$rec.lowSince -gt $last) { $rec.lowSince = $last; $changed = $true }

        $stop = [double]$rec.stop
        $tp = Get-RecordTp -Rec $rec
        $hi = [double]$rec.highSince
        $lo = [double]$rec.lowSince
        $ts = $now.ToString('o')
        $st = Get-RecordStatus -Rec $rec

        if ($st -ne 'open') { continue }

        if ($rec.side -eq 'long') {
            if ($lo -le $stop) {
                $rec.status = 'hit_stop'
                $rec.hitStopAt = $ts
                $changed = $true
            } elseif ($tp -gt 0 -and $hi -ge $tp) {
                $rec.status = 'hit_tp'
                $rec.hitTpAt = $ts
                $changed = $true
            }
        } else {
            if ($hi -ge $stop) {
                $rec.status = 'hit_stop'
                $rec.hitStopAt = $ts
                $changed = $true
            } elseif ($tp -gt 0 -and $lo -le $tp) {
                $rec.status = 'hit_tp'
                $rec.hitTpAt = $ts
                $changed = $true
            }
        }
    }

    $cutoff = (Get-Date).AddDays(-$HistoryDaysKeep)
    $pruned = @($store.signals | Where-Object {
        try { [datetime]$_.sentAt -gt $cutoff } catch { $false }
    })
    if ($pruned.Count -gt $HistoryMaxRecords) {
        $pruned = $pruned | Sort-Object { [datetime]$_.sentAt } -Descending | Select-Object -First $HistoryMaxRecords
    }

    if ($changed -or $pruned.Count -ne $store.signals.Count) {
        $store.signals = $pruned
        Save-SignalHistoryStore -Store $store
    }
}

function Get-HistoryForDisplay {
    $store = Get-SignalHistoryStore
    return @($store.signals | Sort-Object {
        try { [datetime]$_.sentAt } catch { Get-Date '2000-01-01' }
    } -Descending | Select-Object -First $HistoryMaxDisplay)
}

function Get-HistoryStatusLabel {
    param($Rec, $I18n)
    switch (Get-RecordStatus -Rec $Rec) {
        'hit_stop' { return $I18n.statusStop }
        'hit_tp'   { return $I18n.statusTp }
        default    { return $I18n.statusOpen }
    }
}

function Get-HistoryMark {
    param([bool]$Hit, [string]$MarkText)
    if ($Hit) { return $MarkText }
    return ""
}

function Format-HistoryTelegramHtml {
    param($PriceMap, $I18n)

    $rows = Get-HistoryForDisplay
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("<b>$($I18n.historyTitle)</b>")

    if ($rows.Count -eq 0) {
        $lines.Add("<i>$($I18n.historyEmpty)</i>")
        return ($lines -join "`n")
    }

    foreach ($rec in $rows) {
        $sideTxt = if ($rec.side -eq 'long') { $I18n.historySideLong } else { $I18n.historySideShort }
        try {
            $t = [datetime]$rec.sentAt
            $timeTxt = $t.ToString('MM-dd HH:mm')
        } catch { $timeTxt = "?" }

        $nowPx = if ($PriceMap.ContainsKey($rec.instId)) {
            $PriceMap[$rec.instId]
        } else { $rec.entry }
        $ref = [double]$nowPx
        $entryFmt = Format-PriceLevel -Price ([double]$rec.entry) -RefLast $ref
        $nowFmt = Format-PriceLevel -Price $ref -RefLast $ref
        $stopFmt = Format-PriceLevel -Price ([double]$rec.stop) -RefLast $ref
        $tpFmt = Format-PriceLevel -Price (Get-RecordTp -Rec $rec) -RefLast $ref

        $st = Get-RecordStatus -Rec $rec
        $stopHit = ($st -eq 'hit_stop') -or $rec.hitStopAt
        $tpHit = ($st -eq 'hit_tp') -or $rec.hitTpAt -or $rec.hitTp1At -or $rec.hitTp2At

        $mStop = Get-HistoryMark -Hit $stopHit -MarkText $I18n.markStop
        $mTp = Get-HistoryMark -Hit $tpHit -MarkText $I18n.markTp

        $statusLbl = Get-HistoryStatusLabel -Rec $rec -I18n $I18n
        $st = Get-RecordStatus -Rec $rec
        $holdTag = if ($st -eq 'open') { " 【持仓跟踪】" } else { "" }

        $lines.Add($($I18n.historyRow -f ($rec.base + $holdTag), $sideTxt, $timeTxt, $entryFmt, $nowFmt))
        $lines.Add($($I18n.historyLevels -f $stopFmt, $mStop, $tpFmt, $mTp))
        $lines.Add($($I18n.historyStatus -f $statusLbl))
        $lines.Add("")
    }

    return ($lines -join "`n")
}

function Get-TickerLastMap {
    param($Tickers)
    $map = @{}
    foreach ($t in $Tickers) {
        $map[$t.instId] = [double]$t.last
    }
    return $map
}

function Invoke-HistoryCycle {
    param($NewItems, $Tickers, $I18n)
    $priceMap = Get-TickerLastMap -Tickers $Tickers
    Update-SignalHistoryTriggers -PriceMap $priceMap
    Add-SignalsFromScan -NewItems $NewItems
    Update-SignalHistoryTriggers -PriceMap $priceMap
    return Format-HistoryTelegramHtml -PriceMap $priceMap -I18n $I18n
}
