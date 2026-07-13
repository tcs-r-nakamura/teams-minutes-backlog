# =====================================================================
# minutes draft script (Sakura AI Engine)
#
# Sends the built prompt (work\ai_prompt.txt) to the Sakura AI Engine
# OpenAI-compatible Chat Completions API and saves the returned Markdown
# minutes draft to work\minutes.md. This automates the previously manual
# "paste the prompt into ChatGPT and download the .md" step.
#
# The human pre-publication check and Backlog registration stay manual and
# unchanged: this only produces a DRAFT for a person to review.
#
# Auth : environment variable SAKURA_AI_TOKEN ("<UUID>:<secret>"). Never
#        stored in files. Set once with:  setx SAKURA_AI_TOKEN "<uuid>:<secret>"
# Config (non-secret) read from backlog.config.txt (all optional; defaults shown):
#   SakuraBaseUrl   = https://api.ai.sakura.ad.jp/v1
#   SakuraModel     = gpt-oss-120b
#   SakuraMaxTokens = 8000
#   SakuraTemp      = 0.3
#
# Run:
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\draft.ps1"
#
# Messages are in English on purpose (PS 5.1 mangles Japanese in a .ps1
# without a UTF-8 BOM). Japanese lives in the prompt/response data files.
# =====================================================================

param(
    [string]$PromptPath = "C:\minutes\work\ai_prompt.txt",
    [string]$OutPath    = "C:\minutes\work\minutes.md"
)

try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$base = "C:\minutes"

# Read a "key = value" file (UTF-8) into a hashtable with lower-case keys.
function Read-KV($path) {
    $h = @{}
    if (Test-Path $path) {
        foreach ($line in (Get-Content $path -Encoding UTF8)) {
            if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*)$') { $h[$matches[1].ToLower()] = $matches[2].Trim() }
        }
    }
    return $h
}

# Preconditions
if (-not (Test-Path $PromptPath)) {
    Write-Host "[ERROR] prompt not found: $PromptPath  (run the prompt stage first)" -ForegroundColor Red; exit 1
}
# Read the token from the process env; fall back to the User/Machine scope so a
# fresh `setx` value works even in a PowerShell window that was opened earlier
# (setx only populates the process env of NEW windows).
$token = ""
if ($env:SAKURA_AI_TOKEN) { $token = $env:SAKURA_AI_TOKEN.Trim() }
if ($token -eq "") { $t = [Environment]::GetEnvironmentVariable("SAKURA_AI_TOKEN","User");    if ($t) { $token = $t.Trim() } }
if ($token -eq "") { $t = [Environment]::GetEnvironmentVariable("SAKURA_AI_TOKEN","Machine"); if ($t) { $token = $t.Trim() } }
if ($token -eq "") {
    Write-Host "[ERROR] SAKURA_AI_TOKEN is not set. Set it once (then reopen PowerShell):" -ForegroundColor Red
    Write-Host '        setx SAKURA_AI_TOKEN "<UUID>:<secret>"' -ForegroundColor Yellow
    exit 1
}

# Non-secret config
$cfgPath = "$base\backlog.config.txt"
if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $PSScriptRoot "backlog.config.txt" }
$cfg = Read-KV $cfgPath
$baseUrl = if ($cfg.ContainsKey("sakurabaseurl")) { $cfg["sakurabaseurl"] } else { "https://api.ai.sakura.ad.jp/v1" }
$model   = if ($cfg.ContainsKey("sakuramodel"))   { $cfg["sakuramodel"] }   else { "gpt-oss-120b" }
$maxTok  = 8000
if ($cfg.ContainsKey("sakuramaxtokens")) { [void][int]::TryParse($cfg["sakuramaxtokens"], [ref]$maxTok) }
$temp    = 0.3
if ($cfg.ContainsKey("sakuratemp")) {
    $t = 0.0
    if ([double]::TryParse($cfg["sakuratemp"], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$t)) { $temp = $t }
}

# Host allowlist (defense in depth): only ever send to the approved API host.
try {
    $u = [System.Uri]$baseUrl
    if ($u.Scheme -ne "https" -or $u.Host -notmatch '(^|\.)sakura\.ad\.jp$') {
        Write-Host ("[ERROR] SakuraBaseUrl host not allowed: " + $u.Host) -ForegroundColor Red; exit 1
    }
} catch {
    Write-Host "[ERROR] invalid SakuraBaseUrl in config" -ForegroundColor Red; exit 1
}

