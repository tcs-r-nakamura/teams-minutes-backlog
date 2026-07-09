# =====================================================================
# minutes environment setup
#
# Sets up FFmpeg, whisper.cpp + model, working folders under C:\minutes,
# and deploys transcribe.ps1 into C:\minutes.
#
# Run (from anywhere):
#   powershell -ExecutionPolicy Bypass -File "<this file's path>\setup.ps1"
#
# Idempotent: already-installed parts are skipped, so it is safe to re-run.
# =====================================================================

try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$base       = "C:\minutes"
$whisperDir = "$base\tools\whisper"
$cliPath    = "$whisperDir\Release\whisper-cli.exe"
$modelPath  = "$whisperDir\models\ggml-medium.bin"
$whisperUrl = "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-bin-x64.zip"
$modelUrl   = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

# Download to a .part file, then move into place only on success.
# Uses curl.exe -f (fail on HTTP error) and --retry so a partial/HTTP-error
# download does not get treated as a finished file.
function Download-File($url, $dest) {
    $tmp = "$dest.part"
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
    curl.exe -fL --retry 3 -o "$tmp" "$url"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] download failed (exit $LASTEXITCODE): $url" -ForegroundColor Red
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return $false
    }
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    return $true
}

Write-Host "=== minutes environment setup ===" -ForegroundColor Green

# 1) Folders
Write-Host "[1/5] Creating folders under $base ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force "$whisperDir\models" | Out-Null
New-Item -ItemType Directory -Force "$base\work" | Out-Null

# 2) FFmpeg (winget)
Write-Host "[2/5] FFmpeg ..." -ForegroundColor Cyan
Refresh-Path
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Write-Host "  already installed - skip" -ForegroundColor DarkGray
} else {
    Write-Host "  installing via winget (Gyan.FFmpeg) ..." -ForegroundColor DarkGray
    winget install --id Gyan.FFmpeg --source winget --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Host "  [WARN] ffmpeg not on PATH yet. Open a NEW PowerShell after setup finishes." -ForegroundColor Yellow
    }
}

# 3) whisper.cpp binary (expected at Release\whisper-cli.exe)
Write-Host "[3/5] whisper.cpp ..." -ForegroundColor Cyan
if (Test-Path $cliPath) {
    Write-Host "  already present - skip" -ForegroundColor DarkGray
} else {
    Write-Host "  downloading v1.9.1 (whisper-bin-x64.zip) ..." -ForegroundColor DarkGray
    $zip = "$whisperDir\whisper-bin-x64.zip"
    if (Download-File $whisperUrl $zip) {
        try {
            Expand-Archive -Path $zip -DestinationPath $whisperDir -Force -ErrorAction Stop
        } catch {
            Write-Host "  [ERROR] unzip failed: $_" -ForegroundColor Red
        }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $cliPath)) {
            Write-Host "  [WARN] whisper-cli.exe not found at $cliPath after unzip." -ForegroundColor Yellow
        }
    }
}

# 4) Model (ggml-medium.bin, ~1.5 GB)
Write-Host "[4/5] model (ggml-medium.bin, ~1.5 GB) ..." -ForegroundColor Cyan
if ((Test-Path $modelPath) -and ((Get-Item $modelPath).Length -gt 1GB)) {
    Write-Host "  already present - skip" -ForegroundColor DarkGray
} else {
    Write-Host "  downloading (may take several minutes) ..." -ForegroundColor DarkGray
    [void](Download-File $modelUrl $modelPath)
}

# 5) Deploy scripts/template and names.txt into C:\minutes (from next to this setup.ps1)
Write-Host "[5/5] Deploying scripts / template ..." -ForegroundColor Cyan
foreach ($f in @("transcribe.ps1", "buildprompt.ps1", "register.ps1", "prompt_template.txt", "field_labels.txt")) {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination "$base\$f" -Force
        Write-Host "  $f -> $base" -ForegroundColor DarkGray
    } else {
        Write-Host "  $f not found next to setup.ps1 - skip (place it manually)" -ForegroundColor Yellow
    }
}
$srcNames = Join-Path $PSScriptRoot "names.txt"
$dstNames = "$base\work\names.txt"
if (Test-Path $srcNames) {
    if (Test-Path $dstNames) {
        Write-Host "  names.txt already in work - keep (not overwritten)" -ForegroundColor DarkGray
    } else {
        Copy-Item -LiteralPath $srcNames -Destination $dstNames -Force
        Write-Host "  names.txt -> $base\work" -ForegroundColor DarkGray
    }
}

# Verify
Write-Host "=== Verify ===" -ForegroundColor Green
Refresh-Path
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) { Write-Host "  ffmpeg        : OK" -ForegroundColor Green } else { Write-Host "  ffmpeg        : NOT FOUND (open a new PowerShell and re-check)" -ForegroundColor Yellow }
if (Test-Path $cliPath) { Write-Host "  whisper-cli   : OK" -ForegroundColor Green } else { Write-Host "  whisper-cli   : NOT FOUND" -ForegroundColor Yellow }
if ((Test-Path $modelPath) -and ((Get-Item $modelPath).Length -gt 1GB)) { Write-Host ("  model         : OK (" + [math]::Round((Get-Item $modelPath).Length/1MB) + " MB)") -ForegroundColor Green } else { Write-Host "  model         : MISSING or incomplete" -ForegroundColor Yellow }
if (Test-Path "$base\transcribe.ps1") { Write-Host "  transcribe.ps1: OK" -ForegroundColor Green } else { Write-Host "  transcribe.ps1: NOT deployed" -ForegroundColor Yellow }
if (Test-Path "$base\buildprompt.ps1") { Write-Host "  buildprompt.ps1: OK" -ForegroundColor Green } else { Write-Host "  buildprompt.ps1: NOT deployed" -ForegroundColor Yellow }
if (Test-Path "$base\register.ps1") { Write-Host "  register.ps1  : OK" -ForegroundColor Green } else { Write-Host "  register.ps1  : NOT deployed" -ForegroundColor Yellow }
if (Test-Path "$base\prompt_template.txt") { Write-Host "  prompt_template: OK" -ForegroundColor Green } else { Write-Host "  prompt_template: NOT deployed" -ForegroundColor Yellow }
if (Test-Path "$base\work\names.txt") { Write-Host "  names.txt     : OK" -ForegroundColor Green } else { Write-Host "  names.txt     : (none - optional)" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "Done. Next: put a recording (.mp4) into $base\work and run:" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$base\transcribe.ps1`"" -ForegroundColor Green
