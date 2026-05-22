# Deep single-coin analysis
param([string[]]$Bases = @('POL','XLM','FET','APT'))

. (Join-Path $PSScriptRoot 'lib\Load-BinanceEnv.ps1') -ErrorAction SilentlyContinue
$BaseUrl = 'https://fapi.binance.com'

function Get-Rsi { param([double[]]$Closes, [int]$Period = 14)
    if ($Closes.Count -lt $Period + 2) { return $null }
    $arr = if ($Closes.Count -gt 60) { $Closes[-60..-1] } else { $Closes }
    $g = 0.0; $l = 0.0
    for ($i = $arr.Count - $Period; $i -lt $arr.Count; $i++) {
        $d = $arr[$i] - $arr[$i - 1]
        if ($d -ge 0) { $g += $d } else { $l += -$d }
    }
    if ($l -eq 0) { return 100.0 }
    return [math]::Round(100 - (100 / (1 + ($g / $Period) / ($l / $Period))), 2)
}

function Get-Ema { param([double[]]$Data, [int]$Period)
    if ($Data.Count -lt $Period) { return $null }
    $k = 2.0 / ($Period + 1)
    $ema = ($Data[0..($Period-1)] | Measure-Object -Average).Average
    for ($i = $Period; $i -lt $Data.Count; $i++) { $ema = $Data[$i]*$k + $ema*(1-$k) }
    return $ema
}

function Get-K { param($Sym, $Iv, $Lim)
    @(Invoke-RestMethod "$BaseUrl/fapi/v1/klines?symbol=$Sym&interval=$Iv&limit=$Lim" -TimeoutSec 14)
}

