# dictation-flow

A personal, free replacement for the dictation part of Wispr Flow. Hold a key, speak PT-PT or English, release: the text is transcribed locally and pasted into the focused app. An optional LLM pass removes fillers and resolves self-corrections.

Repo location: `~/Documents/Projetos/dictation-flow` (the build bakes the repo path into the app, so rebuild with `./build.sh` if you move it).

## Overview

Two processes, split along the macOS permission boundary:

- **`dictflow` (Python, `src/dictflow`)** is the worker. It decodes audio, trims silence, runs the ASR engine, runs the optional cleanup, and serves it all on `127.0.0.1:8765` with the model kept warm. It needs no macOS permissions: it only computes and makes outgoing HTTPS calls. It is also a CLI, so everything except the hotkey, microphone and paste can be tested from audio files.
- **`DictFlow.app` (Swift, `app/`)** is a menu-bar app (no Dock icon). It holds every permission-sensitive piece: the global hotkey (event tap), the microphone, and the paste (synthetic Cmd-V). It starts the worker as a child process and kills it on quit.

Why permissions live only in the `.app`: macOS grants Microphone, Accessibility and Input Monitoring per app identity. One signed bundle with a stable identifier (`pt.franciscoribeiro.dictflow`) means three grants in one place, and the worker, which also reads your API keys from `.env`, never touches them.

Pipeline: right Option held -> record -> 16 kHz mono WAV -> `POST /transcribe` -> ASR (+ optional cleanup) -> paste. Expected latency after release: about 0.6 s raw, about 1.3 s with Haiku cleanup. Running cost: 0 with cleanup off or Ollama; cents per month with Haiku or the Groq free tier.

## Requirements

- macOS 14+ on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`; full Xcode is not needed)
- [uv](https://docs.astral.sh/uv/)
- ffmpeg

## Installed software and downloads

- brew packages: none new. `uv` and `ffmpeg` were already installed (`brew install uv ffmpeg` if you lack them).
- Python dependencies (installed into `.venv` by `uv sync`): `parakeet-mlx`, `mlx-whisper`, `numpy`; dev: `pytest`.
- Models, fetched automatically from Hugging Face on first use into `~/.cache/huggingface`:
  - `mlx-community/parakeet-tdt-0.6b-v3`, about 2.5 GB (default engine)
  - `mlx-community/whisper-large-v3-turbo`, about 1.6 GB (only if you use `whisper`)
- Optional, for local cleanup: `ollama pull qwen2.5:3b` (requires Ollama).

## Install

```bash
uv sync
./build.sh                      # builds build/DictFlow.app
open build/DictFlow.app         # or move it to ~/Applications first, then open it
```

On first launch, grant the three permissions (see the checklist below). Keys, if any, go in a gitignored `.env`:

```bash
cp .env.example .env            # then fill in only what you need
```

## Configuration

Variables come from the environment or from `.env` at the repo root. A variable already set in the environment wins over `.env`. Empty values mean "use the default". Only the Python worker reads these.

| Variable | Default | Meaning |
|---|---|---|
| `DICTFLOW_ENGINE` | `parakeet` | ASR engine: `parakeet` (local, auto language), `whisper` (local, honours `DICTFLOW_LANG` and `DICTFLOW_PROMPT`), `groq` (cloud, needs `GROQ_API_KEY`) |
| `DICTFLOW_LANG` | `auto` | `auto`, `pt` or `en`. Only forced by `whisper` and `groq` |
| `DICTFLOW_PROMPT` | empty | Vocabulary hint for `whisper`/`groq`, e.g. `Vektrum, Order2Party, Supabase` |
| `DICTFLOW_CLEANUP` | `anthropic` if `ANTHROPIC_API_KEY` is set, else `none` | Cleanup provider: `anthropic`, `openai` (any OpenAI-compatible endpoint) or `none` |
| `DICTFLOW_LLM_BASE_URL` | empty | Base URL for the `openai` provider, e.g. `http://localhost:11434/v1` |
| `DICTFLOW_LLM_MODEL` | `claude-haiku-4-5-20251001` for `anthropic`; required for `openai` | Cleanup model name |
| `DICTFLOW_LLM_API_KEY` | empty | Bearer key for the `openai` provider (not needed for Ollama) |
| `ANTHROPIC_API_KEY` | empty | Key for the `anthropic` provider |
| `GROQ_API_KEY` | empty | Key for the `groq` ASR engine |
| `DICTFLOW_PORT` | `8765` | Worker port on `127.0.0.1` |

The app also reads `DICTFLOW_HOTKEY` (`rightoption` by default, or `fn`, `rightcmd`) from its own environment, not from `.env`. It only applies when you start the binary from a terminal: `DICTFLOW_HOTKEY=rightcmd build/DictFlow.app/Contents/MacOS/DictFlow`.

Cleanup never blocks dictation: it has a 3 s timeout, its output is checked (length, refusals), and on any failure the raw transcript is pasted.

### Cleanup setups

Haiku (about cents per month):

