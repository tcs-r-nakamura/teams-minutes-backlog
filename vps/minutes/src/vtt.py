"""Parse a Teams WEBVTT transcript into speaker-labelled text + speaker list.

Ported from the PowerShell version (transcribe.ps1):
- speaker names: full-width space -> half-width, collapse spaces, trim,
  then apply optional overrides from speaker_aliases.txt.
- a cue's payload runs from "<v Speaker>" to "</v>" OR the next blank line
  (defensive: some WebVTT omits the closing tag).
- consecutive same-speaker cues are merged (new line, no name repeat).
"""
import re

FULLWIDTH_SPACE = "　"
VOICE_OPEN = re.compile(r"<v\s+([^>]+)>(.*)")
TAG = re.compile(r"<[^>]+>")


def normalize_name(name):
    n = name.replace(FULLWIDTH_SPACE, " ")
    n = re.sub(r"\s+", " ", n).strip()
    return n


def load_aliases(path):
    aliases = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.strip().startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = normalize_name(k.strip())
                if k:
                    aliases[k] = v.strip()
    except FileNotFoundError:
        pass
    return aliases


def is_teams_vtt(path):
    """First non-empty line is WEBVTT and there is at least one <v ...> cue."""
    try:
        with open(path, encoding="utf-8") as f:
            first_seen = False
            hdr = False
            for line in f:
                s = line.strip()
                if not first_seen:
                    if s == "":
                        continue
                    first_seen = True
                    if not s.startswith("WEBVTT"):
                        return False
                    hdr = True
                    continue
                if VOICE_OPEN.search(line):
                    return hdr
    except OSError:
        return False
    return False


def parse(path, aliases=None):
    """Return (body_text, speakers_list)."""
    aliases = aliases or {}
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    segs = []
    in_cue = False
    cur_spk = ""
    buf = ""

    def emit():
        text = TAG.sub("", buf).strip()
        if text:
            segs.append((cur_spk, text))

    for ln in lines:
        if not in_cue:
            m = VOICE_OPEN.match(ln)
            if m:
                cur_spk = normalize_name(m.group(1))
                cur_spk = aliases.get(cur_spk, cur_spk)
                rest = m.group(2)
                if "</v>" in rest:
                    buf = rest.split("</v>", 1)[0]
                    emit()
                    buf = ""
                else:
                    buf = rest
                    in_cue = True
        else:
            if "</v>" in ln:
                buf += ln.split("</v>", 1)[0]
                emit()
                buf = ""
                in_cue = False
            elif ln.strip() == "":
                emit()
                buf = ""
                in_cue = False
            else:
                buf += ln

    if in_cue:  # a final cue that ended at EOF without </v> or a blank line
        emit()

    merged = []
    speakers = []
    for spk, text in segs:
        if spk not in speakers:
            speakers.append(spk)
        if merged and merged[-1][0] == spk:
            merged[-1] = (spk, merged[-1][1] + "\n" + text)
        else:
            merged.append([spk, text])
    body = "\n".join("%s: %s" % (spk, text) for spk, text in merged)
    return body, speakers
