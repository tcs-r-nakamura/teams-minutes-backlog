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


def build(template, meeting_no, meeting_date, rec_link, speaker, teams_text, whisper_text):
    teams_block = teams_text.strip() if (teams_text and teams_text.strip()) else "(none)"
    out = template
    out = out.replace("{{MEETING_NO}}", str(meeting_no))
    out = out.replace("{{MEETING_DATE}}", meeting_date)
    out = out.replace("{{REC_LINK}}", rec_link)
    out = out.replace("{{SPEAKER}}", speaker)
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
