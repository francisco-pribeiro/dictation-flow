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
    ("Não consigo registar-me como catsitter", "pt"),
    ("Dá-me feedback a sério.", "pt"),
    ("Só falta acertar o preço do projeto.", "pt"),
    ("Diz-me o que achas do pipeline.", "pt"),
    ("Feedback do cliente chegou esta manhã.", "pt"),
    ("Vou marcar a meeting", "pt"),
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


class FakeWhisper:
    def __init__(self, p):
        self.p, self.calls = p, []

    def lang_prob(self, samples, code="pt"):
        return self.p

    def transcribe(self, samples, sr, lang="auto", prompt=""):
        self.calls.append(lang)
        return "Foi crazy workflow ontem", "pt"


def _guard_worker(text, p, monkeypatch, flag="1", engine="parakeet"):
    monkeypatch.setenv("DICTFLOW_LANG_GUARD", flag)
    w = server.Worker.__new__(server.Worker)
    w.engine = FakeEngine(text)
    w.engine.name = engine
    w.lock = __import__("threading").Lock()
    w.provider = "none"
    w.guard_whisper = FakeWhisper(p)
    return w


def test_lang_guard_retranscribes_en_looking_parakeet_when_audio_is_pt(monkeypatch):
    w = _guard_worker("Foo crazy workflow on thy.", 0.9, monkeypatch)
    res = w.process((FIX / "pt_facto.wav").read_bytes(), False, "")
    assert res["raw"] == "Foi crazy workflow ontem" and w.guard_whisper.calls == ["pt"] and "guard" in res["timings_ms"]


def test_lang_guard_keeps_real_english_and_skips_pt_output(monkeypatch):
    w = _guard_worker("Foo crazy workflow on thy.", 0.1, monkeypatch)
    assert w.process((FIX / "pt_facto.wav").read_bytes(), False, "")["raw"] == "Foo crazy workflow on thy."
    w = _guard_worker("Isto está crazy de verdade", 0.9, monkeypatch)
    assert w.process((FIX / "pt_facto.wav").read_bytes(), False, "")["raw"] == "Isto está crazy de verdade"
    assert w.guard_whisper.calls == []


def test_lang_guard_off_by_default(monkeypatch):
    w = _guard_worker("Foo crazy workflow on thy.", 0.9, monkeypatch, flag="")
    assert w.process((FIX / "pt_facto.wav").read_bytes(), False, "")["raw"] == "Foo crazy workflow on thy."
