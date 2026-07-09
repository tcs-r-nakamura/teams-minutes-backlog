# =====================================================================
# minutes transcribe script
#
# Usage:
#   1) Put the recording (.mp4) into  C:\minutes\work
#   2) (Optional) Edit  C:\minutes\work\names.txt  (save as UTF-8)
#      to list participant names as a recognition hint.
#   3) Run:
#        powershell -ExecutionPolicy Bypass -File "C:\minutes\transcribe.ps1"
#
# Output:  C:\minutes\work\transcript.txt / .srt / .vtt
# Note: messages are in English on purpose (PowerShell 5.1 mangles
#       Japanese text embedded in a .ps1 without a UTF-8 BOM).
# =====================================================================

param(
    [switch]$Auto
)

# Use UTF-8 for console (best effort for Japanese in the transcript)
try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$base  = "C:\minutes"
$work  = "$base\work"
$cli   = "$base\tools\whisper\Release\whisper-cli.exe"
$model = "$base\tools\whisper\models\ggml-medium.bin"

# Refresh PATH so ffmpeg/ffprobe are found in a fresh session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

function Notify-Done {
    # Short two-tone beep so you notice completion while doing other work.
    try { [console]::Beep(1000, 350); [console]::Beep(1300, 450) } catch {}
}

# Keep the window open when double-clicked, so results stay visible.
# In -Auto (unattended) mode this is skipped so nothing waits for input.
function Pause-End {
    if ($Auto) { return }
    if ($Host.Name -eq "ConsoleHost") {
        try { Read-Host "Press Enter to close" | Out-Null } catch {}
    }
}

# Preconditions - fail early with a clear message
if (-not (Test-Path $work)) { Write-Host "[ERROR] work folder not found: $work  (run setup.ps1 first)" -ForegroundColor Red; Pause-End; exit 1 }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Host "[ERROR] ffmpeg not found (run setup.ps1, or open a new PowerShell)" -ForegroundColor Red; Pause-End; exit 1 }
if (-not (Test-Path $cli))   { Write-Host "[ERROR] whisper-cli.exe not found: $cli  (run setup.ps1)" -ForegroundColor Red; Pause-End; exit 1 }
if (-not (Test-Path $model)) { Write-Host "[ERROR] model not found: $model  (run setup.ps1)" -ForegroundColor Red; Pause-End; exit 1 }

# Pick the recording (.mp4) in work.
#   - 0 files : error
#   - 1 file  : use it automatically
#   - 2+ files: show a numbered list and let the user choose
$mp4s = @(Get-ChildItem "$work\*.mp4" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($mp4s.Count -eq 0) { Write-Host "[ERROR] No .mp4 found in $work" -ForegroundColor Red; Pause-End; exit 1 }
if ($mp4s.Count -eq 1) {
    $rec = $mp4s[0]
} elseif ($Auto) {
    # -Auto: do not prompt; use the newest recording (list is sorted desc).
    $rec = $mp4s[0]
    Write-Host ("Auto-selected newest recording: " + $rec.Name) -ForegroundColor Cyan
} else {
    Write-Host "Recordings in work:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $mp4s.Count; $i++) {
        $sizeMB = [math]::Round($mp4s[$i].Length / 1MB)
        Write-Host ("  [{0}] {1}  ({2} MB, {3})" -f ($i + 1), $mp4s[$i].Name, $sizeMB, $mp4s[$i].LastWriteTime)
    }
    $sel = 0
    while ($sel -lt 1 -or $sel -gt $mp4s.Count) {
        $ans = Read-Host ("Enter number (1-{0})" -f $mp4s.Count)
        [void][int]::TryParse($ans, [ref]$sel)
    }
    $rec = $mp4s[$sel - 1]
}