foreach ($base in $Bases) {
    $sym = "$base" + 'USDT'
    Write-Host "`n========================================" -ForegroundColor Yellow
    Write-Host " $base ($sym) " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Yellow

    $t = Invoke-RestMethod "$BaseUrl/fapi/v1/ticker/24hr?symbol=$sym" -TimeoutSec 10
    $f = Invoke-RestMethod "$BaseUrl/fapi/v1/premiumIndex?symbol=$sym" -TimeoutSec 10
    $oi = Invoke-RestMethod "$BaseUrl/fapi/v1/openInterest?symbol=$sym" -TimeoutSec 10

    $last = [double]$t.lastPrice
    $open = [double]$t.openPrice
    $hi = [double]$t.highPrice
    $lo = [double]$t.lowPrice
    $chg24 = ($last - $open) / $open * 100
    $volM = [math]::Round([double]$t.quoteVolume / 1e6, 1)
    $fund = [math]::Round([double]$f.lastFundingRate * 100, 4)
    $oiM = [math]::Round([double]$oi.openInterest * $last / 1e6, 1)

    $d = Get-K $sym '1d' 90
    $h4 = Get-K $sym '4h' 48
    $h1 = Get-K $sym '1h' 48
    $m15 = Get-K $sym '15m' 96

    $dCl = @($d | ForEach-Object { [double]$_[4] })
    $dHi = @($d | ForEach-Object { [double]$_[2] })
    $dLo = @($d | ForEach-Object { [double]$_[3] })
    $dVol = @($d | ForEach-Object { [double]$_[5] })

    $ma7 = ($dCl[-7..-1] | Measure-Object -Average).Average
    $ma20 = ($dCl[-20..-1] | Measure-Object -Average).Average
    $ma60 = ($dCl[-60..-1] | Measure-Object -Average).Average
    $low20 = ($dLo[-20..-1] | Measure-Object -Minimum).Minimum
    $high20 = ($dHi[-20..-1] | Measure-Object -Maximum).Maximum
    $low60 = ($dLo[-60..-1] | Measure-Object -Minimum).Minimum
    $high60 = ($dHi[-60..-1] | Measure-Object -Maximum).Maximum

    $pos20 = ($last - $low20) / ($high20 - $low20) * 100
    $distLow20 = ($last - $low20) / $low20 * 100
    $distHigh20 = ($high20 - $last) / $high20 * 100
    $distLow60 = ($last - $low60) / $low60 * 100
    $dropFrom60h = ($high60 - $last) / $high60 * 100

    $rsi = Get-Rsi $dCl
    $rsi5ago = Get-Rsi $dCl[0..($dCl.Count-6)]
    $ema12 = Get-Ema $dCl 12
    $ema26 = Get-Ema $dCl 26

    $h4Cl = @($h4 | ForEach-Object { [double]$_[4] })
    $h1Cl = @($h1 | ForEach-Object { [double]$_[4] })
    $m15Cl = @($m15 | ForEach-Object { [double]$_[4] })

    $bars = @(
        @{ n='15m'; c=$m15Cl },
        @{ n='1h';  c=$h1Cl },
        @{ n='4h';  c=$h4Cl },
        @{ n='1d';  c=$dCl }
    )
    Write-Host "`n[Price] LAST=$last  24h=$([math]::Round($chg24,2))%  H=$hi L=$lo  Vol=${volM}M  OI~${oiM}M  Fund=$fund%"
    Write-Host "[20D] pos=$([math]::Round($pos20,1))%  distLow=$([math]::Round($distLow20,1))%  distHigh=$([math]::Round($distHigh20,1))%  L20=$low20 H20=$high20"
    Write-Host "[60D] distLow=$([math]::Round($distLow60,1))%  dropFromHigh=$([math]::Round($dropFrom60h,1))%  L60=$low60 H60=$high60"
    Write-Host "[MA]  MA7=$([math]::Round($ma7,4)) MA20=$([math]::Round($ma20,4)) MA60=$([math]::Round($ma60,4))  above7=$([math]::Round(($last-$ma7)/$ma7*100,2))%"
    Write-Host "[RSI] $rsi  (5d ago $rsi5ago)  EMA12/26=$([math]::Round($ema12,4))/$([math]::Round($ema26,4)) bull=$($ema12 -gt $ema26)"

    Write-Host "`n[Multi-TF momentum]"
    foreach ($b in $bars) {
        $c = $b.c
        if ($c.Count -lt 3) { continue }
        $ch = ($c[-1]-$c[-2])/$c[-2]*100
        $ch4 = if ($c.Count -ge 5) { ($c[-1]-$c[-5])/$c[-5]*100 } else { 0 }
        Write-Host ("  {0,-4} bar={1,7}%  last4bars={2,7}%" -f $b.n, [math]::Round($ch,2), [math]::Round($ch4,2))
    }

    $avgVol = ($dVol[-20..-1] | Measure-Object -Average).Average
    Write-Host "`n[Volume] today/avg20 = $([math]::Round($dVol[-1]/$avgVol, 2))x"

    try {
        $oiH = @(Invoke-RestMethod "$BaseUrl/futures/data/openInterestHist?symbol=$sym&period=4h&limit=12" -TimeoutSec 10)
        $o0 = [double]$oiH[-1].sumOpenInterest; $o3 = [double]$oiH[-4].sumOpenInterest
        $oi4d = [math]::Round(($o0-$o3)/$o3*100, 2)
        Write-Host "[OI] 4h x3 change = $oi4d%"
    } catch { Write-Host "[OI] n/a" }

    $support = [math]::Round($low20, 4)
    $res1 = [math]::Round($ma20, 4)
    $res2 = [math]::Round($high20, 4)
    $stop = [math]::Round($low20 * 0.985, 4)
    $tp1 = [math]::Round($ma20 * 1.01, 4)
    $tp2 = [math]::Round($high20 * 0.98, 4)
    Write-Host "`n[Levels] Support~$support  Stop~$stop  TP1(MA20)~$tp1  TP2(H20)~$tp2"
    Start-Sleep -Milliseconds 400
}
