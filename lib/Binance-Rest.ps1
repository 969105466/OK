. (Join-Path $PSScriptRoot 'Load-BinanceEnv.ps1')

function Get-BinanceServerTimeMs {
    param([string]$BaseUrl = 'https://fapi.binance.com')
    $r = Invoke-RestMethod -Uri "$BaseUrl/fapi/v1/time" -Method Get
    return [int64]$r.serverTime
}

function New-BinanceSignature {
    param([string]$Query, [string]$Secret)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Query))
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    } finally {
        $hmac.Dispose()
    }
}

function Invoke-BinanceSigned {
    param(
        [string]$Path,
        [hashtable]$Query = @{},
        [string]$Method = 'GET',
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$BaseUrl = 'https://fapi.binance.com'
    )

    if (-not $ApiKey -or -not $ApiSecret) {
        throw 'BINANCE_API_KEY and BINANCE_API_SECRET are required for signed requests.'
    }

    $q = [ordered]@{}
    foreach ($k in ($Query.Keys | Sort-Object)) { $q[$k] = $Query[$k] }
    $q['timestamp'] = Get-BinanceServerTimeMs -BaseUrl $BaseUrl
    $q['recvWindow'] = 5000

    $pairs = @()
    foreach ($k in $q.Keys) { $pairs += "{0}={1}" -f $k, [uri]::EscapeDataString([string]$q[$k]) }
    $queryString = $pairs -join '&'
    $sig = New-BinanceSignature -Query $queryString -Secret $ApiSecret
    $uri = "$BaseUrl$Path`?$queryString&signature=$sig"

    $headers = @{ 'X-MBX-APIKEY' = $ApiKey }
    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers
}

function Get-BinanceKlines {
    param(
        [string]$Symbol,
        [string]$Interval = '15m',
        [int]$Limit = 30,
        [string]$BaseUrl = 'https://fapi.binance.com'
    )
    $uri = "$BaseUrl/fapi/v1/klines?symbol=$Symbol&interval=$Interval&limit=$Limit"
    return Invoke-RestMethod -Uri $uri -Method Get
}

function Test-BinanceAccount {
    param([hashtable]$Env)

    $base = Get-BinanceBaseUrl -Env $Env
    $key = $Env['BINANCE_API_KEY']
    $secret = $Env['BINANCE_API_SECRET']
    $acc = Invoke-BinanceSigned -Path '/fapi/v2/account' -ApiKey $key -ApiSecret $secret -BaseUrl $base
    return @{
        canTrade = $acc.canTrade
        totalWalletBalance = $acc.totalWalletBalance
        availableBalance = $acc.availableBalance
        assetCount = @($acc.assets | Where-Object { [double]$_.walletBalance -gt 0 }).Count
    }
}
