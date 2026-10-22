"""Opt-in debug capture (DICTFLOW_DEBUG_CAPTURE=1) and the `dictflow replay` tool.

Capture stores the user's voice and text on disk, so it is off by default and the worker announces it at startup.
"""
import itertools
import json
import os
import re
import sys
import time
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

KEEP = 30
_counter = itertools.count(1)

# Accent-free stopwords. Words that are valid in both languages (a, no, me, so...) are left out on purpose.
PT = set("""o os as um uma uns umas de do da dos das em na nos nas num numa por para com sem sobre entre ate
e ou mas que se nao sim eu tu ele ela nos eles elas voce voces meu minha meus minhas teu tua seu sua nosso nossa
isto isso aquilo este esta estes estas esse essa esses essas aquele aquela ao aos pelo pela pelos pelas
foi ser sou es somos sao era estou esta estao estava tem tenho temos tinha ha ja ainda muito muita
mais menos tambem quando como onde porque porquê entao pois depois antes agora hoje amanha ontem aqui ali la
bom boa dia bem obrigado obrigada preciso precisa fazer faz vamos vai vou facto equipa contacto""".split())
EN = set("""the an and or but of to in on at by for with from about into over than then that this these those
i you he she it we they me my your his her its our their is are was were be been am do does did have has had
will would can could should not it's don't just so very really what when where why how which who there here
hello hi thanks thank please yes lunch meeting tomorrow today""".split())


def _tokens(text):
    s = unicodedata.normalize("NFKD", text.lower().replace("’", "'"))
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.findall(r"[a-z']+", s)


def guess_lang(text):
    """'pt', 'en', 'mixed' or 'unknown' from stopword hits. A lone English word in a PT sentence stays 'pt'."""
    toks = _tokens(text or "")
    pt = sum(t in PT for t in toks)
    en = sum(t in EN for t in toks)
    if pt + en == 0:
        return "unknown"
    share = pt / (pt + en)
    if share >= 0.7:
        return "pt"
    if share <= 0.3:
        return "en"
    return "mixed"


def enabled():
    return os.environ.get("DICTFLOW_DEBUG_CAPTURE") == "1"


def debug_dir():
    return Path.home() / "Library" / "Logs" / "DictFlow" / "debug"


def _write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


_SESSION = re.compile(r"-s([0-9a-f]{8})-\d+$")


def _dictation(stem):
    """The pieces of one chunked dictation share a session id in their name and count as one dictation."""
    m = _SESSION.search(stem)
    return m.group(1) if m else stem


def _prune(d, keep=KEEP):
    stems = sorted({p.stem for p in d.iterdir() if p.suffix in (".wav", ".json")})
    last = {}   # dictation -> position of its newest piece
    for i, stem in enumerate(stems):
        last[_dictation(stem)] = i
    keep_set = set(sorted(last, key=last.get)[-keep:]) if keep else set()
    for stem in stems:
        if _dictation(stem) in keep_set:
            continue
        for ext in (".wav", ".json"):
            try:
                (d / (stem + ext)).unlink()
            except OSError:
                pass


def capture(wav, lang, res, raw_engine, chunk=None):
    """Write the wav + json pair. Call only after the HTTP response is sent. Never raises.
    `chunk` is set for a piece of a chunked dictation: session, seq, ctx flag and the read-only previous-segment
    context itself (text, stored under the same opt-in as everything else here), so replay can reproduce it."""
    try:
        d = debug_dir()
        d.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(d, 0o700)
        stem = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}Z-{next(_counter):04d}"
        if chunk and chunk.get("session") and chunk.get("seq") is not None:
            stem += f"-s{chunk['session']}-{chunk['seq']}"
        info = {
            "raw_engine": raw_engine, "raw": res["raw"], "text": res["text"], "engine": res["engine"],
            "lang": lang, "cleanup_provider": res["cleanup_provider"], "fell_back": res["fell_back"],
            "timings_ms": res["timings_ms"], "guess_lang_raw_engine": guess_lang(raw_engine),
            "guess_lang_raw": guess_lang(res["raw"]), "guess_lang_text": guess_lang(res["text"]),
        }
        if chunk:
            info.update(chunk)
        _write(d / (stem + ".wav"), wav)
        _write(d / (stem + ".json"), json.dumps(info, ensure_ascii=False, indent=1).encode())
        _prune(d)
    except Exception:
        pass


