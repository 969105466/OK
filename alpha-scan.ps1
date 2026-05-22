# Binance Alpha: analyze all tokens (token list + tradeable kline deep scan)
param(
    [int]$DeepTop = 60,
    [int]$ShowGainers = 15,
    [int]$ShowLosers = 10,
    [int]$ShowBottom = 20,
    [switch]$Deep,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Continue'
$Base = 'https://www.binance.com/bapi/defi/v1/public'
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'alpha-scan-latest.json' }

function Get-Rsi {
    param([double[]]$Closes, [int]$Period = 14)
    if ($Closes.Count -lt $Period + 2) { return $null }
    $arr = if ($Closes.Count -gt 40) { $Closes[-40..-1] } else { $Closes }
    $g = 0.0; $l = 0.0
    for ($i = $arr.Count - $Period; $i -lt $arr.Count; $i++) {
        $d = $arr[$i] - $arr[$i - 1]
        if ($d -ge 0) { $g += $d } else { $l += -$d }
    }
    if ($l -eq 0) { return 100.0 }
    return [math]::Round(100 - (100 / (1 + ($g / $Period) / ($l / $Period))), 2)
}

function Get-AlphaKlines {
    param([string]$TradeSymbol, [string]$Interval, [int]$Limit)
    try {
        $u = "$Base/alpha-trade/klines?symbol=$TradeSymbol&interval=$Interval&limit=$Limit"
        $r = Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 12
        if ($r.success -and $r.data) { return @($r.data) }
    } catch {}
    return @()
}

Write-Host '=== Binance Alpha Full Scan ===' -ForegroundColor Yellow
Write-Host 'Loading token list...' -ForegroundColor DarkGray
$list = Invoke-RestMethod "$Base/wallet-direct/buw/wallet/cex/alpha/all/token/list" -TimeoutSec 45
if (-not $list.success) { throw 'Token list failed' }

Write-Host 'Loading exchange info...' -ForegroundColor DarkGray
$ex = Invoke-RestMethod "$Base/alpha-trade/get-exchange-info" -TimeoutSec 45
$tradeMap = @{}
foreach ($s in $ex.data.symbols) {
    if ($s.status -eq 'TRADING' -and $s.quoteAsset -eq 'USDT') {
        $tradeMap[$s.baseAsset] = $s.symbol
    }
}

$rows = @()
foreach ($t in $list.data) {
    if ($t.offline -or $t.fullyDelisted) { continue }
    $price = [double]$t.price
    if ($price -le 0) { continue }
    $hi = [double]$t.priceHigh24h
    $lo = [double]$t.priceLow24h
    $chg = [double]$t.percentChange24h
    $vol = [double]$t.volume24h
    $mcap = [double]$t.marketCap
    $liq = [double]$t.liquidity
    $pos24 = if ($hi -gt $lo) { ($price - $lo) / ($hi - $lo) * 100 } else { 50 }
    $tradeSym = $null
    if ($tradeMap.ContainsKey($t.alphaId)) { $tradeSym = $tradeMap[$t.alphaId] }
    $rows += [pscustomobject]@{
        AlphaId = $t.alphaId
        Symbol = $t.symbol
        Name = $t.name
        Chain = $t.chainName
        Price = $price
        Chg24 = [math]::Round($chg, 2)
        Vol24 = [math]::Round($vol, 0)
        Mcap = [math]::Round($mcap, 0)
        Liq = [math]::Round($liq, 0)
        Pos24 = [math]::Round($pos24, 1)
        Holders = $t.holders
        Score = $t.score
        TradeSymbol = $tradeSym
        Tradeable = [bool]$tradeSym
        HotTag = $t.hotTag
        ListingCex = $t.listingCex
        OnlineAirdrop = $t.onlineAirdrop
    }
}

Write-Host ("Active tokens: {0} | Tradeable USDT pairs: {1}" -f $rows.Count, @($rows | Where-Object Tradeable).Count) -ForegroundColor Cyan

