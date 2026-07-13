"""Audio helpers (ffmpeg): extract mp3 from a recording and split long audio
into chunks under the Sakura Whisper per-request limit (30 min / 30 MB).

Split points are chosen at SILENCE near the target time so words are not cut
mid-sentence. If no silence is found in the window, a fixed-time cut is used and
the run is flagged (needs a human check of the seam).
"""
import math
import os
import re
import subprocess

from . import config


def _run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True)


def extract_audio(src, dst_mp3):
    """Extract mono 16 kHz mp3 (small; well under 30 MB even for long meetings)."""
    _run(["ffmpeg", "-y", "-loglevel", "error", "-i", src,
          "-vn", "-ac", "1", "-ar", "16000", "-b:a", "64k", dst_mp3])
    return dst_mp3


def duration_seconds(path):
    out = _run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", path]).stdout.strip()
    return float(out)


def detect_silences(path):
    """Return list of (start, end) silence intervals via ffmpeg silencedetect.

    Parses the log IN ORDER (pairing each silence_start with the following
    silence_end) rather than by index, and checks the ffmpeg return code.
    """
    p = subprocess.run(
        ["ffmpeg", "-i", path, "-af",
         "silencedetect=noise=%s:d=%s" % (config.SILENCE_NOISE_DB, config.SILENCE_MIN_DUR),
         "-f", "null", "-"],
        capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg silencedetect failed (%d): %s" % (p.returncode, p.stderr[-500:]))
    silences = []
    cur_start = None
    for line in p.stderr.splitlines():
        m = re.search(r"silence_start:\s*(-?[0-9.]+)", line)
        if m:
            cur_start = max(0.0, float(m.group(1)))
            continue
        m = re.search(r"silence_end:\s*([0-9.]+)", line)
        if m and cur_start is not None:
            silences.append((cur_start, float(m.group(1))))
            cur_start = None
    return silences


def _enforce_max_gap(boundaries, max_gap):
    """Insert fixed cut points so no segment between boundaries exceeds max_gap.
    Returns (new_boundaries, added_fixed_cut)."""
    out = [boundaries[0]]
    added = False
    for b in boundaries[1:]:
        prev = out[-1]
        gap = b - prev
        if gap > max_gap:
            n = int(math.ceil(gap / max_gap))
            step = gap / n
            for i in range(1, n):
                out.append(prev + step * i)
            added = True
        out.append(b)
    return out, added


def _split_points(total, silences):
    """Choose cut times near multiples of the target length, at a silence
    midpoint within the search window. Returns list of (time, is_fixed)."""
    target = config.CHUNK_TARGET_SECONDS
    window = config.SILENCE_SEARCH_WINDOW
    points = []
    t = target
    while t < total - 60:
        best = None
        best_d = None
        for (s, e) in silences:
            mid = (s + e) / 2.0
            if abs(mid - t) <= window:
                d = abs(mid - t)
                if best_d is None or d < best_d:
                    best_d = d
                    best = mid
        if best is None:
            points.append((float(t), True))   # fixed-time fallback -> flag
            t = t + target
        else:
            points.append((best, False))
            t = best + target
    return points


def split_audio(mp3, out_dir):
    """Split mp3 into chunks <= 30 min. Returns (chunk_paths, flagged)."""
    os.makedirs(out_dir, exist_ok=True)
    total = duration_seconds(mp3)
    size = os.path.getsize(mp3)
    # If already within limits (with margin), use as a single chunk.
    if total <= (config.CHUNK_MAX_SECONDS - 30) and size <= config.CHUNK_MAX_BYTES:
        dst = os.path.join(out_dir, "chunk_000.mp3")
        _run(["ffmpeg", "-y", "-loglevel", "error", "-i", mp3, "-c", "copy", dst])
        return [dst], False

    silences = detect_silences(mp3)
    points = _split_points(total, silences)
    boundaries = [0.0] + [p for p, _ in points] + [total]
    flagged = any(f for _, f in points)

    # Guarantee the duration contract: no segment may exceed the hard limit.
    # (a silence may not exist near the target, or config may be misset).
    max_gap = config.CHUNK_MAX_SECONDS - 30  # keep a 30s margin under 30 min
    boundaries, added = _enforce_max_gap(boundaries, max_gap)
    if added:
        flagged = True

    chunks = []
    for i in range(len(boundaries) - 1):
        s = boundaries[i]
        e = boundaries[i + 1]
        dst = os.path.join(out_dir, "chunk_%03d.mp3" % i)
        _run(["ffmpeg", "-y", "-loglevel", "error", "-ss", "%.3f" % s, "-to", "%.3f" % e,
              "-i", mp3, "-c", "copy", dst])
        chunks.append(dst)

    # Verify the contract before returning (fail fast instead of sending an
    # over-limit chunk that the API would reject).
    for c in chunks:
        if os.path.getsize(c) > config.CHUNK_MAX_BYTES:
            raise RuntimeError(
                "chunk %s exceeds 30MB; extract at a lower bitrate or reduce "
                "CHUNK_TARGET_SECONDS" % c)
        if duration_seconds(c) > config.CHUNK_MAX_SECONDS:
            raise RuntimeError("chunk %s exceeds 30 min (internal split error)" % c)
    return chunks, flagged
