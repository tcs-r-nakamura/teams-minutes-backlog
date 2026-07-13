# =====================================================================
# minutes run script (pipeline launcher)
#
# One entry point for the minutes pipeline. The pipeline has a deliberate human
# gate (AI drafting + pre-publication review) that is NOT automated yet, so
# run.ps1 covers the two automatable phases around it:
#
#   -To prompt   (default) : transcribe -> build the AI prompt, then STOP at the
#                            manual gate (paste into the approved AI, save the
#                            minutes as work\minutes.md, do the Step 6 review).
#   -To draft              : transcribe -> build the prompt -> call the approved
#                            AI API (Sakura AI Engine) to produce work\minutes.md,
#                            then STOP for the human pre-publication review.
#   -To register           : register the reviewed work\minutes.md to Backlog.
#
# Future: when an approved AI API is available, a "draft" stage (sendprompt.ps1)
# will slot between prompt and register, and -To register may chain end to end
# behind an approval.json gate.
#
# -Fetch moves the newest just-downloaded file from your Downloads folder into
# work, so you do not move/save it by hand (Cybozu / the AI download click stays
# manual - there is no API for it):
#   -To prompt   -Fetch : newest .mp4 (+ matching Teams .vtt) -> work
#   -To register -Fetch : newest .md  -> work\minutes.md
#
# Run:
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1"
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1" -Fetch
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1" -To register
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1" -To register -Fetch
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1" -To register -Force
#
# Messages are in English on purpose (PS 5.1 mangles Japanese in a .ps1 without
# a UTF-8 BOM).
# =====================================================================

param(
    [ValidateSet("prompt","draft","register")]
    [string]$To = "prompt",
    [switch]$Force,
    [switch]$Fetch
)

try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$base = "C:\minutes"
$ps   = (Get-Process -Id $PID).Path   # this PowerShell executable
if (-not $ps) { $ps = Join-Path $PSHOME "powershell.exe" }

# Locate a deployed script: prefer C:\minutes, fall back to this script's folder.
function Resolve-Script($name) {
    $p = "$base\$name"
    if (-not (Test-Path $p)) { $p = Join-Path $PSScriptRoot $name }
    return $p
}

# Resolve the user's Downloads folder (known-folder registry, then a plain
# %USERPROFILE%\Downloads fallback). Returns the path, or "" if none exists.
function Get-DownloadsDir {
    $dl = $null
    try {
        $key = "{374DE290-123F-4565-9164-39C4925E467B}"   # Downloads known folder
        $raw = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name $key -ErrorAction Stop).$key
        if ($raw) { $dl = [Environment]::ExpandEnvironmentVariables($raw) }
    } catch {}
    if (-not $dl -or -not (Test-Path $dl)) { $dl = Join-Path $env:USERPROFILE "Downloads" }
    if (-not (Test-Path $dl)) { return "" }
    return $dl
}