# Read as a pure .NET string. NOT Get-Content -Raw: that returns a string decorated
# with PowerShell note-properties (PSPath, etc.), which ConvertTo-Json would then
# serialize INTO the "content" field as an object (malformed request).
$prompt = [System.IO.File]::ReadAllText($PromptPath, [System.Text.Encoding]::UTF8)
if ($prompt.Trim() -eq "") { Write-Host "[ERROR] prompt file is empty: $PromptPath" -ForegroundColor Red; exit 1 }

# Build the request body and send UTF-8 bytes (so Japanese is not mangled).
$body = @{
    model       = $model
    messages    = @(@{ role = "user"; content = $prompt })
    temperature = $temp
    max_tokens  = $maxTok
}
$json  = $body | ConvertTo-Json -Depth 6 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

$uri = $baseUrl.TrimEnd('/') + "/chat/completions"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Write-Host ""
Write-Host "=== AI draft (Sakura AI Engine) ===" -ForegroundColor Green
Write-Host ("Endpoint : " + $uri)
Write-Host ("Model    : " + $model)
Write-Host ("Prompt   : {0} chars" -f $prompt.Length)
Write-Host "Sending... (may take a while for long meetings; do not close this window)" -ForegroundColor Cyan

# POST helper that forces UTF-8 decode of the RESPONSE. NOT Invoke-RestMethod:
# on PS 5.1 it decodes a body without an explicit charset as ISO-8859-1, which
# garbles the Japanese in the returned minutes. HttpWebRequest + a UTF-8
# StreamReader reads the bytes correctly. Returns the raw response text.
function Invoke-ChatPost($u, $tok, $bodyBytes, $timeoutMs) {
    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.Method = "POST"
    $req.ContentType = "application/json"
    $req.Accept = "application/json"
    $req.Headers.Add("Authorization", "Bearer " + $tok)
    $req.Timeout = $timeoutMs
    $req.ReadWriteTimeout = $timeoutMs
    # Do not follow redirects: the host allowlist is checked on the initial URL
    # only, so auto-following a 3xx could send the request (and Authorization) to
    # a non-approved host. A 3xx then fails safely (body is not JSON).
    $req.AllowAutoRedirect = $false
    $rs = $req.GetRequestStream()
    try { $rs.Write($bodyBytes, 0, $bodyBytes.Length) } finally { $rs.Close() }
    $resp = $req.GetResponse()
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Close() }
    } finally { $resp.Close() }
}

$respText = $null
$maxAttempts = 4
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $respText = Invoke-ChatPost $uri $token $bytes 300000
        break
    } catch [System.Net.WebException] {
        $code = 0
        $webResp = $_.Exception.Response
        if ($webResp) {
            try { $code = [int]$webResp.StatusCode } catch {}
            try { $webResp.Close() } catch {}   # release the connection before retrying
        }
        $retriable = ($code -eq 429 -or ($code -ge 500 -and $code -le 599) -or $code -eq 0)
        if ($attempt -lt $maxAttempts -and $retriable) {
            $wait = [int][math]::Pow(2, $attempt)
            Write-Host ("[WARN] attempt " + $attempt + " failed (HTTP " + $code + "); retrying in " + $wait + "s...") -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        } else {
            Write-Host ("[ERROR] Chat Completions request failed (HTTP " + $code + "): " + $_.Exception.Message) -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host ("[ERROR] Chat Completions request error: " + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

$resp = $null
try { $resp = $respText | ConvertFrom-Json } catch { Write-Host "[ERROR] could not parse API response as JSON." -ForegroundColor Red; exit 1 }
$content = ""
try { $content = [string]$resp.choices[0].message.content } catch {}
if ($content -eq $null -or $content.Trim() -eq "") {
    Write-Host "[ERROR] empty response from the model." -ForegroundColor Red; exit 1
}

# If the model wrapped the whole answer in a Markdown code fence, unwrap it.
$content = $content.Trim()
if ($content -match '^```[A-Za-z]*\s*\r?\n') {
    $content = $content -replace '^```[A-Za-z]*\s*\r?\n', ''
    $content = $content -replace '\r?\n```\s*$', ''
    $content = $content.Trim()
}

# Save UTF-8 without BOM
[System.IO.File]::WriteAllText($OutPath, $content, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "=== draft saved ===" -ForegroundColor Green
Write-Host ("Saved : " + $OutPath + ("  ({0} chars)" -f $content.Length)) -ForegroundColor Green
Write-Host "Next  : do the pre-publication review (Step B-4), then register:" -ForegroundColor Cyan
Write-Host '        powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1" -To register' -ForegroundColor Cyan
