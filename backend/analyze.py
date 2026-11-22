#!/usr/bin/env python3
from __future__ import annotations

import argparse
from bisect import bisect_left, bisect_right
from collections.abc import Callable, Iterator
import hashlib
import json
import math
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from silero_vad import get_speech_timestamps, load_silero_vad
from speechbrain.inference.speaker import SpeakerRecognition

from timeline_audio import decode_mono_16k, load_manifest_mono_16k, source_identity

SAMPLE_RATE = 16000
CACHE_VERSION = 4
APP_DIR = Path(os.environ.get("STREAMER_VOICE_DATA_DIR") or Path.home() / ".streamer_voice")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def pick_device(requested: str) -> str:
    requested = (requested or "auto").lower()
    if requested != "auto":
        return requested
    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_mono_16k(path: Path, input_offset: float = 0.0, input_duration: float | None = None) -> torch.Tensor:
    arr = decode_mono_16k(path, input_offset, input_duration, log=log)
    wav = torch.from_numpy(arr).float().cpu()
    minimum, maximum = torch.aminmax(wav)
    peak = max(-minimum.item(), maximum.item())
    if peak > 1.0:
        wav = wav / peak
    return wav.contiguous()


def load_manifest_16k(path: Path, input_offset: float = 0.0, input_duration: float | None = None) -> torch.Tensor:
    arr = load_manifest_mono_16k(path, input_offset, input_duration, log=log)
    wav = torch.from_numpy(arr).float().cpu()
    minimum, maximum = torch.aminmax(wav)
    peak = max(-minimum.item(), maximum.item())
    if peak > 1.0:
        wav = wav / peak
    return wav.contiguous()


def vad_segments(
    wav: torch.Tensor,
    model,
    *,
    speech_pad_ms: int = 20,
    min_silence_ms: int = 120,
) -> list[tuple[int, int]]:
    timestamps = get_speech_timestamps(
        wav,
        model,
        sampling_rate=SAMPLE_RATE,
        threshold=0.5,
        min_speech_duration_ms=250,
        min_silence_duration_ms=max(30, int(min_silence_ms)),
        speech_pad_ms=max(0, int(speech_pad_ms)),
        return_seconds=False,
    )
    return [(int(x["start"]), int(x["end"])) for x in timestamps]


def collect_reference_speech(ref: torch.Tensor, vad_model) -> torch.Tensor:
    # Reference cleanup can keep a slightly larger pad than final marker timing.
    segs = vad_segments(ref, vad_model, speech_pad_ms=40, min_silence_ms=100)
    if not segs:
        return ref[:0]
    return torch.cat([ref[start:end] for start, end in segs])


def active_profile_reference_paths() -> tuple[str | None, list[Path]]:
    app = APP_DIR
    active = app / "active_profile.txt"
    if not active.exists():
        return None, []
    name = active.read_text(encoding="utf-8").strip()
    if not name:
        return None, []
    refs = sorted((app / "profiles" / name / "refs").glob("ref_*.wav"))
    return name, refs


def centroid_reference_embedding(model: SpeakerRecognition, references: list[torch.Tensor], device: str) -> torch.Tensor:
    embeddings = [encode_reference(model, ref, device) for ref in references]
    if not embeddings:
        raise RuntimeError("No usable reference embeddings")
    stacked = torch.cat(embeddings, dim=0)
    centroid = F.normalize(stacked.mean(dim=0, keepdim=True), dim=-1)
    return centroid.cpu()


def window_metadata(
    speech: list[tuple[int, int]],
    window_samples: int,
    hop_samples: int,
    min_speech_samples: int,
) -> list[dict]:
    meta = []
    for speech_index, (seg_start, seg_end) in enumerate(speech):
        if seg_end - seg_start < min_speech_samples or window_samples < min_speech_samples:
            continue
        last = max(seg_start, seg_end - window_samples)
        starts = list(range(seg_start, last + 1, hop_samples))
        if starts[-1] != last:
            starts.append(last)

        for window_index, start in enumerate(starts):
            meta.append(
                {
                    "start": start / SAMPLE_RATE,
                    "end": min(start + window_samples, seg_end) / SAMPLE_RATE,
                    "speech_start": seg_start / SAMPLE_RATE,
                    "speech_end": seg_end / SAMPLE_RATE,
                    "speech_index": speech_index,
                    "window_index": window_index,
                    "window_count": len(starts),
                }
            )
    return meta


