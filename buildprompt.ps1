# =====================================================================
# minutes buildprompt script
#
# Builds a ready-to-send AI prompt from prompt_template.txt + transcript.txt.
# You enter the meeting info; the script fills the template, saves
# work\ai_prompt.txt, copies it to the clipboard, and opens it.
#
# Run (usually called automatically at the end of transcribe.ps1):
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\buildprompt.ps1"
#
# Messages are in English on purpose (PS 5.1 mangles Japanese embedded in a
# .ps1 without a UTF-8 BOM). All Japanese text lives in prompt_template.txt.
# =====================================================================

try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$base    = "C:\minutes"
$work    = "$base\work"
$txtPath = "$work\transcript.txt"
$outPath = "$work\ai_prompt.txt"

# Locate the template: prefer C:\minutes, fall back to this script's folder.
$tpl = "$base\prompt_template.txt"
if (-not (Test-Path $tpl)) { $tpl = Join-Path $PSScriptRoot "prompt_template.txt" }

# Preconditions
if (-not (Test-Path $txtPath)) { Write-Host "[ERROR] transcript.txt not found: $txtPath  (run transcribe.ps1 first)" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $tpl))     { Write-Host "[ERROR] prompt_template.txt not found (run setup.ps1)" -ForegroundColor Red; exit 1 }

# Field labels (Japanese) are read from field_labels.txt (UTF-8) so the .ps1
# can stay ASCII-only. English fallbacks are used if the file is missing.
$L = @{
    meeting_no    = "Meeting number (digits only, e.g. 1)"
    meeting_date  = "Meeting date (YYYY/MM/DD)"
    rec_link      = "Recording link (blank = none)"
    speaker       = "Speaker(s), full name (blank = none)"
    review_header = "Review"
    confirm       = "Create with this? (y = yes, other = re-enter)"
}
$labelFile = "$base\field_labels.txt"
if (-not (Test-Path $labelFile)) { $labelFile = Join-Path $PSScriptRoot "field_labels.txt" }
if (Test-Path $labelFile) {
    foreach ($line in (Get-Content $labelFile -Encoding UTF8)) {
        if ($line -match '^\s*([a-z_]+)\s*=\s*(.+)$') { $L[$matches[1]] = $matches[2].Trim() }
    }
}

Write-Host ""
Write-Host "=== build AI prompt ===" -ForegroundColor Green

# Short field name for the summary: drop the hint part after "(" or full-width "(".
# The full-width paren is built from its code point so this .ps1 stays ASCII-only.
function Get-ShortLabel($s) {
    $fp = [char]0xFF08
    (($s -replace ([regex]::Escape($fp) + '.*$'), '') -replace '\(.*$', '').Trim()
}

# Collect, show a summary, and let the user re-enter until it is confirmed.
do {
    $no   = (Read-Host $L.meeting_no).Trim()
    $date = (Read-Host $L.meeting_date).Trim()
    $link = (Read-Host $L.rec_link).Trim()
    $spk  = (Read-Host $L.speaker).Trim()

    Write-Host ""
    Write-Host ("--- " + $L.review_header + " ---") -ForegroundColor Cyan
    Write-Host ("  " + (Get-ShortLabel $L.meeting_no)   + " : " + $no)
    Write-Host ("  " + (Get-ShortLabel $L.meeting_date) + " : " + $date)
    Write-Host ("  " + (Get-ShortLabel $L.rec_link)     + " : " + $link)
    Write-Host ("  " + (Get-ShortLabel $L.speaker)      + " : " + $spk)
    Write-Host ""
    $ans = (Read-Host $L.confirm).Trim()
} while ($ans -ne "y" -and $ans -ne "Y")

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

try { Start-Process notepad.exe $outPath } catch {}
