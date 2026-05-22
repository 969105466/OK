# Binance USDT-M: top market-cap coins — bottom zone + startup signals
param(
    [int]$TopMcap = 300,
    [int]$DeepScan = 55,
    [double]$MinVolUsd24h = 5000000,
    [int]$ShowTop = 20,
    [switch]$Deep,
    [string]$OutFile = '',
    [string]$BaseUrl = 'https://fapi.binance.com'
)

$ErrorActionPreference = 'Continue'

if ($Deep) {
    $DeepScan = 99999
    $MinVolUsd24h = 3000000
    $ShowTop = 35
    if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'bottom-scan-latest.json' }
}

$stable = @('USDT','USDC','DAI','USDE','FDUSD','TUSD','USDD','EUR','PYUSD','USD1')

function Get-Rsi {
    param([double[]]$Closes, [int]$Period = 14)
    if ($Closes.Count -lt $Period + 2) { return $null }
    $arr = if ($Closes.Count -gt ($Period + 50)) { $Closes[-($Period + 50)..-1] } else { $Closes }
    $gains = 0.0; $losses = 0.0
    for ($i = $arr.Count - $Period; $i -lt $arr.Count; $i++) {
        $d = $arr[$i] - $arr[$i - 1]
        if ($d -ge 0) { $gains += $d } else { $losses += -$d }
    }
    $avgG = $gains / $Period; $avgL = $losses / $Period
    if ($avgL -eq 0) { return 100.0 }
    return [math]::Round(100 - (100 / (1 + ($avgG / $avgL))), 2)
}

function Get-Ema {
    param([double[]]$Data, [int]$Period)
    if ($Data.Count -lt $Period) { return $null }
    $k = 2.0 / ($Period + 1)
    $ema = ($Data[0..($Period - 1)] | Measure-Object -Average).Average
    for ($i = $Period; $i -lt $Data.Count; $i++) {
        $ema = $Data[$i] * $k + $ema * (1 - $k)
    }
    return $ema
}

function Get-MacdSignal {
    param([double[]]$Closes)
    if ($Closes.Count -lt 40) { return @{ Hist = $null; TurnUp = $false } }
    $ema12 = Get-Ema $Closes 12
    $ema26 = Get-Ema $Closes 26
    $prev12 = Get-Ema ($Closes[0..($Closes.Count - 2)]) 12
    $prev26 = Get-Ema ($Closes[0..($Closes.Count - 2)]) 26
    if ($null -eq $ema12 -or $null -eq $ema26) { return @{ Hist = $null; TurnUp = $false } }
    $macd = $ema12 - $ema26
    $prevMacd = if ($prev12 -and $prev26) { $prev12 - $prev26 } else { $macd }
    $hist = $macd - $prevMacd
    return @{ Hist = [math]::Round($hist, 8); TurnUp = ($hist -gt 0) }
}

function Get-BnKlines {
    param([string]$Symbol, [string]$Interval, [int]$Limit)
    try {
        $u = "$BaseUrl/fapi/v1/klines?symbol=$Symbol&interval=$Interval&limit=$Limit"
        return @(Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 14)
    } catch { return @() }
}

function Get-OiDelta4h {
    param([string]$Symbol)
    try {
        $u = "$BaseUrl/futures/data/openInterestHist?symbol=$Symbol&period=4h&limit=8"
        $r = @(Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 12)
        if ($r.Count -lt 3) { return $null }
        $o0 = [double]$r[-1].sumOpenInterest
        $o3 = [double]$r[-4].sumOpenInterest
        if ($o3 -le 0) { return $null }
        return [math]::Round(($o0 - $o3) / $o3 * 100, 2)
    } catch { return $null }
}

function Get-TopMcapCoins {
    param([int]$N)
    $all = @()
    $per = 250
    for ($p = 1; $p -le [math]::Ceiling($N / $per); $p++) {
        $uri = "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=$per&page=$p&sparkline=false"
        $all += Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 25
        if ($all.Count -ge $N) { break }
        Start-Sleep -Milliseconds 1100
    }
    return $all | Select-Object -First $N
}

