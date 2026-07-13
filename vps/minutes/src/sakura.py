"""Sakura AI Engine client (OpenAI-compatible).

- chat(prompt): text generation via /v1/chat/completions
- transcribe(path): audio transcription via /v1/audio/transcriptions

Uses `requests`, which decodes UTF-8 responses correctly (unlike PowerShell 5.1's
Invoke-RestMethod). The token is read from config (env var) and never logged.
"""
import os
import time
from urllib.parse import urlparse

import requests

from . import config


def _check():
    if not config.SAKURA_TOKEN:
        raise RuntimeError("SAKURA_AI_TOKEN is not set (export it before running).")
    u = urlparse(config.SAKURA_BASE_URL)
    if u.scheme != "https":
        # Never send the Bearer token over cleartext.
        raise RuntimeError("SAKURA_AI_BASE_URL must be https (got: %s)" % u.scheme)
    host = (u.hostname or "").lower()
    if not (host == config.ALLOWED_HOST_SUFFIX or host.endswith("." + config.ALLOWED_HOST_SUFFIX)):
        raise RuntimeError("SAKURA_AI_BASE_URL host not allowed: %s" % host)


def _auth():
    return {"Authorization": "Bearer " + config.SAKURA_TOKEN}


def _retry(fn, attempts=4):
    """Call fn() -> requests.Response; retry on 429/5xx/connection errors."""
    last = None
    for i in range(1, attempts + 1):
        try:
            r = fn()
        except requests.RequestException as e:
            last = e
            if i < attempts:
                time.sleep(2 ** i)
                continue
            raise
        if r.status_code == 429 or 500 <= r.status_code < 600:
            if i < attempts:
                time.sleep(2 ** i)
                continue
        r.raise_for_status()
        return r
    if last:
        raise last
    raise RuntimeError("request failed")


def chat(prompt, model=None, temperature=0.3, max_tokens=8000, timeout=300):
    _check()
    url = config.SAKURA_BASE_URL.rstrip("/") + "/chat/completions"
    payload = {
        "model": model or config.CHAT_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    headers = dict(_auth())
    headers["Content-Type"] = "application/json"
    r = _retry(lambda: requests.post(url, headers=headers, json=payload, timeout=timeout))
    data = r.json()
    return data["choices"][0]["message"]["content"]


def transcribe(path, model=None, timeout=600):
    """Transcribe one audio file (must be <= 30 min / 30 MB). Returns text."""
    _check()
    url = config.SAKURA_BASE_URL.rstrip("/") + "/audio/transcriptions"
    name = os.path.basename(path)
    form = {"model": model or config.WHISPER_MODEL}

    def do_post():
        # Reopen the file on EVERY attempt: a retried multipart POST must send the
        # file from the start (a reused, already-read handle sends empty/partial).
        with open(path, "rb") as f:
            return requests.post(url, headers=_auth(), files={"file": (name, f)},
                                 data=form, timeout=timeout)

    r = _retry(do_post)
    return r.json().get("text", "")
