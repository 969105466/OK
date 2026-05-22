# 1-2 week swing picks: bottom structure + room to run + liquidity (Binance USDT-M)
param([int]$TopMcap = 300, [int]$DeepScan = 70, [int]$ShowTop = 15)

$BaseUrl = 'https://fapi.binance.com'
$ErrorActionPreference = 'Continue'

function Get-Rsi { param([double[]]$Closes, [int]$P = 14)
    if ($Closes.Count -lt $P + 2) { return 50 }
    $arr = $Closes[-($P + 30)..-1]
    $g = 0.0; $l = 0.0
    for ($i = $arr.Count - $P; $i -lt $arr.Count; $i++) {
        $d = $arr[$i] - $arr[$i - 1]
        if ($d -ge 0) { $g += $d } else { $l += -$d }
    }
    if ($l -eq 0) { return 100 }
    return [math]::Round(100 - (100 / (1 + ($g / $P) / ($l / $P))), 1)
}

function Get-K { param($S, $I, $L)
    try { return @(Invoke-RestMethod "$BaseUrl/fapi/v1/klines?symbol=$S&interval=$I&limit=$L" -TimeoutSec 12) } catch { return @() }
}

function Score-Swing {
    param($D, $H4, $Last, $Chg24, $VolM, $Fund)

    if ($D.Count -lt 25 -or $H4.Count -lt 15) { return $null }

    $dCl = @($D | ForEach-Object { [double]$_[4] })
    $dHi = @($D | ForEach-Object { [double]$_[2] })
    $dLo = @($D | ForEach-Object { [double]$_[3] })

    $ma7 = ($dCl[-7..-1] | Measure-Object -Average).Average
    $ma20 = ($dCl[-20..-1] | Measure-Object -Average).Average
    $low20 = ($dLo[-20..-1] | Measure-Object -Minimum).Minimum
    $high20 = ($dHi[-20..-1] | Measure-Object -Maximum).Maximum
    $low60 = if ($dLo.Count -ge 60) { ($dLo[-60..-1] | Measure-Object -Minimum).Minimum } else { $low20 }

    $pos20 = ($Last - $low20) / ($high20 - $low20) * 100
    $distLow20 = ($Last - $low20) / $low20 * 100
    $roomH20 = ($high20 - $Last) / $Last * 100
    $roomMa20 = ($ma20 - $Last) / $Last * 100

    $rsi = Get-Rsi $dCl
    $h4Cl = @($H4 | ForEach-Object { [double]$_[4] })
    $px4h = ($h4Cl[-1] - $h4Cl[-2]) / $h4Cl[-2] * 100
    $px1w = if ($dCl.Count -ge 8) { ($Last - $dCl[-8]) / $dCl[-8] * 100 } else { 0 }

    $sc = 0; $tags = @()

    # Sweet spot: not bottom knife, not top chase
    if ($pos20 -ge 15 -and $pos20 -le 45) { $sc += 5; $tags += 'low-mid' }
    elseif ($pos20 -lt 15) { $sc += 3; $tags += 'deep-low' }
    elseif ($pos20 -le 60) { $sc += 2 }

    if ($distLow20 -le 15) { $sc += 3; $tags += 'near-support' }
    if ($roomH20 -ge 12) { $sc += 4; $tags += 'room-up' }
    if ($roomMa20 -ge 3) { $sc += 2 }

    if ($rsi -ge 35 -and $rsi -le 55) { $sc += 3; $tags += 'rsi-ok' }
    if ($rsi -gt 70) { $sc -= 4; $tags += 'overbought' }
    if ($rsi -lt 28) { $sc += 1 }

    if ($Last -gt $ma7) { $sc += 3; $tags += 'above-ma7' }
    if ($ma7 -gt $ma20 * 0.995) { $sc += 2; $tags += 'ma-align' }

    if ($px4h -ge -2 -and $px4h -le 8) { $sc += 2 }
    if ($px1w -ge -8 -and $px1w -le 12) { $sc += 2; $tags += '1w-base' }

    if ($Chg24 -ge -8 -and $Chg24 -le 8) { $sc += 2 }
    if ($Chg24 -gt 25) { $sc -= 5; $tags += 'pumped' }
    if ($Chg24 -lt -20) { $sc -= 2 }

    if ($VolM -ge 30) { $sc += 2; $tags += 'liquid' }
    elseif ($VolM -ge 10) { $sc += 1 }

    if ($Fund -lt -0.01) { $sc += 1; $tags += 'neg-fund' }

    if ($sc -lt 12) { return $null }

    $grade = if ($sc -ge 18 -and $roomH20 -ge 15) { 'A' } elseif ($sc -ge 14) { 'B' } else { 'C' }

    return [pscustomobject]@{
        Score = $sc; Grade = $grade
        Pos20 = [math]::Round($pos20, 1); DistLow20 = [math]::Round($distLow20, 1)
        RoomH20 = [math]::Round($roomH20, 1); RoomMa20 = [math]::Round($roomMa20, 1)
        Rsi = $rsi; Px4h = [math]::Round($px4h, 2); Px1w = [math]::Round($px1w, 2)
        Ma7 = [math]::Round($ma7, 4); Ma20 = [math]::Round($ma20, 4)
        Stop = [math]::Round($low20 * 0.97, 6)
        Tp1 = [math]::Round($ma20, 6)
        Tp2 = [math]::Round($high20 * 0.98, 6)
        Tags = ($tags -join ',')
    }
}

Write-Host '=== Swing Picks (1-2 week, Binance USDT-M) ===' -ForegroundColor Yellow