# ---- replay ----

ENGINE_NAMES = ("parakeet", "whisper-pt", "whisper-auto")


def _default_engine(name):
    from . import asr
    if name == "parakeet":
        return asr.ParakeetEngine(), "auto"
    return asr.WhisperEngine(), "pt" if name == "whisper-pt" else "auto"


def _files(files, dirpath):
    if files:
        return [Path(f) for f in files]
    return sorted((Path(dirpath) if dirpath else debug_dir()).glob("*.wav"))


def run_replay(files, dirpath, engines, do_cleanup, as_json, make_engine=_default_engine, clean=None, out=None):
    """Run each engine in process over each wav and print a table. make_engine/clean are injectable for tests."""
    from . import audio, cleanup, config, dictionary
    out = out or sys.stdout
    bad = [e for e in engines if e not in ENGINE_NAMES]
    if bad:
        raise ValueError(f"unknown replay engine {bad[0]!r} (choose from {', '.join(ENGINE_NAMES)})")
    wavs = _files(files, dirpath)
    if not wavs:
        print("no wav files", file=sys.stderr)
        return 1
    if do_cleanup and clean is None:
        clean = lambda t, d, **kw: cleanup.clean(t, d=d, **kw)  # noqa: E731
    d = dictionary.current()
    loaded = {}
    results = []
    for w in wavs:
        samples = audio.trim_silence(audio.load_audio(w, fmt="wav"))
        row = {"file": w.name, "audio_s": round(len(samples) / audio.SR, 1), "engines": {}, "flags": []}
        side = w.with_suffix(".json")
        stored = None
        if side.exists():
            try:
                stored = json.loads(side.read_text())
            except (OSError, ValueError):
                pass
        # a piece of a chunked dictation is replayed with the same read-only context and mid-sentence flag
        kw = {}
        if stored and stored.get("context"):
            kw["context"] = stored["context"]
        if stored and stored.get("partial"):
            kw["partial"] = True
        for name in engines:
            if name not in loaded:
                eng, lg = make_engine(name)
                eng.load()
                loaded[name] = (eng, lg)
            eng, lg = loaded[name]
            t = time.perf_counter()
            text = eng.transcribe(samples, audio.SR, lg, dictionary.asr_prompt(config.prompt(), d))[0] if len(samples) else ""
            ms = round((time.perf_counter() - t) * 1000)
            try:
                text = d.apply(text)
            except Exception:
                pass
            r = {"ms": ms, "lang": guess_lang(text), "text": text}
            if do_cleanup:
                r["cleaned"] = clean(text, d, **kw)[0] if text else ""
                r["cleaned_lang"] = guess_lang(r["cleaned"])
            row["engines"][name] = r
        langs = {r["lang"] for r in row["engines"].values()} - {"unknown"}
        if len(langs) > 1:
            row["flags"].append("ENGINES DISAGREE: " + ", ".join(f"{n}={r['lang']}" for n, r in row["engines"].items()))
        if stored:
            a, b = guess_lang(stored.get("raw_engine", "")), guess_lang(stored.get("text", ""))
            row["stored"] = {"raw_engine_lang": a, "text_lang": b}
            if stored.get("session"):
                row["stored"].update(session=stored["session"], seq=stored.get("seq"), ctx=bool(stored.get("ctx")))
            if "unknown" not in (a, b) and a != b:
                row["flags"].append(f"FLIPPED AFTER ENGINE: stored raw_engine={a} but final text={b} (cleanup/dictionary, not the engine)")
        results.append(row)
    if as_json:
        print(json.dumps(results, ensure_ascii=False, indent=1), file=out)
        return 0
    for row in results:
        for i, (name, r) in enumerate(row["engines"].items()):
            head = f"{row['file']}  {row['audio_s']}s" if i == 0 else ""
            line = f"{head:<44} {name:<12} {r['ms']:>5}ms  {r['lang']:<7} {r['text'][:80]}"
            print(line, file=out)
            if do_cleanup:
                print(f"{'':<44} {'+cleanup':<12} {'':>7}  {r['cleaned_lang']:<7} {r['cleaned'][:80]}", file=out)
        for f in row["flags"]:
            print(f"  !! {f}", file=out)
    return 0
