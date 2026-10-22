import io
import json
import os
import shutil
import stat
from pathlib import Path

import pytest

from dictflow import debug, server

FIX = Path(__file__).parent / "fixtures"


@pytest.mark.parametrize("text,want", [
    ("O facto é que a equipa precisa do contacto antes de sexta-feira.", "pt"),
    ("Está tudo bem, não te preocupes com isso.", "pt"),
    ("Bom dia", "pt"),
    ("Hello, let's have lunch tomorrow.", "en"),
    ("I think we should ship it on Friday", "en"),
    ("Isto é uma ideia crazy mas pode funcionar", "pt"),
    ("Preciso de ajustar o workflow da equipa para amanhã", "pt"),
    ("I said não e depois the other one", "mixed"),
    ("", "unknown"),
    ("xyzzy", "unknown"),
])
def test_guess_lang(text, want):
    assert debug.guess_lang(text) == want


class FakeEngine:
    def __init__(self, text):
        self.text = text

    def load(self):
        pass

    def transcribe(self, samples, sr, lang="auto", prompt=""):
        return self.text, None


def test_replay_flags_disagreement_and_flip(tmp_path, capsys):
    wav = tmp_path / "a.wav"
    shutil.copy(FIX / "pt_facto.wav", wav)
    wav.with_suffix(".json").write_text(json.dumps({"raw_engine": "Isto é o meu workflow", "text": "This is my workflow"}))
    texts = {"parakeet": "Isto é o meu workflow", "whisper-pt": "Isto é o meu workflow", "whisper-auto": "This is my workflow"}
    out = io.StringIO()
    debug.run_replay([str(wav)], None, list(texts), True, False, make_engine=lambda n: (FakeEngine(texts[n]), "auto"),
                     clean=lambda t, d: (t.upper(), "fake", False, 1), out=out)
    s = out.getvalue()
    assert "ENGINES DISAGREE" in s and "FLIPPED AFTER ENGINE" in s and "+cleanup" in s


def test_replay_json_default_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    d = debug.debug_dir()
    d.mkdir(parents=True)
    shutil.copy(FIX / "pt_facto.wav", d / "x.wav")
    out = io.StringIO()
    debug.run_replay([], None, ["parakeet"], False, True, make_engine=lambda n: (FakeEngine("Bom dia"), "auto"), out=out)
    r = json.loads(out.getvalue())
    assert r[0]["file"] == "x.wav" and r[0]["engines"]["parakeet"]["lang"] == "pt" and r[0]["flags"] == []


def test_capture_writes_pair_modes_and_prunes(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    res = {"raw": "a", "text": "b", "engine": "parakeet", "cleanup_provider": "none", "fell_back": False,
           "timings_ms": {"total": 1}}
    for _ in range(debug.KEEP + 5):
        debug.capture(b"RIFF", "auto", res, "a0")
    d = debug.debug_dir()
    assert len(list(d.glob("*.wav"))) == len(list(d.glob("*.json"))) == debug.KEEP
    assert stat.S_IMODE(d.stat().st_mode) == 0o700
    j = next(d.glob("*.json"))
    assert stat.S_IMODE(j.stat().st_mode) == 0o600
    assert json.loads(j.read_text())["raw_engine"] == "a0"


def test_capture_swallows_errors(tmp_path, monkeypatch):
    f = tmp_path / "file"
    f.write_text("x")
    monkeypatch.setenv("HOME", str(f))  # mkdir under a file fails
    debug.capture(b"x", "", {}, "")  # must not raise


def test_process_returns_raw_engine_before_dictionary(monkeypatch):
    w = server.Worker.__new__(server.Worker)
    w.engine = FakeEngine("crazy")
    w.engine.name = "fake"
    w.lock = __import__("threading").Lock()
    w.provider = "none"
    from dictflow import dictionary
    monkeypatch.setattr(dictionary.current().__class__, "apply", lambda self, t: t.upper())
    res = w.process((FIX / "pt_facto.wav").read_bytes(), False, "")
    assert res["raw_engine"] == "crazy" and res["raw"] == "CRAZY"


def _post(monkeypatch, tmp_path, on):
    import threading
    import urllib.request
    from http.server import ThreadingHTTPServer
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("DICTFLOW_DEBUG_CAPTURE", "1" if on else "0")
    w = server.Worker.__new__(server.Worker)
    w.engine = FakeEngine("crazy")
    w.engine.name = "fake"
    w.lock = threading.Lock()
    w.provider = "none"
    srv = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(w, 0))
    port = srv.server_address[1]
    srv.RequestHandlerClass = server.make_handler(w, port)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/transcribe?lang=pt", (FIX / "pt_facto.wav").read_bytes(),
                                 {"Content-Type": "audio/wav"})
    body = json.load(urllib.request.urlopen(req))
    srv.shutdown()
    srv.server_close()
    return body


def test_endpoint_capture_on_and_off(monkeypatch, tmp_path):
    body = _post(monkeypatch, tmp_path, True)
    assert "raw_engine" not in body
    import time
    time.sleep(0.2)
    j = json.loads(next(debug.debug_dir().glob("*.json")).read_text())
    assert j["lang"] == "pt" and j["raw_engine"] == "crazy"
    off = tmp_path / "off"
    off.mkdir()
    _post(monkeypatch, off, False)
    time.sleep(0.2)
    assert not debug.debug_dir().exists()


def test_chunked_capture_records_context_and_prunes_by_dictation(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    res = {"raw": "a", "text": "b", "engine": "parakeet", "cleanup_provider": "x", "fell_back": False, "timings_ms": {"total": 1}}
    for n in range(debug.KEEP + 3):          # KEEP+3 dictations of 6 pieces each
        sid = f"{n:08x}"
        for seq in range(6):
            chunk = {"session": sid, "seq": seq, "chunked": True, "ctx": seq > 0, "partial": seq < 5,
                     "context": "antes" if seq else None}
            debug.capture(b"RIFF", "auto", res, "a", chunk)
    d = debug.debug_dir()
    assert len(list(d.glob("*.wav"))) == debug.KEEP * 6          # 30 dictations kept, not 5
    j = sorted(d.glob("*-s*-3.json"))[-1]
    info = json.loads(j.read_text())
    assert info["seq"] == 3 and info["ctx"] is True and info["context"] == "antes" and info["partial"] is True


def test_replay_reuses_stored_context(tmp_path):
    wav = tmp_path / "a.wav"
    shutil.copy(FIX / "pt_facto.wav", wav)
    wav.with_suffix(".json").write_text(json.dumps({"raw_engine": "x", "text": "y", "context": "frase anterior", "partial": True,
                                                    "session": "abcd1234", "seq": 1, "ctx": True}))
    seen = []
    out = io.StringIO()
    debug.run_replay([str(wav)], None, ["parakeet"], True, False, make_engine=lambda n: (FakeEngine("Bom dia"), "auto"),
                     clean=lambda t, d, **kw: seen.append(kw) or (t, "fake", False, 1), out=out)
    assert seen == [{"context": "frase anterior", "partial": True}]