Write-Host "`n--- Market overview ---" -ForegroundColor Yellow
$up = @($rows | Where-Object { $_.Chg24 -gt 0 }).Count
$dn = @($rows | Where-Object { $_.Chg24 -lt 0 }).Count
$avgChg = ($rows | Measure-Object -Property Chg24 -Average).Average
Write-Host ("  Up/Down: {0} / {1}  |  Avg 24h change: {2:N2}%" -f $up, $dn, $avgChg)
Write-Host ("  Chain BSC: {0}  |  Tradeable: {1}" -f @($rows | Where-Object Chain -eq 'BSC').Count, @($rows | Where-Object Tradeable).Count)

Write-Host "`n--- TOP GAINERS 24h ---" -ForegroundColor Green
$rows | Sort-Object Chg24 -Descending | Select-Object -First $ShowGainers | ForEach-Object {
    Write-Host ("  {0,-12} {1,-10} chg={2,7}%  vol={3,12:N0}  liq={4,10:N0}  pos24={5,4}%  trade={6}" -f `
        $_.Symbol, $_.AlphaId, $_.Chg24, $_.Vol24, $_.Liq, $_.Pos24, $(if ($_.Tradeable) { 'Y' } else { 'N' }))
}

Write-Host "`n--- TOP LOSERS 24h ---" -ForegroundColor Red
$rows | Sort-Object Chg24 | Select-Object -First $ShowLosers | ForEach-Object {
    Write-Host ("  {0,-12} {1,-10} chg={2,7}%  vol=${3:N0}  liq=${4:N0}  pos24={5,4}%" -f `
        $_.Symbol, $_.AlphaId, $_.Chg24, $_.Vol24, $_.Liq, $_.Pos24)
}

Write-Host "`n--- HIGH VOLUME (24h) ---" -ForegroundColor Cyan
$rows | Sort-Object Vol24 -Descending | Select-Object -First 12 | ForEach-Object {
    Write-Host ("  {0,-12} vol=${1:N0}  chg={2,6}%  mcap=${3:N0}  trade={4}" -f `
        $_.Symbol, $_.Vol24, $_.Chg24, $_.Mcap, $(if ($_.Tradeable) { 'Y' } else { 'N' }))
}

Write-Host "`n--- NEAR 24h LOW (pos24<=20%, vol>50k) ---" -ForegroundColor Cyan
$nearLow = @($rows | Where-Object { $_.Pos24 -le 20 -and $_.Vol24 -gt 50000 } | Sort-Object Pos24)
$nearLow | Select-Object -First $ShowBottom | ForEach-Object {
    Write-Host ("  {0,-12} pos24={1,4}%  chg={2,6}%  vol=${3:N0}  liq=${4:N0}  trade={5}" -f `
        $_.Symbol, $_.Pos24, $_.Chg24, $_.Vol24, $_.Liq, $(if ($_.Tradeable) { 'Y' } else { 'N' }))
}

Write-Host "`n--- LOW LIQUIDITY RISK (liq<30k, mcap>100k) ---" -ForegroundColor DarkYellow
$rows | Where-Object { $_.Liq -lt 30000 -and $_.Mcap -gt 100000 } | Sort-Object Liq | Select-Object -First 10 | ForEach-Object {
    Write-Host ("  {0,-12} liq=${1:N0}  mcap=${2:N0}  vol=${3:N0}" -f $_.Symbol, $_.Liq, $_.Mcap, $_.Vol24)
}

$deepCandidates = @($rows | Where-Object { $_.Tradeable -and $_.Vol24 -gt 100000 } | Sort-Object Vol24 -Descending | Select-Object -First $DeepTop)
$deepResults = @()

if ($Deep -or $deepCandidates.Count -gt 0) {
    Write-Host "`n--- DEEP KLINE SCAN (tradeable, top vol) $($deepCandidates.Count) ---" -ForegroundColor Yellow
    $i = 0
    foreach ($p in $deepCandidates) {
        $i++
        if ($i % 15 -eq 0) { Write-Host "  ... $i / $($deepCandidates.Count)" -ForegroundColor DarkGray }
        Start-Sleep -Milliseconds 45
        $d = Get-AlphaKlines $p.TradeSymbol '1d' 25
        $h1 = Get-AlphaKlines $p.TradeSymbol '1h' 24
        if ($d.Count -lt 10) { continue }
        $dCl = @($d | ForEach-Object { [double]$_[4] })
        $dLo = @($d | ForEach-Object { [double]$_[3] })
        $dHi = @($d | ForEach-Object { [double]$_[2] })
        $last = $p.Price
        $low10 = ($dLo[-10..-1] | Measure-Object -Minimum).Minimum
        $high10 = ($dHi[-10..-1] | Measure-Object -Maximum).Maximum
        $pos10 = if ($high10 -gt $low10) { ($last - $low10) / ($high10 - $low10) * 100 } else { 50 }
        $rsi = Get-Rsi $dCl
        $ma7 = ($dCl[-7..-1] | Measure-Object -Average).Average
        $px1h = 0.0
        if ($h1.Count -ge 3) {
            $hCl = @($h1 | ForEach-Object { [double]$_[4] })
            $px1h = ($hCl[-1] - $hCl[-3]) / $hCl[-3] * 100
        }
        $sc = 0
        if ($pos10 -le 30) { $sc += 3 }
        if ($rsi -ge 30 -and $rsi -le 55) { $sc += 2 }
        if ($last -gt $ma7) { $sc += 2 }
        if ($px1h -ge 0.5) { $sc += 2 }
        if ($p.Chg24 -ge 0 -and $p.Chg24 -le 15) { $sc += 1 }
        if ($sc -ge 6) {
            $deepResults += [pscustomobject]@{
                Symbol = $p.Symbol; AlphaId = $p.AlphaId; Price = $last
                Chg24 = $p.Chg24; Vol24 = $p.Vol24; Pos10d = [math]::Round($pos10, 1)
                Rsi = $rsi; Px1h = [math]::Round($px1h, 2); Score = $sc
            }
        }
    }
    if ($deepResults.Count -gt 0) {
        Write-Host "`n  Bottom+startup (kline score>=6):" -ForegroundColor Green
        $deepResults | Sort-Object Score -Descending | Select-Object -First 20 | ForEach-Object {
            Write-Host ("    {0,-12} S={1}  24h={2,6}%  pos10d={3,4}%  RSI={4,5}  1h={5,5}%" -f `
                $_.Symbol, $_.Score, $_.Chg24, $_.Pos10d, $_.Rsi, $_.Px1h)
        }
    }
}

$export = @{
    scannedAt = (Get-Date).ToString('o')
    totalActive = $rows.Count
    tradeable = @($rows | Where-Object Tradeable).Count
    overview = @{ up = $up; down = $dn; avgChg24 = [math]::Round($avgChg, 2) }
    topGainers = @($rows | Sort-Object Chg24 -Descending | Select-Object -First 30)
    topLosers = @($rows | Sort-Object Chg24 | Select-Object -First 30)
    topVolume = @($rows | Sort-Object Vol24 -Descending | Select-Object -First 30)
    nearLow24 = @($nearLow | Select-Object -First 40)
    lowLiquidityRisk = @($rows | Where-Object { $_.Liq -lt 30000 -and $_.Mcap -gt 100000 } | Sort-Object Liq | Select-Object -First 30)
    deepBottomStartup = $deepResults
    allTokens = $rows
}
$export | ConvertTo-Json -Depth 6 | Set-Content $OutFile -Encoding UTF8
Write-Host "`nSaved: $OutFile ($($rows.Count) tokens)" -ForegroundColor DarkGray
Write-Host 'Not financial advice.' -ForegroundColor DarkGray
