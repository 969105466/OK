# Binance USDT-M: ticker + funding + OI + multi-timeframe klines (public API)
param(
    [string[]]$Bases = @('BTC', 'ETH'),
    [switch]$UseEnvDefault
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Load-BinanceEnv.ps1')
. (Join-Path $PSScriptRoot 'lib\Binance-Rest.ps1')

$baseUrl = 'https://fapi.binance.com'
if (Test-Path (Get-BinanceEnvPath)) {
    try {
        $ev = Import-BinanceEnv
        $baseUrl = Get-BinanceBaseUrl -Env $ev
        if ($UseEnvDefault -and $ev['BINANCE_DEFAULT_BASE']) {
            $Bases = @($ev['BINANCE_DEFAULT_BASE'])
        }
    } catch { }
}

$bars = @(
    @{ label = '15m'; interval = '15m' },
    @{ label = '1H';  interval = '1h' },
    @{ label = '4H';  interval = '4h' },
    @{ label = '1D';  interval = '1d' }
)

foreach ($base in $Bases) {
    $symbol = "$base" + 'USDT'
    Write-Host "`n========== $symbol ==========" -ForegroundColor Cyan
    try {
        $t = (Invoke-RestMethod "$baseUrl/fapi/v1/ticker/24hr?symbol=$symbol")
        $fund = (Invoke-RestMethod "$baseUrl/fapi/v1/premiumIndex?symbol=$symbol")
        $oi = (Invoke-RestMethod "$baseUrl/fapi/v1/openInterest?symbol=$symbol")

        $last = [double]$t.lastPrice
        $open = [double]$t.openPrice
        $hi24 = [double]$t.highPrice
        $lo24 = [double]$t.lowPrice
        $chg = ($last - $open) / $open * 100
        $volM = [math]::Round([double]$t.quoteVolume / 1e6, 1)
        $fundPct = [math]::Round([double]$fund.lastFundingRate * 100, 4)
        $oiUsdM = [math]::Round([double]$oi.openInterest * $last / 1e6, 2)

        foreach ($bar in $bars) {
            $c = Get-BinanceKlines -Symbol $symbol -Interval $bar.interval -Limit 5 -BaseUrl $baseUrl
            $cl0 = [double]$c[-1][4]
            $cl1 = [double]$c[-2][4]
            $pct = ($cl0 - $cl1) / $cl1 * 100
            Write-Host ("  {0,-4} px={1} barChg={2}%" -f $bar.label, $cl0, [math]::Round($pct, 2))
        }

        $d = Get-BinanceKlines -Symbol $symbol -Interval '1d' -Limit 25 -BaseUrl $baseUrl
        $closes = @($d | ForEach-Object { [double]$_[4] })
        $ma7 = ($closes | Select-Object -Last 7 | Measure-Object -Average).Average
        $ma20 = ($closes | Select-Object -Last 20 | Measure-Object -Average).Average
        $h20 = ($d | Select-Object -Last 20 | ForEach-Object { [double]$_[2] } | Measure-Object -Maximum).Maximum
        $l20 = ($d | Select-Object -Last 20 | ForEach-Object { [double]$_[3] } | Measure-Object -Minimum).Minimum

        Write-Host "  LAST=$last CHG24=$([math]::Round($chg,2))% H24=$hi24 L24=$lo24 VOL=${volM}M"
        Write-Host "  FUND=${fundPct}% OI~${oiUsdM}M USD"
        Write-Host "  MA7=$([math]::Round($ma7,4)) MA20=$([math]::Round($ma20,4)) H20=$h20 L20=$l20"
        $aboveMa7 = ($last - $ma7) / $ma7 * 100
        $toHigh = ($h20 - $last) / $h20 * 100
        Write-Host "  above_MA7=$([math]::Round($aboveMa7,2))% to_H20=$([math]::Round($toHigh,2))%"
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 300
}
