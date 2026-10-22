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
```

## Run

```bash
open build/DictFlow.app
```

Then do the manual checklist below once. To see the app's log while testing:

```bash
open --stderr /tmp/dictflow.log build/DictFlow.app && tail -f /tmp/dictflow.log
```

To change the hotkey, use the menu: **Atalho** lists the presets (Option direito, Command direito, Control direito, Fn) with a checkmark on the current one, and **Gravar novo atalho...** records the next modifier key you press (Esc cancels; any modifier key works, left or right). It applies immediately and is saved to `~/Library/Application Support/DictFlow/settings.json`. The saved choice wins over `DICTFLOW_HOTKEY`, which only sets the default when settings.json has none:

```bash
open --env DICTFLOW_HOTKEY=rightcmd build/DictFlow.app      # or fn, rightctrl, rightoption (default)
```

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
| `DICTFLOW_HOTKEY` | `rightoption` | App only, not read from `.env`: `rightoption`, `rightcmd`, `rightctrl` or `fn`. Default only: a choice saved in `settings.json` (menu Atalho) wins. Set it with `open --env` (see Run) |
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
Supabase                         # canonical spelling
super base | superbase -> Supabase   # replacement; several wrongs may map to one Right
order to party -> Order2Party
```

Manage it with `uv run dictflow dict add "wrong -> Right"` (or `add "Term"`), `dict list`, `dict remove <text>` (a whole line, a term, a Right form, or one wrong form) and `dict path`. Adding dedupes (case-insensitive); a new Right for an existing wrong replaces it. You can also edit the file by hand; the worker re-reads it when its mtime changes, so no restart is needed. A missing or malformed file never breaks dictation: bad lines are skipped.

Where it is used:

1. After the ASR, `wrong -> Right` entries are applied deterministically: case-insensitive, whole words, longest match first, with the Right form kept exactly.
2. In the cleanup prompt (`anthropic`/`openai`), as a delimited, escaped list marked as vocabulary and never as instructions (max 150 entries / 3000 characters). The content guardrail accepts dictionary words in the output.
3. For `whisper`/`groq`, terms and Right forms are appended to `DICTFLOW_PROMPT` (at most 500 characters, `DICTFLOW_PROMPT` first).

The file is local only. It is sent nowhere except, when cleanup is enabled, as part of the cleanup request to your configured provider. Plain `Term` entries are not forced onto the raw transcript without cleanup; use `wrong -> Right` for that.

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

**App:** hold **right Option**, speak, release; the text is pasted into the focused app. The menu-bar icon shows idle (`◦`), recording (`●`) or transcribing (`…`); `!` means a permission is missing or the hotkey is not active. The menu has the last transcript (click to copy), Check permissions, and Quit.

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

Tests: `uv run pytest`.

Headless self-tests of the app binary (after `./build.sh`):

```bash
build/DictFlow.app/Contents/MacOS/DictFlow --convert tests/fixtures/pt_facto.wav /tmp/out.wav   # Swift WAV conversion
build/DictFlow.app/Contents/MacOS/DictFlow --pipeline-test tests/fixtures/pt_facto.wav          # spawns the worker, transcribes, stops it
build/DictFlow.app/Contents/MacOS/DictFlow --clipboard-test                                     # clipboard snapshot and restore; prints PASS
build/DictFlow.app/Contents/MacOS/DictFlow --settings-test                                      # settings.json load/save, corrupt file, precedence, hotkey capture logic; prints PASS
```

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
14. **Gravar novo atalho.** Atalho > Gravar novo atalho..., press left Shift: the menu shows it checked and it works as the hotkey. Repeat and press Esc: nothing changes. While recording, typing letters does nothing to the choice. Success also requires Input Monitoring (otherwise the item just beeps).
15. **Wispr Flow.** Do not run Wispr Flow on the same hotkey at the same time. If you switch DictFlow to `fn`, set System Settings > Keyboard > Press Globe key to: Do Nothing.

## Known limitations

- Neither ASR engine controls the Portuguese dialect, so PT-BR spellings can appear in the raw transcript. Only the cleanup pass fixes them; with cleanup off you get what the engine gives. `bench` flags BR forms so you can A/B engines on your own voice.
- The cleanup guardrail accepts filler removal, single self-corrections and the common BR to PT-PT respellings, but rejects chains of corrections ("segunda, não, terça, não, quarta"); you then get the raw text. It cannot tell a wrong word swap ("cem" to "mil", a dropped "não") from a correction.
- The silence check only catches digital silence. With room noise and `whisper` or `groq`, a hold with nothing said can paste invented text such as "Thank you." Parakeet returns nothing in the same case.
- Secure input: when the frontmost app holds secure input (a password field), DictFlow skips cloud cleanup, does not paste, beeps and leaves the text on the clipboard with no expiry. With `DICTFLOW_ENGINE=groq` the audio is still sent to Groq, and the text shows in the menu's "Last:" item. Secure input held by a background app is ignored.
- Starting a new dictation while the previous one is still being transcribed is ignored, with no beep.
- The app waits at most 15 s for the worker. A long dictation with `whisper` or `groq` plus a slow cleanup can exceed that, and the text is dropped with a beep.
- Two dictations within about 1 s of each other can leave the first dictation's text on the clipboard instead of your original contents.
- On first launch without the model downloaded (Install step 2), the worker cannot start within the app's 60 s limit.
- Pasting is the insertion method, so it briefly uses the clipboard (restored after about 1 s) and fails in apps that block Cmd-V.
- Permissions must be granted again whenever the signing identity changes (including ad-hoc rebuilds).
- Recording is capped at 120 s per hold.
