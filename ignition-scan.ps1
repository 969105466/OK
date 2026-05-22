# Find coins with MYX/RAVE-style daily ignition NOW (vol spike + big green daily)
param(
    [double]$MinDailyPct = 20.0,
    [double]$MinVolMult = 5.0,
    [int]$MinVol24Usd = 300000,
    [int]$MaxPos24 = 92.0,
    [int]$TopN = 25
)

$Base = 'https://www.binance.com/bapi/defi/v1/public'
$Fapi = 'https://fapi.binance.com'

function Get-AlphaDaily { param($Sym, $Lim = 25)
    try {
        $r = Invoke-RestMethod "$Base/alpha-trade/klines?symbol=$Sym&interval=1d&limit=$Lim" -TimeoutSec 12
        if ($r.success -and $r.data.Count -ge 5) { return @($r.data) }
    } catch {}
    return @()
}

function Get-FutDaily { param($Sym, $Lim = 25)
    try {
        return @(Invoke-RestMethod "$Fapi/fapi/v1/klines?symbol=$Sym&interval=1d&limit=$Lim" -TimeoutSec 12)
    } catch {}
    return @()
}

function Test-Ignition {
    param($Bars, [string]$Market)

    if ($Bars.Count -lt 8) { return $null }

    $rows = @()
    foreach ($b in $Bars) {
        $rows += [pscustomobject]@{
            O = [double]$b[1]; H = [double]$b[2]; L = [double]$b[3]; C = [double]$b[4]
            Qv = [double]$b[7]
            T = [int64]$b[0]
        }
    }
    $last = $rows[-1]
    $prev = $rows[-2]
    $d1 = ($last.C - $prev.C) / $prev.C * 100

    $d2 = 0.0; $d3 = 0.0
    if ($rows.Count -ge 3) { $d2 = ($rows[-1].C - $rows[-3].C) / $rows[-3].C * 100 }
    if ($rows.Count -ge 4) { $d3 = ($rows[-1].C - $rows[-4].C) / $rows[-4].C * 100 }

    $avgVol = ($rows[-21..-2] | Measure-Object Qv -Average).Average
    if ($avgVol -le 0) { $avgVol = 1 }
    $volMult = $last.Qv / $avgVol

    $hi10 = ($rows[-10..-1] | Measure-Object H -Maximum).Maximum
    $lo10 = ($rows[-10..-1] | Measure-Object L -Minimum).Minimum
    $pos10 = if ($hi10 -gt $lo10) { ($last.C - $lo10) / ($hi10 - $lo10) * 100 } else { 50 }

    $hi24 = ($rows[-2..-1] | Measure-Object H -Maximum).Maximum
    $lo24 = ($rows[-2..-1] | Measure-Object L -Minimum).Minimum
    $pos24 = if ($hi24 -gt $lo24) { ($last.C - $lo24) / ($hi24 - $lo24) * 100 } else { 50 }

    # consecutive +15% days
    $run = 0; $maxRun = 0
    for ($i = $rows.Count - 1; $i -ge 1; $i--) {
        $p = ($rows[$i].C - $rows[$i-1].C) / $rows[$i-1].C * 100
        if ($p -ge 15) { $run++; if ($run -gt $maxRun) { $maxRun = $run } } else { break }
    }

    $phase = 'NONE'
    $score = 0
    $tags = @()

    # IGNITION: today/yesterday huge day + vol explosion (RAVE Apr9 / MYX Aug4)
    if ($d1 -ge $MinDailyPct -and $volMult -ge $MinVolMult) {
        $phase = 'IGNITION'
        $score += 15
        $tags += 'today-rocket', 'vol-explode'
    }
    elseif ($d1 -ge 15 -and $volMult -ge ($MinVolMult / 2)) {
        $phase = 'IGNITION-WEAK'
        $score += 10
        $tags += 'strong-day', 'vol-up'
    }

    # MID-PUMP: 3d compound +50% with running days
    if ($d3 -ge 50 -and $maxRun -ge 2) {
        if ($phase -eq 'NONE') { $phase = 'MID-PUMP' }
        $score += 12
        $tags += '3d-momo', "run${maxRun}d"
    }
    elseif ($d3 -ge 30 -and $d1 -ge 10) {
        if ($phase -eq 'NONE') { $phase = 'EARLY-RUN' }
        $score += 8
        $tags += '3d-up'
    }

    if ($volMult -ge 5) { $score += 3; $tags += "vol${([math]::Round($volMult,0))}x" }
    if ($pos24 -le 70 -and $d1 -gt 0) { $score += 2; $tags += 'room-24h' }
    if ($pos24 -gt $MaxPos24) { $score -= 5; $tags += 'near-top' }
    if ($d1 -lt -10) { $score -= 8; $phase = 'DUMP' }

    if ($phase -eq 'NONE' -or $score -lt 7) { return $null }

    return [pscustomobject]@{
        Market = $Market
        Phase = $phase
        Score = $score
        D1 = [math]::Round($d1, 1)
        D3 = [math]::Round($d3, 1)
        VolMult = [math]::Round($volMult, 1)
        Pos10 = [math]::Round($pos10, 1)
        Pos24 = [math]::Round($pos24, 1)
        RunDays = $maxRun
        Last = $last.C
        VolDay = [math]::Round($last.Qv, 0)
        Tags = ($tags -join ',')
    }
}

