# =====================================================================
# minutes register script (Backlog document)
#
# Registers a finished minutes Markdown file to Backlog as a document,
# using the official "Add Document" API (POST /api/v2/documents; the
# content field is parsed as Markdown).
#
# Run:
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\register.ps1"
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\register.ps1" -Path "C:\minutes\work\minutes.md"
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\register.ps1" -DryRun
#
# Config (secrets/IDs are NOT stored in the repo): C:\minutes\backlog.config.txt
#   Space=example.backlog.com     # your space host (.backlog.com or .backlog.jp)
#   ProjectId=12345               # numeric id of the target project (ALL)
#   ParentId=019f3bd8...          # parent document id, string from the doc URL (required)
#   AddLast=true                  # add as the last sibling (optional)
#   ApiKey=...                    # optional here; env var BACKLOG_API_KEY wins
# If the file is missing, a starter is created and the script stops.
# The API key is best supplied via the BACKLOG_API_KEY environment variable.
#
# Title: taken from -Title, else the first H1 (# ...) in the Markdown,
#        else the file name. Convention: YYYYMMDD_<name>_gijiroku.
#
# Messages are in English on purpose (PS 5.1 mangles Japanese embedded in a
# .ps1 without a UTF-8 BOM). The document body (Japanese) lives in the .md file.
# =====================================================================

param(
    [string]$Path  = "",
    [string]$Title = "",
    [switch]$DryRun
)

try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# Backlog requires TLS 1.2+; PS 5.1 does not always negotiate it by default.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$base       = "C:\minutes"
$work        = "$base\work"
$configPath = "$base\backlog.config.txt"
$defaultMd  = "$work\minutes.md"

# Read a "key = value" file (UTF-8) into a hashtable with lower-case keys.
# Lines that do not start with a letter/underscore (e.g. comments) are ignored.
function Read-KV($p) {
    $h = @{}
    if (Test-Path $p) {
        foreach ($line in (Get-Content $p -Encoding UTF8)) {
            if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*)$') { $h[$matches[1].ToLower()] = $matches[2].Trim() }
        }
    }
    return $h
}

# Percent-encode one value as application/x-www-form-urlencoded (UTF-8).
# Done at the byte level on purpose: Uri.EscapeDataString throws
# UriFormatException on strings longer than ~65,520 chars in .NET Framework /
# PS 5.1, and the minutes body can easily exceed that.
function Encode-FormValue([string]$s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        if (($b -ge 0x41 -and $b -le 0x5A) -or
            ($b -ge 0x61 -and $b -le 0x7A) -or
            ($b -ge 0x30 -and $b -le 0x39) -or
            $b -eq 0x2D -or $b -eq 0x2E -or $b -eq 0x5F -or $b -eq 0x7E) {
            [void]$sb.Append([char]$b)
        } elseif ($b -eq 0x20) {
            [void]$sb.Append("+")
        } else {
            [void]$sb.Append("%")
            [void]$sb.Append($b.ToString("X2"))
        }
    }
    return $sb.ToString()
}

# Encode a hashtable as an application/x-www-form-urlencoded string.
function Encode-Form($h) {
    $pairs = @()
    foreach ($k in $h.Keys) {
        $pairs += ((Encode-FormValue ([string]$k)) + "=" + (Encode-FormValue ([string]$h[$k])))
    }
    return ($pairs -join "&")
}

# --- 1) Resolve the Markdown file -----------------------------------
$mdPath = if ($Path -ne "") { $Path } else { $defaultMd }
if (-not (Test-Path $mdPath)) {
    Write-Host "[ERROR] Markdown not found: $mdPath" -ForegroundColor Red
    Write-Host "        Save the approved minutes there, or pass -Path <file.md>." -ForegroundColor Yellow
    exit 1
}
$content = Get-Content $mdPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Host "[ERROR] Markdown is empty: $mdPath" -ForegroundColor Red
    exit 1
}

# --- 2) Resolve the title -------------------------------------------
if ($Title -eq "") {
    $inFence = $false
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if (-not $inFence -and $line -match '^\s*#\s+(.+?)\s*#*\s*$') { $Title = $matches[1].Trim(); break }
    }
}
if ($Title -eq "") { $Title = [System.IO.Path]::GetFileNameWithoutExtension($mdPath) }

