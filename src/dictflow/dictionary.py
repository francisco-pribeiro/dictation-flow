"""Personal dictionary: canonical terms and 'wrong -> Right' replacements.

File format, one entry per line, '#' starts a comment:
    Supabase                      canonical spelling (vocabulary)
    super base -> Supabase        replacement; 'a | b -> Right' maps several wrongs
Local only. A missing or malformed file never raises: bad lines are skipped.
"""
import os
import re
import unicodedata
from pathlib import Path

from . import config

MAX_PROMPT_ENTRIES = 150
MAX_PROMPT_CHARS = 3000
ASR_PROMPT_CHARS = 500  # ~150 tokens, under whisper's 224-token initial prompt


def path():
    p = config.get("DICTFLOW_DICTIONARY")
    return Path(p).expanduser() if p else Path.home() / "Library/Application Support/DictFlow/dictionary.txt"


def _norm(s):
    return " ".join(s.split())


def _key(s):
    return _norm(s).casefold()


def parse_line(line):
    """Return ('term', Term), ('rep', [wrongs], Right) or None for blank, comment or malformed."""
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    if "->" in line:
        left, right = line.split("->", 1)
        right = _norm(right)
        wrongs = [_norm(w) for w in left.split("|")]
        if not right or "->" in right or not wrongs or not all(wrongs):
            return None
        return ("rep", wrongs, right)
    if "|" in line:
        return None
    return ("term", _norm(line))


class Dictionary:
    def __init__(self, lines=()):
        self.terms, self.replacements = [], {}  # replacements: casefolded wrong -> (wrong, Right)
        for line in lines:
            e = parse_line(line)
            if not e:
                continue
            if e[0] == "term":
                if e[1] not in self.terms:
                    self.terms.append(e[1])
            else:
                for w in e[1]:
                    self.replacements.setdefault(_key(w), (w, e[2]))
        keys = sorted(self.replacements, key=len, reverse=True)
        self._rx = re.compile(
            r"(?<!\w)(?:" + "|".join(r"\s+".join(map(re.escape, k.split())) for k in keys) + r")(?!\w)",
            re.I) if keys else None

    def __bool__(self):
        return bool(self.terms or self.replacements)

    def apply(self, text):
        """Case-insensitive, word-boundary, longest-first replacement; the Right form is kept exactly."""
        if not self._rx or not text:
            return text
        return self._rx.sub(lambda m: self.replacements[_key(m.group(0))][1], text)

    def vocab(self):
        """Accent-free lowercase words the dictionary vouches for (for the content guard)."""
        out = set()
        for s in self.terms + [r for _, r in self.replacements.values()]:
            out.update(words(s))
        return out

    def wrong_to_right(self):
        """{wrong word: right words} so a replaced word is not counted as lost."""
        return {w: set(words(r)) for _, (wr, r) in self.replacements.items() for w in words(wr)}

    def prompt_entries(self):
        """Terms first, then replacements; capped. Escaped and single-line, safe to embed in a prompt."""
        lines = [_esc(t) for t in self.terms] + [f"{_esc(w)} -> {_esc(r)}" for w, r in self.replacements.values()]
        out, n = [], 0
        for ln in lines[:MAX_PROMPT_ENTRIES]:
            n += len(ln) + 1
            if n > MAX_PROMPT_CHARS:
                break
            out.append(ln)
        return out


def _esc(s):
    return s.replace("<", "&lt;").replace(">", "&gt;")


def words(s):
    s = unicodedata.normalize("NFKD", s.lower())
    return re.sub(r"[^\w\s]", " ", "".join(c for c in s if not unicodedata.combining(c))).split()


_cache = {"sig": None, "dict": Dictionary()}


def current():
    """The dictionary, re-read when the file's mtime or size changes. Never raises."""
    p = path()
    try:
        st = p.stat()
        sig = (str(p), st.st_mtime_ns, st.st_size)
    except OSError:
        sig = (str(p), None, None)
    if sig != _cache["sig"]:
        try:
            d = Dictionary(p.read_text(encoding="utf-8").splitlines()) if sig[1] else Dictionary()
        except (OSError, UnicodeDecodeError, re.error):
            d = Dictionary()
        _cache.update(sig=sig, dict=d)
    return _cache["dict"]


def asr_prompt(base="", d=None):
    """DICTFLOW_PROMPT first, then dictionary terms and corrected forms, within ASR_PROMPT_CHARS."""
    d = current() if d is None else d
    parts = [base.strip()] if base.strip() else []
    extra = d.terms + [r for _, r in d.replacements.values() if r not in d.terms]
    seen = {p.casefold() for p in parts}
    for t in extra:
        if t.casefold() in seen:
            continue
        cand = ", ".join(parts + [t])
        if len(cand) > ASR_PROMPT_CHARS and parts:
            break
        parts.append(t)
        seen.add(t.casefold())
    return ", ".join(parts)


# ---- file editing (CLI) ----

def _read_lines():
    try:
        return path().read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []


def _write_lines(lines):
    p = path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def add(text):
    """Add an entry. Returns 'added', 'updated' (same wrong, new Right) or 'exists'. Raises ValueError if malformed."""
    e = parse_line(text)
    if not e:
        raise ValueError("expected 'Term' or 'wrong -> Right'")
    lines = _read_lines()
    if e[0] == "term":
        canon = e[1]
        if any((pe := parse_line(l)) and pe[0] == "term" and _key(pe[1]) == _key(canon) for l in lines):
            return "exists"
        _write_lines(lines + [canon])
        return "added"
    _, wrongs, right = e
    new = " | ".join(wrongs) + " -> " + right
    status, out = "added", []
    wk = {_key(w) for w in wrongs}
    for l in lines:
        pe = parse_line(l)
        if pe and pe[0] == "rep":
            have = {_key(w) for w in pe[1]}
            if wk <= have and pe[2] == right:
                return "exists"
            if have & wk:
                # drop the overlapping wrongs from the old line, keep its other wrongs
                rest = [w for w in pe[1] if _key(w) not in wk]
                status = "updated"
                if rest:
                    out.append(" | ".join(rest) + " -> " + pe[2])
                continue
        out.append(l)
    _write_lines(out + [new])
    return status


def remove(text):
    """Remove by whole line, term, Right form (drops the line) or a wrong form (drops just that wrong). Returns lines changed."""
    k = _key(text)
    out, n = [], 0
    for l in _read_lines():
        pe = parse_line(l)
        if not pe:
            out.append(l)
        elif pe[0] == "term":
            n += _key(pe[1]) == k
            if _key(pe[1]) != k:
                out.append(l)
        elif _key(l) == k or _key(pe[2]) == k:
            n += 1
        else:
            rest = [w for w in pe[1] if _key(w) != k]
            if len(rest) == len(pe[1]):
                out.append(l)
            else:
                n += 1
                if rest:
                    out.append(" | ".join(rest) + " -> " + pe[2])
    if n:
        _write_lines(out)
    return n


def entries():
    return [l.strip() for l in _read_lines() if parse_line(l)]
