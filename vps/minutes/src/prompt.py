"""Build the AI prompt from the template + meeting info + the two transcripts.

Mirrors buildprompt.ps1: fills {{MEETING_NO}} {{MEETING_DATE}} {{REC_LINK}}
{{SPEAKER}} {{TEAMS_TRANSCRIPT}} {{WHISPER_TRANSCRIPT}}. When there is no Teams
transcript, {{TEAMS_TRANSCRIPT}} becomes the literal "(none)" so the template's
guidance tells the model to use whisper only.
"""
import datetime
import re

TOKEN_RE = re.compile(r"(\d{8})_(\d{6})")


def date_from_filename(name):
    """Return (date 'YYYY/MM/DD', token 'YYYYMMDD_HHMMSS') or (None, None)."""
    m = TOKEN_RE.search(name)
    if m:
        try:
            d = datetime.datetime.strptime(m.group(1), "%Y%m%d")
            return d.strftime("%Y/%m/%d"), m.group(1) + "_" + m.group(2)
        except ValueError:
            pass
    return None, None


def load_glossary(path):
    """Read glossary.txt -> a bullet block for the prompt (or '' if none).

    Plain lines are canonical spellings; 'wrong = right' lines are explicit
    corrections. Lets the model fix transcription noise (e.g. 'MPフォー' -> 'MP4')
    to house-standard terms instead of us hard-coding every mis-hearing.
    """
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.readlines()
    except FileNotFoundError:
        return ""
    items = []
    for line in raw:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            wrong, right = line.split("=", 1)
            wrong, right = wrong.strip(), right.strip()
            if wrong and right:
                items.append("- 「%s」は「%s」と表記する" % (wrong, right))
        else:
            items.append("- %s" % line)
    return "\n".join(items)


def build(template, meeting_no, meeting_date, rec_link, speaker, teams_text,
          whisper_text, glossary=""):
    teams_block = teams_text.strip() if (teams_text and teams_text.strip()) else "(none)"
    glossary_block = glossary.strip() if (glossary and glossary.strip()) else "(用語集は指定なし)"
    out = template
    out = out.replace("{{MEETING_NO}}", str(meeting_no))
    out = out.replace("{{MEETING_DATE}}", meeting_date)
    out = out.replace("{{REC_LINK}}", rec_link)
    out = out.replace("{{SPEAKER}}", speaker)
    out = out.replace("{{GLOSSARY}}", glossary_block)
    out = out.replace("{{TEAMS_TRANSCRIPT}}", teams_block)
    out = out.replace("{{WHISPER_TRANSCRIPT}}", whisper_text)
    out = out.replace("{{TRANSCRIPT}}", whisper_text)  # back-compat
    return out


FENCE_HEAD = re.compile(r"^```[A-Za-z]*\s*\r?\n")
FENCE_TAIL = re.compile(r"\r?\n```\s*$")


def strip_code_fence(text):
    t = text.strip()
    if FENCE_HEAD.match(t):
        t = FENCE_HEAD.sub("", t)
        t = FENCE_TAIL.sub("", t)
        t = t.strip()
    return t


HEADING_RE = re.compile(r"^#{1,6}\s")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def normalize_md(text):
    """Tidy the model's Markdown to match the house style deterministically.

    The prompt asks for these too, but the model is inconsistent (it habitually
    appends hard-break "  " and skips the blank line after ### sub-headings), so
    enforce them in code:
      - strip trailing whitespace on every line (removes stray hard breaks)
      - remove bold markers ** (house style is no bold; the model keeps adding it)
      - ensure exactly one blank line after a heading (##, ### ...)
      - collapse runs of blank lines down to a single blank line

    Fenced code blocks (``` / ~~~) are left verbatim: a '# comment' inside code
    is not a heading, code whitespace/blank lines are significant, and a literal
    ** in code must not be touched.
    """
    src = text.splitlines()

    # Pass 1: rstrip + drop bold + insert a blank line after headings
    # (skip everything inside fences).
    spaced = []
    in_fence = False
    for i, ln in enumerate(src):
        if FENCE_RE.match(ln):
            in_fence = not in_fence
            spaced.append(ln.rstrip())
            continue
        if in_fence:
            spaced.append(ln)  # preserve code lines verbatim
            continue
        ln = ln.rstrip().replace("**", "")  # drop bold markers (house style: no bold)
        spaced.append(ln)
        if HEADING_RE.match(ln):
            nxt = src[i + 1] if i + 1 < len(src) else ""
            if nxt.strip() != "":
                spaced.append("")

    # Pass 2: collapse runs of blank lines to one (skip inside fences).
    out = []
    in_fence = False
    blanks = 0
    for ln in spaced:
        if FENCE_RE.match(ln):
            in_fence = not in_fence
            blanks = 0
            out.append(ln)
            continue
        if in_fence:
            out.append(ln)
            continue
        if ln == "":
            blanks += 1
            if blanks >= 2:
                continue
        else:
            blanks = 0
        out.append(ln)
    return "\n".join(out).strip() + "\n"
