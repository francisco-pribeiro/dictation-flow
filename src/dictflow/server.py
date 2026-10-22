"""Warm localhost worker: model loaded once, HTTP on 127.0.0.1 only."""
import json
import os
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np

from . import asr, audio, cleanup, config, dictionary

MAX_BODY = 20 * 1024 * 1024


def _ms(t0):
    return round((time.perf_counter() - t0) * 1000)


class Worker:
    def __init__(self, engine_name):
        self.engine = asr.get_engine(engine_name)
        self.lock = threading.Lock()
        self.provider = cleanup.pick_provider()

    def warmup(self):
        self.engine.load()
        # Zeros: only exercises the model so the first real request is fast.
        self.engine.transcribe(np.zeros(audio.SR // 2, dtype=np.float32), audio.SR, "auto", "")
        if self.provider != "none":
            # Off the startup path: a hung cleanup endpoint must not keep /health down.
            threading.Thread(target=cleanup.warm, args=(self.provider,), daemon=True).start()

    def process(self, wav, do_cleanup, lang):
        timings = {"decode": 0, "asr": 0, "cleanup": 0}
        t_all = time.perf_counter()
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(wav)
            f.flush()
            t = time.perf_counter()
            samples = audio.trim_silence(audio.load_audio(f.name, fmt="wav"))
            timings["decode"] = _ms(t)
        raw = ""
        d = dictionary.current()  # re-read only when the file changed
        if len(samples):
            t = time.perf_counter()
            with self.lock:
                raw, _ = self.engine.transcribe(samples, audio.SR, lang or config.lang(),
                                                dictionary.asr_prompt(config.prompt(), d))
            timings["asr"] = _ms(t)
        raw = d.apply(raw)
        text, prov, fell_back = raw, "none", False
        if do_cleanup and raw:
            text, prov, fell_back, timings["cleanup"] = cleanup.clean(raw, self.provider, d=d)
        timings["total"] = _ms(t_all)
        return {"raw": raw, "text": text, "cleanup_provider": prov, "fell_back": fell_back, "timings_ms": timings}


def make_handler(worker, port):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            pass  # one line per request is logged in _log

        def _log(self, code, t0):
            print(f"{self.command} {self.path} -> {code} {_ms(t0)}ms", file=sys.stderr, flush=True)

        def _forbidden(self):
            """Browsers add Origin; DNS rebinding changes Host. The app sends neither."""
            return self.headers.get("Origin") is not None or self.headers.get("Host") not in allowed_hosts

        def do_GET(self):
            t0 = time.perf_counter()
            if self._forbidden():
                code, obj = 403, {"error": "forbidden"}
            elif urlparse(self.path).path == "/health":
                code, obj = 200, {"status": "ok", "engine": worker.engine.name, "cleanup_provider": worker.provider}
            else:
                code, obj = 404, {"error": "not found"}
            try:
                self._send(code, obj)
            except OSError:
                pass  # the app's 1 s health probe gave up while the model was loading
            self._log(code, t0)

        def do_POST(self):
            t0 = time.perf_counter()
            code, obj = self._transcribe()
            try:
                self._send(code, obj)
            except OSError:
                pass
            self._log(code, t0)

        def _transcribe(self):
            if self._forbidden() or self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "audio/wav":
                self.close_connection = True
                return 403, {"error": "forbidden"}
            u = urlparse(self.path)
            if u.path != "/transcribe":
                return 404, {"error": "not found"}
            try:
                n = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return 411, {"error": "Content-Length required"}
            if n > MAX_BODY:
                self.close_connection = True
                return 413, {"error": "body exceeds 20 MB"}
            if n <= 0:
                return 400, {"error": "empty body"}
            q = parse_qs(u.query)
            lang = q.get("lang", [""])[0]
            if lang not in ("", "auto", "pt", "en"):
                return 400, {"error": "lang must be auto, pt or en"}
            default = "0" if worker.provider == "none" else "1"
            do_cleanup = q.get("cleanup", [default])[0] != "0"
            body = self.rfile.read(n)
            try:
                return 200, worker.process(body, do_cleanup, lang)
            except (RuntimeError, ValueError) as e:
                msg = str(e)
                # decode failures are the caller's problem; anything else is ours
                return (400 if msg.startswith("ffmpeg failed") else 500), {"error": msg}
            except Exception as e:
                return 500, {"error": f"{type(e).__name__}: {e}"}

    return Handler


def serve(port=None, engine_name=None):
    port = port or config.port()
    # Bind first: a duplicate worker fails at once instead of after loading the model.
    # Requests queue in the backlog until serve_forever, so /health answers only once warm.
    srv = ThreadingHTTPServer(("127.0.0.1", port), make_handler(worker := Worker(engine_name or config.engine()), port))
    srv.daemon_threads = True
    t = time.perf_counter()
    worker.warmup()
    print(f"dictflow: engine={worker.engine.name} warm in {_ms(t)}ms cleanup={worker.provider}", file=sys.stderr, flush=True)
    print(f"dictflow: listening on 127.0.0.1:{port}", file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0
