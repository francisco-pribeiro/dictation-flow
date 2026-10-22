import io
import wave

from dictflow import server


def _wav(seconds, sr=16000):
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\0\0" * int(sr * seconds))
    return b.getvalue()


def test_wav_seconds():
    assert server.wav_seconds(_wav(1.5)) == 1.5
    assert server.wav_seconds(b"junk") == 0.0


def test_timing_suffix_has_no_text():
    res = {"text": "segredo", "raw": "segredo cru", "fell_back": True,
           "timings_ms": {"decode": 5, "asr": 200, "cleanup": 300, "total": 510}}
    line = server.timing_suffix(2.0, res)
    assert line == " decode=5ms asr=200ms cleanup=300ms total=510ms audio=2.0s chars=7 fell_back=true mode=rewrite"
    assert "segredo" not in line