def window_batches(
    wav: torch.Tensor, meta: list[dict], window_samples: int, batch_size: int
) -> Iterator[torch.Tensor]:
    for offset in range(0, len(meta), batch_size):
        batch = torch.zeros((min(batch_size, len(meta) - offset), window_samples), dtype=wav.dtype)
        for row, window in enumerate(meta[offset : offset + batch_size]):
            start = round(window["start"] * SAMPLE_RATE)
            end = round(window["end"] * SAMPLE_RATE)
            batch[row, : end - start] = wav[start:end]
        yield batch


def evidence_hits(meta: list[dict], scores: list[float], threshold: float, hop_seconds: float) -> list[dict]:
    if not meta:
        return []
    positive = [float(score) >= threshold for score in scores]
    half_cell = max(0.01, float(hop_seconds) * 0.5)
    hits: list[dict] = []

    for i, (m, score) in enumerate(zip(meta, scores)):
        if not positive[i]:
            continue
        start = float(m["start"])
        end = float(m["end"])
        speech_start = float(m["speech_start"])
        speech_end = float(m["speech_end"])
        window_count = int(m["window_count"])
        window_index = int(m["window_index"])

        if window_count <= 1:
            evidence_start = speech_start
            evidence_end = speech_end
        else:
            center = (start + end) * 0.5
            evidence_start = max(speech_start, center - half_cell)
            evidence_end = min(speech_end, center + half_cell)

            if window_index == 0 and i + 1 < len(meta):
                n = meta[i + 1]
                if (
                    positive[i + 1]
                    and int(n["speech_index"]) == int(m["speech_index"])
                    and int(n["window_index"]) == 1
                ):
                    evidence_start = speech_start

            if window_index == window_count - 1 and i > 0:
                p = meta[i - 1]
                if (
                    positive[i - 1]
                    and int(p["speech_index"]) == int(m["speech_index"])
                    and int(p["window_index"]) == window_index - 1
                ):
                    evidence_end = speech_end

        if evidence_end > evidence_start:
            hits.append({"start": evidence_start, "end": evidence_end, "score": float(score)})
    return hits


def move_speaker_model(model: SpeakerRecognition, device: str) -> SpeakerRecognition:
    model.mods.to(device)
    model.device = device
    model.device_type = device.split(":", 1)[0]
    return model


def load_speaker_model(source: str, requested_device: str) -> tuple[SpeakerRecognition, str]:
    savedir = str(APP_DIR / "models" / "ecapa")
    if requested_device == "mps":
        log("SpeechBrain MPS compatibility workaround: initialize on CPU, then move ECAPA to MPS")
        speaker = SpeakerRecognition.from_hparams(source=source, savedir=savedir, run_opts={"device": "cpu"})
        try:
            move_speaker_model(speaker, "mps")
            log("speaker model ready on mps")
            return speaker, "mps"
        except Exception as exc:
            log(f"MPS model move failed ({type(exc).__name__}: {exc}); using CPU")
            move_speaker_model(speaker, "cpu")
            return speaker, "cpu"
    speaker = SpeakerRecognition.from_hparams(
        source=source,
        savedir=savedir,
        run_opts={"device": requested_device},
    )
    return speaker, requested_device


def encode_reference(model: SpeakerRecognition, wav: torch.Tensor, device: str) -> torch.Tensor:
    with torch.inference_mode():
        batch = wav.unsqueeze(0).to(device)
        emb = model.encode_batch(batch)
        emb = emb.reshape(emb.shape[0], -1)
        return F.normalize(emb.float(), dim=-1).cpu()


def encode_batches(
    model: SpeakerRecognition, batches: Iterator[torch.Tensor], device: str, *, total: int | None = None
) -> torch.Tensor:
    out: list[torch.Tensor] = []
    processed = 0
    with torch.inference_mode():
        for batch in batches:
            emb = model.encode_batch(batch.to(device))
            emb = emb.reshape(emb.shape[0], -1)
            out.append(F.normalize(emb.float(), dim=-1).cpu())
            processed += batch.shape[0]
            if total is not None and (len(out) % 25 == 0 or processed == total):
                log(f"speaker windows: {processed}/{total}")
    if not out:
        return torch.empty((0, 0), dtype=torch.float32)
    return torch.cat(out, dim=0)


def similarity_scores(ref_emb: torch.Tensor, embeddings: torch.Tensor) -> list[float]:
    if embeddings.numel() == 0:
        return []
    ref = ref_emb.expand(embeddings.shape[0], -1)
    return [float(x) for x in F.cosine_similarity(ref, embeddings, dim=-1).tolist()]