Write-Host '=== MYX/RAVE Ignition Scan (now) ===' -ForegroundColor Yellow

$list = Invoke-RestMethod "$Base/wallet-direct/buw/wallet/cex/alpha/all/token/list" -TimeoutSec 40
$ex = Invoke-RestMethod "$Base/alpha-trade/get-exchange-info" -TimeoutSec 40
$tradeMap = @{}
foreach ($s in $ex.data.symbols) {
    if ($s.status -eq 'TRADING' -and $s.quoteAsset -eq 'USDT') { $tradeMap[$s.baseAsset] = $s.symbol }
}

$pool = @()
foreach ($t in $list.data) {
    if ($t.offline -or $t.fullyDelisted) { continue }
    if (-not $tradeMap.ContainsKey($t.alphaId)) { continue }
    if ([double]$t.volume24h -lt $MinVol24Usd) { continue }
    $pool += [pscustomobject]@{
        Symbol = $t.symbol; AlphaId = $t.alphaId; TradeSymbol = $tradeMap[$t.alphaId]
        Vol24 = [double]$t.volume24h; Chg24 = [double]$t.percentChange24h
    }
}

Write-Host "Scanning $($pool.Count) Alpha tradeable tokens (daily klines)..." -ForegroundColor DarkGray
$hits = @()
$i = 0
foreach ($p in $pool) {
    $i++
    if ($i % 50 -eq 0) { Write-Host "  $i/$($pool.Count)" -ForegroundColor DarkGray }
    Start-Sleep -Milliseconds 35
    $d = Get-AlphaDaily $p.TradeSymbol 25
    $r = Test-Ignition $d "Alpha"
    if ($r) {
        $hits += [pscustomobject]@{
            Symbol = $p.Symbol; AlphaId = $p.AlphaId; TradeSymbol = $p.TradeSymbol
            Chg24snap = [math]::Round($p.Chg24, 1); Vol24snap = [math]::Round($p.Vol24, 0)
            Market = $r.Market; Phase = $r.Phase; Score = $r.Score
            D1 = $r.D1; D3 = $r.D3; VolMult = $r.VolMult; Pos10 = $r.Pos10; Pos24 = $r.Pos24
            RunDays = $r.RunDays; Last = $r.Last; VolDay = $r.VolDay; Tags = $r.Tags
        }
    }
}

