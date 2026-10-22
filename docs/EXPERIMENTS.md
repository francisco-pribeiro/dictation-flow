# Latency and language experiments (2026-10-22)

Three experiments ran in separate git worktrees, each on its own branch off `main` at `f497121`. None of them is merged. This file is the only change to `main`.

The baseline for a typical 20-25 s PT-PT dictation on the M4, warm: the wait between releasing the key and the text appearing is about **2.0-2.3 s**. Parakeet ASR takes about 0.6-1.0 s, Haiku cleanup about 1.3-1.5 s, and paste 10-50 ms.

## Summary

| Branch | Worktree | Flag | Verdict | Gain on a 20 s dictation | Cost |
|---|---|---|---|---|---|
| `exp/chunking` | `../dictation-flow-wt/chunking` | `DICTFLOW_CHUNKING=1` (or `"chunking": true` in settings.json) | **Test first.** Promising but flawed | **about -1.1 to -1.2 s** (2.2-2.4 s down to 1.1 s in the sim; 2.0 s down to 0.85-0.9 s with real Haiku, n=2) | Largest change (Swift and worker, about 1700 lines). Text quality after the last fix is unmeasured. Already-sent pieces are billed and captured even if you press Esc |
| `exp/language` | `../dictation-flow-wt/language` | `DICTFLOW_LANG_GUARD=1` | **Test second, passively.** Promising but flawed | 0 s on PT. **+0.9-1.1 s on every English dictation** | Whisper turbo stays loaded next to Parakeet (RAM not measured). Fixes only 1 synthetic clip. The `guess_lang` label fix is worth keeping on its own |
| `exp/llm-edits` | `../dictation-flow-wt/llm-edits` | `DICTFLOW_CLEANUP_MODE=edits` | **Failed. Skip it** | about -0.1 to -0.2 s (paired ratio 0.90 against a 0.70 target) | Fell back to raw, uncleaned text on 3/16 texts and 9/27 long runs (rewrite: 0). Worse grammar next to edits ("do equipa") |

## Measured numbers

### exp/chunking (5 commits, last one `1bfb66c`)

The app cuts the recording at pauses (450 ms pause, at least 4 s of speech per piece) and sends each piece to the worker while you are still talking. After release, only the last piece still needs ASR and cleanup. "Wait" below means release to assembled text, with paste excluded.

| Case | Single shot | Chunked | Ratio (target 0.40 or lower) |
|---|---|---|---|
| Sim, after the fix, immediate release (n=4) | 2275 ms (2228-2353) | 1104 ms (1103-1114) | 0.485 |
| Sim, after the fix, 700 ms pause before release (n=4) | 2408 ms (2306-2552) | 1118 ms (1116-1126) | 0.464 |
| Real Haiku, before the fix, immediate release (n=2, uncontended) | 2059, 1990 ms | 853, 906 ms | 0.434 |
| Real Haiku, before the fix, tail pause (n=1) | 2289 ms | 794 ms | 0.347 |

- The sim cleanup (850 ms + 1.7 ms per char) is pessimistic for chunking: short pieces took 953-989 ms in the sim and 607-778 ms with real Haiku.
- Per piece with real Haiku: ASR 189-569 ms, cleanup 607-778 ms. The floor is about 0.9-1.1 s (last piece ASR plus one Haiku call).
- Quality before the fix: WER 0.086 chunked vs 0.129 single (n=small). 0 PT-to-EN flips. Regressions: "workflow" became "Wispr Flow" in 2/2 chunked runs, and "Envia" became "Envie" in 1 run. The fix raised the minimum piece to 4 s to stop this, but nobody has re-checked it with real Haiku.
- Hung worker: before the fix, the wait was 171894 ms. A 15 s deadline now exists, covered only by `--chunking-test`.
- Tests: 84 pytest passed. All 5 app self-tests pass (`--chunking-test`, `--hotkey-test`, `--timinglog-test`, `--settings-test`, `--shortcut-test`).
- Haiku calls used: 41 in total, 0 after the fix.

### exp/language (2 commits, last one `653eced`)

- The only PT-to-EN flip anyone reproduced came from **Parakeet, not Haiku**. Synthetic clip s07 ("Foi crazy workflow ontem", 1.9 s, macOS `say`) came out as "Foo crazy workflow on thy." in 4/4 runs. Whisper with `language=pt` gave "Fui, Crazy Workflow, Ontem".
- Haiku made 0 language flips in 18 real calls. A probe with fakes found that the cleanup guardrail accepts 2/6 realistic PT-to-EN translations, so Haiku remains a possible cause that is not covered.
- Your real flip has not been reproduced. Your 6 real captures: 0 flips on 3 engines.
- With the guard on (worker in process, cleanup off, 2 reps per clip, load average about 5.5):