function Test-BottomStartup {
    param($D, $H4, $H1, $M15, $Last, $Chg24, $FundPct, $Oi4h, [bool]$Full = $false)

    if ($D.Count -lt 25 -or $H4.Count -lt 15 -or $M15.Count -lt 12) { return $null }

    $dCl = @($D | ForEach-Object { [double]$_[4] })
    $dHi = @($D | ForEach-Object { [double]$_[2] })
    $dLo = @($D | ForEach-Object { [double]$_[3] })
    $dVol = @($D | ForEach-Object { [double]$_[5] })

    $ma7 = ($dCl[-7..-1] | Measure-Object -Average).Average
    $ma20 = ($dCl[-20..-1] | Measure-Object -Average).Average
    $ma60 = if ($dCl.Count -ge 60) { ($dCl[-60..-1] | Measure-Object -Average).Average } else { $ma20 }
    $low20 = ($dLo[-20..-1] | Measure-Object -Minimum).Minimum
    $high20 = ($dHi[-20..-1] | Measure-Object -Maximum).Maximum
    $low60 = if ($dLo.Count -ge 60) { ($dLo[-60..-1] | Measure-Object -Minimum).Minimum } else { $low20 }
    $range20 = $high20 - $low20
    if ($range20 -le 0) { return $null }

    $posInRange = ($Last - $low20) / $range20 * 100
    $distLow20 = ($Last - $low20) / $low20 * 100
    $distLow60 = if ($low60 -gt 0) { ($Last - $low60) / $low60 * 100 } else { $distLow20 }
    $distHigh20 = ($high20 - $Last) / $high20 * 100
    if ($distLow20 -gt 80) { return $null }

    $rsi = Get-Rsi $dCl 14
    $rsiPrev = Get-Rsi $dCl[0..($dCl.Count - 2)] 14
    $macd = Get-MacdSignal $dCl

    $avgVol20 = ($dVol[-20..-1] | Measure-Object -Average).Average
    $volRatio = if ($avgVol20 -gt 0) { $dVol[-1] / $avgVol20 } else { 1 }

    $h4Cl = @($H4 | ForEach-Object { [double]$_[4] })
    $h4Lo = @($H4 | ForEach-Object { [double]$_[3] })
    $px4h = ($h4Cl[-1] - $h4Cl[-2]) / $h4Cl[-2] * 100
    $higherLow4h = ($h4Lo[-1] -gt $h4Lo[-3]) -and ($h4Cl[-1] -gt $h4Cl[-3])

    $h1Cl = if ($H1.Count -ge 6) { @($H1 | ForEach-Object { [double]$_[4] }) } else { @() }
    $px1h = if ($h1Cl.Count -ge 3) { ($h1Cl[-1] - $h1Cl[-3]) / $h1Cl[-3] * 100 } else { 0 }

    $m15Cl = @($M15 | ForEach-Object { [double]$_[4] })
    $px15 = ($m15Cl[-1] - $m15Cl[-2]) / $m15Cl[-2] * 100
    $px3h = if ($m15Cl.Count -ge 13) { ($m15Cl[-1] - $m15Cl[-13]) / $m15Cl[-13] * 100 } else { 0 }

    $bbMid = $ma20
    $bbStd = [math]::Sqrt(($dCl[-20..-1] | ForEach-Object { [math]::Pow($_ - $bbMid, 2) } | Measure-Object -Sum).Sum / 20)
    $bbLower = $bbMid - 2 * $bbStd
    $nearLowerBb = $bbLower -gt 0 -and $Last -ge $bbLower * 0.992 -and $Last -le $bbMid

    $ma7Slope = if ($dCl.Count -ge 10) {
        $ma7a = ($dCl[-10..-4] | Measure-Object -Average).Average
        ($ma7 - $ma7a) / $ma7a * 100
    } else { 0 }

    $score = 0
    $tags = @()

    if ($posInRange -le 30) { $score += 5; $tags += 'low-zone' }
    elseif ($posInRange -le 45) { $score += 3 }
    elseif ($posInRange -le 55) { $score += 1 }

    if ($distLow20 -le 8) { $score += 4; $tags += 'near-low20' }
    elseif ($distLow20 -le 15) { $score += 2; $tags += 'near-low20' }
    if ($Full -and $distLow60 -le 20) { $score += 2; $tags += 'near-low60' }
    if ($distHigh20 -ge 20) { $score += 1 }

    if ($rsi -ge 30 -and $rsi -le 55) { $score += 2; $tags += 'rsi-recover' }
    if ($rsiPrev -ne $null -and $rsi -gt $rsiPrev + 1.5 -and $rsi -lt 58) { $score += 3; $tags += 'rsi-up' }
    if ($rsi -lt 25) { $score -= 2 }

    if ($macd.TurnUp) { $score += 3; $tags += 'macd-turn' }
    if ($Last -gt $ma7 -and $ma7 -gt $ma20 * 0.997) { $score += 4; $tags += 'ma-bull' }
    elseif ($Last -gt $ma7) { $score += 2; $tags += 'above-ma7' }
    if ($ma7Slope -gt 0.3) { $score += 2; $tags += 'ma7-up' }

    if ($px15 -ge 0.35) { $score += 3; $tags += 'm15-momo' }
    elseif ($px15 -ge 0.15) { $score += 1 }
    if ($px4h -ge 0.2) { $score += 2 }
    if ($px1h -ge 0.25) { $score += 2; $tags += 'h1-momo' }
    if ($px3h -ge 0.5 -and $px3h -le 12) { $score += 1 }

    if ($volRatio -ge 1.25) { $score += 3; $tags += 'vol-spike' }
    elseif ($volRatio -ge 1.1) { $score += 1 }
    if ($nearLowerBb) { $score += 2; $tags += 'bb-bounce' }
    if ($higherLow4h) { $score += 2; $tags += 'h4-higher-low' }

    if ($FundPct -lt -0.008) { $score += 2; $tags += 'neg-fund' }
    elseif ($FundPct -lt -0.003) { $score += 1 }
    if ($Oi4h -ne $null -and $Oi4h -ge 2) { $score += 2; $tags += 'oi-up' }
    if ($Chg24 -ge -15 -and $Chg24 -le 8) { $score += 1 }
    if ($Chg24 -gt 20) { $score -= 4 }
    if ($Chg24 -lt -30) { $score -= 3 }

    $startupPts = 0
    if ($px15 -ge 0.2 -or $px1h -ge 0.2) { $startupPts += 2 }
    if ($rsi -gt $rsiPrev) { $startupPts += 1 }
    if ($macd.TurnUp) { $startupPts += 1 }
    if ($volRatio -ge 1.1) { $startupPts += 1 }
    if ($higherLow4h) { $startupPts += 1 }

    $grade = 'C'
    if ($score -ge 14 -and $startupPts -ge 4 -and $posInRange -le 40) { $grade = 'A' }
    elseif ($score -ge 11 -and $startupPts -ge 3) { $grade = 'B' }
    elseif ($score -ge 8) { $grade = 'C' }

    $minScore = if ($Full) { 7 } else { 8 }
    if ($score -lt $minScore) { return $null }

    return [pscustomobject]@{
        Score = $score
        Grade = $grade
        StartupPts = $startupPts
        PosRange = [math]::Round($posInRange, 1)
        DistLow20 = [math]::Round($distLow20, 1)
        DistLow60 = [math]::Round($distLow60, 1)
        DistHigh20 = [math]::Round($distHigh20, 1)
        Rsi = $rsi
        RsiPrev = $rsiPrev
        MacdTurn = $macd.TurnUp
        Px15 = [math]::Round($px15, 2)
        Px4h = [math]::Round($px4h, 2)
        Px1h = [math]::Round($px1h, 2)
        Px3h = [math]::Round($px3h, 2)
        VolRatio = [math]::Round($volRatio, 2)
        Oi4h = $Oi4h
        Ma7Slope = [math]::Round($ma7Slope, 2)
        Tags = ($tags -join ',')
    }
}