def merge_hits(
    hits: list[dict],
    merge_gap: float,
    pad_before: float,
    pad_after: float,
    audio_duration: float,
) -> list[dict]:
    if not hits:
        return []
    hits = sorted(hits, key=lambda x: (x["start"], x["end"]))
    merged: list[dict] = []
    cur = dict(hits[0])
    cur["scores"] = [cur.pop("score")]
    for hit in hits[1:]:
        if hit["start"] <= cur["end"] + merge_gap:
            cur["end"] = max(cur["end"], hit["end"])
            cur["scores"].append(hit["score"])
        else:
            merged.append(cur)
            cur = dict(hit)
            cur["scores"] = [cur.pop("score")]
    merged.append(cur)

    out: list[dict] = []
    for seg in merged:
        scores = seg.pop("scores")
        out.append(
            {
                "start": max(0.0, seg["start"] - pad_before),
                "end": min(audio_duration, seg["end"] + pad_after),
                "score": max(scores),
                "mean_score": sum(scores) / len(scores),
                "windows": len(scores),
            }
        )
    return out


def speech_overlap_seconds(speech: list[tuple[int, int]], start_seconds: float, end_seconds: float) -> float:
    if end_seconds <= start_seconds:
        return 0.0
    start_sample = int(round(start_seconds * SAMPLE_RATE))
    end_sample = int(round(end_seconds * SAMPLE_RATE))
    total = 0
    index = bisect_right(speech, start_sample, key=lambda span: span[1])
    while index < len(speech):
        s, e = speech[index]
        if s >= end_sample:
            break
        total += min(e, end_sample) - max(s, start_sample)
        index += 1
    return total / SAMPLE_RATE


def merge_streamer_pauses(
    segments: list[dict],
    speech: list[tuple[int, int]],
    pause_merge_gap: float,
    pause_speech_tolerance: float,
    long_silence_merge_gap: float,
    long_silence_speech_tolerance: float,
) -> list[dict]:
    if not segments:
        return segments
    segments = sorted(segments, key=lambda x: (x["start"], x["end"]))
    out: list[dict] = []
    cur = dict(segments[0])

    for nxt in segments[1:]:
        gap_start = float(cur["end"])
        gap_end = float(nxt["start"])
        gap = max(0.0, gap_end - gap_start)
        voiced = speech_overlap_seconds(speech, gap_start, gap_end)
        normal_pause = gap <= pause_merge_gap and voiced <= pause_speech_tolerance
        silent_stop = gap <= long_silence_merge_gap and voiced <= long_silence_speech_tolerance
        bridge = normal_pause or silent_stop

        if bridge:
            cur_windows = int(cur.get("windows", 1))
            next_windows = int(nxt.get("windows", 1))
            total_windows = cur_windows + next_windows
            cur_mean = float(cur.get("mean_score", cur.get("score", 0.0)))
            next_mean = float(nxt.get("mean_score", nxt.get("score", 0.0)))
            cur["end"] = max(float(cur["end"]), float(nxt["end"]))
            cur["score"] = max(float(cur.get("score", 0.0)), float(nxt.get("score", 0.0)))
            cur["mean_score"] = (
                (cur_mean * cur_windows + next_mean * next_windows) / max(1, total_windows)
            )
            cur["windows"] = total_windows
            cur["bridged_pauses"] = int(cur.get("bridged_pauses", 0)) + int(nxt.get("bridged_pauses", 0)) + 1
            cur["bridged_silence_seconds"] = float(cur.get("bridged_silence_seconds", 0.0)) + gap
        else:
            out.append(cur)
            cur = dict(nxt)
    out.append(cur)
    return out


def cache_key(identity: dict, args: argparse.Namespace) -> str:
    local_model = Path(args.model).expanduser()
    model_files = []
    if local_model.is_dir():
        model_files = [audio_identity(path.resolve(), 0, None) for path in sorted(local_model.rglob("*")) if path.is_file()]
    payload = {
        "version": CACHE_VERSION,
        "audio": identity,
        "window": args.window,
        "hop": args.hop,
        "min_speech": args.min_speech,
        "vad_pad_ms": args.vad_pad_ms,
        "vad_min_silence_ms": args.vad_min_silence_ms,
        "model": args.model,
        "model_files": model_files,
    }
    raw = json.dumps(payload, sort_keys=True).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:24]


