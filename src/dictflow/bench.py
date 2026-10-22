"""Benchmark engines on clips that have a .txt reference next to them."""
import os
import re
import statistics
import sys
import time
from pathlib import Path

from . import audio, config

BR_FORMS = ["fato", "contato", "tela", "time", "registro", "ônibus", "recepção",
            "celular", "trem", "café da manhã"]
_BR_RE = re.compile(r"(?<!\w)(" + "|".join(re.escape(f) for f in BR_FORMS) + r")(?!\w)", re.I)
_PT_WORDS = {"o", "a", "os", "as", "de", "do", "da", "que", "para", "não", "um", "uma", "é", "com", "em", "por", "se"}


def normalize(text):
    text = re.sub(r"[^\w\s]", " ", text.lower())
    return text.split()


def wer(ref, hyp):
    """Word-level Levenshtein distance / reference length, after normalising."""
    r, h = normalize(ref), normalize(hyp)
    if not r:
        return 0.0 if not h else 1.0
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i]
        for j, hw in enumerate(h, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rw != hw)))
        prev = cur
    return prev[-1] / len(r)


def is_portuguese(text):
    words = normalize(text)
    return sum(w in _PT_WORDS for w in words) >= 2 and "the" not in words


def br_flags(ref, hyp):
    """Brazilian-only forms found in hyp; only checked when ref is Portuguese."""
    if not is_portuguese(ref):
        return []
    return sorted({m.group(1).lower() for m in _BR_RE.finditer(hyp)})


def default_clips():
    d = Path(__file__).resolve().parents[2] / "tests" / "fixtures"
    return sorted(d.glob("*.wav"))


def _collect(paths):
    clips = []
    for p in paths:
        p = Path(p)
        for f in sorted(p.glob("*.wav")) if p.is_dir() else [p]:
            ref_file = f.with_suffix(".txt")
            ref = ref_file.read_text().strip() if ref_file.exists() else ""
            if not ref:
                print(f"skip {f.name}: no reference text", file=sys.stderr)
                continue
            samples = audio.trim_silence(audio.load_audio(f))
            if len(samples) == 0:
                print(f"skip {f.name}: no speech", file=sys.stderr)
                continue
            clips.append((f.name, samples, ref))
    return clips


def _ms(t0):
    return (time.perf_counter() - t0) * 1000


def run(clip_paths=None, engines=("parakeet", "whisper"), runs=3, with_cleanup=False, max_wer=None):
    from . import asr

    clips = _collect(clip_paths or default_clips())
    if not clips:
        print("no clips with references found", file=sys.stderr)
        return 1
    lang, prompt = config.lang(), config.prompt()
    worst = 0.0
    for name in engines:
        if name == "groq" and not os.environ.get("GROQ_API_KEY"):
            print(f"[groq] skipped: GROQ_API_KEY is not set")
            continue
        eng = asr.get_engine(name)
        try:
            t = time.perf_counter()
            eng.load()
            cold = _ms(t)
            # whisper loads weights lazily, so fold the first call into cold load
            t = time.perf_counter()
            eng.transcribe(clips[0][1], audio.SR, lang, prompt)
            cold += _ms(t)
        except RuntimeError as e:
            print(f"[{name}] skipped: {e}")
            continue
        print(f"\n[{name}] cold load {cold:.0f} ms (load + first transcription)")
        print(f"{'clip':<18}{'dur s':>7}{'warm ms':>9}{'RTF':>7}{'clean ms':>9}{'WER':>7}  BR-flags")
        wers, warms, rtfs = [], [], []
        for cname, samples, ref in clips:
            dur = len(samples) / audio.SR
            times, text = [], ""
            for _ in range(max(1, runs)):
                t = time.perf_counter()
                text, _lang = eng.transcribe(samples, audio.SR, lang, prompt)
                times.append(_ms(t))
            warm = statistics.median(times)
            cms = "-"
            if with_cleanup and text:
                from . import cleanup
                cms = f"{cleanup.clean(text)[3]:.0f}"
            w = wer(ref, text)
            flags = br_flags(ref, text)
            wers.append(w)
            warms.append(warm)
            rtfs.append(warm / 1000 / dur)
            print(f"{cname:<18}{dur:>7.1f}{warm:>9.0f}{rtfs[-1]:>7.2f}{cms:>9}{w:>7.2%}  {','.join(flags) or '-'}")
        mean = statistics.mean(wers)
        worst = max(worst, mean)
        print(f"summary {name}: cold {cold:.0f} ms, warm median {statistics.median(warms):.0f} ms, "
              f"mean RTF {statistics.mean(rtfs):.2f}, mean WER {mean:.2%}")
    if max_wer is not None and worst > max_wer:
        print(f"FAIL: mean WER {worst:.4f} exceeds --max-wer {max_wer}", file=sys.stderr)
        return 1
    return 0
