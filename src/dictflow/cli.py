import argparse
import sys
import time

from . import config


def _ms(t0):
    return round((time.perf_counter() - t0) * 1000)


def cmd_transcribe(args):
    import json

    from . import asr, audio

    t = time.perf_counter()
    samples = audio.load_audio(args.file)
    decode = _ms(t)
    samples = audio.trim_silence(samples)
    timings = {"decode": decode}
    lang = args.lang or config.lang()
    if len(samples) == 0:
        text, detected = "", None
        timings.update(load=0, asr=0)
        print("no speech detected; engine skipped", file=sys.stderr)
    else:
        eng = asr.get_engine(args.engine or config.engine())
        t = time.perf_counter()
        eng.load()
        timings["load"] = _ms(t)
        t = time.perf_counter()
        text, detected = eng.transcribe(samples, audio.SR, lang, config.prompt())
        timings["asr"] = _ms(t)
    raw = text
    if args.cleanup and text:
        from . import cleanup

        text, prov, fb, cms = cleanup.clean(text)
        timings["cleanup"] = cms
        print(f"cleanup: provider={prov} fell_back={fb}", file=sys.stderr)
    if args.json:
        print(json.dumps({"raw": raw, "text": text, "lang": detected, "timings_ms": timings}, ensure_ascii=False))
    else:
        print(text)
    print("timings_ms: " + " ".join(f"{k}={v}" for k, v in timings.items()), file=sys.stderr)
    return 0


def cmd_clean(args):
    from . import cleanup

    text, prov, fb, ms = cleanup.clean(args.text, args.provider)
    print(text)
    print(f"cleanup: provider={prov} fell_back={fb} ms={ms}", file=sys.stderr)
    return 0


def main(argv=None):
    config.load_env()
    p = argparse.ArgumentParser(prog="dictflow", description="Local dictation worker and tools.")
    sub = p.add_subparsers(dest="cmd")
    t = sub.add_parser("transcribe", help="transcribe an audio file")
    t.add_argument("file")
    t.add_argument("--engine", choices=["parakeet", "whisper", "groq"])
    t.add_argument("--lang", choices=["auto", "pt", "en"])
    t.add_argument("--json", action="store_true")
    t.add_argument("--cleanup", action="store_true", help="run the LLM cleanup pass")
    c = sub.add_parser("clean", help="run LLM cleanup on text")
    c.add_argument("text")
    c.add_argument("--provider", choices=["anthropic", "openai", "none"])
    s = sub.add_parser("serve", help="run the localhost worker")
    s.add_argument("--port", type=int)
    sub.add_parser("bench", help="benchmark engines on fixtures")
    args = p.parse_args(argv)
    if not args.cmd:
        p.print_help()
        return 0
    if args.cmd == "transcribe":
        try:
            return cmd_transcribe(args)
        except (RuntimeError, ValueError, OSError) as e:
            print(f"dictflow: error: {e}", file=sys.stderr)
            return 1
    if args.cmd == "clean":
        return cmd_clean(args)
    if args.cmd == "serve":
        from . import server

        try:
            return server.serve(args.port)
        except (RuntimeError, ValueError, OSError) as e:
            print(f"dictflow: error: {e}", file=sys.stderr)
            return 1
    print(f"{args.cmd}: not implemented yet")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