| Input | Guard time | Total before cleanup |
|---|---|---|
| 22 PT and mixed clips (44 runs) | 0 ms | 154-1148 ms (unchanged) |
| English, short (`c_en_s`) | 871-1081 ms | 1146-1149 ms (ASR 179-187) |
| English, medium (`c_en_med`) | 871-1081 ms | 1112-1124 ms (ASR 190-212) |
| English, long (`c_en_long`) | 871-1081 ms | 1667-1751 ms (ASR 625-758) |
| s07 (the flip) | 1849-1975 ms | 2056-2153 ms, fixed in 2/2 |

- The trigger is "Parakeet's text looks English", so every genuine English dictation pays about +1 s.
- Separate fix on the same commit: `debug.guess_lang` no longer counts pure PT ("Dá-me", "Só", "registar-me") as `mixed`. On `main`, debug capture still raises false `ENGINES DISAGREE` and `FLIPPED AFTER ENGINE` flags.
- Side findings: Parakeet spells English words in Portuguese ("crazy" became "crasí", "meeting" became "mirem", "pipeline" became "pipelino") and dropped "merge" in real capture 0005. Haiku once changed "meeting" to "reunião". Parakeet produced `<unk>` bursts in 2 of about 300 runs under load, and nothing strips them before paste.
- Tests: 72 passed.

### exp/llm-edits (5 commits, last one `f4ab3a8`)

- In edits mode, Haiku returns `[find, replace]` pairs instead of the whole text.
- Latency, paired per text (9 texts over 150 chars): median ratio 0.899 from cache and 0.828 live (n=5). Live means: rewrite 1023 ms, edits 833 ms. Per-text ratios ranged from 0.733 to 1.134.
- Why the gain is small: Haiku time is about 457 ms fixed + 0.092 ms per input token + 6.67 ms per output token. Each JSON pair costs 8-15 output tokens, so mean output on long texts only fell from 55 to 36 tokens.
- Quality (16 texts): rewrite matched 16/16 normalised and fell back on 0. Edits matched 13/16 and fell back on 3/16, every time because Haiku gave a find that matched more than once.
- The sweep found no other lever: dictionary size from 0 to 200 entries, shots and `max_tokens` all stayed within noise (about 200 ms). Prompt cache hits were 0 on every call.
- Tests: 94 passed. Rewrite mode sends a request byte-identical to `main` (SHA-256 match over 24 requests).
- Haiku calls used: 96 against a budget of 90.

## Build state (checked 2026-10-22 evening)

| Bundle | Signature | Usable? |
|---|---|---|
| `dictation-flow/build/DictFlow.app` (main) | Authority=Vektrum Recorder Local | yes |
| `dictation-flow-wt/language/build/DictFlow.app` | Authority=Vektrum Recorder Local (19:26) | yes, no rebuild needed (no Swift changes) |
| `dictation-flow-wt/llm-edits/build/DictFlow.app` | **ad hoc**, leftover `DictFlow.cstemp` | no. Rebuild first (no Swift changes, so only for completeness) |
| `dictation-flow-wt/chunking/build/DictFlow.app` | **ad hoc**, leftover `DictFlow.cstemp` (21:41) | **no. You must rebuild it**: the Swift code changed |

The two ad hoc bundles exist because codesign was waiting on a keychain "allow access to key" dialog that a headless session cannot answer. If one is still open on your screen, dismiss it. When you rebuild yourself, click **Always Allow**. Never launch an ad hoc bundle: it puts the mic, Accessibility and Input Monitoring permissions at risk.

## How to test each branch

### Rules for every branch

- Quit the main app first, so only one app holds the hotkey. Quitting the app also stops its worker on 8765, which is a child process.
- Give each branch its own worker port with `--env DICTFLOW_PORT=...`. The app polls that port, so it can never silently reuse main's worker. Environment variables win over `.env`, and each worktree's `.env` is a symlink to yours, so Haiku works.
- Pass flags with `open --env`. Never write them into `.env`: that is the same file `main` uses.
- Debug capture keeps only the newest 30 dictations. If a dictation goes wrong, copy its `.wav` and `.json` out of `~/Library/Logs/DictFlow/debug/` right away.

