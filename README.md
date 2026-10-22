# dictation-flow

A personal, free replacement for the dictation part of Wispr Flow. Hold a key, speak PT-PT or English, release: the text is transcribed locally and pasted into the focused app. An optional LLM pass removes fillers, resolves self-corrections and fixes Brazilian spellings.

Repo location: `~/Documents/Projetos/dictation-flow`. The build bakes the repo path into the app, so run `./build.sh` again if you move the repo.

## Overview

Two processes, split along the macOS permission boundary:

- **`dictflow` (Python, `src/dictflow`)** is the worker. It decodes audio, trims silence, runs the ASR engine, runs the optional cleanup, and serves it all on `127.0.0.1:8765` with the model kept warm. It needs no macOS permissions: it only computes and makes outgoing HTTPS calls. It is also a CLI, so everything except the hotkey, microphone and paste can be tested from audio files.
- **`DictFlow.app` (Swift, `app/`)** is a menu-bar app (no Dock icon). It holds every permission-sensitive piece: the global hotkey (event tap), the microphone, and the paste (synthetic Cmd-V). It starts the worker as a child process and kills it on quit.

Why permissions live only in the `.app`: macOS grants Microphone, Accessibility and Input Monitoring per app identity. One signed bundle with a stable identifier (`pt.franciscoribeiro.dictflow`) means three grants in one place, and the worker, which also reads your API keys from `.env`, never touches them.

Pipeline: right Option held -> record -> 16 kHz mono WAV -> `POST /transcribe` -> ASR (+ optional cleanup) -> paste.

Measured on the MacBook Air M4 (2026-10-22, synthetic TTS fixtures of 2-5 s, model already downloaded):

| Step | Time |
|---|---|
| Worker start (parakeet load + warm-up) | 2.5-3.6 s |
| Parakeet ASR, warm (bench median) | 170-320 ms |
| Worker request without cleanup (`POST /transcribe`, decode + ASR) | 410-500 ms |
| Worker request with Haiku cleanup | 850-950 ms |
| First request after start, with Haiku cleanup | 2.3 s (first real ASR call is slower) |
| Whisper large-v3-turbo ASR, warm | about 2.1 s (cold 17 s) |

Running cost: 0 with cleanup off or Ollama; cents per month with Haiku or the Groq free tier.

## Features and shortcuts

| What | How |
|---|---|
| Dictate (hold) | Hold the hotkey (default right Option), speak, release |
| Hands-free | Tap the hotkey twice quickly: recording latches (`◉`); one press stops and pastes, Esc cancels |
| Change the hotkey | Menu **Atalho** (presets or **Gravar novo atalho...**); applies at once |
| Paste last transcript | **Cmd+Ctrl+Z** (configurable under **Atalho**), or menu **Colar ultima transcricao** |
| Copy last transcript | Menu **Copiar ultima transcricao** (or click the "Last:" line) |
| Personal dictionary | Menu **Dicionario** (entry count, **Adicionar ao dicionario...**, **Abrir dicionario**), or `dictflow dict` |
| Optional cleanup | Haiku (or Groq/Ollama) removes fillers, resolves self-corrections, fixes PT-BR spellings; see Configuration |

### settings.json

`~/Library/Application Support/DictFlow/settings.json`, written by the menu (never edit it while the app runs). Both keys are optional:

```json
{ "hotkey": "rightctrl", "pasteShortcut": "ctrl+cmd+z" }
```

`hotkey` is one of `rightoption`, `rightcmd`, `rightctrl`, `fn`, `leftoption`, `leftcmd`, `leftctrl`, `leftshift`, `rightshift`. `pasteShortcut` is modifiers plus one letter or digit (`ctrl`, `cmd`, `opt`, `shift`). Unknown or corrupt values fall back to the defaults. The saved hotkey wins over `DICTFLOW_HOTKEY`.

## Requirements

