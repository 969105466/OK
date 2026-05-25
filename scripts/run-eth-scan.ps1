# 一键执行：ETH 老币拉盘扫描 + 重点币安全（DexScreener，不依赖 GMGN OpenAPI）
param(
    [string[]]$Watch = @(
        '0x9ac9468e7e3e1d194080827226b45d0b892c77fd',
        '0x2b566950BA2298AcEf3c730CC0129b2f4fBd30a3'
    )
)

$ErrorActionPreference = 'Stop'
$outDir = Split-Path $PSScriptRoot -Parent

Write-Host "`n[1/2] scan-eth-old-pump.ps1" -ForegroundColor Cyan
& "$PSScriptRoot\scan-eth-old-pump.ps1"

Write-Host "`n[2/2] Watchlist detail" -ForegroundColor Cyan
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$report = @()
foreach ($addr in $Watch) {
    $r = Invoke-RestMethod "https://api.dexscreener.com/latest/dex/tokens/$addr" -TimeoutSec 25
    $p = $r.pairs | Where-Object { $_.chainId -eq 'ethereum' } | Sort-Object { $_.liquidity.usd } -Descending | Select-Object -First 1
    if (-not $p) { continue }
    $key = $addr.ToLower()
    $g = Invoke-RestMethod "https://api.gopluslabs.io/api/v1/token_security/1?contract_addresses=$key" -TimeoutSec 25
    $s = $g.result.$key
    $report += [PSCustomObject]@{
        Symbol = $p.baseToken.symbol
        Address = $p.baseToken.address
        AgeDays = [math]::Round(($now - $p.pairCreatedAt) / 86400000.0, 0)
        PriceUsd = $p.priceUsd
        McapUsd = $p.marketCap
        LiqUsd = $p.liquidity.usd
        Vol24h = $p.volume.h24
        Chg1h = $p.priceChange.h1
        Chg6h = $p.priceChange.h6
        Chg24h = $p.priceChange.h24
        Buys24h = $p.txns.h24.buys
        Sells24h = $p.txns.h24.sells
        Honeypot = $s.is_honeypot
        BuyTax = $s.buy_tax
        SellTax = $s.sell_tax
        Holders = $s.holder_count
        DexUrl = $p.url
        GmgnUrl = "https://gmgn.ai/eth/token/$key"
    }
}

$reportPath = Join-Path $outDir 'scan-report.csv'
$report | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Host "Report saved: $reportPath" -ForegroundColor Green
$report | Format-Table -AutoSize

# GMGN CLI (optional, needs network to openapi.gmgn.ai)
if ($env:GMGN_API_KEY -or (Test-Path "$env:USERPROFILE\.config\gmgn\.env")) {
    if (-not $env:GMGN_API_KEY) {
        $env:GMGN_API_KEY = (Get-Content "$env:USERPROFILE\.config\gmgn\.env" -Raw).Trim() -replace '^GMGN_API_KEY=', ''
    }
    Write-Host "`n[Optional] GMGN CLI trending (may timeout behind firewall):" -ForegroundColor Yellow
    npx --yes gmgn-cli market trending --chain eth --interval 24h --order-by volume --limit 20 --raw 2>&1
}
