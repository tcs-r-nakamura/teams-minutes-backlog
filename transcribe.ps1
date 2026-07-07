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
# =====================================================================

# Use UTF-8 for console (best effort for Japanese)
try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$base  = "C:\minutes"
$work  = "$base\work"
$cli   = "$base\tools\whisper\Release\whisper-cli.exe"
$model = "$base\tools\whisper\models\ggml-medium.bin"

# Refresh PATH so ffmpeg is found in a fresh session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# Preconditions - fail early with a clear message
if (-not (Test-Path $work)) { Write-Host "[ERROR] work folder not found: $work  (run setup.ps1 first)" -ForegroundColor Red; exit 1 }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Host "[ERROR] ffmpeg not found (run setup.ps1, or open a new PowerShell)" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $cli))   { Write-Host "[ERROR] whisper-cli.exe not found: $cli  (run setup.ps1)" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $model)) { Write-Host "[ERROR] model not found: $model  (run setup.ps1)" -ForegroundColor Red; exit 1 }

# Pick the recording (.mp4) in work.
#   - 0 files : error
#   - 1 file  : use it automatically
#   - 2+ files: show a numbered list and let the user choose
$mp4s = @(Get-ChildItem "$work\*.mp4" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($mp4s.Count -eq 0) { Write-Host "[ERROR] No .mp4 found in $work" -ForegroundColor Red; exit 1 }
if ($mp4s.Count -eq 1) {
    $rec = $mp4s[0]
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
Write-Host ("Recording : " + $rec.Name) -ForegroundColor Cyan

# Read name hint (UTF-8) if present
$names = ""
$namesPath = "$work\names.txt"
if (Test-Path $namesPath) { $names = (Get-Content $namesPath -Encoding UTF8 -Raw).Trim() }
if ($names) { Write-Host ("Name hint : " + $names) -ForegroundColor DarkGray }

# 1) Extract audio (16kHz mono WAV)
Write-Host "[1/3] Extracting audio..." -ForegroundColor Cyan
ffmpeg -y -loglevel error -i $rec.FullName -ar 16000 -ac 1 -c:a pcm_s16le "$work\transcript.wav"
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] ffmpeg failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }

# 2) Transcribe (Japanese). Uses --prompt when names.txt exists.
Write-Host "[2/3] Transcribing in Japanese (this can take a while)..." -ForegroundColor Cyan
if ($names) {
    & $cli -m $model -f "$work\transcript.wav" -l ja --prompt $names --carry-initial-prompt -otxt -osrt -ovtt -pp -of "$work\transcript"
} else {
    & $cli -m $model -f "$work\transcript.wav" -l ja -otxt -osrt -ovtt -pp -of "$work\transcript"
}
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] whisper-cli failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }

# 3) Show result
if (-not (Test-Path "$work\transcript.txt")) { Write-Host "[ERROR] transcript.txt was not produced" -ForegroundColor Red; exit 1 }
Write-Host "[3/3] Done. transcript.txt :" -ForegroundColor Green
Get-Content "$work\transcript.txt" -Encoding UTF8