```
osascript -e 'quit app "DictFlow"'; sleep 2
lsof -nP -iTCP:8765 -sTCP:LISTEN     # must print nothing
```

### 1. exp/chunking

```
cd /Users/franciscoribeiro/Documents/Projetos/dictation-flow-wt/chunking
DICTFLOW_SIGN_IDENTITY="Vektrum Recorder Local" ./build.sh      # click Always Allow on the keychain prompt
codesign -dvv build/DictFlow.app 2>&1 | grep Authority          # must print Authority=Vektrum Recorder Local; otherwise stop
open --env DICTFLOW_CHUNKING=1 --env DICTFLOW_PORT=8766 --stderr /tmp/dictflow-chunking.log build/DictFlow.app
lsof -nP -iTCP:8766 -sTCP:LISTEN
```

What to dictate: 3-5 dictations of 20-30 s in PT-PT, each with an English word and natural pauses. Also one with a 1 s thinking pause mid-sentence, one in English, and one short 3 s dictation (it should behave exactly as on main, as 1 piece). For example: "Hoje revi o workflow com a Marta. Acho que o fornecedor está a ser um bocado crazy com os preços. Envia o orçamento até sexta. Não, envia na segunda."

What to read:
- `tail -5 ~/Library/Logs/DictFlow/timings.log`: chunked lines end with `chunks=N tail_audio=X.Xs wait=...ms`. Compare that `wait=` with the `total` on today's main lines. Expect about 1.0-1.2 s against 2.0-2.4 s.
- Text: pasted once, in order, with no `. lowercase` break at the pause. "workflow" must not become "Wispr Flow", "Envia" must not become "Envie", and no PT sentence may come out in English.
- Esc after the first pause: nothing is pasted, but `grep 'POST /transcribe' /tmp/dictflow-chunking.log` shows the piece already sent. This is expected.
- A password field mid-dictation: the remaining pieces are not cleaned up.

### 2. exp/language

The bundle is already signed. Rebuilding is optional:

```
cd /Users/franciscoribeiro/Documents/Projetos/dictation-flow-wt/language
# A side, guard off (main behaviour plus the guess_lang label fix):
open --env DICTFLOW_PORT=8767 --stderr /tmp/dictflow-language.log build/DictFlow.app
# B side, guard on (quit, then reopen):
osascript -e 'quit app "DictFlow"'; sleep 2
open --env DICTFLOW_LANG_GUARD=1 --env DICTFLOW_PORT=8767 --stderr /tmp/dictflow-language.log build/DictFlow.app
ps -ax -o pid,command | grep 'dictation-flow-wt/language' | grep serve     # the branch worker must be the one running
```

What to dictate: "Foi crazy workflow ontem." / "Isto está crazy." / "O workflow ficou pronto." / "Vou marcar a meeting amanhã.", one of your normal 20-30 s PT dictations with one English word, and pure English (short, plus a 20 s paragraph).

What to read:
- The guard time is not printed in the log line. It is only inside `total=` and in each capture's json:

```
ls -t ~/Library/Logs/DictFlow/debug/*.json | head -3 | xargs -I{} python3 -c "import json;d=json.load(open('{}'));print('{}'.split('/')[-1],d['timings_ms'],d.get('guess_lang_raw_engine'))"
```

- After any flip, replay it with the fixed labels:

```
cd /Users/franciscoribeiro/Documents/Projetos/dictation-flow-wt/language
uv run dictflow replay ~/Library/Logs/DictFlow/debug/<stem>.wav --engines parakeet,whisper-pt,whisper-auto   # add --cleanup for Haiku (1 call per engine)
```

`ENGINES DISAGREE` means the ASR engine flipped the language. `FLIPPED AFTER ENGINE` means cleanup or the dictionary did. With the guard on, `raw_engine` in the capture holds Whisper's text, not Parakeet's. Replay re-runs the engines, so this is recoverable.

### 3. exp/llm-edits (optional, failed)

Only run this if you want to hear the failure yourself.

```
cd /Users/franciscoribeiro/Documents/Projetos/dictation-flow-wt/llm-edits
DICTFLOW_SIGN_IDENTITY="Vektrum Recorder Local" ./build.sh
codesign -dvv build/DictFlow.app 2>&1 | grep Authority          # must print Authority=Vektrum Recorder Local
open --env DICTFLOW_CLEANUP_MODE=edits --env DICTFLOW_PORT=8768 --stderr /tmp/dictflow-llm-edits.log build/DictFlow.app
# rewrite arm: quit, then reopen without DICTFLOW_CLEANUP_MODE
grep -E 'mode=(edits|rewrite)' /tmp/dictflow-llm-edits.log      # compare cleanup= per mode
```