- macOS 14+ on Apple Silicon (tested on macOS 15.7.4)
- Xcode Command Line Tools (`xcode-select --install`; full Xcode is not needed)
- [uv](https://docs.astral.sh/uv/) at `/opt/homebrew/bin/uv`, `~/.local/bin/uv` or `/usr/local/bin/uv` (the app looks only there)
- ffmpeg

## Installed software and downloads

- brew packages: none new. `uv` and `ffmpeg` were already installed (`brew install uv ffmpeg` if you lack them).
- Python dependencies (installed into `.venv` by `uv sync`): `parakeet-mlx`, `mlx-whisper`, `numpy`; dev: `pytest`.
- Models, fetched from Hugging Face on first use into `~/.cache/huggingface`:
  - `mlx-community/parakeet-tdt-0.6b-v3`, about 2.4 GB (default engine)
  - `mlx-community/whisper-large-v3-turbo`, about 1.5 GB (only if you use `whisper`)
- Optional, for local cleanup: `ollama pull qwen2.5:3b` (requires Ollama).

## Install

From the repo root:

```bash
# 1. Python worker and its dependencies
uv sync

# 2. Download the ASR model once, before opening the app (about 2.4 GB).
#    The app gives the worker 60 s to start, which is not enough for the download.
uv run dictflow transcribe tests/fixtures/pt_facto.wav
#    Only if you will use whisper:
uv run dictflow transcribe tests/fixtures/pt_facto.wav --engine whisper

# 3. Optional: keys and settings (see Configuration). Without .env everything is local and cleanup is off.
cp .env.example .env

# 4. Optional but recommended: a stable signing identity (see Signing), then:
export DICTFLOW_SIGN_IDENTITY='DictFlow Local'

# 5. Build the app
./build.sh                      # writes build/DictFlow.app

# 6. Check the build headlessly (no permissions needed)
uv run pytest -q
build/DictFlow.app/Contents/MacOS/DictFlow --pipeline-test tests/fixtures/pt_facto.wav
#    expected last line: O facto é que a equipa precisa do contacto antes de sexta-feira.
#    (quit DictFlow first: a running worker on 8765 is reused instead of the new build's; see Usage)
```

## Run

```bash
open build/DictFlow.app
```

**Rebuilding resets permissions unless you sign with the `DictFlow Local` certificate** (see Signing): with the default ad-hoc signature macOS treats each build as a new app and asks for Microphone, Accessibility and Input Monitoring again.

Then do the manual checklist below once. To see the app's log while testing:

```bash
open --stderr /tmp/dictflow.log build/DictFlow.app && tail -f /tmp/dictflow.log
```

To change the hotkey, use the menu: **Atalho** lists the presets (Option direito, Command direito, Control direito, Fn) with a checkmark on the current one, and **Gravar novo atalho...** records the next modifier key you press (Esc cancels; any modifier key works, left or right). It applies immediately and is saved to `~/Library/Application Support/DictFlow/settings.json`. The saved choice wins over `DICTFLOW_HOTKEY`, which only sets the default when settings.json has none:

```bash
open --env DICTFLOW_HOTKEY=rightcmd build/DictFlow.app      # or fn, rightctrl, rightoption (default)
```

**Hands-free:** tap the key twice quickly (second press within 400 ms of the first release, both presses shorter than 250 ms) and recording latches: the icon turns `◉` and a short sound plays. Let go and keep talking; the next single press stops and transcribes, Esc cancels without pasting. The 120 s cap still applies. Holding the key works as before. The logic is `HotkeyMachine` (`app/Sources/DictFlow/HotkeyMachine.swift`).

**Paste last transcript:** **Cmd+Ctrl+Z** (default; shown as Ctrl+Cmd+Z in the menu) re-pastes the last final text (after dictionary and cleanup) at the cursor, and the focused app does not see the keystroke. The text is kept in memory only, never on disk, and is lost when the app quits. Menu items **Colar ultima transcricao** and **Copiar ultima transcricao** do the same from the menu. With nothing dictated yet, or while recording or transcribing, you only get a beep. Change the shortcut under **Atalho > Colar ultima transcricao** (presets, or **Gravar novo atalho de colar...**: press modifiers plus a letter or digit, including Ctrl or Opt; Cmd alone is refused so Cmd+V/C/Z can never be hijacked; Esc cancels). Saved as `"pasteShortcut"` (e.g. `"ctrl+cmd+z"`) in `settings.json`. It uses its own event tap, which needs Accessibility; if that tap fails, only this shortcut is off (the header shows "inativo") and dictation keeps working. Note this shortcut shadows Cmd+Ctrl+Z in every app.

Do not start the binary inside `Contents/MacOS` from a terminal for real use: macOS then charges Microphone, Accessibility and Input Monitoring to the terminal, not to DictFlow.

To start at login: System Settings > General > Login Items > add `DictFlow.app`.

## Configuration

Every variable is optional. With none set, the app uses local Parakeet, no cleanup, port 8765 and right Option. Variables come from the environment or from `.env` at the repo root; a variable already set in the environment wins over `.env`, and an empty value means "use the default". The Python worker reads all of these except `DICTFLOW_HOTKEY`.

| Variable | Default | Meaning |
|---|---|---|
| `DICTFLOW_ENGINE` | `parakeet` | ASR engine: `parakeet` (local, auto language), `whisper` (local, honours `DICTFLOW_LANG` and `DICTFLOW_PROMPT`), `groq` (cloud, needs `GROQ_API_KEY`) |
| `DICTFLOW_LANG` | `auto` | `auto`, `pt` or `en`. Only `whisper` and `groq` use it |
| `DICTFLOW_DICTIONARY` | `~/Library/Application Support/DictFlow/dictionary.txt` | Personal dictionary file (see Dictionary) |
| `DICTFLOW_PROMPT` | empty | Vocabulary hint for `whisper`/`groq`, e.g. `Vektrum, Order2Party, Supabase` |
| `DICTFLOW_CLEANUP` | `none` | Cleanup provider: `anthropic`, `openai` (any OpenAI-compatible endpoint) or `none`. Explicit opt-in: a key alone does not enable cleanup |
| `DICTFLOW_LLM_BASE_URL` | empty | Base URL for the `openai` provider, e.g. `http://localhost:11434/v1`. Required for `openai` |
| `DICTFLOW_LLM_MODEL` | `claude-haiku-4-5-20251001` for `anthropic` | Cleanup model name. Required for `openai` |
| `DICTFLOW_LLM_API_KEY` | empty | Bearer key for the `openai` provider (not needed for Ollama) |
| `ANTHROPIC_API_KEY` | empty | Required only for `DICTFLOW_CLEANUP=anthropic` |
| `GROQ_API_KEY` | empty | Required only for `DICTFLOW_ENGINE=groq` |
| `DICTFLOW_PORT` | `8765` | Worker port on `127.0.0.1`. If you change it, also launch the app with `open --env DICTFLOW_PORT=...`, otherwise the app polls 8765 |
| `DICTFLOW_HOTKEY` | `rightoption` | App only, not read from `.env`: any `hotkey` name listed under settings.json (e.g. `rightcmd`, `rightctrl`, `fn`). Default only: a choice saved in `settings.json` (menu Atalho) wins. Set it with `open --env` (see Run) |
| `DICTFLOW_LANG_GUARD` | off | `1` (Parakeet only): when the Parakeet text looks English, Whisper checks the audio language and, if p(pt) > 0.5, re-transcribes with `language=pt`. Portuguese-looking output pays 0 ms; English-looking output pays about 0.9 s (about 1.9 s when it re-transcribes) |
| `DICTFLOW_DEBUG_CAPTURE` | off | `1` stores each dictation's audio and text locally for debugging (see Debug capture and replay) |
| `DICTFLOW_SIGN_IDENTITY` | ad hoc | `build.sh` only: signing identity name (see Signing) |

How cleanup fails safe: its timeout scales with the text (2 s + 1 s per 100 characters, max 10 s), the worker warms the provider in the background at startup (for Ollama also set `OLLAMA_KEEP_ALIVE=-1`), the transcript is escaped inside the prompt, and the output is checked (length, refusals, and that the original words mostly survive, allowing for removed fillers and PT-BR to PT-PT respellings). On any failure the raw transcript is pasted.

### Cleanup setups

Haiku (cents per month):

```
DICTFLOW_CLEANUP=anthropic
ANTHROPIC_API_KEY=sk-ant-...
```

Groq free tier through the `openai` provider (also set `GROQ_API_KEY` if you want Groq ASR):

```
DICTFLOW_CLEANUP=openai
DICTFLOW_LLM_BASE_URL=https://api.groq.com/openai/v1
DICTFLOW_LLM_MODEL=llama-3.1-8b-instant
DICTFLOW_LLM_API_KEY=gsk_...
```

Local Ollama (free, offline):

```
DICTFLOW_CLEANUP=openai
DICTFLOW_LLM_BASE_URL=http://localhost:11434/v1
DICTFLOW_LLM_MODEL=qwen2.5:3b
```

No cleanup: leave `DICTFLOW_CLEANUP` empty (or `none`). Restart the app after changing `.env`.

## Dictionary

A local file of your vocabulary, one entry per line, `#` for comments:

```
# canonical spelling
Supabase
# replacement; several wrongs may map to one Right
super base | superbase -> Supabase
order to party -> Order2Party
```

A trailing `# comment` after whitespace is also accepted; `C#` or `F# -> F Sharp` still work.

Examples in the style you will actually use:

```
# vocabulary (hint for the cleanup pass and for whisper/groq)
Vektrum
Supabase
n8n
MiauCare

# corrections applied after every transcription
vector um | vetrum | vek trum -> Vektrum
order to party | order two party | ordem tu party -> Order2Party
super base | superbase -> Supabase
n oito n | n 8 n | en eight en -> n8n
miau care | meow care -> MiauCare
```

**From the menu:** **Dicionario** shows the number of entries (refreshed each time the menu opens). **Adicionar ao dicionario...** opens a small dialog: type `Term` or `wrong -> Right` (several wrongs with `|`) and press Adicionar; a duplicate just beeps. **Abrir dicionario** opens the file in the default editor and first creates it with a commented example header if it does not exist. The app sends the entry to the local worker (`POST /dictionary/add`, `/dictionary/ensure`, `GET /dictionary`, all on 127.0.0.1 with the same host/origin checks as `/transcribe`), which uses exactly the same code and dedupe as the CLI, so the menu needs the worker to be running (it starts it if needed). Writes go to a temp file in the same folder and are renamed over the dictionary under a lock file (`dictionary.txt.lock`), so a transcription reading at that moment sees the old or the new file, never a partial one, and the CLI and the menu cannot overwrite each other. Comments and the header are kept.

Manage it with `uv run dictflow dict add "wrong -> Right"` (or `add "Term"`), `dict list`, `dict remove <text>` (a whole line, a term, a Right form, or one wrong form) and `dict path`. Adding dedupes (case-insensitive); a new Right for an existing wrong replaces it. You can also edit the file by hand; the worker re-reads it when its mtime changes, so no restart is needed. A missing or malformed file never breaks dictation: bad lines are skipped.

Where it is used:

1. After the ASR, `wrong -> Right` entries are applied deterministically: case-insensitive, whole words, longest match first, with the Right form kept exactly.
2. In the cleanup prompt (`anthropic`/`openai`), as a delimited, escaped list marked as vocabulary and never as instructions (max 150 entries / 3000 characters). The content guardrail accepts dictionary words in the output.
3. For `whisper`/`groq`, terms and Right forms are appended to `DICTFLOW_PROMPT` (at most 500 characters, `DICTFLOW_PROMPT` first).

The file is stored locally only. Its contents leave the machine in two cases: as part of the cleanup request to your configured provider when cleanup is on, and, with `DICTFLOW_ENGINE=groq`, as the ASR prompt sent to Groq on every dictation (also with cleanup off and in password fields). With `parakeet` or `whisper` and cleanup off it is sent nowhere. Plain `Term` entries are not forced onto the raw transcript without cleanup; use `wrong -> Right` for that.

## Signing

`build.sh` signs ad hoc by default. macOS ties permission grants to the code signature, so with ad-hoc signing every rebuild looks like a new app and you must grant Microphone, Accessibility and Input Monitoring again. To avoid that, create a self-signed certificate once:

1. Open Keychain Access > menu Keychain Access > Certificate Assistant > Create a Certificate...
2. Name: `DictFlow Local`. Identity Type: Self Signed Root. Certificate Type: **Code Signing**. Create.
3. Build with it:

```bash
export DICTFLOW_SIGN_IDENTITY='DictFlow Local'
./build.sh
```

Add the export to your shell profile to keep it. Grant permissions once after the first build with this identity; later rebuilds keep them. Changing identity (including going from ad hoc to the certificate) requires granting again.

## Usage

**App:** hold **right Option**, speak, release; the text is pasted into the focused app. The menu-bar icon shows idle (`◦`), recording (`●`) or transcribing (`…`); `!` means a permission is missing or the hotkey is not active. The menu has the last transcript (click to copy), Check permissions, Colar/Copiar ultima transcricao, Atalho, Dicionario, and Quit.

**CLI** (no permissions needed; run from the repo root):

```bash
uv run dictflow transcribe tests/fixtures/pt_facto.wav            # prints text; timings on stderr
uv run dictflow transcribe tests/fixtures/pt_facto.wav --json --engine whisper --lang pt
uv run dictflow transcribe tests/fixtures/pt_correcao.wav --cleanup
uv run dictflow clean "hum então tipo o contacto está no registo pronto"
uv run dictflow serve                                              # worker on 127.0.0.1:8765
uv run dictflow bench                                              # see Benchmark
```

Digitally silent clips are detected and skip the engine. With the worker running (`serve`), in another shell:

```bash
curl -s http://127.0.0.1:8765/health
curl -s -X POST -H 'Content-Type: audio/wav' --data-binary @tests/fixtures/pt_facto.wav 'http://127.0.0.1:8765/transcribe?cleanup=0'
```

The response is JSON: `raw`, `text`, `cleanup_provider`, `fell_back`, `timings_ms`.

Timing log: each dictation appends one line to `~/Library/Logs/DictFlow/timings.log` (mode 0600, capped at about 1 MB) with timestamp, audio seconds, character count, engine, cleanup provider, fallback flag and the worker and app-side millisecond timings. It contains no transcript text and no app or window names; it is written on a background queue after the paste, so it does not add latency.

Tests: `uv run pytest`.

Headless self-tests of the app binary (after `./build.sh`):

```bash
build/DictFlow.app/Contents/MacOS/DictFlow --convert tests/fixtures/pt_facto.wav /tmp/out.wav   # Swift WAV conversion
build/DictFlow.app/Contents/MacOS/DictFlow --pipeline-test tests/fixtures/pt_facto.wav          # spawns the worker, transcribes, stops it (see note below)
build/DictFlow.app/Contents/MacOS/DictFlow --clipboard-test                                     # clipboard snapshot and restore; prints PASS
build/DictFlow.app/Contents/MacOS/DictFlow --settings-test                                      # settings.json load/save, corrupt file, precedence, hotkey capture logic; prints PASS
build/DictFlow.app/Contents/MacOS/DictFlow --hotkey-test                                        # hold/tap/double-tap/triple-tap/busy/Esc state machine; prints PASS
build/DictFlow.app/Contents/MacOS/DictFlow --shortcut-test                                      # paste shortcut parsing, matching, capture; prints PASS
build/DictFlow.app/Contents/MacOS/DictFlow --timinglog-test                                    # timing log format, 0600 mode, size cap, enqueue cost; prints PASS
```

`--pipeline-test` reuses any healthy worker already on the port: with DictFlow.app (or `dictflow serve`) running, it tests that worker, with that checkout's `.env`, not the one you just built. To test the fresh build's own worker, quit the app first or use another port: `DICTFLOW_PORT=8799 build/DictFlow.app/Contents/MacOS/DictFlow --pipeline-test tests/fixtures/pt_facto.wav`.

`--check-permissions` also exists, but run from a shell it reports the terminal's grants, not DictFlow's. Use the menu's Check permissions (with the `--stderr` log above) for the real state.

## Benchmark

`bench` runs each engine on every `.wav` that has a `.txt` reference next to it, and prints cold load time, warm median latency, real-time factor, word error rate, and any Brazilian-only spellings (`fato`, `contato`, `tela`, `registro`...) found in a Portuguese clip. Clips without a reference are skipped. Default clips: `tests/fixtures` (`pt_fillers`, whose reference is the cleaned text, only with `--cleanup`).

Result on the fixtures (2026-10-22, `--runs 5`):

```
[parakeet] cold 1899 ms, warm median 187 ms, mean RTF 0.06, mean WER 0.00%
[whisper]  cold 16936 ms, warm median 2112 ms, mean RTF 0.68, mean WER 7.20%
```

With `--engines parakeet --cleanup` and Haiku: cleanup 620-800 ms per clip; `pt_fillers` goes from 81.8% WER with four BR forms to 9.1% with none. `pt_correcao` shows 18.2% cleaned WER only because its reference keeps the self-correction.

The fixtures are synthetic TTS. Record real clips of your own voice (in a throwaway folder), then write what you said as the reference:

```bash
mkdir -p ~/dictflow-clips
ffmpeg -f avfoundation -i ":default" -ar 16000 -ac 1 -t 8 ~/dictflow-clips/pt1.wav   # speak, 8 s
echo "O facto é que a equipa precisa do contacto antes de sexta-feira." > ~/dictflow-clips/pt1.txt
uv run dictflow bench ~/dictflow-clips                       # parakeet and whisper
uv run dictflow bench ~/dictflow-clips --engines parakeet,whisper,groq --runs 5 --cleanup
```

`--max-wer 0.15` makes the command exit non-zero when mean raw WER is above the limit. `groq` is skipped when `GROQ_API_KEY` is unset. `ffmpeg` recording needs the terminal to have Microphone access.

## Debug capture and replay

Opt-in tool to find out who turns Portuguese-with-an-English-word into English: the ASR engine or the cleanup LLM.

**Privacy: this stores your voice and your text on disk.** It is off by default. With `DICTFLOW_DEBUG_CAPTURE=1` the worker, after sending each `/transcribe` response (no added latency), writes `<UTC timestamp>-<n>.wav` (the audio you sent) and `.json` (engine output before and after the dictionary, final text, engine, lang, cleanup provider, `fell_back`, timings, and `guess_lang` of each) to `~/Library/Logs/DictFlow/debug/` (folder 0700, files 0600, newest 30 pairs kept). The worker prints `DEBUG CAPTURE ON` at startup when active.

```bash
# on: set it in .env (DICTFLOW_DEBUG_CAPTURE=1) or the environment, then restart the app
# off: remove the line (or set it to 0), restart the app, then delete what was stored:
rm -rf ~/Library/Logs/DictFlow/debug
```

`dictflow replay [FILES... | --dir DIR] [--engines parakeet,whisper-pt,whisper-auto] [--cleanup] [--json]` re-runs wavs (default: the debug folder) through each engine in process and prints one row per file and engine: milliseconds, guessed language (`pt`/`en`/`mixed`/`unknown`, stopword-based) and the first 80 characters. It flags `ENGINES DISAGREE` when engines differ in language and `FLIPPED AFTER ENGINE` when a capture's stored `raw_engine` language differs from its final text (the engine was right, cleanup or the dictionary changed it). `--cleanup` also runs the current cleanup provider on each engine's output (real API calls if a provider is set).

## Manual checklist

These steps need a GUI and your hands; no automated test covers them. Do them once after the first build (and again after any change of signing identity). Keep `tail -f /tmp/dictflow.log` open (see Run).

1. **Microphone.** `open --stderr /tmp/dictflow.log build/DictFlow.app`. Success: a "DictFlow would like to access the microphone" prompt with the Portuguese usage text; click Allow. The log shows `microphone request: true`, and DictFlow is listed and on in System Settings > Privacy & Security > Microphone.
2. **Accessibility.** On first launch macOS shows an Accessibility prompt. Open System Settings > Privacy & Security > Accessibility and turn DictFlow on. Success: DictFlow is listed there and switched on.
3. **Input Monitoring.** System Settings > Privacy & Security > Input Monitoring: turn DictFlow on (add it with `+` from `build/` if it is not listed). Success: DictFlow is listed and switched on.
4. **Relaunch and permission check.** Quit DictFlow from its menu and open it again. Click Check permissions. Success: the log shows `microphone=granted accessibility=true input-monitoring=true`, the menu shows no "Missing" or "Hotkey off" line, the icon is `◦` (not `!`), and the log shows `worker ready` within a few seconds.
5. **Hotkey.** With any text field focused, hold right Option about 2 s and release. Success: the icon goes `●` while held, then `…`, then back to `◦`, the orange microphone indicator in the menu bar turns off after release, and the log shows no `transcribe failed`.
6. **Hotkey edge cases.** (a) Option+2 still types `@` and the icon never turns `●` for longer than the key press. (b) A tap shorter than 250 ms produces no text. (c) A hold with nothing said gives a beep and no text.
7. **Insertion in TextEdit** (native app). New document, hold right Option, say "O facto é que a equipa precisa do contacto antes de sexta-feira", release. Success: that sentence appears at the cursor within about 1 s (2 s with cleanup), and Cmd-V afterwards pastes what was on your clipboard before you dictated.
8. **Insertion in Chrome** (browser text field, e.g. a Google search box or Gmail draft). Dictate "Can we move lunch to Thursday at one?". Success: the English sentence appears in the field; clipboard restored as in step 7.
9. **Insertion in Slack or another Electron app**, and in **Terminal**. Dictate a mixed sentence. Success: the text appears in both; in Terminal it is typed at the prompt and not executed (no Enter is sent).
10. **Cleanup** (only if `DICTFLOW_CLEANUP` is set). Dictate "hum tipo marca a reunião para terça não quarta às dez". Success: "Marca a reunião para quarta às dez." is pasted. If the raw text is pasted instead, the log of the worker shows why (`fallback to raw` or `rejected by guardrails`).
11. **Password field.** In a login page's password field, dictate anything. Success: nothing is pasted, a beep, the menu shows "Secure input field: text left on clipboard", and the worker log shows the request with `cleanup=0`. (With `DICTFLOW_ENGINE=groq` the audio still goes to Groq; see Known limitations.)
12. **Quit.** Quit from the menu. Success: `lsof -iTCP:8765 -sTCP:LISTEN` prints nothing.
13. **Atalho menu.** Open the menu-bar menu > Atalho. Success: the title shows the current key, the current preset has a checkmark. Pick Control direito: the checkmark moves, holding right Control now dictates and right Option no longer does, with no restart; `~/Library/Application Support/DictFlow/settings.json` contains `"hotkey": "rightctrl"`. Quit and relaunch: the choice persists (and wins over `DICTFLOW_HOTKEY`).
14. **Gravar novo atalho.** Atalho > Gravar novo atalho..., tap and release left Shift: the menu shows it checked and it works as the hotkey. Repeat and press Esc: nothing changes. While recording, pressing Cmd+Tab, Cmd+C or Shift+letter, or Shift+click, does not rebind it (only a clean tap of one modifier does), and typing letters does nothing to the choice. Success also requires Input Monitoring (otherwise the item just beeps).
15. **Hands-free.** Tap the key twice quickly in a text field. Success: after the second tap the icon is `◉` and you hear a tick; speak with the key released, press once: the text is pasted and the icon returns to `◦`. Repeat and press Esc while `◉`: nothing is pasted, the microphone indicator goes off. A single tap still produces nothing; a slow second tap (over 400 ms later) does not latch; typing in another app while `◉` does not cancel it.
16. **Paste last transcript.** After a dictation, click elsewhere and press Cmd+Ctrl+Z: the last text is pasted again and the app does not react to the keystroke (no undo). Menu Colar ultima transcricao pastes it; Copiar ultima transcricao puts it on the clipboard. After a fresh launch, the shortcut only beeps. Atalho > Colar ultima transcricao: pick Ctrl+Opt+V, it works and `settings.json` has `"pasteShortcut": "ctrl+opt+v"`; Gravar novo atalho de colar..., press Cmd+Opt+L, it applies and persists; Esc cancels. Cmd+Z alone still undoes.
17. **Wispr Flow.** Do not run Wispr Flow on the same hotkey at the same time. If you switch DictFlow to `fn`, set System Settings > Keyboard > Press Globe key to: Do Nothing.
18. **Shortcut capture.** Atalho > Gravar novo atalho...: the item reads "A gravar..."; press right Shift: it becomes the checked hotkey and works. Atalho > Gravar novo atalho de colar..., press Ctrl+Opt+P: it is applied and `settings.json` has `"pasteShortcut": "ctrl+opt+p"`. Start either capture and press Esc: nothing changes. Starting one capture while the other is active cancels the first.
19. **Esc cancel.** Hold the hotkey, speak, press Esc before releasing: nothing is pasted and the microphone indicator goes off. Repeat in hands-free (`◉`): Esc cancels the same way.
20. **Paste last in three apps.** Dictate a sentence in TextEdit. Click into Chrome (a text field), press Cmd+Ctrl+Z: the sentence is pasted. Repeat in Slack (or another Electron app) and in Terminal (typed at the prompt, no Enter). The clipboard is restored afterwards. Press the shortcut twice within a second: your original clipboard still comes back. Choose Ctrl+Opt+V with right Option as push-to-talk and press it while holding right Option: it pastes with no stray recording. Try to record Cmd+V as the paste shortcut: it is ignored.
21. **Dictionary entry then dictate.** Menu Dicionario > Adicionar ao dicionario..., enter `vector um -> Vektrum`, press Adicionar: the count in the submenu title goes up by one. Entering it again beeps and the count does not change; entering `a -> b -> c` shows an error dialog. Dictate "o vector um é uma agência": the pasted text has "Vektrum". Edit `dictionary.txt` by hand (add a line), reopen the menu: the count follows, with no restart. In the Adicionar dialog, Cmd+V pastes into the field; after closing it, dictating pastes into the app you were in.
22. **Abrir dicionario.** Move the dictionary file away (`mv ~/Library/Application\ Support/DictFlow/dictionary.txt ~/Desktop/`), click Dicionario > Abrir dicionario: the default editor opens a new file that starts with the commented example header. Move your file back afterwards.

## Known limitations

- Neither ASR engine controls the Portuguese dialect, so PT-BR spellings can appear in the raw transcript. Only the cleanup pass fixes them; with cleanup off you get what the engine gives. `bench` flags BR forms so you can A/B engines on your own voice.
- The cleanup guardrail accepts filler removal, single self-corrections and the common BR to PT-PT respellings, but rejects chains of corrections ("segunda, não, terça, não, quarta"); you then get the raw text. It cannot tell a wrong word swap ("cem" to "mil", a dropped "não") from a correction, and it also accepts an output that flips a negation ("não envies o email" to "Envia o email.") or appends a short answer to a dictated question ("qual é a capital de frança" to "Qual é a capital de França? Paris.").
- The silence check only catches digital silence. With room noise and `whisper` or `groq`, a hold with nothing said can paste invented text such as "Thank you." Parakeet returns nothing in the same case.
- Secure input: when the frontmost app holds secure input (a password field), DictFlow skips cloud cleanup, does not paste, beeps and leaves the text on the clipboard with no expiry. With `DICTFLOW_ENGINE=groq` the audio is still sent to Groq. The text still becomes the last transcript: it shows in plain text in the menu's "Last:" item, the paste-last shortcut and Colar ultima transcricao paste it into any app, and Copiar ultima transcricao puts it on the clipboard without the concealed marker, so clipboard managers may keep it. Secure input held by a background app is ignored.
- Shortcut capture has no timeout: after Gravar novo atalho de colar..., the next modifier+letter/digit chord with Ctrl or Opt is saved, even much later and even a text-producing one such as Opt+2 (`@` on the PT-PT layout) or Ctrl+C, which is then swallowed system-wide. Only Esc (or starting the other capture) ends it. Likewise, while Gravar novo atalho... is active, dictation is off and a click does not end it. Finish or Esc every capture you start.
- A mouse click during a hold cancels the recording silently, however long you have been speaking (it is meant to drop Option+click). Release the key before clicking; in hands-free (`◉`) clicks are fine.
- The dictionary file must be UTF-8. If it is saved in another encoding (e.g. Latin-1 with accented words), it is read as empty, and adding an entry from the menu or `dict add` overwrites it with only the new entry.
- Starting a new dictation while the previous one is still being transcribed is ignored, with no beep.
- A lone tap still starts and cancels a short recording (so the microphone indicator blinks), because the app cannot know a second tap is coming. Hands-free, the swallowing paste shortcut and the sound/icon feedback depend on macOS permissions and were not verified headless: only the state machine and shortcut parsing are unit-tested.
- The app waits at most 15 s for the worker. A long dictation with `whisper` or `groq` plus a slow cleanup can exceed that, and the text is dropped with a beep.
- Two dictations within about 1 s of each other can leave the first dictation's text on the clipboard instead of your original contents.
- On first launch without the model downloaded (Install step 2), the worker cannot start within the app's 60 s limit.
- Pasting is the insertion method, so it briefly uses the clipboard (restored after about 1 s) and fails in apps that block Cmd-V.
- Permissions must be granted again whenever the signing identity changes (including ad-hoc rebuilds).
- Recording is capped at 120 s per hold.
