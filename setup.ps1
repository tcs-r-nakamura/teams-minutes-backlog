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
    curl.exe -fL --retry 3 --connect-timeout 30 -o "$tmp" "$url"
    $exit = $LASTEXITCODE
    # Treat as failure unless curl succeeded AND a non-empty file landed.
    if ($exit -ne 0 -or -not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) {
        Write-Host "  [ERROR] download failed (exit $exit): $url" -ForegroundColor Red
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return $false
    }
    try {
        Move-Item -LiteralPath $tmp -Destination $dest -Force -ErrorAction Stop
    } catch {
        Write-Host ("  [ERROR] could not place file: " + $_) -ForegroundColor Red
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return $false
    }
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
foreach ($f in @("transcribe.ps1", "buildprompt.ps1", "register.ps1", "run.ps1", "prompt_template.txt", "field_labels.txt", "backlog.config.sample.txt")) {
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

# Create the live Backlog config from the shared sample (keep any existing one,
# since a user may have added notes; the API key is never stored here anyway).
$srcCfgSample = Join-Path $PSScriptRoot "backlog.config.sample.txt"
$dstCfg       = "$base\backlog.config.txt"
if (Test-Path $srcCfgSample) {
    if (Test-Path $dstCfg) {
        Write-Host "  backlog.config.txt already present - keep (not overwritten)" -ForegroundColor DarkGray
        # Migrate configs from the pre-RecFolderUrl (meeting.txt) design: append
        # the non-secret recording-link key from the sample if it is missing, so
        # the recording link does not end up blank in the generated prompt.
        $hasRec = $false
        foreach ($line in (Get-Content $dstCfg -Encoding UTF8)) {
            if ($line -match '^\s*RecFolderUrl\s*=') { $hasRec = $true; break }
        }
        if (-not $hasRec) {
            $recLine = Get-Content $srcCfgSample -Encoding UTF8 | Where-Object { $_ -match '^\s*RecFolderUrl\s*=' } | Select-Object -First 1
            if ($recLine) {
                Add-Content -Path $dstCfg -Value $recLine -Encoding UTF8
                Write-Host "  backlog.config.txt: added missing RecFolderUrl (migrated)" -ForegroundColor DarkGray
            }
        }
    } else {
        Copy-Item -LiteralPath $srcCfgSample -Destination $dstCfg -Force
        Write-Host "  backlog.config.txt created from sample -> $base" -ForegroundColor DarkGray
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
if (Test-Path "$base\run.ps1") { Write-Host "  run.ps1       : OK" -ForegroundColor Green } else { Write-Host "  run.ps1       : NOT deployed" -ForegroundColor Yellow }
if (Test-Path "$base\backlog.config.txt") {
    Write-Host "  backlog.config: OK (set BACKLOG_API_KEY env var per user)" -ForegroundColor Green
    # Warn if the kept config still has placeholder/empty required values.
    $kv = @{}
    foreach ($line in (Get-Content "$base\backlog.config.txt" -Encoding UTF8)) {
        if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*)$') { $kv[$matches[1].ToLower()] = $matches[2].Trim() }
    }
    $cfgWarn = @()
    if (-not $kv.ContainsKey("space")     -or $kv["space"] -eq "example.backlog.com" -or $kv["space"] -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\.backlog\.(com|jp)$') { $cfgWarn += "Space" }
    if (-not $kv.ContainsKey("projectid") -or $kv["projectid"] -notmatch '^[0-9]+$')             { $cfgWarn += "ProjectId" }
    if (-not $kv.ContainsKey("parentid")  -or $kv["parentid"] -notmatch '^[0-9A-Za-z]{16,64}$')  { $cfgWarn += "ParentId" }
    if (-not $kv.ContainsKey("recfolderurl") -or $kv["recfolderurl"] -eq "")                     { $cfgWarn += "RecFolderUrl" }
    if ($cfgWarn.Count -gt 0) { Write-Host ("  [WARN] backlog.config.txt needs: " + ($cfgWarn -join ", ")) -ForegroundColor Yellow }
    if ($kv.ContainsKey("apikey") -and $kv["apikey"] -ne "") { Write-Host "  [WARN] Remove ApiKey from backlog.config.txt - use the BACKLOG_API_KEY env var." -ForegroundColor Yellow }
} else {
    Write-Host "  backlog.config: (none - created on next setup if sample present)" -ForegroundColor DarkGray
}
if (Test-Path "$base\prompt_template.txt") { Write-Host "  prompt_template: OK" -ForegroundColor Green } else { Write-Host "  prompt_template: NOT deployed" -ForegroundColor Yellow }
if (Test-Path "$base\work\names.txt") { Write-Host "  names.txt     : OK" -ForegroundColor Green } else { Write-Host "  names.txt     : (none - optional)" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "Done. Next: put a recording (.mp4) into $base\work, then run one command" -ForegroundColor Green
Write-Host "  (recording link and speaker are filled in automatically):" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$base\run.ps1`"" -ForegroundColor Green
