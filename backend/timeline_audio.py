#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import mmap
import subprocess
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Callable

import imageio_ffmpeg
import numpy as np

SAMPLE_RATE = 16000


def _log_default(_: str) -> None:
    pass


def decode_mono_16k(
    path: Path,
    input_offset: float = 0.0,
    input_duration: float | None = None,
    *,
    log: Callable[[str], None] | None = None,
) -> np.ndarray:
    logger = log or _log_default
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    cmd = [ffmpeg, "-nostdin", "-v", "error"]
    if input_offset > 0:
        cmd += ["-ss", f"{input_offset:.9f}"]
    cmd += ["-i", str(path)]
    if input_duration is not None and input_duration > 0:
        cmd += ["-t", f"{input_duration:.9f}"]
    cmd += ["-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "pipe:1"]
    logger(f"decoding with ffmpeg: {path}")
    if input_offset > 0 or input_duration:
        logger(f"source slice: offset={input_offset:.6f}s duration={input_duration}")
    # Let FFmpeg stream decoded samples to disk and map them into memory.
    # This avoids keeping both subprocess stdout and a full NumPy copy.
    with tempfile.TemporaryFile() as output:
        proc = subprocess.run(cmd, stdout=output, stderr=subprocess.PIPE, check=False)
        if proc.returncode:
            err = proc.stderr.decode("utf-8", errors="replace")[-4000:]
            raise RuntimeError(f"ffmpeg could not decode audio: {err}")
        if output.seek(0, 2) == 0:
            raise RuntimeError(f"Audio contains no decodable samples: {path}")
        samples = mmap.mmap(output.fileno(), length=0, access=mmap.ACCESS_COPY)
    return np.frombuffer(samples, dtype=np.float32)


def read_manifest(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if int(payload.get("version", 0)) != 1:
        raise RuntimeError("Unsupported timeline audio manifest version")
    clips = payload.get("clips")
    if not isinstance(clips, list) or not clips:
        raise RuntimeError("Timeline audio manifest contains no clips")
    return payload


def manifest_fingerprint(path: Path) -> str:
    payload = read_manifest(path)
    h = hashlib.sha256()
    h.update(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8"))
    for clip in payload.get("clips", []):
        p = Path(str(clip.get("path", ""))).expanduser()
        try:
            st = p.stat()
            h.update(str(p.resolve()).encode("utf-8"))
            h.update(f"{st.st_size}:{st.st_mtime_ns}".encode("ascii"))
        except OSError:
            h.update(str(p).encode("utf-8"))
    return h.hexdigest()


def source_identity(
    audio_path: Path | None, manifest_path: Path | None, offset: float, duration: float | None
) -> dict:
    if manifest_path is not None:
        source = {"kind": "manifest", "fingerprint": manifest_fingerprint(manifest_path)}
    else:
        assert audio_path is not None
        stat = audio_path.stat()
        source = {"kind": "audio", "path": str(audio_path), "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
    return {**source, "offset": offset, "duration": duration}


def _build_placements(payload: dict, start: float, duration: float | None) -> tuple[list[dict], float]:
    timeline_duration = max(0.0, float(payload.get("duration_seconds") or 0.0))
    region_start = max(0.0, float(start or 0.0))
    if duration is None or duration <= 0:
        region_end = timeline_duration
    else:
        region_end = min(timeline_duration, region_start + float(duration)) if timeline_duration > 0 else region_start + float(duration)
    if region_end <= region_start:
        raise RuntimeError("Requested timeline audio region is empty")

    placements: list[dict] = []
    for clip in payload.get("clips", []):
        try:
            clip_start = float(clip["timeline_start"])
            clip_duration = float(clip["duration"])
            source_offset = float(clip.get("source_offset", 0.0))
            source_path = Path(str(clip["path"])).expanduser().resolve()
        except Exception:
            continue
        if clip_duration <= 0 or not source_path.exists():
            continue
        clip_end = clip_start + clip_duration
        a = max(region_start, clip_start)
        b = min(region_end, clip_end)
        if b <= a:
            continue
        placements.append(
            {
                "path": source_path,
                "timeline_start": a - region_start,
                "source_start": source_offset + (a - clip_start),
                "duration": b - a,
                "gain": float(clip.get("gain", 1.0) or 1.0),
            }
        )
    if not placements:
        raise RuntimeError("No file-backed audio clips overlap the requested timeline region")
    return placements, region_end - region_start


def load_manifest_mono_16k(
    manifest_path: Path,
    input_offset: float = 0.0,
    input_duration: float | None = None,
    *,
    log: Callable[[str], None] | None = None,
) -> np.ndarray:
    logger = log or _log_default
    payload = read_manifest(manifest_path)
    placements, out_duration = _build_placements(payload, input_offset, input_duration)
    out_len = max(1, int(round(out_duration * SAMPLE_RATE)))
    mixed = np.zeros(out_len, dtype=np.float32)

    # Merge nearby source ranges from the same media file. A heavily cut stream can
    # have hundreds of timeline clips; decoding each one in a separate ffmpeg process
    # is needlessly slow. Groups with <=2s source gaps are decoded together once.
    by_path: dict[Path, list[dict]] = defaultdict(list)
    for placement in placements:
        by_path[placement["path"]].append(placement)

    for source_path, items in by_path.items():
        items.sort(key=lambda x: x["source_start"])
        groups: list[dict] = []
        for item in items:
            s = float(item["source_start"])
            e = s + float(item["duration"])
            if not groups or s - groups[-1]["end"] > 2.0:
                groups.append({"start": s, "end": e, "items": [item]})
            else:
                groups[-1]["end"] = max(groups[-1]["end"], e)
                groups[-1]["items"].append(item)

        for group in groups:
            group_start = max(0.0, float(group["start"]))
            group_duration = max(0.001, float(group["end"]) - group_start)
            logger(
                f"timeline manifest decode: {source_path.name} "
                f"offset={group_start:.3f}s duration={group_duration:.3f}s clips={len(group['items'])}"
            )
            decoded = decode_mono_16k(source_path, group_start, group_duration, log=logger)
            for item in group["items"]:
                rel_source = float(item["source_start"]) - group_start
                src0 = max(0, int(round(rel_source * SAMPLE_RATE)))
                n = max(1, int(round(float(item["duration"]) * SAMPLE_RATE)))
                src1 = min(decoded.size, src0 + n)
                if src1 <= src0:
                    continue
                dst0 = max(0, int(round(float(item["timeline_start"]) * SAMPLE_RATE)))
                dst1 = min(mixed.size, dst0 + (src1 - src0))
                if dst1 <= dst0:
                    continue
                mixed[dst0:dst1] += decoded[src0 : src0 + (dst1 - dst0)] * float(item.get("gain", 1.0))

    peak = max(float(mixed.max()), -float(mixed.min()))
    if peak > 1.0:
        mixed /= peak
    if peak <= 1e-7:
        raise RuntimeError("Timeline manifest decoded only silence")
    return mixed


def materialize_manifest_wav(
    manifest_path: Path,
    output_path: Path,
    input_offset: float,
    input_duration: float,
    *,
    log: Callable[[str], None] | None = None,
) -> Path:
    import soundfile as sf

    arr = load_manifest_mono_16k(
        manifest_path,
        input_offset=input_offset,
        input_duration=input_duration,
        log=log,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(output_path), arr, SAMPLE_RATE, subtype="PCM_16")
    return output_path
