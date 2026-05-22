function Get-BinanceEnvPath {
    $projectRoot = Split-Path $PSScriptRoot -Parent
    Join-Path $projectRoot 'binance.env'
}

function Import-BinanceEnv {
    param([string]$Path)

    if (-not $Path) { $Path = Get-BinanceEnvPath }
    if (-not (Test-Path $Path)) {
        throw "Missing binance.env. Copy binance.env.example to binance.env and set API keys. Path: $Path"
    }

    $vars = @{}
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { return }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $vars[$key] = $val
        Set-Item -Path "Env:$key" -Value $val -Force
    }
    return $vars
}

function Get-BinanceBaseUrl {
    param([hashtable]$Env = $null)
    if (-not $Env) {
        Import-BinanceEnv | Out-Null
        $testnet = $env:BINANCE_USE_TESTNET
    } else {
        $testnet = $Env['BINANCE_USE_TESTNET']
    }
    if ($testnet -eq 'true' -or $testnet -eq '1') {
        return 'https://testnet.binancefuture.com'
    }
    return 'https://fapi.binance.com'
}
