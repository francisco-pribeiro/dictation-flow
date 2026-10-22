import json
import socket
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from types import SimpleNamespace

from dictflow import dictionary, server


def test_ensure_file_creates_commented_header_and_never_clobbers():
    p = dictionary.ensure_file()
    assert p.read_text().startswith("# DictFlow dictionary")
    assert not dictionary.entries() and not dictionary.current()  # header is all comments
    dictionary.add("Vektrum")
    before = p.read_text()
    dictionary.ensure_file()
    assert p.read_text() == before
    assert dictionary.entries() == ["Vektrum"]
    assert p.read_text().startswith("# DictFlow dictionary")  # header survives add


def test_no_temp_or_partial_files_left_and_concurrent_adds_all_land():
    ts = [threading.Thread(target=dictionary.add, args=(f"Term{i}",)) for i in range(20)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sorted(dictionary.entries()) == sorted(f"Term{i}" for i in range(20))
    assert not list(dictionary.path().parent.glob("*.tmp"))


def test_reader_never_sees_partial_file_during_writes():
    dictionary.add("Seed")
    stop, bad = threading.Event(), []

    def reader():
        while not stop.is_set():
            lines = dictionary.path().read_text().splitlines()
            if "Seed" not in lines:
                bad.append(lines)

    t = threading.Thread(target=reader)
    t.start()
    for i in range(60):
        dictionary.add(f"X{i}")
    stop.set()
    t.join()
    assert not bad


def _serve():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    worker = SimpleNamespace(engine=SimpleNamespace(name="fake"), provider="none")
    srv = ThreadingHTTPServer(("127.0.0.1", port), server.make_handler(worker, port))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{port}"


def _post(url, body, ctype="application/json"):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={"Content-Type": ctype})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def test_http_dictionary_add_ensure_info():
    srv, base = _serve()
    try:
        assert _post(base + "/dictionary/ensure", {})[0] == 200
        with urllib.request.urlopen(base + "/dictionary") as r:
            info = json.load(r)
        assert info["count"] == 0 and info["path"] == str(dictionary.path())
        assert _post(base + "/dictionary/add", {"entry": "super base -> Supabase"})[1]["status"] == "added"
        code, obj = _post(base + "/dictionary/add", {"entry": "Super  Base -> Supabase"})
        assert (code, obj["status"], obj["count"]) == (200, "exists", 1)
        assert _post(base + "/dictionary/add", {"entry": "a -> b -> c"})[0] == 400
        assert _post(base + "/dictionary/add", {"entry": 3})[0] == 400
        assert _post(base + "/dictionary/add", {"entry": "x"}, ctype="text/plain")[0] == 403
        assert _post(base + "/dictionary/nope", {})[0] == 404
        assert dictionary.entries() == ["super base -> Supabase"]
    finally:
        srv.shutdown()
