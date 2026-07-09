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
#   -To register           : register the reviewed work\minutes.md to Backlog.
#
# Future: when an approved AI API is available, a "draft" stage (sendprompt.ps1)
# will slot between prompt and register, and -To register may chain end to end
# behind an approval.json gate.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1"
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1" -To register
#   powershell -ExecutionPolicy Bypass -File "C:\minutes\run.ps1" -To register -Force
#
# Messages are in English on purpose (PS 5.1 mangles Japanese in a .ps1 without
# a UTF-8 BOM).
# =====================================================================

param(
    [ValidateSet("prompt","register")]
    [string]$To = "prompt",
    [switch]$Force
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

Write-Host ""
Write-Host ("=== minutes pipeline (-To " + $To + ") ===") -ForegroundColor Green

if ($To -eq "prompt") {
    # transcribe.ps1 also chains to buildprompt.ps1, producing work\ai_prompt.txt.
    # -Auto makes it unattended: newest recording, no Enter wait, no notepad.
    $t = Resolve-Script "transcribe.ps1"
    if (-not (Test-Path $t)) { Write-Host "[ERROR] transcribe.ps1 not found (run setup.ps1)" -ForegroundColor Red; exit 1 }
    & $ps -ExecutionPolicy Bypass -File $t -Auto
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Host ("[ERROR] transcribe stage failed (exit " + $code + ")") -ForegroundColor Red; exit $code }

    Write-Host ""
    Write-Host "=== manual gate (not automated yet) ===" -ForegroundColor Cyan
    Write-Host "1) Paste work\ai_prompt.txt into the approved AI; save the result as" -ForegroundColor Cyan
    Write-Host "   C:\minutes\work\minutes.md" -ForegroundColor Cyan
    Write-Host "2) Do the pre-publication review (Step 6)." -ForegroundColor Cyan
    Write-Host "3) Then register:  run.ps1 -To register" -ForegroundColor Cyan
    exit 0
}

if ($To -eq "register") {
    $r = Resolve-Script "register.ps1"
    if (-not (Test-Path $r)) { Write-Host "[ERROR] register.ps1 not found (run setup.ps1)" -ForegroundColor Red; exit 1 }
    if ($Force) {
        & $ps -ExecutionPolicy Bypass -File $r -Force
    } else {
        & $ps -ExecutionPolicy Bypass -File $r
    }
    exit $LASTEXITCODE
}
