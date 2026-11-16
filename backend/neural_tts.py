"""CPU Chinese neural TTS; loaded only when explicitly configured."""
import io
from pathlib import Path
import threading
import wave


TEST_TEXT = "这是一条测试播报。"


class SpeechBusyError(RuntimeError):
    pass


class MeloTts:
    def __init__(self, model_dir, threads=2):
        import sherpa_onnx

        root = Path(model_dir).resolve()
        for name in ("model.onnx", "tokens.txt", "lexicon.txt"):
            if not (root / name).is_file():
                raise ValueError(f"Missing TTS resource: {root / name}")
        # Some archives contain a 133-byte Git LFS pointer called model.int8.onnx.
        # Use the actual FP32 weight file, never mistake the pointer for a model.
        if (root / "model.onnx").stat().st_size < 1_000_000:
            raise ValueError("model.onnx is not a downloaded neural model")
        vits = sherpa_onnx.OfflineTtsVitsModelConfig(
            model=str(root / "model.onnx"),
            tokens=str(root / "tokens.txt"),
            lexicon=str(root / "lexicon.txt"),
            noise_scale=0.0,
            noise_scale_w=0.0,
        )
        config = sherpa_onnx.OfflineTtsConfig(
            model=sherpa_onnx.OfflineTtsModelConfig(
                vits=vits, num_threads=threads, provider="cpu", debug=False
            ),
            rule_fsts=",".join(str(root / name) for name in (
                "phone.fst", "date.fst", "number.fst", "new_heteronym.fst"
            ) if (root / name).is_file()),
            max_num_sentences=1,
        )
        if not config.validate():
            raise ValueError("Invalid neural TTS configuration")
        self.engine = sherpa_onnx.OfflineTts(config)
        self.lock = threading.Lock()

    def synthesize(self, text):
        import numpy as np

        if not isinstance(text, str) or not text.strip() or len(text) > 80:
            raise ValueError("TTS text must contain 1 to 80 characters")
        if not self.lock.acquire(blocking=False):
            raise SpeechBusyError("TTS is busy; skip instead of queuing stale speech")
        try:
            audio = self.engine.generate(text.strip(), sid=0, speed=0.9)
            samples = np.asarray(audio.samples, dtype=np.float32)
            if samples.size == 0 or samples.size > audio.sample_rate * 15:
                raise ValueError("TTS returned empty or excessively long audio")
            if not np.all(np.isfinite(samples)):
                raise ValueError("TTS returned invalid samples")
            peak = float(np.max(np.abs(samples)))
            if peak < 1e-6:
                raise ValueError("TTS returned silent audio")
            # Short reminders should be audible without clipping. Deterministic
            # VITS noise settings and a slightly slower rate aid reproducibility.
            samples = samples * (0.85 / peak)
            pcm = np.rint(np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
            output = io.BytesIO()
            with wave.open(output, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(audio.sample_rate)
                wav.writeframes(pcm)
            return output.getvalue()
        finally:
            self.lock.release()
