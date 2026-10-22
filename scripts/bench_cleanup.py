"""Benchmark Haiku cleanup: 'edits' vs 'rewrite' mode, plus a prompt-size / max_tokens sweep.

    uv run python scripts/bench_cleanup.py smoke            # 4 calls
    uv run python scripts/bench_cleanup.py main             # median of 3 runs on texts >150 chars, 1 run on the rest
    uv run python scripts/bench_cleanup.py sweep            # dictionary size, shots, max_tokens
    uv run python scripts/bench_cleanup.py report           # tables + JSON summary from the cache (0 calls)
    add --fake for a zero-cost dry run (no network, no ledger)

Every real call is cached (key = sha256 of mode, model, system, messages, max_tokens, run index) and counted
in a persistent ledger that aborts before call MAX_CALLS+1. Re-running from cache makes 0 calls.
Corpus texts are synthetic. Nothing here prints or logs transcript text except the result tables of the corpus.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from dictflow import cleanup, config, debug  # noqa: E402
from dictflow.dictionary import Dictionary  # noqa: E402

HERE = Path(__file__).resolve().parent
SCRATCH = Path(os.environ.get("BENCH_DIR", "/private/tmp/claude-502/-Users-franciscoribeiro-Documents-Vektrum/f9ecd1ed-ad9d-46ac-a470-a8b13fce821a/scratchpad"))
MAX_CALLS = 90
LONG = 150
CORPUS = json.loads((HERE / "bench_cleanup_corpus.json").read_text())
TEXTS = CORPUS["texts"]
MAIN_DICT = Dictionary(CORPUS["dictionary"])


class Store:
    def __init__(self, fake):
        self.fake = fake
        tag = "fake" if fake else "real"
        self.cache_p = SCRATCH / f"bench_cache_{tag}.json"
        self.ledger_p = SCRATCH / "bench_ledger.json"
        self.cache = json.loads(self.cache_p.read_text()) if self.cache_p.exists() else {}
        self.ledger = json.loads(self.ledger_p.read_text()) if self.ledger_p.exists() else {"calls": 0}

    def save(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        self.cache_p.write_text(json.dumps(self.cache, ensure_ascii=False))
        if not self.fake:
            self.ledger_p.write_text(json.dumps(self.ledger))


def key_of(label, body, run):
    blob = json.dumps([label, body["model"], body["system"], body["messages"], body["max_tokens"], run], ensure_ascii=False)
    return hashlib.sha256(blob.encode()).hexdigest()


def real_call(body):
    if self_store.ledger["calls"] >= MAX_CALLS:
        sys.exit(f"ABORT: ledger is at {self_store.ledger['calls']} calls (cap {MAX_CALLS})")
    self_store.ledger["calls"] += 1
    self_store.save()   # count before the call, so a crash cannot hide spend
    key = config.get("ANTHROPIC_API_KEY")
    t0 = time.perf_counter()
    try:
        d = cleanup._post(cleanup.ANTHROPIC_URL, {"x-api-key": key, "anthropic-version": "2023-06-01"}, body, 30)
        err = None
    except Exception as e:
        d, err = {"content": [], "usage": {}}, type(e).__name__
    ms = round((time.perf_counter() - t0) * 1000)
    u = d.get("usage", {})
    return {"ms": ms, "reply": "".join(b.get("text", "") for b in d["content"] if b.get("type") == "text"),
            "in_tok": u.get("input_tokens"), "out_tok": u.get("output_tokens"), "stop": d.get("stop_reason"),
            "cache_read": u.get("cache_read_input_tokens", 0), "cache_create": u.get("cache_creation_input_tokens", 0),
            "error": err}


def fake_call(body, text, mode):
    ref = next(t["reference"] for t in TEXTS if t["raw"] == text)
    return {"ms": 0, "reply": "[]" if mode == "edits" else ref, "in_tok": 0, "out_tok": 0, "stop": "end_turn",
            "cache_read": 0, "cache_create": 0, "error": None}


def get(text, mode, run, d=MAIN_DICT, label=None, shots=True, max_tokens=None, n_dict=None):
    """One cached call. Returns the cell with the evaluation of its reply attached (computed offline, free)."""
    body = cleanup.anthropic_body(text, d, mode)
    if not shots:
        body["messages"] = body["messages"][-1:]
    if max_tokens:
        body["max_tokens"] = max_tokens
    label = label or f"{mode}"
    k = key_of(label, body, run)
    if k not in self_store.cache:
        self_store.cache[k] = fake_call(body, text, mode) if self_store.fake else real_call(body)
        self_store.cache[k].update(label=label, mode=mode, run=run, chars=len(text), n_dict=n_dict)
        self_store.save()
    cell = dict(self_store.cache[k])
    cell.update(evaluate(text, mode, cell["reply"], d))
    return cell


def norm(s):
    return " ".join(cleanup._words(s))


def evaluate(raw, mode, reply, d):
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        out, _, fb, _ = cleanup.clean(raw, "fake", call=lambda t: reply, d=d, mode_=mode)
    err = buf.getvalue()
    reason = None
    if fb:
        reason = ("guard" if "guardrails" in err else err.split("(")[1].split(")")[0] if "edits rejected" in err else "error")
    return {"out": out, "fell_back": fb, "reason": reason,
            "flip": debug.guess_lang(raw) == "pt" and debug.guess_lang(out) == "en"}


def score(cell, ref):
    return {"exact": cell["out"] == ref, "norm": norm(cell["out"]) == norm(ref)}


def med(xs):
    return statistics.median(xs) if xs else None


def iqr(xs):
    if len(xs) < 2:
        return None
    q = statistics.quantiles(xs, n=4, method="inclusive")
    return [round(q[0]), round(q[2])]


def run_main(modes=("rewrite", "edits"), only=None):
    for t in TEXTS:
        if only is not None and t["id"] not in only:
            continue
        runs = 3 if len(t["raw"]) > LONG else 1
        for r in range(runs):
            for m in (modes if r % 2 == 0 else modes[::-1]):   # interleave, alternate who goes first
                get(t["raw"], m, r)


def run_sweep():
    """2 runs per arm (budget); the baseline arm reuses the main-run cells for the same text and 20-entry dictionary."""
    t = next(x for x in TEXTS if x["category"] == "pt_long_300")["raw"]
    for n in (0, 50, 200):
        d = Dictionary([f"Termo{i:03d}Xyz" for i in range(n)] if n else [])
        for r in range(2):
            get(t, "rewrite", r, d=d, label=f"sweep_dict{n}", n_dict=n)
    for r in range(2):
        get(t, "rewrite", r, label="sweep_noshots", shots=False)
        get(t, "rewrite", r, label="sweep_maxtok1024", max_tokens=1024)


def lstsq(rows):
    """ms = a + b*in_tok + c*out_tok by normal equations (3x3, Cramer)."""
    X = [(1, r["in_tok"], r["out_tok"]) for r in rows]
    y = [r["ms"] for r in rows]
    A = [[sum(x[i] * x[j] for x in X) for j in range(3)] for i in range(3)]
    B = [sum(x[i] * v for x, v in zip(X, y)) for i in range(3)]

    def det(M):
        return (M[0][0] * (M[1][1] * M[2][2] - M[1][2] * M[2][1]) - M[0][1] * (M[1][0] * M[2][2] - M[1][2] * M[2][0])
                + M[0][2] * (M[1][0] * M[2][1] - M[1][1] * M[2][0]))
    D = det(A)
    if abs(D) < 1e-9:
        return None
    sol = []
    for c in range(3):
        M = [row[:] for row in A]
        for i in range(3):
            M[i][c] = B[i]
        sol.append(det(M) / D)
    return sol


def report():
    res = {}
    cells = {m: {} for m in ("rewrite", "edits")}
    for t in TEXTS:
        runs = 3 if len(t["raw"]) > LONG else 1
        for m in cells:
            cells[m][t["id"]] = [get(t["raw"], m, r) for r in range(runs)]
    long_ids = [t["id"] for t in TEXTS if len(t["raw"]) > LONG]
    print(f"{'id':>2} {'category':22} {'chars':>5} | {'rw ms':>6} {'rw tok':>6} {'ed ms':>6} {'ed tok':>6} | rw ok  ed ok  | notes")
    for t in TEXTS:
        i = t["id"]
        row = {}
        for m in cells:
            cs = cells[m][i]
            row[m] = (med([c["ms"] for c in cs]), cs[0]["out_tok"], score(cs[0], t["reference"]), cs[0])
        def flag(m):
            s, c = row[m][2], row[m][3]
            return ("EX" if s["exact"] else "nm" if s["norm"] else "--") + ("F" if c["fell_back"] else " ")
        note = ",".join(x for x in (row["edits"][3]["reason"] or "", "FLIP-ed" if row["edits"][3]["flip"] else "", "FLIP-rw" if row["rewrite"][3]["flip"] else "") if x)
        print(f"{i:>2} {t['category']:22} {len(t['raw']):>5} | {row['rewrite'][0]:>6} {row['rewrite'][1]!s:>6} {row['edits'][0]:>6} {row['edits'][1]!s:>6} | {flag('rewrite')}   {flag('edits')}   | {note}")
    for m in cells:   # summary
        meds = [med([c["ms"] for c in cells[m][i]]) for i in long_ids]
        sc = [score(cells[m][t["id"]][0], t["reference"]) for t in TEXTS]
        c0 = [cells[m][t["id"]][0] for t in TEXTS]
        res[m] = {"median_of_medians_long_ms": med(meds), "iqr_long_ms": iqr(meds), "n_long": len(long_ids),
                  "exact": sum(s["exact"] for s in sc), "norm": sum(s["norm"] for s in sc),
                  "fell_back": sum(c["fell_back"] for c in c0), "fallback_reasons": [c["reason"] for c in c0 if c["fell_back"]],
                  "flips": sum(c["flip"] for c in c0),
                  "all_runs_fell_back_long": sum(c["fell_back"] for i in long_ids for c in cells[m][i]),
                  "all_runs_long": sum(len(cells[m][i]) for i in long_ids),
                  "mean_out_tok_long": statistics.mean(c["out_tok"] for i in long_ids for c in cells[m][i]) if not self_store.fake else None}
    rw, ed = res["rewrite"]["median_of_medians_long_ms"], res["edits"]["median_of_medians_long_ms"]
    res["reduction_pct_long"] = round(100 * (rw - ed) / rw, 1) if rw else None
    res["latency_ratio"] = round(ed / rw, 3) if rw else None
    # per output-token bucket
    buckets = {}
    for m in cells:
        for i in long_ids:
            for c in cells[m][i]:
                b = "<=15" if c["out_tok"] <= 15 else "16-40" if c["out_tok"] <= 40 else "41-80" if c["out_tok"] <= 80 else ">80"
                buckets.setdefault(b, {}).setdefault(m, []).append(c["ms"])
    res["by_out_tokens"] = {b: {m: [len(v), round(statistics.mean(v))] for m, v in d.items()} for b, d in sorted(buckets.items())}
    # sweep
    sw = {}
    groups = {}
    for c in self_store.cache.values():
        if c["label"].startswith("sweep_"):
            groups.setdefault(c["label"], []).append(c)
    pt_long = next(t for t in TEXTS if t["category"] == "pt_long_300")["raw"]
    base = [get(pt_long, "rewrite", r) for r in range(3)]  # 20-entry dictionary, shots, tight max_tokens
    groups["main_dict20"] = base
    for k, v in sorted(groups.items()):
        sw[k] = {"n": len(v), "median_ms": med([c["ms"] for c in v]), "ms": sorted(c["ms"] for c in v),
                 "in_tok": v[0]["in_tok"], "out_tok_med": med([c["out_tok"] for c in v]),
                 "cache_read": max(c["cache_read"] for c in v), "cache_create": max(c["cache_create"] for c in v)}
    res["sweep"] = sw
    rows = [c for c in self_store.cache.values() if c["in_tok"] is not None and not c["error"]]
    if rows and not self_store.fake:
        fit = lstsq(rows)
        if fit:
            res["fit"] = {"intercept_ms": round(fit[0]), "ms_per_100_in_tok": round(100 * fit[1], 1),
                          "ms_per_100_out_tok": round(100 * fit[2], 1), "n": len(rows)}
    res["real_calls_ledger"] = self_store.ledger["calls"]
    res["errors"] = sum(1 for c in self_store.cache.values() if c["error"])
    print(json.dumps(res, indent=1))


def main():
    global self_store
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["smoke", "main", "sweep", "report", "ledger-add"])
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("n", nargs="?", type=int)
    a = ap.parse_args()
    config.load_env()
    self_store = Store(a.fake)
    if a.cmd == "ledger-add":
        self_store.ledger["calls"] += a.n
        self_store.save()
    elif a.cmd == "smoke":
        for tid in (4, 11):
            t = TEXTS[tid]
            for m in ("rewrite", "edits"):
                c = get(t["raw"], m, 0)
                print(tid, m, c["ms"], "ms", c["out_tok"], "tok", "fb" if c["fell_back"] else "ok", c["reason"] or "", "| reply:", c["reply"], "| out:", c["out"])
    elif a.cmd == "main":
        run_main()
    elif a.cmd == "sweep":
        run_sweep()
    if a.cmd != "report":
        print("ledger calls:", self_store.ledger["calls"])
    else:
        report()


if __name__ == "__main__":
    main()
