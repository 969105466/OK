param(
    [string[]]$Query = @(),
    [int]$Top = 5,
    [switch]$Refresh,
    [switch]$ListCategories
)

$ErrorActionPreference = 'Stop'
$gmgnRoot = Split-Path $PSScriptRoot -Parent
$cachePath = Join-Path $gmgnRoot 'skills_zh-CN.json'
$indexUrl = 'https://gmgn.ai/static/opstatic/skills_zh-CN.json'

function Get-SkillsList {
    param([object]$Data)
    if ($Data.skills) { return $Data.skills }
    if ($Data -is [System.Array]) { return $Data }
    if ($Data.data) { return $Data.data }
    if ($Data.list) { return $Data.list }
    throw 'Invalid skills_zh-CN.json: expected { skills: [...] }'
}

function Expand-SkillEntry {
    param($Entry)
    $inner = $Entry.skills
    if (-not $inner) {
        return [PSCustomObject]@{
            id             = $Entry.id
            slug           = $Entry.slug
            url            = $Entry.url
            category       = $Entry.category
            source         = $Entry.source
            title          = $Entry.title
            subtitle       = $Entry.subtitle
            installation   = $Entry.installation
            capabilities   = $Entry.capabilities
            prompts        = $Entry.prompts
        }
    }
    [PSCustomObject]@{
        id             = $Entry.id
        slug           = $Entry.slug
        url            = $Entry.url
        category       = $Entry.category
        source         = $Entry.source
        title          = $inner.title
        subtitle       = $inner.subtitle
        installation   = $inner.installation
        capabilities   = $inner.capabilities
        prompts        = $inner.prompts
    }
}

function Invoke-DownloadSkills {
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        'Accept'       = 'application/json,*/*'
    }
    try {
        Invoke-WebRequest -Uri $indexUrl -Headers $headers -UseBasicParsing -TimeoutSec 60 -OutFile $cachePath
    }
    catch {
        & curl.exe -sL $indexUrl -o $cachePath
        if (-not (Test-Path $cachePath) -or (Get-Item $cachePath).Length -lt 100) {
            throw "Download failed: $($_.Exception.Message). Save manually to $cachePath"
        }
    }
}

if ($Refresh) {
    Write-Host "Downloading -> $cachePath"
    Invoke-DownloadSkills
}

if (-not (Test-Path $cachePath)) {
    throw "Missing $cachePath. Save skills_zh-CN.json under $gmgnRoot or run -Refresh."
}

$raw = Get-Content -Path $cachePath -Raw -Encoding UTF8
$data = $raw | ConvertFrom-Json
$entries = @(Get-SkillsList -Data $data)
$skills = $entries | ForEach-Object { Expand-SkillEntry -Entry $_ }

if ($ListCategories) {
    if ($data.categories) {
        $data.categories | ForEach-Object {
            $name = $_.name.'zh-CN'
            if (-not $name) { $name = $_.slug }
            Write-Host "$($_.slug) -> $name"
        }
    }
    else {
        $skills | ForEach-Object { $_.category } | Where-Object { $_ } | Sort-Object -Unique
    }
    exit 0
}

if ($Query.Count -eq 0) {
    Write-Host "Total skills: $($skills.Count). Use -Query keyword or -ListCategories."
    exit 0
}

$terms = $Query | ForEach-Object { $_.ToLowerInvariant() }

$scored = foreach ($s in $skills) {
    $cap = if ($s.capabilities -is [System.Array]) { ($s.capabilities -join ' ') } else { [string]$s.capabilities }
    $hay = @(
        [string]$s.title,
        [string]$s.subtitle,
        [string]$s.category,
        [string]$s.slug,
        [string]$s.source,
        $cap
    ) -join ' ' | ForEach-Object { $_.ToLowerInvariant() }

    $score = 0
    foreach ($t in $terms) {
        if ([string]$s.title -and $s.title.ToLowerInvariant().Contains($t)) { $score += 10 }
        if ([string]$s.slug -and $s.slug.ToLowerInvariant().Contains($t)) { $score += 8 }
        if ($cap -and $cap.ToLowerInvariant().Contains($t)) { $score += 6 }
        if ($hay.Contains($t)) { $score += 3 }
    }
    if ($score -gt 0) { [PSCustomObject]@{ Score = $score; Skill = $s } }
}

$results = $scored | Sort-Object Score -Descending | Select-Object -First $Top

if (-not $results) {
    Write-Host 'No matches. Try other keywords or https://gmgn.ai/ai'
    exit 1
}

$i = 1
foreach ($r in $results) {
    $s = $r.Skill
    $cap = if ($s.capabilities -is [System.Array]) { ($s.capabilities -join ' | ') } else { $s.capabilities }
    Write-Host ''
    Write-Host "[$i] $($s.title) (score=$($r.Score), slug=$($s.slug))"
    Write-Host "    category: $($s.category)"
    Write-Host "    subtitle: $($s.subtitle)"
    Write-Host "    capabilities: $cap"
    Write-Host "    source: $($s.source)"
    Write-Host "    url: $($s.url)"
    if ($s.installation) {
        $preview = ($s.installation -replace "`r?`n", ' ').Substring(0, [Math]::Min(120, $s.installation.Length))
        Write-Host "    installation: $preview..."
    }
    $i++
}
