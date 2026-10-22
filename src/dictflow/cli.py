import argparse
import sys
import time

from . import config, dictionary


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
        text, detected = eng.transcribe(samples, audio.SR, lang, dictionary.asr_prompt(config.prompt()))
        timings["asr"] = _ms(t)
    text = dictionary.current().apply(text)
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

    text, prov, fb, ms = cleanup.clean(dictionary.current().apply(args.text), args.provider)
    print(text)
    print(f"cleanup: provider={prov} fell_back={fb} ms={ms}", file=sys.stderr)
    return 0


def cmd_dict(args):
    if args.dict_cmd == "path":
        print(dictionary.path())
    elif args.dict_cmd == "list":
        for e in dictionary.entries():
            print(e)
    elif args.dict_cmd == "add":
        try:
            print(dictionary.add(args.entry))
        except ValueError as e:
            print(f"dictflow: error: {e}", file=sys.stderr)
            return 1
        except OSError as e:
            print(f"dictflow: error: {e}", file=sys.stderr)
            return 1
    elif args.dict_cmd == "remove":
        try:
            n = dictionary.remove(args.text)
        except OSError as e:
            print(f"dictflow: error: {e}", file=sys.stderr)
            return 1
        print(f"removed {n}")
        return 0 if n else 1
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
    d = sub.add_parser("dict", help="manage the personal dictionary").add_subparsers(dest="dict_cmd", required=True)
    d.add_parser("add", help="add 'Term' or 'wrong -> Right'").add_argument("entry")
    d.add_parser("list", help="print the entries")
    d.add_parser("remove", help="remove an entry by line, term or wrong form").add_argument("text")
    d.add_parser("path", help="print the dictionary file path")
    s = sub.add_parser("serve", help="run the localhost worker")
    s.add_argument("--port", type=int)
    b = sub.add_parser("bench", help="benchmark engines on clips with .txt references")
    b.add_argument("clips", nargs="*", help="wav files or folders (default: tests/fixtures)")
    b.add_argument("--engines", default="parakeet,whisper")
    b.add_argument("--runs", type=int, default=3)
    b.add_argument("--cleanup", action="store_true")
    b.add_argument("--max-wer", type=float)
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
    if args.cmd == "dict":
        return cmd_dict(args)
    if args.cmd == "serve":
        from . import server

        try:
            return server.serve(args.port)
        except (RuntimeError, ValueError, OSError) as e:
            print(f"dictflow: error: {e}", file=sys.stderr)
            return 1
    if args.cmd == "bench":
        from . import bench

        try:
            return bench.run(args.clips, [e.strip() for e in args.engines.split(",") if e.strip()],
                             args.runs, args.cleanup, args.max_wer)
        except (RuntimeError, ValueError, OSError) as e:
            print(f"dictflow: error: {e}", file=sys.stderr)
            return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
