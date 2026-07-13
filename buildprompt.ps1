# =====================================================================
# minutes buildprompt script
#
# Builds a ready-to-send AI prompt from prompt_template.txt + transcript.txt.
# Non-interactive: values are substituted from files, no questions are asked.
#
#   - Meeting date : auto from the recording timestamp (source.txt, written by
#                    transcribe.ps1).
#   - Meeting no.  : sequential counter (meeting_no.txt), keyed to the recording
#                    so re-running on the SAME recording keeps the number; a new
#                    recording increments it.
#   - Recording link : the shared Cybozu folder URL (RecFolderUrl) from
#                    backlog.config.txt.
#   - Speaker      : left blank; the AI infers it from the transcript (the
#                    template marks inferred names to verify).
#
# All four values are automatic - there is nothing to fill in by hand.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\buildprompt.ps1"
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\buildprompt.ps1" -NoOpen   # no notepad (automation)
#
# Messages are in English on purpose (PS 5.1 mangles Japanese embedded in a
# .ps1 without a UTF-8 BOM). Japanese text lives in prompt_template.txt.
# =====================================================================

param(
    [switch]$NoOpen
)

try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$base    = "C:\minutes"
$work    = "$base\work"
$txtPath = "$work\transcript.txt"
$outPath = "$work\ai_prompt.txt"
$srcPath = "$work\source.txt"
$noPath  = "$work\meeting_no.txt"

# Locate the template: prefer C:\minutes, fall back to this script's folder.
$tpl = "$base\prompt_template.txt"
if (-not (Test-Path $tpl)) { $tpl = Join-Path $PSScriptRoot "prompt_template.txt" }

# Preconditions
if (-not (Test-Path $txtPath)) { Write-Host "[ERROR] transcript.txt not found: $txtPath  (run transcribe.ps1 first)" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $tpl))     { Write-Host "[ERROR] prompt_template.txt not found (run setup.ps1)" -ForegroundColor Red; exit 1 }

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

# Recursively find a document node by id within a Backlog document tree
# (nodes have id / name / children[]). Handles a single node or an array.
function Find-DocNode($node, $id) {
    foreach ($n in @($node)) {
        if ($n -eq $null) { continue }
        if ([string]$n.id -eq [string]$id) { return $n }
        if ($n.children) {
            $found = Find-DocNode $n.children $id
            if ($found -ne $null) { return $found }
        }
    }
    return $null
}

# Meeting number from Backlog, so it is correct for everyone on any machine (the
# local counter starts at 1 per PC and cannot know the true number on a fresh
# setup). The parent doc's existing minutes titles carry a "dai N kai" marker, so
# the next meeting is max(N)+1. If THIS meeting's date already appears in a
# sibling title, reuse that sibling's number (a re-run on an already-registered
# meeting must not bump the count). Returns $null on ANY failure (no key, network
# error, parent not found) so the caller falls back to the local counter.
function Get-BacklogMeetingNo($space, $projectId, $parentId, $apiKey, $dateToken) {
    if ($space -eq "" -or $projectId -eq "" -or $parentId -eq "" -or $apiKey -eq "") { return $null }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    try {
        $uri  = "https://" + $space + "/api/v2/documents/tree?projectIdOrKey=" + [System.Uri]::EscapeDataString($projectId) + "&apiKey=" + [System.Uri]::EscapeDataString($apiKey)
        $tree = Invoke-RestMethod -Uri $uri -TimeoutSec 60 -ErrorAction Stop
    } catch { return $null }
    $parentNode = Find-DocNode $tree.activeTree $parentId
    if ($parentNode -eq $null) { return $null }
    $kids = @()
    if ($parentNode.children) { $kids = @($parentNode.children) }
    # "dai N kai" pattern, built from code points so this .ps1 stays ASCII-only.
    $dai = [char]0x7B2C
    $kai = [char]0x56DE
    $pat = "$dai([0-9]+)$kai"
    $maxNo = 0
    $existing = $null
    foreach ($c in $kids) {
        $nm = "" + $c.name
        if ($nm -match $pat) {
            $n = [int]$matches[1]
            if ($n -gt $maxNo) { $maxNo = $n }
            if ($dateToken -ne "" -and $nm -like ("*" + $dateToken + "*")) { $existing = $n }
        }
    }
    if ($existing -ne $null) { return $existing }
    return ($maxNo + 1)
}

# 1) Auto values from the recording (written by transcribe.ps1 into source.txt).
$src      = Read-KV $srcPath
$autoDate = if ($src.ContainsKey("date")) { $src["date"] } else { "" }
$srcKey   = if ($src.ContainsKey("key"))  { $src["key"] }  else { "" }

# 2) Sequential meeting number, keyed to the recording so a re-run on the same
#    recording reuses the number instead of bumping it.
$prev   = Read-KV $noPath
$lastNo = 0
if ($prev.ContainsKey("no")) { [void][int]::TryParse($prev["no"], [ref]$lastNo) }
$lastKey = if ($prev.ContainsKey("key")) { $prev["key"] } else { "" }
if ($srcKey -eq "") {
    # No recording info (buildprompt run without transcribe): reuse the last
    # number and do NOT bump the counter.
    $autoNo = if ($lastNo -gt 0) { $lastNo } else { 1 }
} elseif ($srcKey -eq $lastKey) {
    $autoNo = $lastNo          # same recording -> re-run, keep the number
} else {
    $autoNo = $lastNo + 1      # new recording -> next number
}

# 3) Recording link + meeting number from config/Backlog. Speaker is left blank
#    so the AI infers it (the template marks inferred names to verify). Date
#    comes from the recording (source.txt).
$cfgPath = "$base\backlog.config.txt"
if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $PSScriptRoot "backlog.config.txt" }
$cfg     = Read-KV $cfgPath
$defLink = if ($cfg.ContainsKey("recfolderurl")) { $cfg["recfolderurl"] } else { "" }

