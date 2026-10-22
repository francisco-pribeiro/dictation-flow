import json
import os
import tempfile
import urllib.error
import urllib.request
import uuid
import wave

import numpy as np

from . import config

PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v3"
WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"


def _wav_bytes(samples, sr):
    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
    import io
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm)
    return buf.getvalue()


class ParakeetEngine:
    name = "parakeet"

    def load(self):
        from parakeet_mlx import from_pretrained
        self.model = from_pretrained(PARAKEET_REPO)

    def transcribe(self, samples, sr, lang="auto", prompt=""):
        # parakeet-mlx only accepts a file path; language ID is automatic.
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(_wav_bytes(samples, sr))
            f.flush()
            res = self.model.transcribe(f.name)
        return res.text.strip(), None


class WhisperEngine:
    name = "whisper"

    def load(self):
        import mlx_whisper  # noqa: F401  (weights load lazily on first call)
        self.mod = mlx_whisper

    def transcribe(self, samples, sr, lang="auto", prompt=""):
        kw = {"path_or_hf_repo": WHISPER_REPO}
        if lang != "auto":
            kw["language"] = lang
        if prompt:
            kw["initial_prompt"] = prompt
        res = self.mod.transcribe(samples.astype(np.float32), **kw)
        return res["text"].strip(), res.get("language")

    def lang_prob(self, samples, code="pt"):
        """Whisper language-ID probability of `code` for the first 30 s (one encoder pass, no decoding)."""
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
        from mlx_whisper.transcribe import ModelHolder
        model = ModelHolder.get_model(WHISPER_REPO, mx.float16)
        mel = log_mel_spectrogram(samples.astype(np.float32), n_mels=model.dims.n_mels, padding=N_SAMPLES)
        mel = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        _, probs = model.detect_language(mel)
        return float(probs.get(code, 0.0))


class GroqEngine:
    name = "groq"
    URL = "https://api.groq.com/openai/v1/audio/transcriptions"

    def load(self):
        self.key = os.environ.get("GROQ_API_KEY")
        if not self.key:
            raise RuntimeError("GROQ_API_KEY is not set (put it in .env or the environment)")

    def transcribe(self, samples, sr, lang="auto", prompt=""):
        boundary = uuid.uuid4().hex
        fields = {"model": "whisper-large-v3-turbo", "response_format": "verbose_json"}
        if lang != "auto":
            fields["language"] = lang
        if prompt:
            fields["prompt"] = prompt
        body = b""
        for k, v in fields.items():
            body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n').encode()
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
                 'Content-Type: audio/wav\r\n\r\n').encode() + _wav_bytes(samples, sr) + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(self.URL, data=body, headers={
            "Authorization": f"Bearer {self.key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": "dictflow/0.1"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                data = json.load(r)
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"Groq HTTP {e.code}: {e.read().decode(errors='replace')[:200]}")
        except (urllib.error.URLError, TimeoutError) as e:
            raise RuntimeError(f"Groq request failed: {e}")
        return data.get("text", "").strip(), data.get("language")


ENGINES = {"parakeet": ParakeetEngine, "whisper": WhisperEngine, "groq": GroqEngine}


def get_engine(name):
    if name not in ENGINES:
        raise ValueError(f"unknown engine {name!r} (choose from {', '.join(ENGINES)})")
    return ENGINES[name]()
