"""Configuration for the minutes service. Secrets come from environment
variables only (never committed): SAKURA_AI_TOKEN, BACKLOG_API_KEY.

Non-secret defaults can be overridden by environment variables too.
"""
import os
import re
import stat
import sys

_ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _load_env_file():
    """Load KEY=VALUE lines from a dotenv-style file into os.environ, WITHOUT
    overriding variables already set in the environment. Lets each engineer keep
    their tokens in one chmod-600 file instead of re-exporting every session.

    Path: $MINUTES_ENV, else ~/.config/minutes.env.
      - default path missing        -> silent no-op
      - MINUTES_ENV set but unusable -> RuntimeError (never echoing contents)
    As it holds secrets we skip symlinks / non-owned / non-regular files, and
    warn on group/other-accessible permissions. Values are never printed.
    """
    explicit = os.environ.get("MINUTES_ENV")
    path = explicit or os.path.join(os.path.expanduser("~"), ".config", "minutes.env")

    def _bail(msg):
        if explicit:
            raise RuntimeError(msg)  # explicit path: fail loud (msg has no secrets)

    try:
        st = os.lstat(path)
    except OSError:
        _bail("MINUTES_ENV is set but not accessible: %s" % path)
        return
    if stat.S_ISLNK(st.st_mode):
        print("[WARN] %s is a symlink; not reading it as a secrets file "
              "(point MINUTES_ENV at the real file)." % path, file=sys.stderr)
        _bail("MINUTES_ENV must be a regular file, not a symlink: %s" % path)
        return
    if not stat.S_ISREG(st.st_mode):
        _bail("MINUTES_ENV is not a regular file: %s" % path)
        return
    if hasattr(os, "getuid"):
        if st.st_uid != os.getuid():
            print("[WARN] %s is not owned by you; skipping (secrets file)." % path,
                  file=sys.stderr)
            _bail("MINUTES_ENV is not owned by the current user: %s" % path)
            return
        if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            print("[WARN] %s is group/other-accessible; run: chmod 600 %s"
                  % (path, path), file=sys.stderr)
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as e:
        _bail("MINUTES_ENV could not be read: %s (%s)" % (path, e.strerror))
        return

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if not _ENV_KEY_RE.match(k):
            print("[WARN] ignoring invalid key name in %s: %r" % (path, k), file=sys.stderr)
            continue
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if k not in os.environ:
            os.environ[k] = v


_load_env_file()


def token_problem(name, value):
    """Return a human-readable reason a token is unusable, or None if it is
    empty (not configured -> the caller handles that) or looks fine.

    Catches the common setup mistake of leaving the ＜...＞ placeholder in
    minutes.env: an unreplaced placeholder otherwise dies deep inside requests
    with an opaque latin-1 UnicodeEncodeError (Sakura), or fails auth silently
    and shows up only as '要確認' / 'duplicate check could not run' (Backlog).
    """
    if not value:
        return None  # unset == not configured; each caller reports that itself
    if not value.isascii():
        return ("%s に非ASCII文字が含まれています（全角の ＜ ＞ や日本語？）。"
                "~/.config/minutes.env に本物のトークンを設定してください。" % name)
    if any(c in "<>" or c.isspace() for c in value):
        return ("%s に '<' '>' か空白が含まれています（プレースホルダのままか貼り間違い）。"
                "~/.config/minutes.env に本物のトークンを設定してください。" % name)
    return None


# --- Sakura AI Engine (OpenAI-compatible) ---
SAKURA_BASE_URL = os.environ.get("SAKURA_AI_BASE_URL", "https://api.ai.sakura.ad.jp/v1")
SAKURA_TOKEN = os.environ.get("SAKURA_AI_TOKEN", "")
CHAT_MODEL = os.environ.get("SAKURA_CHAT_MODEL", "gpt-oss-120b")
WHISPER_MODEL = os.environ.get("SAKURA_WHISPER_MODEL", "whisper-large-v3-turbo")

# Only ever send to the approved API host (defense in depth).
ALLOWED_HOST_SUFFIX = "sakura.ad.jp"

# --- Backlog (register step + meeting-number auto-numbering) ---
BACKLOG_SPACE = os.environ.get("BACKLOG_SPACE", "tcs-s.backlog.com")
BACKLOG_API_KEY = os.environ.get("BACKLOG_API_KEY", "")
BACKLOG_PROJECT_ID = os.environ.get("BACKLOG_PROJECT_ID", "520525")
BACKLOG_PARENT_ID = os.environ.get("BACKLOG_PARENT_ID", "019f3bd7c41e77b78709ccf2885a1175")
BACKLOG_ADD_LAST = os.environ.get("BACKLOG_ADD_LAST", "true")

# Default recording link (Cybozu shared folder) written into the minutes.
REC_FOLDER_URL = os.environ.get(
    "REC_FOLDER_URL", "https://tcs-s.cybozu.com/o/ag.cgi?page=FileIndex&fCID=45883"
)

# --- Audio chunking (Sakura Whisper limit: 30 min / 30 MB per request) ---
CHUNK_TARGET_SECONDS = int(os.environ.get("CHUNK_TARGET_SECONDS", str(25 * 60)))  # aim ~25 min
CHUNK_MAX_SECONDS = 30 * 60          # hard limit per request
CHUNK_MAX_BYTES = 30 * 1024 * 1024   # hard limit per request
SILENCE_NOISE_DB = os.environ.get("SILENCE_NOISE_DB", "-35dB")
SILENCE_MIN_DUR = float(os.environ.get("SILENCE_MIN_DUR", "0.5"))
SILENCE_SEARCH_WINDOW = int(os.environ.get("SILENCE_SEARCH_WINDOW", str(3 * 60)))  # +/- 3 min

# Paths (relative to the project dir).
PROMPT_TEMPLATE = os.environ.get("PROMPT_TEMPLATE", "prompts/prompt_template.txt")
SPEAKER_ALIASES = os.environ.get("SPEAKER_ALIASES", "speaker_aliases.txt")
GLOSSARY = os.environ.get("GLOSSARY", "glossary.txt")
WORK_DIR = os.environ.get("WORK_DIR", "work")
OUT_DIR = os.environ.get("OUT_DIR", "out")