# -Fetch (prompt): move the newest .mp4 from Downloads into work, so after a
# browser download you do not have to move the file by hand. (Cybozu Office has
# no download API, so the download itself stays a manual browser click.)
# Returns $true on success, $false on any failure so the caller can stop instead
# of silently falling through to transcribe an older recording already in work.
function Fetch-Recording {
    $dl = Get-DownloadsDir
    if ($dl -eq "") { Write-Host "[WARN] Downloads folder not found." -ForegroundColor Yellow; return $false }

    $mp4 = Get-ChildItem "$dl\*.mp4" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $mp4) { Write-Host ("[WARN] No .mp4 in Downloads (" + $dl + ") to fetch.") -ForegroundColor Yellow; return $false }

    $dest = Join-Path "$base\work" $mp4.Name
    try {
        Move-Item -LiteralPath $mp4.FullName -Destination $dest -Force -ErrorAction Stop
        Write-Host ("Fetched: " + $mp4.Name + "  (" + $mp4.LastWriteTime + ")  -> work") -ForegroundColor Cyan
    } catch {
        Write-Host ("[ERROR] could not move recording to work: " + $_) -ForegroundColor Red
        return $false
    }

    # Also fetch the matching Teams transcript (.vtt) for the SAME meeting, keyed
    # by the YYYYMMDD_HHMMSS token in the recording name (both files carry it), so
    # an unrelated .vtt is never grabbed. This is optional: no matching .vtt just
    # means whisper-only. The fetched file is saved as teams_<token>.vtt so that
    # transcribe.ps1 selects it strictly by this meeting's token (never a leftover
    # from a previous meeting). Clear any previously-fetched teams_*.vtt first.
    Get-ChildItem "$base\work\teams_*.vtt" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if ($mp4.Name -match '([0-9]{8}_[0-9]{6})') {
        $token = $matches[1]
        $teamsDest = "$base\work\teams_" + $token + ".vtt"
        # Only accept a .vtt that carries the same meeting token AND looks like a
        # real Teams transcript (first non-empty line is the WEBVTT header, plus a
        # "<v Speaker>" voice cue), so a same-dated but unrelated / non-transcript
        # .vtt is not grabbed by mistake.
        $vtt = Get-ChildItem "$dl\*.vtt" -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like ("*" + $token + "*") } |
               Sort-Object LastWriteTime -Descending |
               Where-Object {
                   $firstSeen = $false; $hdrOk = $false; $voice = $false
                   try {
                       foreach ($l in (Get-Content -LiteralPath $_.FullName -Encoding UTF8 -TotalCount 400 -ErrorAction Stop)) {
                           if (-not $firstSeen) {
                               if ($l.Trim() -eq "") { continue }
                               $firstSeen = $true
                               if ($l -match '^\s*WEBVTT') { $hdrOk = $true } else { break }
                               continue
                           }
                           if ($l -match '<v\s+[^>]+>') { $voice = $true; break }
                       }
                   } catch {}
                   ($hdrOk -and $voice)
               } |
               Select-Object -First 1
        if ($vtt) {
            try {
                Move-Item -LiteralPath $vtt.FullName -Destination $teamsDest -Force -ErrorAction Stop
                Write-Host ("Fetched: " + $vtt.Name + "  -> work\" + (Split-Path $teamsDest -Leaf)) -ForegroundColor Cyan
            } catch {
                Write-Host ("[WARN] found a Teams .vtt but could not move it (using whisper only): " + $_) -ForegroundColor Yellow
            }
        } else {
            Write-Host "[NOTE] No matching Teams .vtt in Downloads; using whisper only." -ForegroundColor DarkGray
        }
    }
    return $true
}

# -Fetch (register): move the newest .md from Downloads into work\minutes.md, so
# after downloading the AI-drafted minutes you do not have to save it by hand.
# Returns $true on success, $false on any failure so the caller can stop instead
# of registering an old/unrelated minutes.md already in work.
function Fetch-Minutes {
    $dl = Get-DownloadsDir
    if ($dl -eq "") { Write-Host "[WARN] Downloads folder not found." -ForegroundColor Yellow; return $false }

    $md = Get-ChildItem "$dl\*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $md) { Write-Host ("[WARN] No .md in Downloads (" + $dl + ") to fetch.") -ForegroundColor Yellow; return $false }

    $dest = "$base\work\minutes.md"
    try {
        Move-Item -LiteralPath $md.FullName -Destination $dest -Force -ErrorAction Stop
        Write-Host ("Fetched: " + $md.Name + "  (" + $md.LastWriteTime + ")  -> work\minutes.md") -ForegroundColor Cyan
        return $true
    } catch {
        Write-Host ("[ERROR] could not move minutes to work: " + $_) -ForegroundColor Red
        return $false
    }
}

Write-Host ""
Write-Host ("=== minutes pipeline (-To " + $To + ") ===") -ForegroundColor Green

if ($To -eq "prompt") {
    # -Fetch: pull the just-downloaded recording from Downloads into work first.
    # If it fails, stop here: continuing would transcribe whatever older .mp4 is
    # already in work (transcribe -Auto picks the newest), i.e. the wrong meeting.
    if ($Fetch) {
        if (-not (Fetch-Recording)) {
            Write-Host "[ERROR] -Fetch failed - stopping so an old recording is not transcribed by mistake." -ForegroundColor Red
            exit 1
        }
    }

    # transcribe.ps1 also chains to buildprompt.ps1, producing work\ai_prompt.txt.
    # -Auto runs unattended: newest recording, no Enter wait. The finished prompt
    # still opens at the end so it is ready to review and paste.
    $t = Resolve-Script "transcribe.ps1"
    if (-not (Test-Path $t)) { Write-Host "[ERROR] transcribe.ps1 not found (run setup.ps1)" -ForegroundColor Red; exit 1 }
    & $ps -ExecutionPolicy Bypass -File $t -Auto
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Host ("[ERROR] transcribe stage failed (exit " + $code + ")") -ForegroundColor Red; exit $code }

    Write-Host ""
    Write-Host "=== manual gate (not automated yet) ===" -ForegroundColor Cyan
    Write-Host "1) Paste work\ai_prompt.txt into the approved AI. Save the result as" -ForegroundColor Cyan
    Write-Host "   C:\minutes\work\minutes.md  (or download it as .md to Downloads)." -ForegroundColor Cyan
    Write-Host "2) Do the pre-publication review (Step 6)." -ForegroundColor Cyan
    Write-Host "3) Then register:  run.ps1 -To register" -ForegroundColor Cyan
    Write-Host "   (downloaded the .md instead? use:  run.ps1 -To register -Fetch)" -ForegroundColor Cyan
    exit 0
}

