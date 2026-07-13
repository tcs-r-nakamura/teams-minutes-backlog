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

# Refresh PATH so a PATH-based ffmpeg/ffprobe (older winget installs) is found too.
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# Prefer the locally-installed static FFmpeg (setup.ps1 downloads it there so no
# winget/PATH is required); fall back to a PATH ffmpeg/ffprobe if present.
$ffmpeg  = if (Test-Path "$base\tools\ffmpeg\ffmpeg.exe")  { "$base\tools\ffmpeg\ffmpeg.exe" }  else { "ffmpeg" }
$ffprobe = if (Test-Path "$base\tools\ffmpeg\ffprobe.exe") { "$base\tools\ffmpeg\ffprobe.exe" } else { "ffprobe" }

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
if (-not (Get-Command $ffmpeg -ErrorAction SilentlyContinue)) { Write-Host "[ERROR] ffmpeg not found (run setup.ps1)" -ForegroundColor Red; Pause-End; exit 1 }
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
# date and key the sequential meeting number. Teams recording names embed the
# meeting date/time as "...-YYYYMMDD_HHMMSS-...", which is the real meeting date
# and is stable across re-downloads. Prefer it over the file timestamp: a
# re-download changes the timestamp (bumping the counter, wrong date) but not the
# name. Fall back to the file timestamp/size when the name has no such token.
$mtgDate = $rec.LastWriteTime.ToString("yyyy/MM/dd")          # fallback
$srcKey  = "" + $rec.LastWriteTime.Ticks + "_" + $rec.Length  # fallback
if ($rec.Name -match '([0-9]{8})_([0-9]{6})') {
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($matches[1], "yyyyMMdd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        $mtgDate = $parsed.ToString("yyyy/MM/dd")
        $srcKey  = $matches[1] + "_" + $matches[2]   # meeting datetime token (stable per meeting)
    }
}
$srcMeta = "Name=" + $rec.Name + "`r`nDate=" + $mtgDate + "`r`nKey=" + $srcKey + "`r`n"
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
    $durRaw = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $rec.FullName 2>$null
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
& $ffmpeg -y -loglevel error -i $rec.FullName -ar 16000 -ac 1 -c:a pcm_s16le "$work\transcript.wav"
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

# ---------------------------------------------------------------------
# Teams transcript (optional, used together with whisper)
# ---------------------------------------------------------------------
# If a Teams WEBVTT for THIS recording is present, parse it into speaker-labelled
# text plus a speaker list. buildprompt.ps1 then sends BOTH the Teams transcript
# (speaker names authoritative) and the whisper transcript (high-accuracy wording)
# to the AI so they are cross-checked. The .vtt is selected strictly by this
# recording's YYYYMMDD_HHMMSS token (see below): run.ps1 -Fetch saves the fetched
# transcript as teams_<token>.vtt, and a manually placed Teams .vtt also carries
# the token in its name - so a leftover .vtt from a previous meeting is never
# used. When none is found, remove any stale outputs so an old meeting's speakers
# are not reused. All Japanese here comes from the .vtt content, never literals.
# Verify a file really is a Teams WEBVTT transcript: its first non-empty line is
# the "WEBVTT" header AND it has at least one "<v Speaker>" voice cue. This keeps
# an unrelated / non-transcript .vtt from being mistaken for one. Head-only read.
function Test-TeamsVtt($path) {
    try { $head = Get-Content -LiteralPath $path -Encoding UTF8 -TotalCount 400 -ErrorAction Stop } catch { return $false }
    $firstSeen = $false; $hdrOk = $false; $hasVoice = $false
    foreach ($l in $head) {
        if (-not $firstSeen) {
            if ($l.Trim() -eq "") { continue }
            $firstSeen = $true
            if ($l -match '^\s*WEBVTT') { $hdrOk = $true } else { return $false }
            continue
        }
        if ($l -match '<v\s+[^>]+>') { $hasVoice = $true; break }
    }
    return ($hdrOk -and $hasVoice)
}