$modeLabel = if ($Deep) { 'DEEP (full universe)' } else { "quick ($DeepScan)" }
Write-Host "=== BN Bottom + Startup Scan [$modeLabel] Top $TopMcap mcap ===" -ForegroundColor Yellow

try {
    $mcapCoins = Get-TopMcapCoins -N $TopMcap
} catch {
    Write-Host "CoinGecko failed: $_" -ForegroundColor Red
    exit 1
}

$symSet = @{}
foreach ($c in $mcapCoins) {
    $sym = $c.symbol.ToUpper()
    if ($stable -contains $sym) { continue }
    if (-not $symSet.ContainsKey($sym)) {
        $symSet[$sym] = @{ Name = $c.name; Rank = $c.market_cap_rank; McapB = [math]::Round($c.market_cap / 1e9, 2) }
    }
}

$exchange = Invoke-RestMethod "$BaseUrl/fapi/v1/exchangeInfo" -TimeoutSec 25
$bnBases = @{}
foreach ($s in $exchange.symbols) {
    if ($s.status -eq 'TRADING' -and $s.contractType -eq 'PERPETUAL' -and $s.quoteAsset -eq 'USDT') {
        $bnBases[$s.baseAsset] = $s.symbol
    }
}

$tickers = Invoke-RestMethod "$BaseUrl/fapi/v1/ticker/24hr" -TimeoutSec 35
$tickerMap = @{}
foreach ($t in $tickers) { $tickerMap[$t.symbol] = $t }