```
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

No cleanup: leave `DICTFLOW_CLEANUP` empty and `ANTHROPIC_API_KEY` unset (or `DICTFLOW_CLEANUP=none`).

## Signing

`build.sh` signs ad hoc by default. macOS ties permission grants to the code signature, so with ad-hoc signing every rebuild looks like a new app and you must re-grant Microphone, Accessibility and Input Monitoring. To avoid that, create a one-time self-signed certificate:

1. Open Keychain Access > menu Keychain Access > Certificate Assistant > Create a Certificate...
2. Name: `DictFlow Local`. Identity Type: Self Signed Root. Certificate Type: **Code Signing**. Create.
3. Build with it:

```bash
export DICTFLOW_SIGN_IDENTITY='DictFlow Local'
./build.sh
```

Add the export to your shell profile to keep it. Grant permissions once after the first build with this identity; later rebuilds keep them. Changing identity (including going from ad hoc to the certificate) requires granting again.

## Usage

**App:** open `DictFlow.app`. Hold **right Option**, speak, release; the text is pasted into the focused app. The menu-bar icon shows idle (`◦`), recording (`●`) or transcribing (`…`); `!` means the hotkey is not active (missing Input Monitoring). The menu has the last transcript (click to copy), Check permissions, and Quit. To start at login: System Settings > General > Login Items > add `DictFlow.app` (manual).

**CLI** (no permissions needed; run from the repo root):

```bash
uv run dictflow transcribe tests/fixtures/pt_facto.wav            # prints text; timings on stderr
uv run dictflow transcribe tests/fixtures/pt_facto.wav --json --engine whisper --lang pt
uv run dictflow transcribe tests/fixtures/pt_correcao.wav --cleanup
uv run dictflow clean "hum então tipo o contacto está no registo pronto"
uv run dictflow serve                                              # worker on 127.0.0.1:8765
uv run dictflow bench                                              # see Benchmark
```

Silent clips are detected and skip the engine, so there are no silence hallucinations. With the worker running (`serve`), in another shell:

```bash
curl -s http://127.0.0.1:8765/health
curl -s -X POST --data-binary @tests/fixtures/pt_facto.wav 'http://127.0.0.1:8765/transcribe?cleanup=0'
```

The response is JSON: `raw`, `text`, `cleanup_provider`, `fell_back`, `timings_ms` (and `lang` when the engine detects it).

Tests: `uv run pytest`.

Headless self-tests of the app binary (after `./build.sh`):

```bash
build/DictFlow.app/Contents/MacOS/DictFlow --convert tests/fixtures/pt_facto.wav out.wav
build/DictFlow.app/Contents/MacOS/DictFlow --pipeline-test tests/fixtures/pt_facto.wav
build/DictFlow.app/Contents/MacOS/DictFlow --clipboard-test
build/DictFlow.app/Contents/MacOS/DictFlow --check-permissions
```

## Benchmark

`bench` runs each engine on every `.wav` that has a `.txt` reference next to it, and prints cold load time, warm median latency, real-time factor, word error rate, and any Brazilian-only spellings (`fato`, `contato`, `tela`, `registro`...) found in a Portuguese clip. Clips without a reference are skipped. Default clips: `tests/fixtures`.

Record real clips of your own voice (in a throwaway folder), then write what you said as the reference:

```bash
mkdir -p ~/dictflow-clips
ffmpeg -f avfoundation -i ":default" -ar 16000 -ac 1 -t 8 ~/dictflow-clips/pt1.wav   # speak, 8 s
echo "O facto é que a equipa precisa do contacto antes de sexta-feira." > ~/dictflow-clips/pt1.txt
uv run dictflow bench ~/dictflow-clips                       # parakeet and whisper
uv run dictflow bench ~/dictflow-clips --engines parakeet,whisper,groq --runs 5 --cleanup
```

`--max-wer 0.15` makes the command exit non-zero when mean WER is above the limit. `groq` is skipped when `GROQ_API_KEY` is unset. `ffmpeg` recording needs the terminal to have Microphone access.

## Permissions checklist

These steps need a GUI and your hands, and have not been verified by automated tests. Do them once after the first build.

- [ ] 1. Microphone prompt appears on first launch and is granted.
- [ ] 2. Accessibility is granted to DictFlow (System Settings > Privacy & Security > Accessibility).
- [ ] 3. Input Monitoring is granted to DictFlow.
- [ ] 4. Quit and relaunch the app (the hotkey tap only starts once Input Monitoring is granted; the icon should not show `!`).
- [ ] 5. In TextEdit, hold right Option, speak PT-PT, release: the text appears and your previous clipboard contents are restored.
- [ ] 6. Same in Chrome, Slack or another Electron app, and in Terminal.
- [ ] 7. Option+2 still types `@` and does not start a recording.
- [ ] 8. A tap shorter than 250 ms does nothing.
- [ ] 9. In a password field: no paste, a beep, and the text stays on the clipboard.
- [ ] 10. The orange microphone indicator goes off after release.
- [ ] 11. Quit kills the worker: `lsof -iTCP:8765` prints nothing.
- [ ] 12. Do not run Wispr Flow on the same hotkey at the same time.
- [ ] 13. If you switch to Fn (`DICTFLOW_HOTKEY=fn`): set System Settings > Keyboard > Press Globe key to: Do Nothing.

## Known limitations

- Neither ASR engine controls the Portuguese dialect, so PT-BR spellings can appear in the raw transcript. The cleanup prompt enforces European orthography (AO1990), and `bench` flags the BR forms so you can A/B engines on your own voice. With cleanup off, you get what the engine gives.
- Secure input: password fields and some apps enable secure event input, where pasting is blocked. DictFlow beeps and leaves the text on the clipboard.
- Pasting is the insertion method, so it briefly uses the clipboard (restored after about 250 ms) and fails in apps that block Cmd-V.
- Permissions must be granted again whenever the signing identity changes (including ad-hoc rebuilds).
- Recording is capped at 120 s per hold.