def save_embedding_cache(
    path: Path, speech: list[tuple[int, int]], meta: list[dict], embeddings: torch.Tensor, duration: float
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(dir=path.parent, suffix=".npz")
    try:
        with os.fdopen(fd, "wb") as stream:
            np.savez_compressed(
                stream,
                speech=np.asarray(speech, dtype=np.int64).reshape((-1, 2)),
                meta_json=np.asarray(json.dumps(meta, separators=(",", ":"))),
                embeddings=embeddings.numpy(),
                duration=duration,
            )
        os.replace(temp_path, path)
    finally:
        Path(temp_path).unlink(missing_ok=True)


def load_embedding_cache(path: Path) -> tuple[list[tuple[int, int]], list[dict], torch.Tensor, float] | None:
    if not path.exists():
        return None
    try:
        with np.load(path, allow_pickle=False) as data:
            speech = [(int(a), int(b)) for a, b in np.asarray(data["speech"], dtype=np.int64).tolist()]
            meta = json.loads(str(data["meta_json"].item()))
            embeddings = torch.from_numpy(np.asarray(data["embeddings"], dtype=np.float32))
            duration = float(data["duration"].item())
        if embeddings.ndim != 2 or len(meta) != embeddings.shape[0] or not math.isfinite(duration) or duration <= 0:
            raise ValueError("metadata/embedding length mismatch")
        return speech, meta, embeddings, duration
    except Exception as exc:
        log(f"embedding cache ignored ({type(exc).__name__}: {exc})")
        return None


def nearest_vad_edge(
    speech: list[tuple[int, int]],
    value: float,
    edge: str,
    max_distance: float,
) -> float | None:
    if max_distance <= 0 or not speech:
        return None
    index = 0 if edge == "start" else 1
    sample = value * SAMPLE_RATE
    position = bisect_left(speech, sample, key=lambda span: span[index])
    neighbors = speech[max(0, position - 1) : position + 1]
    nearest = min(neighbors, key=lambda span: abs(span[index] / SAMPLE_RATE - value))[index] / SAMPLE_RATE
    return nearest if abs(nearest - value) <= max_distance else None


def fixed_chunk(wav: torch.Tensor, start_seconds: float, length_seconds: float) -> torch.Tensor:
    length = max(1, int(round(length_seconds * SAMPLE_RATE)))
    start = int(round(start_seconds * SAMPLE_RATE))
    end = start + length
    left_pad = max(0, -start)
    right_pad = max(0, end - wav.numel())
    start = max(0, start)
    end = min(wav.numel(), end)
    chunk = wav[start:end]
    if left_pad or right_pad:
        chunk = F.pad(chunk, (left_pad, right_pad))
    if chunk.numel() < length:
        chunk = F.pad(chunk, (0, length - chunk.numel()))
    return chunk[:length]


def refine_one_boundary(
    get_wav: Callable[[], torch.Tensor],
    speech: list[tuple[int, int]],
    speaker: SpeakerRecognition,
    ref_emb: torch.Tensor,
    device: str,
    coarse: float,
    edge: str,
    threshold: float,
    batch_size: int,
    duration: float,
    *,
    snap_seconds: float,
    search_seconds: float,
    step_seconds: float,
    window_seconds: float,
    threshold_relax: float,
    min_contrast: float,
) -> tuple[float, str, float | None]:
    # Silence/onset boundaries are best taken directly from VAD.  With the
    # reduced VAD padding in 0.2 this is normally within a few frames.
    snapped = nearest_vad_edge(speech, coarse, edge, snap_seconds)
    if snapped is not None:
        return max(0.0, min(duration, snapped)), "vad", None

    # In continuous speech there is no VAD edge at a speaker hand-off.  Search
    # for a point where target-speaker similarity changes most strongly across
    # the point.  Comparing equally sized left/right windows cancels most of the
    # timing bias caused by the speaker model needing ~1 s of context.
    lo = max(0.0, coarse - search_seconds)
    hi = min(duration, coarse + search_seconds)
    if hi <= lo:
        return coarse, "coarse", None
    step = max(0.04, step_seconds)
    count = max(1, int(round((hi - lo) / step)))
    candidates = [lo + i * (hi - lo) / count for i in range(count + 1)]

    wav = get_wav()
    chunks: list[torch.Tensor] = []
    valid_times: list[float] = []
    for t in candidates:
        left_voiced = speech_overlap_seconds(speech, t - window_seconds, t)
        right_voiced = speech_overlap_seconds(speech, t, t + window_seconds)
        target_voiced = right_voiced if edge == "start" else left_voiced
        if target_voiced < min(0.25, window_seconds * 0.30):
            continue
        chunks.append(fixed_chunk(wav, t - window_seconds, window_seconds))
        chunks.append(fixed_chunk(wav, t, window_seconds))
        valid_times.append(t)

    if not chunks:
        return coarse, "coarse", None

    batch = torch.stack(chunks)
    embeddings = encode_batches(speaker, iter(batch.split(batch_size)), device)
    scores = similarity_scores(ref_emb, embeddings)
    target_min = max(0.05, threshold - max(0.0, threshold_relax))
    best_t = coarse
    best_obj = -1e9
    best_contrast: float | None = None

    for idx, t in enumerate(valid_times):
        left_score = scores[idx * 2]
        right_score = scores[idx * 2 + 1]
        if edge == "start":
            target_score = right_score
            contrast = right_score - left_score
        else:
            target_score = left_score
            contrast = left_score - right_score
        if target_score < target_min or contrast < min_contrast:
            continue
        # Prefer the strongest hand-off, with a weak bias toward the coarse
        # boundary so an unrelated transition nearby does not win by accident.
        distance_penalty = 0.025 * abs(t - coarse) / max(0.001, search_seconds)
        objective = contrast - distance_penalty
        if objective > best_obj:
            best_obj = objective
            best_t = t
            best_contrast = contrast

    if best_contrast is None:
        return coarse, "coarse", None
    return max(0.0, min(duration, best_t)), "speaker-change", best_contrast


def refine_segment_boundaries(
    get_wav: Callable[[], torch.Tensor],
    speech: list[tuple[int, int]],
    segments: list[dict],
    speaker: SpeakerRecognition,
    ref_emb: torch.Tensor,
    device: str,
    threshold: float,
    batch_size: int,
    duration: float,
    *,
    enabled: bool,
    snap_seconds: float,
    search_seconds: float,
    step_seconds: float,
    window_seconds: float,
    threshold_relax: float,
    min_contrast: float,
) -> tuple[list[dict], dict]:
    if not enabled or not segments:
        return segments, {"refined": 0, "vad": 0, "speaker_change": 0, "coarse": len(segments) * 2}

    out: list[dict] = []
    stats = {"refined": 0, "vad": 0, "speaker_change": 0, "coarse": 0}
    shifts: list[float] = []
    for idx, seg in enumerate(segments, 1):
        original_start = float(seg["start"])
        original_end = float(seg["end"])
        new_start, start_method, start_contrast = refine_one_boundary(
            get_wav, speech, speaker, ref_emb, device, original_start, "start", threshold, batch_size, duration,
            snap_seconds=snap_seconds, search_seconds=search_seconds, step_seconds=step_seconds,
            window_seconds=window_seconds, threshold_relax=threshold_relax, min_contrast=min_contrast,
        )
        new_end, end_method, end_contrast = refine_one_boundary(
            get_wav, speech, speaker, ref_emb, device, original_end, "end", threshold, batch_size, duration,
            snap_seconds=snap_seconds, search_seconds=search_seconds, step_seconds=step_seconds,
            window_seconds=window_seconds, threshold_relax=threshold_relax, min_contrast=min_contrast,
        )

        # Never collapse a valid region because one local probe was noisy.
        if new_end <= new_start + 0.08:
            new_start, new_end = original_start, original_end
            start_method = end_method = "coarse"
            start_contrast = end_contrast = None

        item = dict(seg)
        item["start"] = new_start
        item["end"] = new_end
        item["boundary_start_method"] = start_method
        item["boundary_end_method"] = end_method
        if start_contrast is not None:
            item["boundary_start_contrast"] = start_contrast
        if end_contrast is not None:
            item["boundary_end_contrast"] = end_contrast
        out.append(item)

        for method in (start_method, end_method):
            if method == "vad":
                stats["vad"] += 1
            elif method == "speaker-change":
                stats["speaker_change"] += 1
            else:
                stats["coarse"] += 1
        if abs(new_start - original_start) > 0.001:
            stats["refined"] += 1
            shifts.append(abs(new_start - original_start))
        if abs(new_end - original_end) > 0.001:
            stats["refined"] += 1
            shifts.append(abs(new_end - original_end))
        if idx % 25 == 0 or idx == len(segments):
            log(f"boundary refinement: {idx}/{len(segments)}")

    stats["mean_shift_seconds"] = (sum(shifts) / len(shifts)) if shifts else 0.0
    stats["max_shift_seconds"] = max(shifts) if shifts else 0.0
    return out, stats


def main() -> int:
    p = argparse.ArgumentParser(description="Find one known speaker in a Resolve timeline/source slice")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--audio")
    source.add_argument("--manifest", help="timeline audio manifest JSON for already-cut timelines")
    p.add_argument("--input-offset", type=float, default=0.0)
    p.add_argument("--input-duration", type=float, default=None)
    p.add_argument("--rendered", action="store_true", help="cache a temporary Resolve render by its decoded audio")
    p.add_argument("--reference-start", type=float, required=True)
    p.add_argument("--reference-duration", type=float, default=10.0)
    p.add_argument("--threshold", type=float, default=0.35)
    p.add_argument("--window", type=float, default=2.4)
    p.add_argument("--hop", type=float, default=0.8)
    p.add_argument("--min-speech", type=float, default=0.55)
    p.add_argument("--merge-gap", type=float, default=0.7)
    p.add_argument("--pause-merge-gap", type=float, default=3.0)
    p.add_argument("--pause-speech-tolerance", type=float, default=0.65)
    p.add_argument("--long-silence-merge-gap", type=float, default=5.0)
    p.add_argument("--long-silence-speech-tolerance", type=float, default=0.15)
    p.add_argument("--pad-before", type=float, default=0.0)
    p.add_argument("--pad-after", type=float, default=0.0)
    p.add_argument("--vad-pad-ms", type=int, default=20)
    p.add_argument("--vad-min-silence-ms", type=int, default=120)
    p.add_argument("--refine-boundaries", action=argparse.BooleanOptionalAction, default=True)
    p.add_argument("--boundary-vad-snap", type=float, default=0.75)
    p.add_argument("--boundary-search", type=float, default=0.9)
    p.add_argument("--boundary-step", type=float, default=0.10)
    p.add_argument("--boundary-window", type=float, default=0.90)
    p.add_argument("--boundary-threshold-relax", type=float, default=0.04)
    p.add_argument("--boundary-min-contrast", type=float, default=0.035)
    p.add_argument("--batch-size", type=int, default=24)
    p.add_argument("--device", default="auto")
    p.add_argument("--model", default="speechbrain/spkrec-ecapa-voxceleb")
    p.add_argument("--cache-dir", default=str(APP_DIR / "cache"))
    p.add_argument("--cache", action=argparse.BooleanOptionalAction, default=True)
    p.add_argument("--analysis-id")
    p.add_argument("--output", required=True)
    p.add_argument("--output-tsv")
    args = p.parse_args()

    numeric = [value for value in vars(args).values() if isinstance(value, float)]
    if any(not math.isfinite(value) for value in numeric):
        p.error("numeric options must be finite")
    if min(args.window, args.hop, args.min_speech, args.reference_duration, args.boundary_window, args.batch_size) <= 0:
        p.error("window, hop, minimum speech, reference duration, boundary window and batch size must be positive")

    audio_path = Path(args.audio).expanduser().resolve() if args.audio else None
    manifest_path = Path(args.manifest).expanduser().resolve() if args.manifest else None
    output_path = Path(args.output).expanduser().resolve()
    identity = source_identity(audio_path, manifest_path, args.input_offset, args.input_duration)

    threads = max(1, min(4, torch.get_num_threads()))
    torch.set_num_threads(1)
    device = pick_device(args.device)
    log(f"device: {device}")
    wav = None
    vad_model = None

    def get_wav() -> torch.Tensor:
        nonlocal wav
        if wav is None:
            if manifest_path is not None:
                wav = load_manifest_16k(manifest_path, args.input_offset, args.input_duration)
            else:
                assert audio_path is not None
                wav = load_mono_16k(audio_path, args.input_offset, args.input_duration)
        return wav

    def get_vad():
        nonlocal vad_model
        if vad_model is None:
            vad_model = load_silero_vad()
        return vad_model

    profile_name, profile_paths = active_profile_reference_paths()
    references: list[torch.Tensor] = []
    reference_mode = "profile" if profile_paths else "timeline"
    for ref_path in profile_paths:
        try:
            cleaned = collect_reference_speech(load_mono_16k(ref_path), get_vad())
            if cleaned.numel() >= int(0.8 * SAMPLE_RATE):
                references.append(cleaned)
            else:
                log(f"profile reference ignored (too little speech): {ref_path.name}")
        except Exception as exc:
            log(f"profile reference ignored ({type(exc).__name__}: {exc}): {ref_path.name}")

    if not references:
        if args.reference_start < 0:
            raise RuntimeError("The active profile has no sample with enough speech; set a temporary reference")
        reference_mode = "timeline"
        ref_start = round(args.reference_start * SAMPLE_RATE)
        ref_end = ref_start + round(args.reference_duration * SAMPLE_RATE)
        raw_reference = get_wav()[ref_start:ref_end]
        if raw_reference.numel() < int(0.8 * SAMPLE_RATE):
            raise RuntimeError("Reference region contains less than 0.8 seconds of audio")
        reference = collect_reference_speech(raw_reference, get_vad())
        if reference.numel() < int(0.8 * SAMPLE_RATE):
            raise RuntimeError("Not enough speech in the reference region; choose a cleaner/longer streamer phrase")
        references = [reference]
    log(f"reference mode: {reference_mode}; usable samples: {len(references)}")

    cache_path = None
    cached = None
    if args.cache:
        cache_identity = identity
        if args.rendered:
            cache_identity = {"rendered_pcm_sha256": hashlib.sha256(memoryview(get_wav().numpy())).hexdigest()}
        key = cache_key(cache_identity, args)
        cache_path = Path(args.cache_dir).expanduser().resolve() / f"timeline_{key}.npz"
        cached = load_embedding_cache(cache_path)

    window_samples = max(1, round(args.window * SAMPLE_RATE))
    if cached is not None:
        speech, window_meta, timeline_embeddings, duration = cached
        log(f"embedding cache hit: {cache_path.name} ({len(window_meta)} windows)")
    else:
        timeline_wav = get_wav()
        duration = timeline_wav.numel() / SAMPLE_RATE
        speech = vad_segments(timeline_wav, get_vad(), speech_pad_ms=args.vad_pad_ms, min_silence_ms=args.vad_min_silence_ms)
        log(f"VAD regions: {len(speech)}")
        window_meta = window_metadata(
            speech, window_samples, max(1, round(args.hop * SAMPLE_RATE)), max(1, round(args.min_speech * SAMPLE_RATE))
        )
        if not window_meta:
            raise RuntimeError("No speech windows detected in timeline audio")
        timeline_embeddings = None

    torch.set_num_threads(threads)
    log(f"loading speaker model: {args.model}")
    speaker, speaker_device = load_speaker_model(args.model, device)
    log(f"encoding {len(references)} reference sample(s)")
    try:
        ref_emb = centroid_reference_embedding(speaker, references, speaker_device)
    except RuntimeError as exc:
        if speaker_device != "mps":
            raise
        log(f"MPS ECAPA warm-up failed ({type(exc).__name__}: {exc}); retrying on CPU")
        speaker_device = "cpu"
        move_speaker_model(speaker, speaker_device)
        ref_emb = centroid_reference_embedding(speaker, references, speaker_device)

    if timeline_embeddings is None:
        log(f"encoding {len(window_meta)} timeline windows on {speaker_device}")

        def encode_timeline(device: str) -> torch.Tensor:
            batches = window_batches(get_wav(), window_meta, window_samples, args.batch_size)
            return encode_batches(speaker, batches, device, total=len(window_meta))

        try:
            timeline_embeddings = encode_timeline(speaker_device)
        except RuntimeError as exc:
            if speaker_device != "mps":
                raise
            log(f"MPS timeline encoding failed ({type(exc).__name__}: {exc}); restarting on CPU")
            speaker_device = "cpu"
            move_speaker_model(speaker, speaker_device)
            ref_emb = centroid_reference_embedding(speaker, references, speaker_device)
            timeline_embeddings = encode_timeline(speaker_device)
        if cache_path is not None:
            try:
                if source_identity(audio_path, manifest_path, args.input_offset, args.input_duration) == identity:
                    save_embedding_cache(cache_path, speech, window_meta, timeline_embeddings, duration)
                    log(f"embedding cache saved: {cache_path.name}")
            except OSError as exc:
                log(f"embedding cache save failed ({type(exc).__name__}: {exc})")

    scores = similarity_scores(ref_emb, timeline_embeddings)
    hits = evidence_hits(window_meta, scores, args.threshold, args.hop)
    segments = merge_hits(hits, args.merge_gap, args.pad_before, args.pad_after, duration)
    raw_segment_count = len(segments)
    segments = merge_streamer_pauses(
        segments,
        speech,
        args.pause_merge_gap,
        args.pause_speech_tolerance,
        args.long_silence_merge_gap,
        args.long_silence_speech_tolerance,
    )
    if len(segments) != raw_segment_count:
        log(
            f"pause grouping: {raw_segment_count} -> {len(segments)} segments "
            f"(gap<={args.pause_merge_gap:.2f}s/speech<={args.pause_speech_tolerance:.2f}s; "
            f"silent stop<={args.long_silence_merge_gap:.2f}s/speech<={args.long_silence_speech_tolerance:.2f}s)"
        )

    pre_refine_count = len(segments)
    try:
        segments, boundary_stats = refine_segment_boundaries(
            get_wav, speech, segments, speaker, ref_emb, speaker_device, args.threshold,
            args.batch_size, duration,
            enabled=args.refine_boundaries,
            snap_seconds=args.boundary_vad_snap,
            search_seconds=args.boundary_search,
            step_seconds=args.boundary_step,
            window_seconds=args.boundary_window,
            threshold_relax=args.boundary_threshold_relax,
            min_contrast=args.boundary_min_contrast,
        )
    except RuntimeError as exc:
        if speaker_device == "mps":
            log(f"MPS boundary refinement failed ({type(exc).__name__}: {exc}); retrying boundaries on CPU")
            speaker_device = "cpu"
            move_speaker_model(speaker, speaker_device)
            ref_emb = centroid_reference_embedding(speaker, references, speaker_device)
            segments, boundary_stats = refine_segment_boundaries(
                get_wav, speech, segments, speaker, ref_emb, speaker_device, args.threshold,
                args.batch_size, duration,
                enabled=args.refine_boundaries,
                snap_seconds=args.boundary_vad_snap,
                search_seconds=args.boundary_search,
                step_seconds=args.boundary_step,
                window_seconds=args.boundary_window,
                threshold_relax=args.boundary_threshold_relax,
                min_contrast=args.boundary_min_contrast,
            )
        else:
            raise

    if args.refine_boundaries:
        log(
            "boundary refinement done: "
            f"changed={boundary_stats['refined']} edges, vad={boundary_stats['vad']}, "
            f"speaker_change={boundary_stats['speaker_change']}, coarse={boundary_stats['coarse']}, "
            f"mean_shift={boundary_stats['mean_shift_seconds']:.3f}s, "
            f"max_shift={boundary_stats['max_shift_seconds']:.3f}s"
        )

    if source_identity(audio_path, manifest_path, args.input_offset, args.input_duration) != identity:
        raise RuntimeError("The source audio changed during analysis; run Find again")

    payload = {
        "version": 2,
        "analysis_id": args.analysis_id,
        "vad": {
            "source": identity,
            "rendered": args.rendered,
            "pad_ms": args.vad_pad_ms,
            "min_silence_ms": args.vad_min_silence_ms,
            "regions_samples": speech,
        },
        "audio": str(manifest_path or audio_path),
        "source_kind": "manifest" if manifest_path is not None else "audio",
        "duration_seconds": duration,
        "reference": {
            "mode": reference_mode,
            "profile": profile_name if reference_mode == "profile" else None,
            "sample_count": len(references),
            "start_seconds": args.reference_start if reference_mode == "timeline" else None,
            "duration_seconds": args.reference_duration if reference_mode == "timeline" else None,
            "voiced_seconds": sum(ref.numel() for ref in references) / SAMPLE_RATE,
        },
        "threshold": args.threshold,
        "window_seconds": args.window,
        "hop_seconds": args.hop,
        "speech_regions": len(speech),
        "candidate_windows": len(window_meta),
        "matching_windows": len(hits),
        "raw_segments_before_pause_grouping": raw_segment_count,
        "segments_before_boundary_refinement": pre_refine_count,
        "pause_merge_gap_seconds": args.pause_merge_gap,
        "long_silence_merge_gap_seconds": args.long_silence_merge_gap,
        "boundary_refinement": boundary_stats,
        "cache_used": cached is not None,
        "cache_file": str(cache_path) if cache_path is not None else None,
        "segments": segments,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    if args.output_tsv:
        tsv_path = Path(args.output_tsv).expanduser().resolve()
        tsv_path.parent.mkdir(parents=True, exist_ok=True)
        lines = ["# start\tend\tscore\tmean_score\twindows"]
        for seg in segments:
            lines.append(
                f"{float(seg['start']):.6f}\t{float(seg['end']):.6f}\t{float(seg['score']):.8f}\t"
                f"{float(seg.get('mean_score', seg['score'])):.8f}\t{int(seg.get('windows', 1))}"
            )
        tsv_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    log(f"done: {len(segments)} merged segments")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