# Also scan futures tickers with high 24h change + vol (catch MYX-style on perp)
Write-Host "Scanning futures high-movers..." -ForegroundColor DarkGray
$tickers = Invoke-RestMethod "$Fapi/fapi/v1/ticker/24hr" -TimeoutSec 35
$futCandidates = @($tickers | Where-Object {
    $_.symbol -match 'USDT$' -and $_.symbol -notmatch '_' -and
    [double]$_.quoteVolume -ge 5e6 -and
    (([double]$_.lastPrice - [double]$_.openPrice) / [double]$_.openPrice * 100) -ge 8
} | Sort-Object { [double]$_.quoteVolume } -Descending | Select-Object -First 80)

foreach ($t in $futCandidates) {
    Start-Sleep -Milliseconds 40
    $d = Get-FutDaily $t.symbol 25
    $r = Test-Ignition $d "Futures"
    if ($r) {
        $base = $t.symbol -replace 'USDT$',''
        if ($hits.Symbol -contains $base) { continue }
        $hits += [pscustomobject]@{
            Symbol = $base; AlphaId = '-'; TradeSymbol = $t.symbol
            Chg24snap = [math]::Round(([double]$t.lastPrice - [double]$t.openPrice) / [double]$t.openPrice * 100, 1)
            Vol24snap = [math]::Round([double]$t.quoteVolume, 0)
            Market = $r.Market; Phase = $r.Phase; Score = $r.Score
            D1 = $r.D1; D3 = $r.D3; VolMult = $r.VolMult; Pos10 = $r.Pos10; Pos24 = $r.Pos24
            RunDays = $r.RunDays; Last = $r.Last; VolDay = $r.VolDay; Tags = $r.Tags
        }
    }
}

Write-Host "`n--- IGNITION (like RAVE 4/9, MYX 8/4) ---" -ForegroundColor Green
$ign = @($hits | Where-Object { $_.Phase -eq 'IGNITION' } | Sort-Object Score -Descending)
if ($ign.Count -eq 0) { Write-Host "  (none right now)" -ForegroundColor DarkGray }
else {
    $ign | Select-Object -First $TopN | ForEach-Object {
        Write-Host ("  [{0}] {1,-12} {2,12}  S={3}  today={4}%  3d={5}%  volX={6}  pos24={7}%  volDay={8:N0}  {9}" -f `
            $_.Market, $_.Symbol, $_.Last, $_.Score, $_.D1, $_.D3, $_.VolMult, $_.Pos24, $_.VolDay, $_.Tags)
        if ($_.TradeSymbol) { Write-Host "       trade: $($_.TradeSymbol)" -ForegroundColor DarkGray }
    }
}

Write-Host "`n--- IGNITION-WEAK / EARLY-RUN (watch next day) ---" -ForegroundColor Cyan
$hits | Where-Object { $_.Phase -in @('IGNITION-WEAK','EARLY-RUN') } | Sort-Object Score -Descending | Select-Object -First 15 | ForEach-Object {
    Write-Host ("  [{0}] {1,-12} {2}  today={3}% 3d={4}% volX={5} pos24={6}% [{7}]" -f `
        $_.Phase, $_.Symbol, $_.Last, $_.D1, $_.D3, $_.VolMult, $_.Pos24, $_.Tags)
}

Write-Host "`n--- MID-PUMP (already running, chase risk) ---" -ForegroundColor Yellow
$hits | Where-Object { $_.Phase -eq 'MID-PUMP' } | Sort-Object D3 -Descending | Select-Object -First 12 | ForEach-Object {
    Write-Host ("  {0,-12} 3d={1}%  today={2}%  volX={3}  run={4}d  pos24={5}%  [{6}]" -f `
        $_.Symbol, $_.D3, $_.D1, $_.VolMult, $_.RunDays, $_.Pos24, $_.Tags)
}

$out = Join-Path $PSScriptRoot 'ignition-scan-latest.json'
@{ scannedAt = (Get-Date).ToString('o'); hits = $hits } | ConvertTo-Json -Depth 5 | Set-Content $out -Encoding UTF8
Write-Host "`nTotal matches: $($hits.Count) | Saved: $out" -ForegroundColor DarkGray
Write-Host 'Not financial advice.' -ForegroundColor DarkGray