# Record which recording is used, so buildprompt.ps1 can auto-fill the meeting
# date (file timestamp) and key the sequential meeting number (timestamp+size,
# not the name, since Teams recordings often share a name).
$srcKey  = "" + $rec.LastWriteTime.Ticks + "_" + $rec.Length
$srcMeta = "Name=" + $rec.Name + "`r`nDate=" + $rec.LastWriteTime.ToString("yyyy/MM/dd") + "`r`nKey=" + $srcKey + "`r`n"
# source.txt is the basis for the meeting date/number, so a failed write must
# stop (otherwise buildprompt would read a stale source.txt from a prior run).
try {
    [System.IO.File]::WriteAllText("$work\source.txt", $srcMeta, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host ("[ERROR] could not write source.txt (needed for date/number): " + $_) -ForegroundColor Red
    Pause-End; exit 1
}

# Recording duration (via ffprobe) so we can show an ETA (~1x realtime).
$durText = "unknown"
$etaText = "unknown"
try {
    $durRaw = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $rec.FullName 2>$null
    $durSec = 0.0
    if ([double]::TryParse([string]$durRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$durSec) -and $durSec -gt 0) {
        $ts = [TimeSpan]::FromSeconds($durSec)
        $durText = "{0:00}:{1:00}:{2:00}" -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
        $etaText = "about {0} min" -f [math]::Ceiling($durSec / 60.0)
    }
} catch {}

Write-Host ""
Write-Host "=== minutes transcribe ===" -ForegroundColor Green
Write-Host ("Recording : " + $rec.Name) -ForegroundColor Cyan
Write-Host ("Duration  : " + $durText) -ForegroundColor Cyan
Write-Host ("Est. time : " + $etaText + " (~1x realtime, CPU)") -ForegroundColor Cyan

# Read name hint (UTF-8) if present
$names = ""
$namesPath = "$work\names.txt"
if (Test-Path $namesPath) { $names = (Get-Content $namesPath -Encoding UTF8 -Raw).Trim() }
if ($names) { Write-Host ("Name hint : " + $names) -ForegroundColor DarkGray }

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 1) Extract audio (16kHz mono WAV)
Write-Host ""
Write-Host "[1/3] Extracting audio..." -ForegroundColor Cyan
ffmpeg -y -loglevel error -i $rec.FullName -ar 16000 -ac 1 -c:a pcm_s16le "$work\transcript.wav"
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] ffmpeg failed (exit $LASTEXITCODE)" -ForegroundColor Red; Pause-End; exit 1 }

# 2) Transcribe (Japanese). Uses --prompt when names.txt exists.
Write-Host ""
Write-Host ("[2/3] Transcribing in Japanese... (" + $etaText + ")") -ForegroundColor Cyan
Write-Host "      *** Do NOT close this window. It is working; just wait. ***" -ForegroundColor Yellow
if ($names) {
    & $cli -m $model -f "$work\transcript.wav" -l ja --prompt $names --carry-initial-prompt -otxt -osrt -ovtt -pp -of "$work\transcript"
} else {
    & $cli -m $model -f "$work\transcript.wav" -l ja -otxt -osrt -ovtt -pp -of "$work\transcript"
}
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] whisper-cli failed (exit $LASTEXITCODE)" -ForegroundColor Red; Pause-End; exit 1 }

# 3) Show result
if (-not (Test-Path "$work\transcript.txt")) { Write-Host "[ERROR] transcript.txt was not produced" -ForegroundColor Red; Pause-End; exit 1 }
$sw.Stop()

$txt = Get-Content "$work\transcript.txt" -Encoding UTF8 -Raw
Write-Host ""
Write-Host "[3/3] transcript.txt :" -ForegroundColor Green
Write-Host $txt

Notify-Done
Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Green
$el = $sw.Elapsed
Write-Host ("Elapsed : {0:00}:{1:00}:{2:00}" -f [math]::Floor($el.TotalHours), $el.Minutes, $el.Seconds) -ForegroundColor Green
Write-Host ("Output  : $work\transcript.txt  ({0} chars)" -f $txt.Length) -ForegroundColor Green
Write-Host ("          $work\transcript.srt / .vtt (with timestamps)") -ForegroundColor DarkGray

# Build the ready-to-send AI prompt (non-interactive; fills the template from
# meeting.txt). In -Auto mode call it with -NoOpen so no notepad window pops up.
$bp = "$base\buildprompt.ps1"
if (-not (Test-Path $bp)) { $bp = Join-Path $PSScriptRoot "buildprompt.ps1" }
if (Test-Path $bp) {
    if ($Auto) { & $bp -NoOpen } else { & $bp }
} else {
    Write-Host "Next    : paste transcript.txt into the AI (Step 4) to draft the minutes." -ForegroundColor Green
}
Pause-End
