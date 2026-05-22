# Alpha pump-start scanner (RAVE-style: vol burst + multi-TF momentum + room to run)
param(
    [int]$MinVol24 = 200000,
    [double]$MinChg24 = 2.0,
    [double]$MaxChg24 = 45.0,
    [double]$MinPx15m = 0.4,
    [double]$MinPx1h = 0.8,
    [int]$TopN = 25,
    [string[]]$RefSymbols = @('RAVE', 'ZEST', 'SPX')
)

$Base = 'https://www.binance.com/bapi/defi/v1/public'
$ErrorActionPreference = 'Continue'

function Get-K {
    param($Sym, $Iv, $Lim)
    try {
        $r = Invoke-RestMethod "$Base/alpha-trade/klines?symbol=$Sym&interval=$Iv&limit=$Lim" -TimeoutSec 12
        if ($r.success) { return @($r.data) }
    } catch {}
    return @()
}

function Get-PxChg { param($Closes, $Bars)
    if ($Closes.Count -lt ($Bars + 1)) { return 0 }
    $a = $Closes[-1]; $b = $Closes[-1 - $Bars]
    if ($b -le 0) { return 0 }
    return ($a - $b) / $b * 100
}

function Get-VolBurst { param($Klines)
    if ($Klines.Count -lt 8) { return 1.0 }
    $vols = @($Klines | ForEach-Object { [double]$_[5] })
    $avg = ($vols[-8..-3] | Measure-Object -Average).Average
    if ($avg -le 0) { return 1.0 }
    return $vols[-1] / $avg
}

Write-Host '=== Alpha Pump-Start Scan (RAVE-style) ===' -ForegroundColor Yellow

$list = Invoke-RestMethod "$Base/wallet-direct/buw/wallet/cex/alpha/all/token/list" -TimeoutSec 40
$ex = Invoke-RestMethod "$Base/alpha-trade/get-exchange-info" -TimeoutSec 40
$tradeMap = @{}
foreach ($s in $ex.data.symbols) {
    if ($s.status -eq 'TRADING' -and $s.quoteAsset -eq 'USDT') { $tradeMap[$s.baseAsset] = $s.symbol }
}

$meta = @{}
foreach ($t in $list.data) {
    if ($t.offline -or $t.fullyDelisted) { continue }
    if (-not $tradeMap.ContainsKey($t.alphaId)) { continue }
    $hi = [double]$t.priceHigh24h; $lo = [double]$t.priceLow24h; $p = [double]$t.price
    $pos24 = if ($hi -gt $lo) { ($p - $lo) / ($hi - $lo) * 100 } else { 50 }
    $meta[$t.alphaId] = @{
        AlphaId = $t.alphaId
        Symbol = $t.symbol; Name = $t.name; Price = $p
        Chg24 = [double]$t.percentChange24h; Vol24 = [double]$t.volume24h
        Pos24 = $pos24; Liq = [double]$t.liquidity
        TradeSymbol = $tradeMap[$t.alphaId]
    }
}

Write-Host "Tradeable pool: $($meta.Count) tokens" -ForegroundColor Cyan

