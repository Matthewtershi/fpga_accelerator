#!/usr/bin/env python3
"""Local dataset collection server for the FPGA audio project."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import mimetypes
import re
import threading
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


PROJECT_ROOT = Path(__file__).resolve().parents[1]
STATIC_ROOT = Path(__file__).resolve().parent / "static"
DATA_ROOT = PROJECT_ROOT / "data"
RAW_ROOT = DATA_ROOT / "raw"
MANIFEST_PATH = DATA_ROOT / "manifest.json"
MAX_REQUEST_BYTES = 80 * 1024 * 1024
MANIFEST_LOCK = threading.Lock()

ALLOWED_LABELS = {
    "echo",
    "reverb",
    "high_pitch",
    "low_pitch",
    "bypass",
    "unknown",
    "silence",
    "calibration_noise",
}
ALLOWED_TYPES = {"command", "unknown", "silence", "calibration_noise"}
ALLOWED_SPLITS = {"unassigned", "train", "validation", "test"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def safe_component(value: str, fallback: str = "sample") -> str:
    value = value.strip().lower().replace(" ", "_")
    value = re.sub(r"[^a-z0-9._-]+", "", value)
    value = value.strip("._-")
    return value[:80] or fallback


def load_manifest() -> list[dict]:
    if not MANIFEST_PATH.exists():
        return []
    try:
        data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    return data if isinstance(data, list) else []


def save_manifest(samples: list[dict]) -> None:
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = MANIFEST_PATH.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(samples, indent=2) + "\n", encoding="utf-8")
    temporary.replace(MANIFEST_PATH)


def decode_audio(data_url: str) -> bytes:
    if not isinstance(data_url, str) or not data_url:
        raise ValueError("Missing audio data")
    encoded = data_url.split(",", 1)[1] if "," in data_url else data_url
    try:
        return base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("Audio data is not valid base64") from exc


def write_audio_file(*, content: bytes, filename: str, bucket: str, sample_id: str) -> str:
    clean_name = safe_component(Path(filename).name, "sample.wav")
    suffix = Path(clean_name).suffix.lower()
    if suffix not in {".wav", ".flac", ".mp3", ".m4a", ".aac", ".ogg", ".webm"}:
        suffix = ".wav"
    stem = safe_component(Path(clean_name).stem)
    target_dir = RAW_ROOT / safe_component(bucket)
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"{sample_id}_{stem}{suffix}"
    target.write_bytes(content)
    return target.relative_to(PROJECT_ROOT).as_posix()


class DashboardHandler(SimpleHTTPRequestHandler):
    server_version = "FPGADataDashboard/1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_ROOT), **kwargs)

    def log_message(self, format: str, *args) -> None:
        print(f"[{self.log_date_time_string()}] {format % args}")

    def send_json(self, payload: dict | list, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("Invalid request length") from exc
        if length <= 0 or length > MAX_REQUEST_BYTES:
            raise ValueError("Request is empty or too large")
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("Request body must be valid JSON") from exc

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/samples":
            with MANIFEST_LOCK:
                samples = load_manifest()
            self.send_json({"samples": samples})
            return
        if path.startswith("/api/audio/"):
            self.serve_audio(unquote(path.removeprefix("/api/audio/")))
            return
        super().do_GET()

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path != "/api/samples":
            self.send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return
        try:
            payload = self.read_json()
            sample = self.create_sample(payload)
        except ValueError as exc:
            self.send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            return
        except OSError as exc:
            self.send_json({"error": f"Could not save sample: {exc}"}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        self.send_json({"sample": sample}, HTTPStatus.CREATED)

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        if not path.startswith("/api/samples/"):
            self.send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return
        sample_id = safe_component(unquote(path.removeprefix("/api/samples/")), "")
        if not sample_id:
            self.send_json({"error": "Missing sample id"}, HTTPStatus.BAD_REQUEST)
            return

        removed = None
        with MANIFEST_LOCK:
            samples = load_manifest()
            retained = []
            for sample in samples:
                if sample.get("id") == sample_id and removed is None:
                    removed = sample
                else:
                    retained.append(sample)
            if removed is not None:
                save_manifest(retained)

        if removed is None:
            self.send_json({"error": "Sample not found"}, HTTPStatus.NOT_FOUND)
            return

        for key in ("audio_path", "noise_profile_path"):
            relative = removed.get(key)
            if not relative:
                continue
            path_to_remove = (PROJECT_ROOT / relative).resolve()
            if RAW_ROOT.resolve() in path_to_remove.parents and path_to_remove.exists():
                path_to_remove.unlink()
        self.send_json({"deleted": sample_id})

    def create_sample(self, payload: dict) -> dict:
        sample_type = str(payload.get("sampleType", "")).strip()
        label = str(payload.get("label", "")).strip()
        split = str(payload.get("split", "unassigned")).strip()
        if sample_type not in ALLOWED_TYPES:
            raise ValueError("Invalid sample type")
        if label not in ALLOWED_LABELS:
            raise ValueError("Invalid label")
        if split not in ALLOWED_SPLITS:
            raise ValueError("Invalid dataset split")

        expected = {
            "command": {"echo", "reverb", "high_pitch", "low_pitch", "bypass"},
            "unknown": {"unknown"},
            "silence": {"silence"},
            "calibration_noise": {"calibration_noise"},
        }
        if label not in expected[sample_type]:
            raise ValueError("Label does not match sample type")

        audio = payload.get("audio") or {}
        audio_bytes = decode_audio(str(audio.get("data", "")))
        if len(audio_bytes) < 44:
            raise ValueError("Audio file is empty")

        sample_id = uuid.uuid4().hex[:12]
        audio_path = write_audio_file(
            content=audio_bytes,
            filename=str(audio.get("name", "sample.wav")),
            bucket=sample_type,
            sample_id=sample_id,
        )

        noise_profile_path = None
        noise = payload.get("noiseProfile")
        if isinstance(noise, dict) and noise.get("data"):
            noise_profile_path = write_audio_file(
                content=decode_audio(str(noise.get("data", ""))),
                filename=str(noise.get("name", "noise_profile.wav")),
                bucket="paired_noise",
                sample_id=sample_id,
            )

        sample = {
            "id": sample_id,
            "created_at": utc_now(),
            "sample_type": sample_type,
            "label": label,
            "speaker": str(payload.get("speaker", "")).strip()[:80],
            "session": str(payload.get("session", "")).strip()[:80],
            "environment": str(payload.get("environment", "")).strip()[:80],
            "distance": str(payload.get("distance", "")).strip()[:40],
            "split": split,
            "notes": str(payload.get("notes", "")).strip()[:500],
            "source_filename": Path(str(audio.get("name", "sample.wav"))).name,
            "audio_path": audio_path,
            "noise_profile_path": noise_profile_path,
        }

        with MANIFEST_LOCK:
            samples = load_manifest()
            samples.append(sample)
            save_manifest(samples)
        return sample

    def serve_audio(self, sample_id: str) -> None:
        kind = "noise" if urlparse(self.path).query == "kind=noise" else "audio"
        with MANIFEST_LOCK:
            samples = load_manifest()
        sample = next((item for item in samples if item.get("id") == sample_id), None)
        if sample is None:
            self.send_json({"error": "Sample not found"}, HTTPStatus.NOT_FOUND)
            return
        relative = sample.get("noise_profile_path" if kind == "noise" else "audio_path")
        if not relative:
            self.send_json({"error": "Audio not found"}, HTTPStatus.NOT_FOUND)
            return
        target = (PROJECT_ROOT / relative).resolve()
        if RAW_ROOT.resolve() not in target.parents or not target.exists():
            self.send_json({"error": "Audio not found"}, HTTPStatus.NOT_FOUND)
            return
        content = target.read_bytes()
        mime = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the local FPGA audio dataset dashboard")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    parser.add_argument("--port", default=8000, type=int, help="Port (default: 8000)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    RAW_ROOT.mkdir(parents=True, exist_ok=True)
    if not MANIFEST_PATH.exists():
        save_manifest([])
    server = ThreadingHTTPServer((args.host, args.port), DashboardHandler)
    print(f"Dataset dashboard: http://{args.host}:{args.port}")
    print(f"Samples: {RAW_ROOT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
