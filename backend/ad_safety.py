#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

from process_utils import NO_WINDOW
from profanity import load_rules, normalize_text, review_transcript
from timeline_audio import decode_mono_16k, load_manifest_mono_16k

APP = Path(os.environ.get("STREAMER_VOICE_DATA_DIR") or Path.home() / ".streamer_voice")
SAMPLE_RATE = 16000

# Keep model caches together and make Hugging Face network failures finite instead
# of looking like a permanently frozen Resolve script.
os.environ.setdefault("HF_HOME", str(APP / "models" / "huggingface"))
os.environ.setdefault("HF_HUB_ETAG_TIMEOUT", "20")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "90")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def load_audio(args) -> np.ndarray:
    if args.manifest:
        path = Path(args.manifest).expanduser().resolve()
        log(f"loading cut timeline audio manifest: {path}")
        return load_manifest_mono_16k(path, args.input_offset, args.input_duration, log=log)
    path = Path(args.audio).expanduser().resolve()
    log(f"loading audio: {path}")
    return decode_mono_16k(path, args.input_offset, args.input_duration, log=log)


def module_available(name: str) -> bool:
    try:
        return importlib.util.find_spec(name) is not None
    except Exception:
        return False


def is_apple_silicon() -> bool:
    return sys.platform == "darwin" and platform.machine().lower() in {"arm64", "aarch64"}


def torch_runtime() -> dict[str, Any]:
    out: dict[str, Any] = {"available": False, "cuda": False, "mps": False}
    try:
        import torch

        out["available"] = True
        out["version"] = getattr(torch, "__version__", "unknown")
        out["cuda"] = bool(torch.cuda.is_available())
        if out["cuda"]:
            try:
                out["cuda_device"] = torch.cuda.get_device_name(0)
            except Exception:
                pass
        out["mps"] = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"
    return out


def ctranslate_runtime() -> dict[str, Any]:
    out: dict[str, Any] = {"available": False, "cuda_devices": 0}
    try:
        import ctranslate2

        out["available"] = True
        out["version"] = getattr(ctranslate2, "__version__", "unknown")
        out["cuda_devices"] = int(ctranslate2.get_cuda_device_count())
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"
    return out


def choose_engine(requested_engine: str, requested_device: str) -> tuple[str, str]:
    engine = (requested_engine or "auto").strip().lower()
    device = (requested_device or "auto").strip().lower()
    aliases = {
        "faster": "faster-whisper",
        "faster_whisper": "faster-whisper",
        "openai": "torch-whisper",
        "torch": "torch-whisper",
        "metal": "mlx",
    }
    engine = aliases.get(engine, engine)

    if engine != "auto":
        if engine == "mlx":
            if not is_apple_silicon() or not module_available("mlx_whisper"):
                raise RuntimeError("MLX Whisper is only available on Apple Silicon with mlx-whisper installed")
            return "mlx", "metal"
        if engine == "torch-whisper":
            rt = torch_runtime()
            if not module_available("whisper"):
                raise RuntimeError("openai-whisper is not installed")
            chosen = "cuda" if device == "auto" and rt.get("cuda") else device
            if chosen == "auto":
                chosen = "cpu"
            if chosen == "cuda" and not rt.get("cuda"):
                raise RuntimeError("CUDA was requested for torch-whisper, but PyTorch CUDA is unavailable")
            return "torch-whisper", chosen
        if engine == "faster-whisper":
            return "faster-whisper", device
        raise RuntimeError(f"Unknown transcription engine: {requested_engine}")

    # Apple Silicon: MLX is the native Metal path. CTranslate2/faster-whisper is
    # CPU-only on macOS, which is exactly why 0.10 could look painfully slow.
    if is_apple_silicon() and device in {"auto", "mps", "metal"} and module_available("mlx_whisper"):
        return "mlx", "metal"

    # Windows: prefer PyTorch CUDA because the official PyTorch wheel carries its
    # CUDA runtime. This avoids requiring users to manually assemble cuBLAS/cuDNN
    # just for CTranslate2. The installer attempts a CUDA PyTorch build when an
    # NVIDIA GPU is detected.
    if sys.platform == "win32" and device in {"auto", "cuda"}:
        rt = torch_runtime()
        if rt.get("cuda") and module_available("whisper"):
            return "torch-whisper", "cuda"

    # Linux / explicitly configured CTranslate2 CUDA can still use faster-whisper.
    if device in {"auto", "cuda"}:
        ct = ctranslate_runtime()
        if int(ct.get("cuda_devices") or 0) > 0:
            return "faster-whisper", "cuda"

    return "faster-whisper", "cpu" if device == "auto" else device