# Meeting number: prefer Backlog (max existing "dai N kai" + 1) so it is correct
# for any user/machine; fall back to the local counter when offline / no API key.
$space     = if ($cfg.ContainsKey("space"))     { $cfg["space"] }     else { "" }
$projectId = if ($cfg.ContainsKey("projectid")) { $cfg["projectid"] } else { "" }
$parentId  = if ($cfg.ContainsKey("parentid"))  { $cfg["parentid"] }  else { "" }
$apiKey    = if ($env:BACKLOG_API_KEY -ne $null) { $env:BACKLOG_API_KEY.Trim() } else { "" }
$dateToken = ($autoDate -replace '[^0-9]', '')   # yyyy/MM/dd -> yyyyMMdd
$blNo      = Get-BacklogMeetingNo $space $projectId $parentId $apiKey $dateToken
$noSource  = if ($blNo -ne $null) { "Backlog" } else { "local counter" }

# Teams transcript + speaker list (written by transcribe.ps1 when a .vtt exists).
# When present, the Teams speaker names fill the Speaker field (authoritative) and
# both transcripts are sent to the AI to cross-check; when absent, whisper only.
$teamsTxtPath = "$work\transcript_teams.txt"
$spkTxtPath   = "$work\speakers.txt"
$teamsText = ""
$teamsSpk  = ""
if (Test-Path $teamsTxtPath) { $teamsText = (Get-Content $teamsTxtPath -Encoding UTF8 -Raw) }
if (Test-Path $spkTxtPath)   { $teamsSpk  = (Get-Content $spkTxtPath   -Encoding UTF8 -Raw).Trim() }
$hasTeams = ($teamsText.Trim() -ne "")

$no   = if ($blNo -ne $null) { [string]$blNo } else { [string]$autoNo }
$date = $autoDate
$link = $defLink
$spk  = if ($hasTeams) { $teamsSpk } else { "" }   # Teams speakers -> Speaker field

# Persist the LOCAL counter value, keyed to this recording, so the offline
# fallback stays consistent regardless of what Backlog returned this run. Only
# when we have a recording key (standalone runs must not corrupt the counter).
if ($srcKey -ne "") {
    $noOut = "No=" + $autoNo + "`r`nKey=" + $srcKey + "`r`n"
    try { [System.IO.File]::WriteAllText($noPath, $noOut, (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

Write-Host ""
Write-Host "=== build AI prompt ===" -ForegroundColor Green
Write-Host ("  Meeting number : " + $no + "  (from " + $noSource + ")")
Write-Host ("  Meeting date   : " + $date)
Write-Host ("  Recording link : " + $link)
if ($hasTeams) {
    Write-Host ("  Speaker        : " + $spk + "  (from Teams transcript)")
} else {
    Write-Host ("  Speaker        : " + $spk + "  (blank -> AI infers)")
}
if ($hasTeams) {
    Write-Host "  Transcript     : Teams + whisper (cross-checked)" -ForegroundColor Green
} else {
    Write-Host "  Transcript     : whisper only (no Teams .vtt)" -ForegroundColor DarkGray
}
if ($link -eq "") { Write-Host "[WARN] Link is blank - add RecFolderUrl to backlog.config.txt." -ForegroundColor Yellow }
if ($blNo -eq $null) { Write-Host "[NOTE] Meeting number is from the local counter (Backlog not reachable / no API key), so it may not match the true number on a fresh setup. Set BACKLOG_API_KEY for the correct number." -ForegroundColor DarkGray }

$tplText = Get-Content $tpl -Encoding UTF8 -Raw
$txt     = Get-Content $txtPath -Encoding UTF8 -Raw

# Literal string replace (.Replace, NOT -replace) so URLs containing $ & % are safe.
# Teams transcript block: the parsed text when present, else an ASCII "(none)"
# marker (kept ASCII so this .ps1 stays ASCII-only; the template's Japanese guide
# tells the AI that "(none)" means "use whisper only").
$teamsBlock = if ($hasTeams) { $teamsText } else { "(none)" }

$out = $tplText
$out = $out.Replace('{{MEETING_NO}}',         $no)
$out = $out.Replace('{{MEETING_DATE}}',       $date)
$out = $out.Replace('{{REC_LINK}}',           $link)
$out = $out.Replace('{{SPEAKER}}',            $spk)
$out = $out.Replace('{{TEAMS_TRANSCRIPT}}',   $teamsBlock)
$out = $out.Replace('{{WHISPER_TRANSCRIPT}}', $txt)
# Back-compat: if an old template still uses {{TRANSCRIPT}}, fill it with whisper.
$out = $out.Replace('{{TRANSCRIPT}}',         $txt)

# Write UTF-8 without BOM
[System.IO.File]::WriteAllText($outPath, $out, (New-Object System.Text.UTF8Encoding($false)))

$copied = $false
try { Set-Clipboard -Value $out; $copied = $true } catch {}

Write-Host ""
Write-Host "=== AI prompt ready ===" -ForegroundColor Green
Write-Host ("Saved     : " + $outPath) -ForegroundColor Green
if ($copied) {
    Write-Host "Clipboard : copied - just paste into the approved AI" -ForegroundColor Green
} else {
    Write-Host "Clipboard : not copied - copy the text from the opened file" -ForegroundColor Yellow
}
Write-Host "Check the meeting name / speaker in the opened file, then send it to the AI." -ForegroundColor Cyan

# Open the finished prompt for a quick look. -NoOpen suppresses this (automation).
if (-not $NoOpen) {
    try { Start-Process notepad.exe $outPath } catch {}
}