$teamsTxt = "$work\transcript_teams.txt"
$spkTxt   = "$work\speakers.txt"
$teamsVtt = $null
if ($srcKey -match '^[0-9]{8}_[0-9]{6}$') {
    # Adopt a Teams .vtt only if it (a) is not whisper's own transcript.vtt,
    # (b) carries THIS recording's YYYYMMDD_HHMMSS token in its name, and (c) is a
    # real Teams WEBVTT. Keying strictly on the token (no untokened canonical file)
    # means a leftover .vtt from a previous meeting is never mixed with this
    # recording's whisper result - this holds for BOTH the run.ps1 -Fetch path
    # (which saves the fetched transcript as teams_<token>.vtt) and a manually
    # placed Teams .vtt (whose original name also contains the token).
    $cand = @(Get-ChildItem "$work\*.vtt" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "transcript.vtt" -and $_.Name -like ("*" + $srcKey + "*") } | Sort-Object LastWriteTime -Descending)
    foreach ($c in $cand) { if (Test-TeamsVtt $c.FullName) { $teamsVtt = $c.FullName; break } }
}
if ($teamsVtt -ne $null) {
    try {
        $vlines  = Get-Content -LiteralPath $teamsVtt -Encoding UTF8

        # Speaker-name normalization: convert a full-width space (U+3000) between
        # surname and given name to a half-width space, collapse runs of spaces,
        # and trim. Then apply optional exact overrides from speaker_aliases.txt
        # ("raw = display"), e.g. to add a half-width space to a name Teams stores
        # without one. Keys in the alias file are normalized the same way so they
        # match regardless of the space width written there. All Japanese lives in
        # that UTF-8 file, so this .ps1 stays ASCII-only.
        $fw = [string][char]0x3000
        $aliasPath = "$base\speaker_aliases.txt"
        if (-not (Test-Path $aliasPath)) { $aliasPath = Join-Path $PSScriptRoot "speaker_aliases.txt" }
        $aliases = @{}
        if (Test-Path $aliasPath) {
            foreach ($al in (Get-Content $aliasPath -Encoding UTF8)) {
                if ($al -match '^\s*#') { continue }
                if ($al -match '^\s*(.+?)\s*=\s*(.+?)\s*$') {
                    $k = ((($matches[1] -replace $fw, ' ') -replace '\s+', ' ')).Trim()
                    if ($k -ne "") { $aliases[$k] = $matches[2].Trim() }
                }
            }
        }

        $segs    = New-Object System.Collections.ArrayList
        $inCue   = $false
        $curSpk  = ""
        $curText = ""
        foreach ($ln in $vlines) {
            if (-not $inCue) {
                # Cue payload opens with "<v Speaker Name>text". Blank / cue-id /
                # timestamp lines between cues fall through and are ignored.
                if ($ln -match '<v\s+([^>]+)>(.*)') {
                    $curSpk = ((($matches[1] -replace $fw, ' ') -replace '\s+', ' ')).Trim()
                    if ($aliases.ContainsKey($curSpk)) { $curSpk = $aliases[$curSpk] }
                    $rest   = $matches[2]
                    if ($rest -match '(?s)^(.*?)</v>') {
                        $tt = ($matches[1] -replace '<[^>]+>', '').Trim()
                        if ($tt -ne "") { [void]$segs.Add([pscustomobject]@{ Spk = $curSpk; Text = $tt }) }
                    } else {
                        $curText = $rest; $inCue = $true   # payload spans more lines
                    }
                }
            } else {
                if ($ln -match '(?s)^(.*?)</v>') {
                    $curText += $matches[1]
                    $tt = ($curText -replace '<[^>]+>', '').Trim()
                    if ($tt -ne "") { [void]$segs.Add([pscustomobject]@{ Spk = $curSpk; Text = $tt }) }
                    $inCue = $false; $curText = ""
                } elseif ($ln.Trim() -eq "") {
                    # Defensive: a blank line ends the cue even if the closing </v>
                    # is missing (a WebVTT voice span may run to the cue end with no
                    # close tag). Without this, a missing tag would swallow the
                    # following cues' id/timestamp lines into this speaker's text.
                    $tt = ($curText -replace '<[^>]+>', '').Trim()
                    if ($tt -ne "") { [void]$segs.Add([pscustomobject]@{ Spk = $curSpk; Text = $tt }) }
                    $inCue = $false; $curText = ""
                } else {
                    # Continuation line of the same cue. Append with NO separator:
                    # a WebVTT line break inside one cue is display wrapping, and
                    # Japanese has no word spaces, so joining is correct here (a
                    # space would insert a spurious gap). Any residual wording issue
                    # is covered by the whisper transcript, which the AI cross-checks.
                    $curText += $ln
                }
            }
        }
        if ($segs.Count -gt 0) {
            # Merge consecutive same-speaker segments into one paragraph; collect
            # unique speakers in first-seen order for the "Speaker" field.
            $sb       = New-Object System.Text.StringBuilder
            $speakers = New-Object System.Collections.ArrayList
            $lastSpk  = $null
            foreach ($s in $segs) {
                if (-not $speakers.Contains($s.Spk)) { [void]$speakers.Add($s.Spk) }
                if ($s.Spk -eq $lastSpk) {
                    # Same speaker, next cue: new line (no name repeat). A newline -
                    # not empty concatenation - so cue boundaries are kept and text
                    # from adjacent cues never runs together into one word.
                    [void]$sb.Append("`r`n" + $s.Text)
                } else {
                    if ($lastSpk -ne $null) { [void]$sb.Append("`r`n") }
                    [void]$sb.Append($s.Spk + ": " + $s.Text)
                    $lastSpk = $s.Spk
                }
            }
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($teamsTxt, $sb.ToString(), $enc)
            [System.IO.File]::WriteAllText($spkTxt,   ($speakers -join ", "), $enc)
            Write-Host ""
            Write-Host ("[Teams] transcript parsed: " + $speakers.Count + " speakers, " + $segs.Count + " segments") -ForegroundColor Green
            Write-Host ("        speakers: " + ($speakers -join ", ")) -ForegroundColor DarkGray
        } else {
            Remove-Item $teamsTxt, $spkTxt -ErrorAction SilentlyContinue
            Write-Host "[Teams] .vtt found but no speech cues parsed; using whisper only." -ForegroundColor Yellow
        }
    } catch {
        Remove-Item $teamsTxt, $spkTxt -ErrorAction SilentlyContinue
        Write-Host ("[Teams] failed to parse .vtt (" + $_ + "); using whisper only.") -ForegroundColor Yellow
    }
} else {
    Remove-Item $teamsTxt, $spkTxt -ErrorAction SilentlyContinue
}

# Build the ready-to-send AI prompt (non-interactive; all values auto-filled).
# Open the finished prompt (ai_prompt.txt) so it is ready to review and paste -
# this runs even in -Auto mode, so after transcription the prompt pops up.
$bp = "$base\buildprompt.ps1"
if (-not (Test-Path $bp)) { $bp = Join-Path $PSScriptRoot "buildprompt.ps1" }
if (Test-Path $bp) {
    & $bp
} else {
    Write-Host "Next    : paste transcript.txt into the AI (Step 4) to draft the minutes." -ForegroundColor Green
}
Pause-End