$universe = @()
foreach ($kv in $symSet.GetEnumerator()) {
    if (-not $bnBases.ContainsKey($kv.Key)) { continue }
    $symbol = $bnBases[$kv.Key]
    if (-not $tickerMap.ContainsKey($symbol)) { continue }
    $t = $tickerMap[$symbol]
    $last = [double]$t.lastPrice
    $open = [double]$t.openPrice
    $vol = [double]$t.quoteVolume
    if ($vol -lt $MinVolUsd24h) { continue }
    $hi = [double]$t.highPrice; $lo = [double]$t.lowPrice
    $chg = if ($open -gt 0) { ($last - $open) / $open * 100 } else { 0 }
    $pos24 = if ($hi -gt $lo) { ($last - $lo) / ($hi - $lo) * 100 } else { 50 }
    $meta = $kv.Value
    $universe += [pscustomobject]@{
        Base = $kv.Key; Symbol = $symbol; Name = $meta.Name; Rank = $meta.Rank
        McapB = $meta.McapB; Last = $last; Chg24 = [math]::Round($chg, 2)
        VolM = [math]::Round($vol / 1e6, 1); Pos24 = [math]::Round($pos24, 1)
        QuickScore = (100 - $pos24) * 0.55 + [math]::Max(0, 12 - [math]::Abs($chg)) * 0.25 + [math]::Log10($vol) * 0.2
    }
}

Write-Host ("Universe: {0} symbols (Binance perp, vol>={1}M)" -f $universe.Count, [math]::Round($MinVolUsd24h / 1e6, 1)) -ForegroundColor Cyan

$btc = $tickerMap['BTCUSDT']; $eth = $tickerMap['ETHUSDT']
Write-Host ("BTC {0} 24h {1:N2}% | ETH {2} 24h {3:N2}%" -f $btc.lastPrice,
    (([double]$btc.lastPrice - [double]$btc.openPrice) / [double]$btc.openPrice * 100),
    $eth.lastPrice, (([double]$eth.lastPrice - [double]$eth.openPrice) / [double]$eth.openPrice * 100))

$scanCount = if ($DeepScan -ge 99999) { $universe.Count } else { [math]::Min($DeepScan, $universe.Count) }
$deepList = @($universe | Sort-Object QuickScore -Descending | Select-Object -First $scanCount)
$delayMs = if ($Deep) { 55 } else { 95 }
Write-Host "Deep scanning $($deepList.Count) symbols..." -ForegroundColor DarkGray

$results = @()
$allMetrics = @()
$i = 0
foreach ($p in $deepList) {
    $i++
    if ($i % 15 -eq 0) { Write-Host "  progress $i / $($deepList.Count)" -ForegroundColor DarkGray }
    Start-Sleep -Milliseconds $delayMs

    $fundPct = 0.0
    try {
        $f = Invoke-RestMethod "$BaseUrl/fapi/v1/premiumIndex?symbol=$($p.Symbol)" -TimeoutSec 8
        $fundPct = [math]::Round([double]$f.lastFundingRate * 100, 4)
    } catch {}

    $oi4h = if ($Deep) { Get-OiDelta4h $p.Symbol } else { $null }
    $dLim = if ($Deep) { 65 } else { 30 }
    $d = Get-BnKlines $p.Symbol '1d' $dLim
    $h4 = Get-BnKlines $p.Symbol '4h' 36
    $h1 = if ($Deep) { Get-BnKlines $p.Symbol '1h' 24 } else { @() }
    $m15 = Get-BnKlines $p.Symbol '15m' 32

    $ana = Test-BottomStartup -D $d -H4 $h4 -H1 $h1 -M15 $m15 -Last $p.Last -Chg24 $p.Chg24 -FundPct $fundPct -Oi4h $oi4h -Full:$Deep
    if ($d.Count -ge 20) {
        $dLo = @($d | ForEach-Object { [double]$_[3] })
        $low20 = ($dLo[-20..-1] | Measure-Object -Minimum).Minimum
        $high20 = (@($d | ForEach-Object { [double]$_[2] }) | Select-Object -Last 20 | Measure-Object -Maximum).Maximum
        $distLow = ($p.Last - $low20) / $low20 * 100
        $pos20 = if ($high20 -gt $low20) { ($p.Last - $low20) / ($high20 - $low20) * 100 } else { 50 }
        $allMetrics += [pscustomobject]@{
            Rank = $p.Rank; Base = $p.Base; Last = $p.Last; Chg24 = $p.Chg24; VolM = $p.VolM
            DistLow20 = [math]::Round($distLow, 1); Pos20d = [math]::Round($pos20, 1)
        }
    }
    if ($ana) {
        $results += [pscustomobject]@{
            Rank = $p.Rank; Base = $p.Base; Name = $p.Name; McapB = $p.McapB
            Last = $p.Last; Chg24 = $p.Chg24; VolM = $p.VolM
            Score = $ana.Score; Grade = $ana.Grade; StartupPts = $ana.StartupPts
            PosRange = $ana.PosRange; DistLow20 = $ana.DistLow20; DistLow60 = $ana.DistLow60
            DistHigh20 = $ana.DistHigh20; Rsi = $ana.Rsi; Px15 = $ana.Px15; Px4h = $ana.Px4h
            Px1h = $ana.Px1h; VolRatio = $ana.VolRatio; Oi4h = $ana.Oi4h; Fund = $fundPct; Tags = $ana.Tags
        }
    }
}

