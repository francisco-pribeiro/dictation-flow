import numpy as np

from dictflow.audio import SR, has_speech, trim_silence


def tone(sec, amp=0.3):
    t = np.arange(int(SR * sec)) / SR
    return (amp * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def sil(sec):
    return np.zeros(int(SR * sec), dtype=np.float32)


def test_silence_has_no_speech():
    assert not has_speech(sil(2))
    assert len(trim_silence(sil(2))) == 0


def test_tone_has_speech():
    assert has_speech(np.concatenate([sil(1), tone(0.5), sil(1)]))


def test_trim_keeps_padding():
    x = np.concatenate([sil(1), tone(0.5), sil(1)])
    y = trim_silence(x)
    assert 0.5 * SR < len(y) < 0.5 * SR + 2 * 0.2 * SR
    assert len(y) < len(x)


def test_padding_clamped_at_edges():
    x = tone(0.5)
    assert len(trim_silence(x)) == len(x)


def test_short_input():
    assert len(trim_silence(np.zeros(10, dtype=np.float32))) == 0
