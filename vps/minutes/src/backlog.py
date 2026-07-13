"""Backlog Document API client.

- meeting_no(date_token): auto meeting number = max "第N回" among the parent's
  children + 1 (reuse the sibling's number if this date already appears there).
- find_duplicate(title): True if a same-title sibling already exists.
- create_document(title, content): POST /api/v2/documents (Markdown body).

Secrets come from config (env var BACKLOG_API_KEY) and are never logged.
The API key is passed as the `apiKey` query parameter (Backlog convention).
"""
import re
import unicodedata

import requests

from . import config

DAI_KAI = re.compile("第([0-9]+)回")  # "第(N)回"
HOST_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*\.backlog\.(com|jp)$")


def _check():
    if not config.BACKLOG_API_KEY:
        raise RuntimeError("BACKLOG_API_KEY is not set.")
    if not HOST_RE.match((config.BACKLOG_SPACE or "").lower()):
        raise RuntimeError("BACKLOG_SPACE is not a valid *.backlog.com/.jp host: %s" % config.BACKLOG_SPACE)
    if not re.match(r"^[0-9]+$", config.BACKLOG_PROJECT_ID or ""):
        raise RuntimeError("BACKLOG_PROJECT_ID must be numeric.")
    if not re.match(r"^[0-9A-Za-z]{16,64}$", config.BACKLOG_PARENT_ID or ""):
        raise RuntimeError("BACKLOG_PARENT_ID is invalid.")


def _base():
    return "https://" + config.BACKLOG_SPACE


def _tree():
    try:
        r = requests.get(_base() + "/api/v2/documents/tree",
                         params={"projectIdOrKey": config.BACKLOG_PROJECT_ID,
                                 "apiKey": config.BACKLOG_API_KEY},
                         timeout=60)
    except requests.RequestException as e:
        raise RuntimeError(_redact("tree fetch failed: %s" % e))
    _raise_for_status(r, "tree fetch")
    return r.json()


def _find(node, doc_id):
    items = node if isinstance(node, list) else [node]
    for n in items:
        if not n:
            continue
        if str(n.get("id")) == str(doc_id):
            return n
        kids = n.get("children")
        if kids:
            found = _find(kids, doc_id)
            if found:
                return found
    return None


def _parent_children():
    tree = _tree()
    parent = _find(tree.get("activeTree"), config.BACKLOG_PARENT_ID)
    if parent is None:
        return None
    return parent.get("children") or []


def _norm(s):
    return unicodedata.normalize("NFC", (s or "").strip())


def _digits(s):
    """NFKC-normalized digit-only view (folds fullwidth digits, drops / - etc.)."""
    return re.sub(r"[^0-9]", "", unicodedata.normalize("NFKC", s or ""))


def _redact(s):
    """Strip the API key value from any string before it is shown/logged."""
    s = str(s)
    key = config.BACKLOG_API_KEY
    if key:
        s = s.replace(key, "***")
    # Also blanket-redact any apiKey=... query fragment, just in case.
    return re.sub(r"(apiKey=)[^&\s]+", r"\1***", s)


def _raise_for_status(r, what):
    """raise_for_status(), but never leak the API key in the message."""
    if r.status_code >= 400:
        body = ""
        try:
            body = r.text[:300]
        except Exception:
            body = ""
        raise RuntimeError(_redact("%s failed: HTTP %s %s" % (what, r.status_code, body)))


def _name(c):
    return c.get("name") or c.get("title") or ""


def meeting_no(date_token):
    """Meeting number from Backlog. date_token: 'YYYYMMDD' or None.
    Returns int, or None on ANY failure (caller falls back)."""
    try:
        _check()
        kids = _parent_children()
    except Exception:
        return None
    if kids is None:
        return None
    max_no = 0
    existing = None
    for c in kids:
        name = _name(c)
        m = DAI_KAI.search(name)
        if m:
            n = int(m.group(1))
            if n > max_no:
                max_no = n
            if date_token and date_token in _digits(name):
                existing = n
    return existing if existing is not None else (max_no + 1)


def number_conflict(title):
    """For a title containing '第N回', return the name of a DIFFERENT sibling that
    already uses the same 第N回 (a numbering collision), else None. Returns None
    on any lookup failure too (caller decides how strict to be)."""
    m = DAI_KAI.search(title or "")
    if not m:
        return None
    try:
        _check()
        kids = _parent_children()
    except Exception:
        return None
    if kids is None:
        return None
    n, tn = m.group(1), _norm(title)
    for c in kids:
        name = _name(c)
        mm = DAI_KAI.search(name)
        if mm and mm.group(1) == n and _norm(name) != tn:
            return name
    return None


def find_duplicate(title):
    """True if a same-title sibling exists under the parent; None if the
    check could not run (network/config)."""
    try:
        _check()
        kids = _parent_children()
    except Exception:
        return None
    if kids is None:
        return None
    tn = _norm(title)
    for c in kids:
        if _norm(_name(c)) == tn:
            return True
    return False


def create_document(title, content):
    """POST /api/v2/documents (form-urlencoded, UTF-8). Returns the created doc."""
    _check()
    fields = {"projectId": config.BACKLOG_PROJECT_ID, "title": title, "content": content}
    if config.BACKLOG_PARENT_ID:
        fields["parentId"] = config.BACKLOG_PARENT_ID
    if config.BACKLOG_ADD_LAST:
        fields["addLast"] = str(config.BACKLOG_ADD_LAST).lower()
    try:
        r = requests.post(_base() + "/api/v2/documents",
                          params={"apiKey": config.BACKLOG_API_KEY},
                          data=fields, timeout=60)
    except requests.RequestException as e:
        raise RuntimeError(_redact("create failed: %s" % e))
    _raise_for_status(r, "create")
    return r.json()