What to watch for: raw text pasted with the fillers left in (an edits fallback), "do equipa"-type agreement errors, and broken ".NET", "p.m." or "Dr.".

### Headless tests, any worktree

```
cd /Users/franciscoribeiro/Documents/Projetos/dictation-flow-wt/<name> && uv run pytest -q
# chunking only, app self-test:
/Users/franciscoribeiro/Documents/Projetos/dictation-flow-wt/chunking/build/DictFlow.app/Contents/MacOS/DictFlow --chunking-test
```

## Return to main

```
osascript -e 'quit app "DictFlow"'; sleep 2
lsof -nP -iTCP:8766 -iTCP:8767 -iTCP:8768 -sTCP:LISTEN     # if a branch worker still listens, kill only that PID
open /Users/franciscoribeiro/Documents/Projetos/dictation-flow/build/DictFlow.app        # or however you normally launch it
```

If you put `"chunking": true` in `~/Library/Application Support/DictFlow/settings.json`, remove it. Main ignores the key, but the next chunking build would read it.

## Combining winners later

The branches overlap in a few files:
- `server.py` is touched by all three.
- `debug.py` and `tests/test_debug.py` are touched by chunking and language.
- `cleanup.py` is touched by chunking and llm-edits.

Plan for a merge and conflicts in those files. Suggested path, after you have chosen:

1. Create a new branch from `main`. Never stack branches on top of each other: `git worktree add ../dictation-flow-wt/combined -b exp/combined main`.
2. Merge chunking whole, if it passes your test: `git merge --no-ff exp/chunking`.
3. Take only the `guess_lang` fix from language. Commit `653eced` bundles it with the guard, so apply just the debug files: `git show 653eced -- src/dictflow/debug.py tests/test_debug.py | git apply -3`. Then resolve against chunking's per-session capture changes in the same files.
4. Add the guard (`asr.py`, the `server.py` hunk) only if a real flip is confirmed to be Parakeet's. Fix its cost first (see open questions).
5. Leave out llm-edits. If you ever revisit the idea, the useful leftover is its bench script (`scripts/bench_cleanup.py`) and latency model, not the edits mode.
6. Run `uv run pytest -q`, the app self-tests and a signed build. Then A/B the combined build against main, using the same steps as above.

## Open questions

1. **Who flips the language on your real voice?** It is still unreproduced. The only reproduced flip is Parakeet on a synthetic 1.9 s clip. Keep debug capture on and replay the first real flip before the 30-file pruning removes it.
2. **A cheaper guard trigger.** The guard currently fires on every English dictation, at +0.9-1.1 s each. Firing only on short clips, or only when the text also contains PT stopwords or diacritics, was not explored.
3. **The guard's RAM cost.** Extra RAM with Whisper turbo resident next to Parakeet was not measured.
4. **Chunking text quality after `1bfb66c`.** The 4 s minimum, the mid-sentence join, the tolerant echo guard and the partial flag have not been re-run with real Haiku. Is "workflow" to "Wispr Flow" gone?
5. **Chunking below 0.40.** The floor is the last piece's ASR plus one Haiku call. Levers not yet built: skip or shorten cleanup on a short tail, or decode the WAV natively instead of spawning ffmpeg (about 40 ms).
6. **Chunking's hung-worker path after the fix.** It is covered only by `--chunking-test`. Before the fix, the wait was 172 s.
7. **The cleanup guardrail lets translations through.** It accepted 2/6 realistic PT-to-EN translations in a probe with fakes. This is not fixed on any branch.
8. **Parakeet garbling English words** ("crasí", "mirem", "pipelino", a dropped "merge"). A dictionary entry or the engine choice may matter more than language ID.
9. **`<unk>` bursts.** Parakeet produced them in 2 of about 300 runs under load, and nothing strips them before paste. The cause is unknown.
10. **Haiku swapping your English terms** ("meeting" to "reunião"). Should the prompt keep English words you chose on purpose?
11. **Permissions.** Will macOS ask again for Microphone, Accessibility or Input Monitoring for a worktree bundle? It has the same bundle id and signing identity but a different path. Not verified.
12. **Hotkey, mic, paste and real pauses with breath and room noise** were not verified on any branch, because none of it can be checked headless.
