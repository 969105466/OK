# Verify Binance API key can access USDT-M futures account
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load-BinanceEnv.ps1')
. (Join-Path $PSScriptRoot 'lib\Binance-Rest.ps1')

$envVars = Import-BinanceEnv
$base = Get-BinanceBaseUrl -Env $envVars
Write-Host "Base URL: $base" -ForegroundColor Cyan

try {
    $info = Test-BinanceAccount -Env $envVars
    Write-Host 'Account linked OK.' -ForegroundColor Green
    Write-Host ("  canTrade={0} wallet={1} available={2} assets>0={3}" -f `
        $info.canTrade, $info.totalWalletBalance, $info.availableBalance, $info.assetCount)
} catch {
    Write-Host "Account check failed: $_" -ForegroundColor Red
    Write-Host 'Tips: use Futures API key, enable Reading; check IP whitelist and testnet flag.' -ForegroundColor Yellow
    exit 1
}
