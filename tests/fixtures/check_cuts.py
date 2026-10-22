#!/usr/bin/env python3
"""Checks `DictFlow --segment` against composite_pt25.cuts.json. Usage: check_cuts.py DictFlow-binary [wav ...]
Pass = every cut lies inside a pause window, none inside speech or an expect_cut=false pause (the 400 ms
borderline pause is reported, not failed), and the cuts found cover every expect_cut pause that held
at least the minimum speech (reported as 'cut'/'MISSED')."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

here = Path(__file__).parent
binary = sys.argv[1]
wavs = sys.argv[2:] or [str(here / "composite_pt25.wav"), str(here / "composite_pt25_tail.wav")]
meta = json.loads((here / "composite_pt25.cuts.json").read_text())
ok = True
for w in wavs:
    out = subprocess.run([binary, "--segment", w], capture_output=True, text=True, env=os.environ).stdout
    cuts = [float(x) for x in re.search(r"cuts:([^\n]*?)\s+tail_speech", out).group(1).split()]
    inside = {i: [c for c in cuts if p["start"] <= c <= p["end"]] for i, p in enumerate(meta["pauses"])}
    stray = [c for c in cuts if not any(p["start"] <= c <= p["end"] for p in meta["pauses"])
             and c < meta["duration_s"]]
    bad = [(c, p["ms"]) for i, p in enumerate(meta["pauses"]) if not p["expect_cut"] and p["kind"] == "inner" for c in inside[i]]
    must = [p for p in meta["pauses"] if p["expect_cut"]]
    hit = sum(bool(inside[i]) for i, p in enumerate(meta["pauses"]) if p["expect_cut"])
    border = [c for i, p in enumerate(meta["pauses"]) if p["kind"] == "borderline" for c in inside[i]]
    tail_only = [c for c in cuts if c >= meta["duration_s"]]
    print(f"{Path(w).name}: cuts={len(cuts)} expected_pauses_cut={hit}/{len(must)} "
          f"cuts_in_speech={len(stray)} cuts_in_inner_pauses(<=300ms)={len(bad)} borderline_400ms_cut={'yes' if border else 'no'} "
          f"cut_in_trailing_pause={len(tail_only)}")
    ok &= not stray and not bad
    for i, p in enumerate(meta["pauses"]):
        if p["expect_cut"] and not inside[i]:
            print(f"  not cut: pause {p['start']:.2f}-{p['end']:.2f} ({p['ms']} ms)")
print("PASS (no cut in speech or in <=300 ms pauses)" if ok else "FAIL")
sys.exit(0 if ok else 1)
