"""Env + optional repo-root .env (never overrides variables already set)."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_env(path=None):
    path = Path(path) if path else ROOT / ".env"
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if k and v and not os.environ.get(k):
            os.environ[k] = v


def get(name, default=""):
    return os.environ.get(name) or default


def engine():
    return get("DICTFLOW_ENGINE", "parakeet")


def lang():
    return get("DICTFLOW_LANG", "auto")


def prompt():
    return get("DICTFLOW_PROMPT", "")


def port():
    return int(get("DICTFLOW_PORT", "8765"))
