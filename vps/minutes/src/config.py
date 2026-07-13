"""Configuration for the minutes service. Secrets come from environment
variables only (never committed): SAKURA_AI_TOKEN, BACKLOG_API_KEY.

Non-secret defaults can be overridden by environment variables too.
"""
import os

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
WORK_DIR = os.environ.get("WORK_DIR", "work")
OUT_DIR = os.environ.get("OUT_DIR", "out")
