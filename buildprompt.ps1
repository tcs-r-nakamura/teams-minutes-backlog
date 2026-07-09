# =====================================================================
# minutes buildprompt script
#
# Builds a ready-to-send AI prompt from prompt_template.txt + transcript.txt.
# Non-interactive: values are substituted from files, no questions are asked.
#
#   - Meeting date : auto from the recording timestamp (source.txt, written by
#                    transcribe.ps1). Override with Date= in meeting.txt.
#   - Meeting no.  : sequential counter (meeting_no.txt), keyed to the recording
#                    so re-running on the SAME recording keeps the number; a new
#                    recording increments it. Override with No= in meeting.txt.
#   - Link/Speaker : from work\meeting.txt (cannot be derived automatically).
#
# On first run a starter meeting.txt (Link/Speaker blank) is created and opened;
# fill Link / Speaker there and re-run. No/Date are auto (add No=/Date= only to
# override).
#
# Run:
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\buildprompt.ps1"
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\buildprompt.ps1" -NoOpen   # no notepad (automation)
#
# Messages are in English on purpose (PS 5.1 mangles Japanese embedded in a
# .ps1 without a UTF-8 BOM). Japanese text lives in prompt_template.txt /
# field_labels.txt / meeting.txt.
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
$mtgPath = "$work\meeting.txt"

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

# 3) meeting.txt holds Link/Speaker (+ optional No/Date overrides). Create a
#    starter the first time. No/Date are NOT written here on purpose: they are
#    auto (recording + counter) so they never go stale for the next recording.
#    Add No= or Date= to meeting.txt only to override the auto value.
$firstTime = -not (Test-Path $mtgPath)
if ($firstTime) {
    $starter = "Link=`r`nSpeaker=`r`n# No and Date are auto; add No= or Date= below only to override.`r`n"
    [System.IO.File]::WriteAllText($mtgPath, $starter, (New-Object System.Text.UTF8Encoding($false)))
}
$mtg = Read-KV $mtgPath

# meeting.txt wins over the auto value when present and non-empty.
$no   = if ($mtg.ContainsKey("no")   -and $mtg["no"]   -ne "") { $mtg["no"] }   else { [string]$autoNo }
$date = if ($mtg.ContainsKey("date") -and $mtg["date"] -ne "") { $mtg["date"] } else { $autoDate }
$link = if ($mtg.ContainsKey("link")) { $mtg["link"] } else { "" }
$spk  = if ($mtg.ContainsKey("speaker")) { $mtg["speaker"] } else { "" }

# Persist the number used, keyed to this recording (for re-run detection above).
# Only when we actually have a recording key, so standalone runs (no source.txt)
# do not corrupt the counter.
if ($srcKey -ne "") {
    $noOut = "No=" + $no + "`r`nKey=" + $srcKey + "`r`n"
    try { [System.IO.File]::WriteAllText($noPath, $noOut, (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

# Field labels (Japanese) are read from field_labels.txt (UTF-8) so the .ps1
# can stay ASCII-only. English fallbacks are used if the file is missing.
$L = @{
    meeting_no    = "Meeting number"
    meeting_date  = "Meeting date"
    rec_link      = "Recording link"
    speaker       = "Speaker(s)"
}
$labelFile = "$base\field_labels.txt"
if (-not (Test-Path $labelFile)) { $labelFile = Join-Path $PSScriptRoot "field_labels.txt" }
if (Test-Path $labelFile) {
    foreach ($line in (Get-Content $labelFile -Encoding UTF8)) {
        if ($line -match '^\s*([a-z_]+)\s*=\s*(.+)$') { $L[$matches[1]] = $matches[2].Trim() }
    }
}

# Short field name for the summary: drop the hint part after "(" or full-width "(".
# The full-width paren is built from its code point so this .ps1 stays ASCII-only.
function Get-ShortLabel($s) {
    $fp = [char]0xFF08
    (($s -replace ([regex]::Escape($fp) + '.*$'), '') -replace '\(.*$', '').Trim()
}

Write-Host ""
Write-Host "=== build AI prompt ===" -ForegroundColor Green
Write-Host ("  " + (Get-ShortLabel $L.meeting_no)   + " : " + $no)
Write-Host ("  " + (Get-ShortLabel $L.meeting_date) + " : " + $date)
Write-Host ("  " + (Get-ShortLabel $L.rec_link)     + " : " + $link)
Write-Host ("  " + (Get-ShortLabel $L.speaker)      + " : " + $spk)
Write-Host ("  (values from: " + $mtgPath + ")") -ForegroundColor DarkGray
if ($firstTime) {
    Write-Host ("[NOTE] Created " + $mtgPath + " (No/Date are auto).") -ForegroundColor Yellow
    Write-Host "       Fill Link / Speaker there, then re-run buildprompt.ps1." -ForegroundColor Yellow
} else {
    if ($link -eq "") { Write-Host "[WARN] Link is blank - edit meeting.txt and re-run to include it." -ForegroundColor Yellow }
    if ($spk  -eq "") { Write-Host "[WARN] Speaker is blank - edit meeting.txt and re-run to include it." -ForegroundColor Yellow }
}

$tplText = Get-Content $tpl -Encoding UTF8 -Raw
$txt     = Get-Content $txtPath -Encoding UTF8 -Raw

# Literal string replace (.Replace, NOT -replace) so URLs containing $ & % are safe.
$out = $tplText
$out = $out.Replace('{{MEETING_NO}}',   $no)
$out = $out.Replace('{{MEETING_DATE}}', $date)
$out = $out.Replace('{{REC_LINK}}',     $link)
$out = $out.Replace('{{SPEAKER}}',      $spk)
$out = $out.Replace('{{TRANSCRIPT}}',   $txt)

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

# First run: open meeting.txt so the user can fill Link/Speaker. Otherwise open
# the finished prompt. -NoOpen suppresses this (for automation).
if (-not $NoOpen) {
    if ($firstTime) {
        try { Start-Process notepad.exe $mtgPath } catch {}
    } else {
        try { Start-Process notepad.exe $outPath } catch {}
    }
}