if ($To -eq "draft") {
    # Full auto up to the DRAFT: fetch -> transcribe -> build prompt -> call the
    # approved AI API (Sakura AI Engine) -> work\minutes.md. This replaces the
    # manual "paste into ChatGPT and download the .md" step. The human
    # pre-publication review and Backlog registration stay manual (unchanged).
    if ($Fetch) {
        if (-not (Fetch-Recording)) {
            Write-Host "[ERROR] -Fetch failed - stopping so an old recording is not transcribed by mistake." -ForegroundColor Red
            exit 1
        }
    }

    # Stamp the time BEFORE transcribe so we can verify the prompt is freshly
    # (re)generated this run (below), and never send a stale one to the AI API.
    $draftStart = Get-Date

    $t = Resolve-Script "transcribe.ps1"
    if (-not (Test-Path $t)) { Write-Host "[ERROR] transcribe.ps1 not found (run setup.ps1)" -ForegroundColor Red; exit 1 }
    & $ps -ExecutionPolicy Bypass -File $t -Auto
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Host ("[ERROR] transcribe stage failed (exit " + $code + ")") -ForegroundColor Red; exit $code }

    # Guard: transcribe.ps1 chains to buildprompt.ps1 to produce work\ai_prompt.txt,
    # but it does not fail hard if buildprompt.ps1 is missing. Require ai_prompt.txt
    # to have been (re)written THIS run, so a leftover prompt from a previous meeting
    # is never sent to the AI by mistake.
    $promptFile = "$base\work\ai_prompt.txt"
    if (-not (Test-Path $promptFile) -or (Get-Item $promptFile).LastWriteTime -lt $draftStart) {
        Write-Host "[ERROR] work\ai_prompt.txt was not regenerated this run - stopping so a stale prompt is not sent to the AI (is buildprompt.ps1 deployed? run setup.ps1)." -ForegroundColor Red
        exit 1
    }

    $d = Resolve-Script "draft.ps1"
    if (-not (Test-Path $d)) { Write-Host "[ERROR] draft.ps1 not found (run setup.ps1)" -ForegroundColor Red; exit 1 }
    & $ps -ExecutionPolicy Bypass -File $d
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Host ("[ERROR] draft stage failed (exit " + $code + ")") -ForegroundColor Red; exit $code }

    Write-Host ""
    Write-Host "=== draft ready - human check required (not automated) ===" -ForegroundColor Cyan
    Write-Host "1) Open C:\minutes\work\minutes.md and do the pre-publication review (Step B-4)." -ForegroundColor Cyan
    Write-Host "2) Then register:  run.ps1 -To register" -ForegroundColor Cyan
    exit 0
}

if ($To -eq "register") {
    # -Fetch: pull the just-downloaded AI minutes (.md) from Downloads into
    # work\minutes.md first. If it fails, stop: continuing would register
    # whatever old minutes.md is already in work.
    if ($Fetch) {
        if (-not (Fetch-Minutes)) {
            Write-Host "[ERROR] -Fetch failed - stopping so an old minutes.md is not registered by mistake." -ForegroundColor Red
            exit 1
        }
    }

    $r = Resolve-Script "register.ps1"
    if (-not (Test-Path $r)) { Write-Host "[ERROR] register.ps1 not found (run setup.ps1)" -ForegroundColor Red; exit 1 }
    if ($Force) {
        & $ps -ExecutionPolicy Bypass -File $r -Force
    } else {
        & $ps -ExecutionPolicy Bypass -File $r
    }
    exit $LASTEXITCODE
}