# Reference: profile RAVE-like at scan time
Write-Host "`n--- Reference coins ---" -ForegroundColor DarkGray
foreach ($ref in $RefSymbols) {
    $id = @($meta.Values | Where-Object { $_.Symbol -eq $ref } | Select-Object -First 1)
    if (-not $id) { Write-Host "  $ref : not in alpha trade pool"; continue }
    $m = $id; $ts = $m.TradeSymbol
    Start-Sleep -Milliseconds 80
    $m15 = Get-K $ts '15m' 24; $h1 = Get-K $ts '1h' 24
    $m15c = @($m15 | ForEach-Object { [double]$_[4] })
    $h1c = @($h1 | ForEach-Object { [double]$_[4] })
    $px15 = Get-PxChg $m15c 1; $px1h = Get-PxChg $h1c 2; $px4h = Get-PxChg $h1c 4
    $vb = Get-VolBurst $m15
    Write-Host ("  {0,-10} 24h={1,6:N1}% pos24={2,4:N0}% 15m={3,5:N2}% 1h={4,5:N2}% volBurst={5:N2}x" -f `
        $ref, $m.Chg24, $m.Pos24, $px15, $px1h, $vb)
}

$hits = @()
$i = 0
$pool = @($meta.Values | Where-Object { $_.Vol24 -ge $MinVol24 })
Write-Host "`nScanning $($pool.Count) tokens..." -ForegroundColor DarkGray

foreach ($m in $pool) {
    $i++
    if ($i % 40 -eq 0) { Write-Host "  $i / $($pool.Count)" -ForegroundColor DarkGray }
    Start-Sleep -Milliseconds 38

    $m15 = Get-K $m.TradeSymbol '15m' 32
    $h1 = Get-K $m.TradeSymbol '1h' 24
    $h4 = Get-K $m.TradeSymbol '4h' 18
    if ($m15.Count -lt 10 -or $h1.Count -lt 6) { continue }

    $m15c = @($m15 | ForEach-Object { [double]$_[4] })
    $h1c = @($h1 | ForEach-Object { [double]$_[4] })
    $h4c = @($h4 | ForEach-Object { [double]$_[4] })
    $h1h = @($h1 | ForEach-Object { [double]$_[2] })
    $h1l = @($h1 | ForEach-Object { [double]$_[3] })

    $px15 = Get-PxChg $m15c 1
    $px1h = Get-PxChg $h1c 2
    $px4h = if ($h4c.Count -ge 2) { Get-PxChg $h4c 1 } else { Get-PxChg $h1c 4 }
    $px3h = Get-PxChg $m15c 12
    $volBurst = Get-VolBurst $m15
    $hi4h = ($h1h[-4..-1] | Measure-Object -Maximum).Maximum
    $roomTo4hHigh = if ($hi4h -gt 0) { ($hi4h - $m.Price) / $hi4h * 100 } else { 0 }
    $distHigh24 = if ($m.Pos24 -lt 100) { (100 - $m.Pos24) } else { 0 }

    $score = 0
    $tags = @()

    # RAVE-style: early pump, not finished
    if ($m.Chg24 -ge $MinChg24 -and $m.Chg24 -le $MaxChg24) { $score += 3; $tags += 'chg-ok' }
    if ($m.Pos24 -ge 25 -and $m.Pos24 -le 85) { $score += 2; $tags += 'breakout-zone' }
    elseif ($m.Pos24 -le 35 -and $px1h -ge 1) { $score += 3; $tags += 'from-low' }

    if ($px15 -ge $MinPx15m) { $score += 2; $tags += 'm15-up' }
    if ($px1h -ge $MinPx1h) { $score += 3; $tags += 'h1-up' }
    if ($px4h -ge 0.5) { $score += 2; $tags += 'h4-up' }
    if ($px3h -ge 1.5 -and $px3h -le 25) { $score += 2; $tags += '3h-momo' }

    if ($volBurst -ge 1.5) { $score += 3; $tags += 'vol-burst' }
    elseif ($volBurst -ge 1.2) { $score += 1 }

    if ($roomTo4hHigh -ge 2) { $score += 2; $tags += 'room-run' }
    if ($distHigh24 -ge 8) { $score += 1 }

    # accelerating: 15m > 0 and 1h > 15m contribution
    if ($px15 -gt 0 -and $px1h -gt $px15) { $score += 2; $tags += 'accel' }

    # exclude: already at top + slowing
    if ($m.Pos24 -gt 92 -and $px15 -lt 0) { $score -= 5; $tags += 'exhaust' }
    if ($m.Chg24 -gt 50) { $score -= 4 }

    if ($score -lt 10) { continue }

    $phase = if ($m.Chg24 -lt 12 -and $m.Pos24 -lt 50) { 'EARLY' }
             elseif ($m.Chg24 -lt 28) { 'MID' }
             else { 'LATE' }

    $hits += [pscustomobject]@{
        Symbol = $m.Symbol; AlphaId = $m.AlphaId
        Price = $m.Price; Chg24 = [math]::Round($m.Chg24, 2)
        Pos24 = [math]::Round($m.Pos24, 1); Vol24 = [math]::Round($m.Vol24, 0)
        Px15 = [math]::Round($px15, 2); Px1h = [math]::Round($px1h, 2)
        Px4h = [math]::Round($px4h, 2); Px3h = [math]::Round($px3h, 2)
        VolBurst = [math]::Round($volBurst, 2); Room4h = [math]::Round($roomTo4hHigh, 1)
        Score = $score; Phase = $phase; Tags = ($tags -join ',')
        TradeSymbol = $m.TradeSymbol
    }
}

Write-Host "`n--- PUMP-START (RAVE-style, score>=10) ---" -ForegroundColor Green
if ($hits.Count -eq 0) {
    Write-Host 'No matches. Loosen thresholds or retry later.' -ForegroundColor Yellow
} else {
    $hits | Sort-Object Score -Descending | Select-Object -First $TopN | ForEach-Object {
        Write-Host ("  [{0}] {1,-12} {2,10}  S={3,2}  24h={4,6}% pos24={5,4}%  15m={6,5}% 1h={7,5}% 4h={8,5}%  volX={9}  room={10,4}%  vol24={11,10:N0}" -f `
            $_.Phase, $_.Symbol, $_.Price, $_.Score, $_.Chg24, $_.Pos24, $_.Px15, $_.Px1h, $_.Px4h, $_.VolBurst, $_.Room4h, $_.Vol24)
        Write-Host ("         {0}  trade={1}" -f $_.Tags, $_.TradeSymbol) -ForegroundColor DarkGray
    }
}

Write-Host "`n--- EARLY phase only (like RAVE before rip) ---" -ForegroundColor Cyan
$hits | Where-Object { $_.Phase -eq 'EARLY' } | Sort-Object Score -Descending | Select-Object -First 12 | ForEach-Object {
    Write-Host ("  {0,-12} S={1} 24h={2}% pos={3}% 1h={4}% volBurst={5}x" -f $_.Symbol, $_.Score, $_.Chg24, $_.Pos24, $_.Px1h, $_.VolBurst)
}

$out = Join-Path $PSScriptRoot 'alpha-pump-latest.json'
@{ scannedAt = (Get-Date).ToString('o'); hits = $hits } | ConvertTo-Json -Depth 5 | Set-Content $out -Encoding UTF8
Write-Host "`nSaved: $out" -ForegroundColor DarkGray
Write-Host 'Not financial advice.' -ForegroundColor DarkGray
