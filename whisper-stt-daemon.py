#!/usr/bin/env python3
"""Whisper STT Daemon — local speech-to-text with pre-loaded MLX model.

HTTP server on 127.0.0.1:19876:
  POST /toggle  — start/stop recording; returns transcribed text on stop
  POST /cancel  — cancel recording without transcription
  GET  /status  — current state + active model
  GET  /models  — list available models
  POST /model   — switch model (body: {"model": "short_name"})
"""

import json
import logging
import os
import sys
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

import numpy as np
import sounddevice as sd

MODELS = {
    "turbo": "mlx-community/whisper-large-v3-turbo",
    "large": "mlx-community/whisper-large-v3-mlx",
}

SAMPLE_RATE = 16000
PORT = 19876
HOST = "127.0.0.1"
CONFIG_PATH = os.path.join(os.path.expanduser("~"), ".whisper-stt", "config.json")
NUM_BARS = 11
LEVELS_HISTORY = 22  # keep ~22 blocks for rolling window

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("whisper-stt")

def read_model_from_config():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        name = cfg.get("model", "turbo")
        return name if name in MODELS else "turbo"
    except Exception:
        return "turbo"


def save_model_to_config(name):
    cfg = {}
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except Exception:
        pass
    cfg["model"] = name
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f)


lock = threading.Lock()
state = {
    "status": "loading",
    "recording": False,
    "audio_chunks": [],
    "active_model": read_model_from_config(),
    "rms_history": [],
}


def load_model(name=None):
    if name is None:
        name = state["active_model"]
    repo = MODELS[name]
    log.info("Loading model: %s (%s)", name, repo)
    with lock:
        state["status"] = "loading"
    import mlx_whisper
    try:
        # Thorough warmup: transcribe different audio lengths to pre-compile
        # all Metal shader variants. Without this, first real transcriptions
        # are 10-15x slower as Metal JIT-compiles kernels on demand.
        for duration_sec in [1, 3, 5]:
            audio = np.zeros(SAMPLE_RATE * duration_sec, dtype=np.float32)
            mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=repo,
                initial_prompt=PUNCTUATION_PROMPT,
            )
            log.info("Warmup %ds done", duration_sec)
        with lock:
            state["active_model"] = name
            state["status"] = "idle"
        log.info("Model '%s' fully warmed up", name)
        return True
    except Exception as e:
        log.error("Failed to load model '%s': %s", name, e)
        with lock:
            state["status"] = "idle"
        return False


def audio_callback(indata, frames, time_info, status):
    if status:
        log.warning("sounddevice: %s", status)
    if state["recording"]:
        mono = indata[:, 0].copy()
        state["audio_chunks"].append(mono)
        # Compute RMS for this block
        rms = float(np.sqrt(np.mean(mono ** 2)))
        hist = state["rms_history"]
        hist.append(rms)
        if len(hist) > LEVELS_HISTORY:
            del hist[:-LEVELS_HISTORY]


audio_stream = sd.InputStream(
    samplerate=SAMPLE_RATE,
    channels=1,
    dtype="float32",
    callback=audio_callback,
    blocksize=1024,
)


PUNCTUATION_PROMPT = "Здравствуйте. Вот, что я хотел сказать: Hello, my name is Anton."


def transcribe(audio):
    import mlx_whisper
    repo = MODELS[state["active_model"]]
    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=repo,
        initial_prompt=PUNCTUATION_PROMPT,
    )
    return result.get("text", "").strip()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/toggle":
            self._toggle()
        elif self.path == "/cancel":
            self._cancel()
        elif self.path == "/model":
            self._switch_model()
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == "/status":
            self._respond({
                "status": state["status"],
                "model": state["active_model"],
            })
        elif self.path == "/models":
            self._respond({
                "active": state["active_model"],
                "available": list(MODELS.keys()),
            })
        elif self.path == "/levels":
            self._get_levels()
        else:
            self.send_error(404)

    # Symmetric shape: center bars get full level, edges get less
    BAR_WEIGHTS = [0.3, 0.5, 0.7, 0.85, 0.95, 1.0, 0.95, 0.85, 0.7, 0.5, 0.3]

    def _get_levels(self):
        hist = state["rms_history"]
        if not hist:
            self._respond({"levels": [0.0] * NUM_BARS})
            return
        # Use last few samples for current level
        recent = hist[-4:]
        level = min(1.0, max(recent) * 20.0)
        # Add slight variation per bar using recent history
        bars = []
        for i in range(NUM_BARS):
            w = self.BAR_WEIGHTS[i]
            # Pick a slightly different RMS sample per bar for natural jitter
            idx = min(i % len(hist), len(hist) - 1)
            jitter = min(1.0, hist[-(idx + 1)] * 20.0) if hist else 0.0
            val = level * w * 0.7 + jitter * w * 0.3
            bars.append(round(min(1.0, val), 2))
        self._respond({"levels": bars})

    def _switch_model(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode() if length else ""
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._respond({"error": "Invalid JSON"})
            return

        name = data.get("model", "")
        if name not in MODELS:
            self._respond({"error": f"Unknown model: {name}", "available": list(MODELS.keys())})
            return

        if name == state["active_model"]:
            self._respond({"status": "ok", "model": name, "message": "Already active"})
            return

        if state["status"] != "idle":
            self._respond({"error": "Cannot switch while " + state["status"]})
            return

        ok = load_model(name)
        if ok:
            save_model_to_config(name)
            self._respond({"status": "ok", "model": name})
        else:
            self._respond({"error": f"Failed to load {name} (not downloaded?)", "model": state["active_model"]})

    def _toggle(self):
        with lock:
            if state["status"] == "loading":
                self._respond({"status": "loading", "error": "Model still loading"})
                return
            if state["status"] == "transcribing":
                self._respond({"status": "transcribing", "error": "Busy"})
                return

            if not state["recording"]:
                state["audio_chunks"] = []
                state["recording"] = True
                state["status"] = "recording"
                log.info("Recording started")
                self._respond({"status": "recording"})
                return
            else:
                state["recording"] = False
                state["status"] = "transcribing"
                chunks = state["audio_chunks"]
                state["audio_chunks"] = []

        if not chunks:
            log.warning("No audio captured")
            with lock:
                state["status"] = "idle"
            self._respond({"status": "done", "text": ""})
            return

        audio = np.concatenate(chunks)
        duration = len(audio) / SAMPLE_RATE
        log.info("Transcribing %.1fs of audio...", duration)

        t0 = time.time()
        text = transcribe(audio)
        elapsed = time.time() - t0
        log.info("Done in %.2fs: %s", elapsed, text[:120])

        with lock:
            state["status"] = "idle"
        self._respond({"status": "done", "text": text})

    def _cancel(self):
        with lock:
            state["recording"] = False
            state["audio_chunks"] = []
            state["status"] = "idle"
        log.info("Cancelled")
        self._respond({"status": "idle"})

    def _respond(self, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    audio_stream.start()
    log.info("Audio stream started (device=%s, rate=%d)", sd.default.device[0], SAMPLE_RATE)
    threading.Thread(target=load_model, daemon=True).start()
    server = HTTPServer((HOST, PORT), Handler)
    log.info("Listening on %s:%d", HOST, PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
    finally:
        audio_stream.stop()
        server.server_close()