Write-Host "`n--- GRADE A (bottom + strong startup) ---" -ForegroundColor Green
$gradeA = @($results | Where-Object { $_.Grade -eq 'A' } | Sort-Object Score -Descending)
if ($gradeA.Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor DarkGray
} else {
    $gradeA | ForEach-Object {
        Write-Host ("  #{0,3} {1,-9} {2,12}  S={3,2} st={4}  24h={5,6}% pos={6,4}% dLow={7,5}% RSI={8,5} 15m={9,5}% 1h={10,5}% volX={11} OI4h={12}% [{13}]" -f `
            $_.Rank, $_.Base, $_.Last, $_.Score, $_.StartupPts, $_.Chg24, $_.PosRange, $_.DistLow20, $_.Rsi, $_.Px15, $_.Px1h, $_.VolRatio, $_.Oi4h, $_.Tags)
    }
}

Write-Host "`n--- GRADE B (bottom + startup) top $ShowTop ---" -ForegroundColor Yellow
$results | Where-Object { $_.Grade -eq 'B' } | Sort-Object Score -Descending | Select-Object -First $ShowTop | ForEach-Object {
    Write-Host ("  #{0,3} {1,-9} {2,12}  S={3,2} st={4}  24h={5,6}% pos={6,4}% dLow={7,5}% d60={8,5}% RSI={9,5} 15m={10,5}% 1h={11,5}% volX={12} [{13}]" -f `
        $_.Rank, $_.Base, $_.Last, $_.Score, $_.StartupPts, $_.Chg24, $_.PosRange, $_.DistLow20, $_.DistLow60, $_.Rsi, $_.Px15, $_.Px1h, $_.VolRatio, $_.Tags)
}

Write-Host "`n--- GRADE C (watch) top 15 ---" -ForegroundColor DarkCyan
$results | Where-Object { $_.Grade -eq 'C' } | Sort-Object Score -Descending | Select-Object -First 15 | ForEach-Object {
    Write-Host ("  #{0,3} {1,-9} S={2,2}  24h={3,6}% pos={4,4}% dLow={5,5}% RSI={6,5} 15m={7,5}% [{8}]" -f `
        $_.Rank, $_.Base, $_.Score, $_.Chg24, $_.PosRange, $_.DistLow20, $_.Rsi, $_.Px15, $_.Tags)
}

Write-Host "`n--- NEAR 20D LOW (all scanned, top 18) ---" -ForegroundColor Cyan
$allMetrics | Where-Object { $_.DistLow20 -le 12 -and $_.Pos20d -le 35 } | Sort-Object DistLow20 | Select-Object -First 18 | ForEach-Object {
    Write-Host ("  #{0,3} {1,-9} {2,12}  24h={3,6}% dLow20={4,5}% pos20d={5,4}% vol={6}M" -f `
        $_.Rank, $_.Base, $_.Last, $_.Chg24, $_.DistLow20, $_.Pos20d, $_.VolM)
}

if ($OutFile) {
    $export = @{
        scannedAt = (Get-Date).ToString('o')
        mode = if ($Deep) { 'deep' } else { 'quick' }
        universe = $universe.Count
        matches = $results.Count
        gradeA = $gradeA
        gradeB = @($results | Where-Object { $_.Grade -eq 'B' })
        gradeC = @($results | Where-Object { $_.Grade -eq 'C' })
        nearLow = @($allMetrics | Where-Object { $_.DistLow20 -le 12 } | Sort-Object DistLow20)
    }
    $export | ConvertTo-Json -Depth 5 | Set-Content $OutFile -Encoding UTF8
    Write-Host "`nSaved: $OutFile" -ForegroundColor DarkGray
}

Write-Host "`nScanned $($deepList.Count) | Matches $($results.Count) | Not financial advice." -ForegroundColor DarkGray