# --- 3) Config file (create a starter the first time) ---------------
if (-not (Test-Path $configPath)) {
    $starter = @(
        "Space=example.backlog.com",
        "ProjectId=",
        "ParentId=",
        "AddLast=true",
        "# ApiKey is best set as the BACKLOG_API_KEY environment variable.",
        "# You may also put it below, but do NOT commit this file.",
        "ApiKey="
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($configPath, $starter, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[NOTE] Created config: $configPath" -ForegroundColor Yellow
    Write-Host "       Fill Space / ProjectId (and ParentId), set BACKLOG_API_KEY, then re-run." -ForegroundColor Yellow
    try { Start-Process notepad.exe $configPath } catch {}
    exit 0
}
$cfg = Read-KV $configPath

$space    = if ($cfg.ContainsKey("space"))     { $cfg["space"] }     else { "" }
$projectId= if ($cfg.ContainsKey("projectid")) { $cfg["projectid"] } else { "" }
$parentId = if ($cfg.ContainsKey("parentid"))  { $cfg["parentid"] }  else { "" }
$addLast  = if ($cfg.ContainsKey("addlast"))   { $cfg["addlast"] }   else { "true" }

# API key: environment variable wins over the config file.
$apiKey = if ($env:BACKLOG_API_KEY -ne $null) { $env:BACKLOG_API_KEY.Trim() } else { "" }
$apiKeyFromConfig = $false
if ([string]::IsNullOrWhiteSpace($apiKey) -and $cfg.ContainsKey("apikey") -and $cfg["apikey"] -ne "") {
    $apiKey = $cfg["apikey"]
    $apiKeyFromConfig = $true
}

# --- 4) Preview / validate ------------------------------------------
Write-Host ""
Write-Host "=== register to Backlog (document) ===" -ForegroundColor Green
Write-Host ("  File      : " + $mdPath)
Write-Host ("  Title     : " + $Title)
Write-Host ("  Space     : " + $space)
Write-Host ("  ProjectId : " + $projectId)
Write-Host ("  ParentId  : " + $(if ($parentId -ne "") { $parentId } else { "(none)" }))
Write-Host ("  Body      : " + $content.Length + " chars")
Write-Host ("  ApiKey    : " + $(if ($apiKey) { "set" } else { "NOT set" }))
if ($apiKeyFromConfig) { Write-Host "[WARN] ApiKey read from config - prefer the BACKLOG_API_KEY env var, and never commit the config file." -ForegroundColor Yellow }

# Force a dry run if anything required is missing/invalid, so the skeleton is
# testable now and a mistyped config cannot send the key to the wrong host.
$missing = @()
if ($space -eq "" -or $space -eq "example.backlog.com" -or
    $space -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\.backlog\.(com|jp)$') { $missing += "Space (valid *.backlog.com/.jp host)" }
if ($projectId -notmatch '^[0-9]+$')          { $missing += "ProjectId (numeric)" }
if ($parentId  -notmatch '^[0-9A-Za-z]+$')    { $missing += "ParentId (document id)" }
if ($addLast   -notmatch '^(?i:true|false)$') { $missing += "AddLast (true/false)" }
if ([string]::IsNullOrWhiteSpace($apiKey))    { $missing += "ApiKey (BACKLOG_API_KEY)" }
if ($missing.Count -gt 0) {
    Write-Host ("[DRY RUN] Missing: " + ($missing -join ", ") + " - not sending. Fill config and re-run.") -ForegroundColor Yellow
    exit 0
}
if ($DryRun) {
    Write-Host "[DRY RUN] -DryRun set - not sending." -ForegroundColor Yellow
    exit 0
}

# --- 5) POST /api/v2/documents --------------------------------------
$fields = @{
    projectId = $projectId
    title     = $Title
    content   = $content
}
if ($parentId -ne "") { $fields["parentId"] = $parentId }
if ($addLast  -ne "") { $fields["addLast"]  = $addLast.ToLower() }

$uri  = "https://" + $space + "/api/v2/documents?apiKey=" + [System.Uri]::EscapeDataString($apiKey)
$body = [System.Text.Encoding]::UTF8.GetBytes((Encode-Form $fields))

try {
    $res = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType "application/x-www-form-urlencoded; charset=utf-8" -TimeoutSec 60 -ErrorAction Stop
} catch {
    Write-Host "[ERROR] Backlog API call failed:" -ForegroundColor Red
    Write-Host ("        " + $_.Exception.Message) -ForegroundColor Red
    $resp = $_.Exception.Response
    if ($resp -ne $null) {
        try {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { $detail = $reader.ReadToEnd() } finally { $reader.Dispose(); $resp.Dispose() }
            if ($detail) { Write-Host ("        " + $detail) -ForegroundColor Red }
        } catch {}
    }
    exit 1
}

Write-Host ""
Write-Host "=== registered ===" -ForegroundColor Green
Write-Host ("  Document id : " + $res.id) -ForegroundColor Green
Write-Host ("  Title       : " + $res.title) -ForegroundColor Green
Write-Host ("  Open Backlog and verify the document was created correctly.") -ForegroundColor Cyan
# TODO (see Backlog-tsushin-teigi.md spec): duplicate-title check, approval.json gate,
#      title normalization (NFC), post-registration verification.