$mcap = @()
for ($p = 1; $p -le 2; $p++) {
    $uri = "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=250&page=$p&sparkline=false"
    $mcap += Invoke-RestMethod $uri -TimeoutSec 25
    Start-Sleep -Milliseconds 1100
}
$mcap = $mcap | Select-Object -First $TopMcap
$stable = @('USDT','USDC','DAI','USDE','FDUSD')

$ex = Invoke-RestMethod "$BaseUrl/fapi/v1/exchangeInfo" -TimeoutSec 25
$bn = @{}
foreach ($s in $ex.symbols) {
    if ($s.status -eq 'TRADING' -and $s.contractType -eq 'PERPETUAL' -and $s.quoteAsset -eq 'USDT') {
        $bn[$s.baseAsset] = $s.symbol
    }
}

$tickers = Invoke-RestMethod "$BaseUrl/fapi/v1/ticker/24hr" -TimeoutSec 30
$tm = @{}; foreach ($t in $tickers) { $tm[$t.symbol] = $t }

$pool = @()
foreach ($c in $mcap) {
    $sym = $c.symbol.ToUpper()
    if ($stable -contains $sym) { continue }
    if (-not $bn.ContainsKey($sym)) { continue }
    $pair = $bn[$sym]
    $t = $tm[$pair]
    $last = [double]$t.lastPrice; $open = [double]$t.openPrice
    $vol = [double]$t.quoteVolume
    if ($vol -lt 8e6) { continue }
    $chg = if ($open -gt 0) { ($last - $open) / $open * 100 } else { 0 }
    $pool += [pscustomobject]@{
        Base = $sym; Symbol = $pair; Rank = $c.market_cap_rank
        McapB = [math]::Round($c.market_cap / 1e9, 2)
        Last = $last; Chg24 = [math]::Round($chg, 2); VolM = [math]::Round($vol / 1e6, 1)
    }
}

$btc = $tm['BTCUSDT']; $eth = $tm['ETHUSDT']
Write-Host ("BTC {0} 24h {1:N2}% | ETH {2} 24h {3:N2}%" -f $btc.lastPrice,
    (([double]$btc.lastPrice - [double]$btc.openPrice) / [double]$btc.openPrice * 100),
    $eth.lastPrice, (([double]$eth.lastPrice - [double]$eth.openPrice) / [double]$eth.openPrice * 100))

$cands = @($pool | Sort-Object { [math]::Abs($_.Chg24) + [math]::Log10($_.VolM) } | Select-Object -First $DeepScan)
Write-Host "Deep scan $($cands.Count)..." -ForegroundColor DarkGray

$picks = @()
$i = 0
foreach ($p in $cands) {
    $i++
    if ($i % 20 -eq 0) { Write-Host "  $i" -ForegroundColor DarkGray }
    Start-Sleep -Milliseconds 70
    $fund = 0.0
    try {
        $f = Invoke-RestMethod "$BaseUrl/fapi/v1/premiumIndex?symbol=$($p.Symbol)" -TimeoutSec 8
        $fund = [math]::Round([double]$f.lastFundingRate * 100, 4)
    } catch {}
    $d = Get-K $p.Symbol '1d' 65
    $h4 = Get-K $p.Symbol '4h' 42
    $ana = Score-Swing -D $d -H4 $h4 -Last $p.Last -Chg24 $p.Chg24 -VolM $p.VolM -Fund $fund
    if ($ana) {
        $picks += [pscustomobject]@{
            Rank = $p.Rank; Base = $p.Base; McapB = $p.McapB
            Last = $p.Last; Chg24 = $p.Chg24; VolM = $p.VolM; Fund = $fund
            Score = $ana.Score; Grade = $ana.Grade
            Pos20 = $ana.Pos20; DistLow20 = $ana.DistLow20; RoomH20 = $ana.RoomH20
            Rsi = $ana.Rsi; Px4h = $ana.Px4h; Px1w = $ana.Px1w
            Stop = $ana.Stop; Tp1 = $ana.Tp1; Tp2 = $ana.Tp2; Tags = $ana.Tags
        }
    }
}

Write-Host "`n--- GRADE A (1-2w swing) ---" -ForegroundColor Green
$picks | Where-Object Grade -eq 'A' | Sort-Object Score -Descending | Select-Object -First $ShowTop | ForEach-Object {
    Write-Host ("  #{0,3} {1,-8} {2,10}  S={3}  24h={4,5}%  pos20={5,4}%  room={6,5}%  RSI={7}  4h={8}%  1w={9}%  vol={10}M" -f `
        $_.Rank, $_.Base, $_.Last, $_.Score, $_.Chg24, $_.Pos20, $_.RoomH20, $_.Rsi, $_.Px4h, $_.Px1w, $_.VolM)
    Write-Host ("       stop~{0}  tp1(MA20)~{1}  tp2(H20)~{2}  [{3}]" -f $_.Stop, $_.Tp1, $_.Tp2, $_.Tags) -ForegroundColor DarkGray
}

Write-Host "`n--- GRADE B ---" -ForegroundColor Cyan
$picks | Where-Object Grade -eq 'B' | Sort-Object Score -Descending | Select-Object -First 12 | ForEach-Object {
    Write-Host ("  #{0,3} {1,-8} S={2}  24h={3}%  pos={4}%  room={5}%  RSI={6}  [{7}]" -f `
        $_.Rank, $_.Base, $_.Score, $_.Chg24, $_.Pos20, $_.RoomH20, $_.Rsi, $_.Tags)
}

$out = Join-Path $PSScriptRoot 'swing-pick-latest.json'
@{ scannedAt = (Get-Date).ToString('o'); picks = $picks } | ConvertTo-Json -Depth 5 | Set-Content $out -Encoding UTF8
Write-Host "`nSaved $out | Not financial advice." -ForegroundColor DarkGray