def runtime_probe(requested_engine: str = "auto", requested_device: str = "auto") -> dict[str, Any]:
    probe: dict[str, Any] = {
        "platform": sys.platform,
        "machine": platform.machine(),
        "python": platform.python_version(),
        "hf_token_set": bool(os.getenv("HF_TOKEN") or os.getenv("HUGGING_FACE_HUB_TOKEN")),
        "mlx_whisper_installed": module_available("mlx_whisper"),
        "openai_whisper_installed": module_available("whisper"),
        "faster_whisper_installed": module_available("faster_whisper"),
        "torch": torch_runtime(),
        "ctranslate2": ctranslate_runtime(),
    }
    try:
        engine, device = choose_engine(requested_engine, requested_device)
        probe["selected_engine"] = engine
        probe["selected_device"] = device
    except Exception as exc:
        probe["selection_error"] = f"{type(exc).__name__}: {exc}"
    return probe


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def write_status(path: Path | None, stage: str, **extra: Any) -> None:
    if path is None:
        return
    # Include the worker PID in every heartbeat/status snapshot. The Resolve UI
    # uses it for a real Cancel button instead of leaving a long Whisper scan
    # running after the user asks it to stop.
    payload: dict[str, Any] = {"stage": stage, "updated_at": time.time(), "pid": os.getpid()}
    payload.update(extra)
    try:
        atomic_json(path, payload)
    except Exception:
        pass


def normalize_result_segments(raw_segments: list[dict[str, Any]], offset: float = 0.0, keep_start: float | None = None, keep_end: float | None = None) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for segment in raw_segments or []:
        seg_words: list[dict[str, Any]] = []
        for word in segment.get("words") or []:
            start = word.get("start")
            end = word.get("end")
            if start is None or end is None:
                continue
            start = float(start) + offset
            end = float(end) + offset
            midpoint = (start + end) * 0.5
            if keep_start is not None and midpoint < keep_start:
                continue
            if keep_end is not None and midpoint >= keep_end:
                continue
            raw = str(word.get("word") or "").strip()
            norm = normalize_text(raw)
            if not norm:
                continue
            seg_words.append(
                {
                    "start": start,
                    "end": end,
                    "word": raw,
                    "norm": norm,
                    "probability": float(word.get("probability") or 0.0),
                }
            )
        if not seg_words:
            continue
        out.append(
            {
                "start": float(seg_words[0]["start"]),
                "end": float(seg_words[-1]["end"]),
                "text": str(segment.get("text") or "").strip(),
                "words": seg_words,
            }
        )
    return out


def normalize_faster_segment(segment: Any) -> dict[str, Any] | None:
    words: list[dict[str, Any]] = []
    for word in segment.words or []:
        if word.start is None or word.end is None:
            continue
        raw = str(word.word or "").strip()
        norm = normalize_text(raw)
        if not norm:
            continue
        words.append(
            {
                "start": float(word.start),
                "end": float(word.end),
                "word": raw,
                "norm": norm,
                "probability": float(word.probability or 0.0),
            }
        )
    if not words:
        return None
    return {
        "start": float(words[0]["start"]),
        "end": float(words[-1]["end"]),
        "text": str(segment.text or "").strip(),
        "words": words,
    }


