# Scan established ETH memes for recent pump signals (DexScreener)
$tokens = @(
    @{ sym = 'PEPE'; addr = '0x6982508145454Ce325DdBe47A25b4ecf2C38BF8' },
    @{ sym = 'WOJAK'; addr = '0x5026F006B857732a14FF1f788Be2703dE7a0100' },
    @{ sym = 'MOG'; addr = '0xaaee1a5fefd5e09cef81359e2ba4f8cda2f55570' },
    @{ sym = 'SPX'; addr = '0xe0f63a424a4422fe70ed244b245fe131610ca762' },
    @{ sym = 'YEE'; addr = '0x9ac9468e7e3e1d194080827226b45d0b892c77fd' },
    @{ sym = 'TURBO'; addr = '0xa359e23a036806cef7f652fc1d9ae6c28e70122c' },
    @{ sym = 'LADYS'; addr = '0x128a9477b615af4eeb56016326a38d2eddd67c74' },
    @{ sym = 'BOBO'; addr = '0xb90b2a1c0e54360bbab57d2b5697ef416ba87800' },
    @{ sym = 'NPC'; addr = '0x8ed54fe99210abf46aecacb53559255a177e33b8' },
    @{ sym = 'NEIRO'; addr = '0x812ba41e071c7bcd27ec4078002fa4a2519f18d0' },
    @{ sym = 'APU'; addr = '0x594daad7d77592a02b277839786467551129c3d3' },
    @{ sym = 'BITCOIN'; addr = '0x0578a8d43df1e81588c0a3c532137ca4b68cab6e' },
    @{ sym = 'MOCHI'; addr = '0x6bd06673eecb8b47682b0027e083e22437473bbf' },
    @{ sym = 'PNDC'; addr = '0x4a0c64fc71003ee60f83bccbcf0e8b5a9506e2d0' },
    @{ sym = 'SHIB'; addr = '0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce' },
    @{ sym = 'FLOKI'; addr = '0xcf0c122c6b73ff809c693db761e7baebe62b6a2e' },
    @{ sym = 'ELON'; addr = '0x761d38e5ddf6aaa6613d69bf782eebaefbc9c325' },
    @{ sym = 'KEKIUS'; addr = '0x3a9f9a1fbaef38d56e5c3b0f0f670002c5c98370' },
    @{ sym = 'KIMCHI'; addr = '0x2b566950BA2298AcEf3c730CC0129b2f4fBd30a3' }
)

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$minAgeDays = 90
$minLiq = 30000
$minMc = 200000

$rows = foreach ($t in $tokens) {
    $url = "https://api.dexscreener.com/latest/dex/tokens/$($t.addr)"
    try {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 20
    } catch { continue }
    $pairs = $r.pairs | Where-Object { $_.chainId -eq 'ethereum' } | Sort-Object { $_.liquidity.usd } -Descending
    $p = $pairs | Select-Object -First 1
    if (-not $p) { continue }
    $ageDays = ($now - $p.pairCreatedAt) / 86400000.0
    if ($ageDays -lt $minAgeDays) { continue }
    if ($p.liquidity.usd -lt $minLiq) { continue }
    if ($p.marketCap -lt $minMc) { continue }
    $h24 = $p.priceChange.h24
    $h6 = $p.priceChange.h6
    $h1 = $p.priceChange.h1
    if ($null -eq $h24) { $h24 = 0 }
    $pumpScore = 0
    if ($h24 -ge 8) { $pumpScore += 3 }
    elseif ($h24 -ge 4) { $pumpScore += 2 }
    elseif ($h24 -ge 2) { $pumpScore += 1 }
    if ($h1 -ge 5) { $pumpScore += 2 }
    if ($p.volume.h24 -ge 100000) { $pumpScore += 1 }
    if ($p.txns.h24.buys -gt $p.txns.h24.sells) { $pumpScore += 1 }
    [PSCustomObject]@{
        Symbol = $p.baseToken.symbol
        Address = $p.baseToken.address
        AgeDays = [math]::Round($ageDays, 0)
        PriceUsd = $p.priceUsd
        Mcap = $p.marketCap
        Liq = $p.liquidity.usd
        Vol24h = $p.volume.h24
        Chg1h = $h1
        Chg6h = $h6
        Chg24h = $h24
        Buys24h = $p.txns.h24.buys
        Sells24h = $p.txns.h24.sells
        PumpScore = $pumpScore
        DexUrl = $p.url
    }
}

$rows | Where-Object { $_.PumpScore -ge 3 } | Sort-Object PumpScore, Chg24h -Descending | Format-Table -AutoSize
Write-Output "`n--- All old memes with any 24h gain >= 2% ---"
$rows | Where-Object { $_.Chg24h -ge 2 } | Sort-Object Chg24h -Descending | Format-Table -AutoSize
