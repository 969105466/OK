# Shared Telegram helpers for OK scripts

function Initialize-TelegramConfig {
    $envFile = Join-Path $PSScriptRoot "telegram.env"
    if (-not (Test-Path $envFile)) {
        return $false
    }
    Get-Content $envFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq "") { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $name = $matches[1].Trim()
            $val = $matches[2].Trim().Trim('"').Trim("'")
            Set-Item -Path "env:$name" -Value $val
        }
    }
    return (-not [string]::IsNullOrWhiteSpace($env:TELEGRAM_BOT_TOKEN)) -and
           (-not [string]::IsNullOrWhiteSpace($env:TELEGRAM_CHAT_ID))
}

function Initialize-TelegramTokenOnly {
    $envFile = Join-Path $PSScriptRoot "telegram.env"
    if (-not (Test-Path $envFile)) { return $false }
    Get-Content $envFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq "") { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $name = $matches[1].Trim()
            $val = $matches[2].Trim().Trim('"').Trim("'")
            Set-Item -Path "env:$name" -Value $val
        }
    }
    return -not [string]::IsNullOrWhiteSpace($env:TELEGRAM_BOT_TOKEN)
}

function Escape-TelegramHtml {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$ParseMode = "HTML"
    )

    $token = $env:TELEGRAM_BOT_TOKEN
    $chatId = $env:TELEGRAM_CHAT_ID
    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($chatId)) {
        return $false
    }

    if ($Text.Length -gt 4000) {
        $Text = $Text.Substring(0, 3990) + "`n...(truncated)"
    }

    try {
        $uri = "https://api.telegram.org/bot$token/sendMessage"
        $body = @{
            chat_id                  = $chatId
            text                     = $Text
            disable_web_page_preview = $true
        }
        if ($ParseMode) { $body.parse_mode = $ParseMode }

        $json = $body | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri $uri -Method Post -Body $json -ContentType "application/json; charset=utf-8" -TimeoutSec 20
        return [bool]$r.ok
    } catch {
        Write-Host "Telegram error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Test-TelegramAlertWorthy {
    param([string]$ReportText)

    if ($script:TelegramEveryCycle) { return $true }

    $patterns = @(
        "DANGER",
        "PROFIT",
        "\[ACTION\]",
        "\[DUMP-SETUP\]",
        "\[OI-DIVERGE\]",
        "\[FUND-CROWD\]",
        "\[FUND-EXTREME\]",
        "\[OI-DROP-STRONG\]",
        "\[OI-DROP\]",
        "ERROR:"
    )
    foreach ($p in $patterns) {
        if ($ReportText -match $p) { return $true }
    }
    return $false
}

function Format-TelegramReport {
    param([string]$PlainText)

    $lines = $PlainText -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.StartsWith("==========")) {
            $title = $t.Trim("=").Trim()
            $out.Add("<b>$(Escape-TelegramHtml -Text $title)</b>")
        } elseif ($t -match '^\[(.+)\]') {
            $out.Add("<b>$(Escape-TelegramHtml -Text $t)</b>")
        } elseif ($t.StartsWith("---")) {
            $out.Add("<i>$(Escape-TelegramHtml -Text ($t.Trim('-').Trim()))</i>")
        } else {
            $out.Add((Escape-TelegramHtml -Text $t))
        }
    }
    return ($out -join "`n")
}