def mlx_model_repo(model: str) -> str:
    value = str(model or "small").strip()
    if "/" in value:
        return value
    known = {
        "tiny": "mlx-community/whisper-tiny-mlx",
        "tiny.en": "mlx-community/whisper-tiny.en-mlx",
        "base": "mlx-community/whisper-base-mlx",
        "base.en": "mlx-community/whisper-base.en-mlx",
        "small": "mlx-community/whisper-small-mlx",
        "small.en": "mlx-community/whisper-small.en-mlx",
        "medium": "mlx-community/whisper-medium-mlx",
        "medium.en": "mlx-community/whisper-medium.en-mlx",
        "large-v2": "mlx-community/whisper-large-v2-mlx",
        "large-v3": "mlx-community/whisper-large-v3-mlx",
        "turbo": "mlx-community/whisper-large-v3-turbo",
        "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    }
    return known.get(value, f"mlx-community/whisper-{value}-mlx")


def iter_overlapped_chunks(audio: np.ndarray, chunk_seconds: float, overlap_seconds: float = 1.5):
    duration = audio.size / SAMPLE_RATE
    chunk_seconds = max(60.0, float(chunk_seconds or 600.0))
    logical_start = 0.0
    while logical_start < duration - 1e-6:
        logical_end = min(duration, logical_start + chunk_seconds)
        physical_start = max(0.0, logical_start - (overlap_seconds if logical_start > 0 else 0.0))
        physical_end = min(duration, logical_end + (overlap_seconds if logical_end < duration else 0.0))
        a = int(round(physical_start * SAMPLE_RATE))
        b = int(round(physical_end * SAMPLE_RATE))
        yield logical_start, logical_end, physical_start, np.ascontiguousarray(audio[a:b], dtype=np.float32)
        logical_start = logical_end


def transcribe_mlx(audio: np.ndarray, args, status_path: Path | None) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    import mlx_whisper

    repo = mlx_model_repo(args.model)
    duration = audio.size / SAMPLE_RATE
    language_arg = None if not args.language or args.language.lower() == "auto" else args.language
    log(f"Whisper runtime: engine=mlx device=metal model={repo}")
    if not (os.getenv("HF_TOKEN") or os.getenv("HUGGING_FACE_HUB_TOKEN")):
        log("HF token: not set (safe; only first model download may be rate-limited)")
    write_status(status_path, "loading_model", engine="mlx", device="metal", model=repo, progress_seconds=0.0, duration_seconds=duration)

    segments: list[dict[str, Any]] = []
    detected_language: str | None = language_arg
    first = True
    for logical_start, logical_end, physical_start, chunk in iter_overlapped_chunks(audio, args.chunk_seconds):
        if first:
            log("MLX first chunk includes model download/load if the model is not cached yet")
        else:
            write_status(status_path, "transcribing", engine="mlx", device="metal", model=repo, progress_seconds=logical_start, duration_seconds=duration)
        t0 = time.monotonic()
        # mlx-whisper currently does not implement beam-search decoding in the
        # released package. Passing beam_size causes DecodingTask to raise
        # NotImplementedError before the first chunk is transcribed. Use the
        # native temperature fallback / greedy path instead.
        result = mlx_whisper.transcribe(
            chunk,
            path_or_hf_repo=repo,
            language=language_arg,
            word_timestamps=True,
            condition_on_previous_text=False,
            fp16=True,
            verbose=None,
        )
        detected_language = detected_language or result.get("language")
        normalized = normalize_result_segments(
            result.get("segments") or [],
            offset=physical_start,
            keep_start=logical_start,
            keep_end=None if logical_end >= duration - 1e-6 else logical_end,
        )
        segments.extend(normalized)
        elapsed = time.monotonic() - t0
        log(f"transcription progress: {logical_end:.0f}/{duration:.0f}s ({100.0*logical_end/max(duration,1e-9):.1f}%) engine=mlx chunk={elapsed:.1f}s")
        write_status(status_path, "transcribing", engine="mlx", device="metal", model=repo, progress_seconds=logical_end, duration_seconds=duration)
        first = False

    return segments, {
        "engine": "mlx",
        "device": "metal",
        "compute_type": "float16",
        "language": detected_language or "unknown",
        "language_probability": None,
        "model_runtime_name": repo,
    }


def transcribe_torch_whisper(audio: np.ndarray, args, status_path: Path | None, device: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    import torch
    import whisper

    duration = audio.size / SAMPLE_RATE
    language_arg = None if not args.language or args.language.lower() == "auto" else args.language
    model_dir = APP / "models" / "openai-whisper"
    model_dir.mkdir(parents=True, exist_ok=True)
    log(f"Whisper runtime: engine=torch-whisper device={device} model={args.model}")
    write_status(status_path, "loading_model", engine="torch-whisper", device=device, model=args.model, progress_seconds=0.0, duration_seconds=duration)
    t0 = time.monotonic()
    model = whisper.load_model(args.model, device=device, download_root=str(model_dir))
    log(f"Whisper model ready: engine=torch-whisper device={device} load={time.monotonic()-t0:.1f}s")

    segments: list[dict[str, Any]] = []
    detected_language: str | None = language_arg
    for logical_start, logical_end, physical_start, chunk in iter_overlapped_chunks(audio, args.chunk_seconds):
        write_status(status_path, "transcribing", engine="torch-whisper", device=device, model=args.model, progress_seconds=logical_start, duration_seconds=duration)
        t1 = time.monotonic()
        result = model.transcribe(
            chunk,
            language=language_arg,
            word_timestamps=True,
            condition_on_previous_text=False,
            beam_size=5,
            fp16=(device == "cuda"),
            verbose=None,
        )
        detected_language = detected_language or result.get("language")
        segments.extend(
            normalize_result_segments(
                result.get("segments") or [],
                offset=physical_start,
                keep_start=logical_start,
                keep_end=None if logical_end >= duration - 1e-6 else logical_end,
            )
        )
        elapsed = time.monotonic() - t1
        log(f"transcription progress: {logical_end:.0f}/{duration:.0f}s ({100.0*logical_end/max(duration,1e-9):.1f}%) engine=torch-whisper chunk={elapsed:.1f}s")
        write_status(status_path, "transcribing", engine="torch-whisper", device=device, model=args.model, progress_seconds=logical_end, duration_seconds=duration)

    if device == "cuda":
        try:
            torch.cuda.empty_cache()
        except Exception:
            pass
    return segments, {
        "engine": "torch-whisper",
        "device": device,
        "compute_type": "float16" if device == "cuda" else "float32",
        "language": detected_language or "unknown",
        "language_probability": None,
        "model_runtime_name": args.model,
    }


def choose_faster_runtime(requested_device: str, requested_compute: str | None) -> tuple[str, str]:
    device = (requested_device or "auto").lower()
    if device == "auto":
        try:
            import ctranslate2

            device = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
        except Exception:
            device = "cpu"
    compute = requested_compute or ("float16" if device == "cuda" else "int8")
    return device, compute


def transcribe_faster(audio: np.ndarray, args, status_path: Path | None, requested_device: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    from faster_whisper import WhisperModel

    duration = audio.size / SAMPLE_RATE
    device, compute_type = choose_faster_runtime(requested_device, args.compute_type)
    model_dir = APP / "models" / "whisper"
    model_dir.mkdir(parents=True, exist_ok=True)
    if not (os.getenv("HF_TOKEN") or os.getenv("HUGGING_FACE_HUB_TOKEN")):
        log("HF token: not set (safe; only first model download may be rate-limited)")
    log(f"Whisper runtime: engine=faster-whisper device={device} compute_type={compute_type} model={args.model}")
    write_status(status_path, "loading_model", engine="faster-whisper", device=device, model=args.model, progress_seconds=0.0, duration_seconds=duration)

    try:
        t0 = time.monotonic()
        model = WhisperModel(args.model, device=device, compute_type=compute_type, download_root=str(model_dir))
        log(f"Whisper model ready: engine=faster-whisper device={device} load={time.monotonic()-t0:.1f}s")
    except Exception as exc:
        if device == "cuda" and (args.engine or "auto").lower() == "auto":
            log(f"faster-whisper CUDA init failed ({type(exc).__name__}: {exc}); falling back to CPU int8")
            device, compute_type = "cpu", "int8"
            model = WhisperModel(args.model, device=device, compute_type=compute_type, download_root=str(model_dir))
        else:
            raise

    language = None if not args.language or args.language.lower() == "auto" else args.language
    segments_iter, info = model.transcribe(
        audio,
        language=language,
        beam_size=5,
        word_timestamps=True,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
        condition_on_previous_text=True,
    )
    write_status(status_path, "transcribing", engine="faster-whisper", device=device, model=args.model, progress_seconds=0.0, duration_seconds=duration)
    segments: list[dict[str, Any]] = []
    last_report = -60.0
    for segment in segments_iter:
        rec = normalize_faster_segment(segment)
        if rec:
            segments.append(rec)
        pos = float(getattr(segment, "end", 0.0) or 0.0)
        if pos >= last_report + 60.0:
            log(f"transcription progress: {pos:.0f}/{duration:.0f}s ({100.0*pos/max(duration,1e-9):.1f}%) engine=faster-whisper")
            write_status(status_path, "transcribing", engine="faster-whisper", device=device, model=args.model, progress_seconds=pos, duration_seconds=duration)
            last_report = pos
    write_status(status_path, "transcribing", engine="faster-whisper", device=device, model=args.model, progress_seconds=duration, duration_seconds=duration)

    return segments, {
        "engine": "faster-whisper",
        "device": device,
        "compute_type": compute_type,
        "language": str(info.language or language or "unknown"),
        "language_probability": float(info.language_probability) if info.language_probability is not None else None,
        "model_runtime_name": args.model,
    }


def transcribe_audio(audio: np.ndarray, args, status_path: Path | None) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    engine, device = choose_engine(args.engine, args.device)
    log(f"selected transcription engine: {engine} / {device}")
    auto_engine = (args.engine or "auto").strip().lower() == "auto"

    if engine == "mlx":
        try:
            return transcribe_mlx(audio, args, status_path)
        except Exception as exc:
            if not auto_engine:
                raise
            # Do not fail the whole Resolve scan if a future mlx-whisper/API
            # incompatibility slips through. CPU int8 is slower, but reliable
            # and keeps the scan usable. The next run will still prefer MLX.
            log(f"MLX transcription failed ({type(exc).__name__}: {exc}); falling back to faster-whisper CPU int8")
            write_status(
                status_path,
                "runtime_fallback",
                engine="faster-whisper",
                device="cpu",
                reason=f"{type(exc).__name__}: {exc}",
                progress_seconds=0.0,
                duration_seconds=audio.size / SAMPLE_RATE,
            )
            return transcribe_faster(audio, args, status_path, "cpu")

    if engine == "torch-whisper":
        try:
            return transcribe_torch_whisper(audio, args, status_path, device)
        except Exception as exc:
            if not auto_engine:
                raise
            log(f"torch-whisper transcription failed ({type(exc).__name__}: {exc}); falling back to faster-whisper CPU int8")
            write_status(
                status_path,
                "runtime_fallback",
                engine="faster-whisper",
                device="cpu",
                reason=f"{type(exc).__name__}: {exc}",
                progress_seconds=0.0,
                duration_seconds=audio.size / SAMPLE_RATE,
            )
            return transcribe_faster(audio, args, status_path, "cpu")

    return transcribe_faster(audio, args, status_path, device)


def safe_tsv(value: object) -> str:
    return str(value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def run_worker(args) -> int:
    status_path = Path(args.status_file).expanduser().resolve() if args.status_file else None
    write_status(status_path, "starting")

    terms_path = Path(args.terms).expanduser().resolve()
    if not terms_path.exists():
        raise FileNotFoundError(terms_path)
    rules = load_rules(terms_path)
    audio = load_audio(args).astype(np.float32, copy=False)
    duration = audio.size / SAMPLE_RATE
    log(f"audio ready: duration={duration:.1f}s samples={audio.size}")
    write_status(status_path, "runtime_selection", duration_seconds=duration, progress_seconds=0.0)

    segment_records, runtime = transcribe_audio(audio, args, status_path)
    lang_prob = runtime.get("language_probability")
    prob_text = "n/a" if lang_prob is None else f"{float(lang_prob):.3f}"
    log(
        f"transcription done: engine={runtime.get('engine')} device={runtime.get('device')} "
        f"language={runtime.get('language')} probability={prob_text} segments={len(segment_records)}"
    )
    write_status(status_path, "matching_rules", duration_seconds=duration, progress_seconds=duration, **runtime)

    events, word_count = review_transcript(segment_records, rules)
    log(f"reviewed {word_count} timed words")

    counts: dict[str, int] = {}
    severity_counts = {"high": 0, "review": 0}
    for event in events:
        counts[event["category"]] = counts.get(event["category"], 0) + 1
        severity_counts[event["severity"]] = severity_counts.get(event["severity"], 0) + 1

    status = "clean_audio_scan"
    if severity_counts.get("high", 0):
        status = "high_risk_review"
    elif severity_counts.get("review", 0):
        status = "review_needed"

    transcript_text = " ".join(seg["text"] for seg in segment_records if seg.get("text")).strip()
    payload = {
        "version": 4,
        "insult_classifier_version": 2,
        "policy_mode": "conservative_audio_review",
        "disclaimer": "Audio transcript screening cannot guarantee a green monetization icon. YouTube also evaluates visuals, title, thumbnail, description and context.",
        "duration_seconds": duration,
        "language": runtime.get("language"),
        "language_probability": runtime.get("language_probability"),
        "model": args.model,
        "transcription_engine": runtime.get("engine"),
        "transcription_device": runtime.get("device"),
        "transcription_compute_type": runtime.get("compute_type"),
        "runtime_model": runtime.get("model_runtime_name"),
        "status": status,
        "high_count": int(severity_counts.get("high", 0)),
        "review_count": int(severity_counts.get("review", 0)),
        "category_counts": counts,
        "events": events,
        "transcript": transcript_text,
        "segments": [{"start": s["start"], "end": s["end"], "text": s["text"]} for s in segment_records],
    }

    out_json = Path(args.output_json).expanduser().resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    out_tsv = Path(args.output).expanduser().resolve()
    out_tsv.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# start\tend\tseverity\tcategory\tlabel\tphrase\tcontext\tconfidence\tauto_censor"]
    for e in events:
        lines.append(
            f"{e['start']:.6f}\t{e['end']:.6f}\t{safe_tsv(e['severity'])}\t{safe_tsv(e['category'])}\t"
            f"{safe_tsv(e['label'])}\t{safe_tsv(e['phrase'])}\t{safe_tsv(e['context'])}\t"
            f"{float(e.get('confidence', 0.0)):.5f}\t{int(e['auto_censor'])}"
        )
    out_tsv.write_text("\n".join(lines) + "\n", encoding="utf-8")

    write_status(
        status_path,
        "complete",
        duration_seconds=duration,
        progress_seconds=duration,
        high_count=severity_counts.get("high", 0),
        review_count=severity_counts.get("review", 0),
        **runtime,
    )
    log(f"ad-safety scan done: status={status} high={severity_counts.get('high', 0)} review={severity_counts.get('review', 0)}")
    return 0


def terminate_process(proc: subprocess.Popen) -> None:
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def run_supervised(args) -> int:
    status_path = Path(args.status_file).expanduser().resolve() if args.status_file else Path(args.output_json).expanduser().resolve().with_suffix(".progress.json")
    try:
        status_path.unlink(missing_ok=True)
    except Exception:
        pass

    worker_args = [a for a in sys.argv[1:] if a != "--worker"]
    if "--status-file" not in worker_args:
        worker_args.extend(["--status-file", str(status_path)])
    worker_args.append("--worker")
    python_args = ["-X", "utf8"] if sys.flags.utf8_mode else []
    cmd = [sys.executable, *python_args, str(Path(__file__).resolve()), *worker_args]
    log(f"starting supervised ad-safety worker: python={sys.executable}")
    if sys.platform == "win32":
        # GUI-subsystem Python needs explicit handles to keep the worker's logs.
        proc = subprocess.Popen(
            cmd, stdin=subprocess.DEVNULL, stdout=sys.stdout, stderr=sys.stderr, creationflags=NO_WINDOW,
        )
    else:
        proc = subprocess.Popen(cmd)

    last_log = 0.0
    last_stage = None
    stage_started = time.monotonic()
    last_progress: float | None = None
    progress_changed = time.monotonic()
    last_status: dict[str, Any] = {}

    while proc.poll() is None:
        now = time.monotonic()
        status: dict[str, Any] = {}
        try:
            if status_path.exists():
                status = json.loads(status_path.read_text(encoding="utf-8"))
        except Exception:
            status = last_status
        if status:
            last_status = status
            stage = status.get("stage")
            progress = status.get("progress_seconds")
            if stage != last_stage:
                last_stage = stage
                stage_started = now
                progress_changed = now
                last_progress = float(progress) if progress is not None else None
                log(f"worker stage: {stage}")
            elif progress is not None:
                p = float(progress)
                if last_progress is None or p > last_progress + 0.5:
                    last_progress = p
                    progress_changed = now

            if stage == "loading_model" and now - stage_started > float(args.model_load_timeout_seconds):
                terminate_process(proc)
                log(f"ERROR: Whisper model load exceeded {args.model_load_timeout_seconds:.0f}s; worker stopped instead of hanging Resolve forever")
                return 75
            if stage == "transcribing" and now - progress_changed > float(args.stall_timeout_seconds):
                terminate_process(proc)
                log(f"ERROR: transcription made no forward progress for {args.stall_timeout_seconds:.0f}s; worker stopped")
                return 76

        if now - last_log >= 15.0:
            stage = last_status.get("stage", "starting")
            progress = last_status.get("progress_seconds")
            duration = last_status.get("duration_seconds")
            if progress is not None and duration:
                log(f"worker heartbeat: stage={stage} progress={float(progress):.0f}/{float(duration):.0f}s ({100*float(progress)/max(float(duration),1e-9):.1f}%) pid={proc.pid}")
            else:
                log(f"worker heartbeat: stage={stage} pid={proc.pid}")
            last_log = now
        time.sleep(2.0)

    rc = int(proc.returncode or 0)
    if rc != 0:
        log(f"ad-safety worker failed with exit code {rc}")
    return rc


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Conservative YouTube advertiser-safety audio transcript scan")
    source = p.add_mutually_exclusive_group(required=False)
    source.add_argument("--audio")
    source.add_argument("--manifest")
    p.add_argument("--input-offset", type=float, default=0.0)
    p.add_argument("--input-duration", type=float, default=None)
    p.add_argument("--model", default="small")
    p.add_argument("--language", default="auto")
    p.add_argument("--engine", default="auto", help="auto, mlx, torch-whisper, faster-whisper")
    p.add_argument("--device", default="auto")
    p.add_argument("--compute-type", default=None)
    p.add_argument("--chunk-seconds", type=float, default=600.0)
    p.add_argument("--stall-timeout-seconds", type=float, default=900.0)
    p.add_argument("--model-load-timeout-seconds", type=float, default=1800.0)
    p.add_argument("--terms")
    p.add_argument("--output")
    p.add_argument("--output-json")
    p.add_argument("--status-file", default=None)
    p.add_argument("--probe-runtime", action="store_true")
    p.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    return p


def main() -> int:
    p = build_parser()
    args = p.parse_args()
    if args.probe_runtime:
        print(json.dumps(runtime_probe(args.engine, args.device), ensure_ascii=False, indent=2))
        return 0
    if not args.audio and not args.manifest:
        p.error("one of --audio/--manifest is required")
    for name in ("terms", "output", "output_json"):
        if not getattr(args, name):
            p.error(f"--{name.replace('_', '-')} is required")
    if args.worker:
        return run_worker(args)
    return run_supervised(args)


if __name__ == "__main__":
    raise SystemExit(main())
