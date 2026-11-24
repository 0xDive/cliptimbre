#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import subprocess
import tempfile
from collections import defaultdict
from pathlib import Path

import imageio_ffmpeg
import numpy as np
import soundfile as sf

from process_utils import NO_WINDOW

SAMPLE_RATE = 48_000
CHANNELS = 2
BLOCK_FRAMES = SAMPLE_RATE * 4


def csv_set(value: str | None) -> set[str]:
    if not value:
        return set()
    return {part.strip() for part in value.split(",") if part.strip()}


def read_manifest(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if int(payload.get("version", 0)) != 1:
        raise RuntimeError("Unsupported timeline audio manifest version")
    clips = payload.get("clips")
    if not isinstance(clips, list) or not clips:
        raise RuntimeError("Timeline audio manifest contains no clips")
    return payload


def build_intervals(
    report: dict,
    categories: set[str],
    severities: set[str],
    duration: float | None,
    pad_before: float,
    pad_after: float,
) -> tuple[list[tuple[float, float]], list[dict]]:
    selected: list[dict] = []
    intervals: list[tuple[float, float]] = []
    max_duration = float(duration) if duration and duration > 0 else None
    for event in report.get("events") or []:
        category = str(event.get("category") or "")
        severity = str(event.get("severity") or "review")
        if category == "frequent_profanity" or event.get("auto_censor") is False:
            continue
        if categories and "all" not in categories and category not in categories:
            continue
        if severities and severity not in severities:
            continue
        try:
            start = float(event.get("start", 0.0)) - pad_before
            end = float(event.get("end", start)) + pad_after
        except Exception:
            continue
        start = max(0.0, start)
        end = max(start, end)
        if max_duration is not None:
            start = min(max_duration, start)
            end = min(max_duration, end)
        if end - start < 0.015:
            continue
        selected.append(event)
        intervals.append((start, end))

    if not intervals:
        return [], selected

    intervals.sort()
    merged: list[list[float]] = []
    join_gap = 0.030
    for start, end in intervals:
        if not merged or start > merged[-1][1] + join_gap:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    return [(a, b) for a, b in merged], selected


def _manifest_groups(payload: dict) -> tuple[list[dict], float, int]:
    duration = max(0.0, float(payload.get("duration_seconds") or 0.0))
    clips: list[dict] = []
    for raw in payload.get("clips") or []:
        try:
            path = Path(str(raw["path"])).expanduser().resolve()
            timeline_start = float(raw["timeline_start"])
            source_offset = float(raw.get("source_offset", 0.0))
            clip_duration = float(raw["duration"])
        except Exception:
            continue
        if clip_duration <= 0:
            continue
        if not path.exists():
            raise FileNotFoundError(path)
        clips.append(
            {
                "path": path,
                "timeline_start": max(0.0, timeline_start),
                "source_start": max(0.0, source_offset),
                "duration": clip_duration,
            }
        )
        duration = max(duration, max(0.0, timeline_start) + clip_duration)
    if not clips:
        raise RuntimeError("Timeline audio manifest contains no usable file-backed clips")

    # Decode nearby source slices only once, then split/trim inside ffmpeg. This
    # keeps heavily cut stream timelines from spawning one decoder per edit.
    by_path: dict[Path, list[dict]] = defaultdict(list)
    for clip in clips:
        by_path[clip["path"]].append(clip)

    groups: list[dict] = []
    for path in sorted(by_path, key=lambda p: str(p)):
        items = sorted(by_path[path], key=lambda x: x["source_start"])
        path_groups: list[dict] = []
        for item in items:
            start = float(item["source_start"])
            end = start + float(item["duration"])
            if not path_groups or start - float(path_groups[-1]["end"]) > 2.0:
                path_groups.append({"path": path, "start": start, "end": end, "items": [item]})
            else:
                path_groups[-1]["end"] = max(float(path_groups[-1]["end"]), end)
                path_groups[-1]["items"].append(item)
        groups.extend(path_groups)
    return groups, duration, len(clips)


def build_manifest_ffmpeg(manifest_path: Path) -> tuple[list[str], Path, float, int, int]:
    payload = read_manifest(manifest_path)
    groups, duration, clip_count = _manifest_groups(payload)
    if duration <= 0:
        raise RuntimeError("Timeline duration is zero")

    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error"]
    for group in groups:
        group_duration = max(0.001, float(group["end"]) - float(group["start"]))
        cmd += [
            "-ss",
            f"{float(group['start']):.9f}",
            "-t",
            f"{group_duration:.9f}",
            "-i",
            str(group["path"]),
        ]

    filters: list[str] = [f"anullsrc=r={SAMPLE_RATE}:cl=stereo:d={duration:.9f}[base]"]
    clip_labels: list[str] = []
    clip_idx = 0
    for input_idx, group in enumerate(groups):
        items = group["items"]
        n = len(items)
        src_labels = [f"g{input_idx}_{i}" for i in range(n)]
        common = (
            f"[{input_idx}:a:0]aresample={SAMPLE_RATE},"
            "aformat=sample_fmts=fltp:channel_layouts=stereo"
        )
        if n == 1:
            filters.append(f"{common}[{src_labels[0]}]")
        else:
            outs = "".join(f"[{label}]" for label in src_labels)
            filters.append(f"{common},asplit={n}{outs}")

        group_start = float(group["start"])
        for item, src_label in zip(items, src_labels):
            rel = max(0.0, float(item["source_start"]) - group_start)
            clip_duration = max(0.001, float(item["duration"]))
            delay_ms = max(0, int(round(float(item["timeline_start"]) * 1000.0)))
            out_label = f"clip{clip_idx}"
            filters.append(
                f"[{src_label}]atrim=start={rel:.9f}:duration={clip_duration:.9f},"
                f"asetpts=PTS-STARTPTS,adelay=delays={delay_ms}:all=1[{out_label}]"
            )
            clip_labels.append(out_label)
            clip_idx += 1

    mix_inputs = "[base]" + "".join(f"[{label}]" for label in clip_labels)
    filters.append(
        f"{mix_inputs}amix=inputs={1 + len(clip_labels)}:duration=first:"
        f"dropout_transition=0:normalize=0,atrim=duration={duration:.9f}[mix]"
    )

    handle = tempfile.NamedTemporaryFile("w", suffix=".fffilter", encoding="utf-8", delete=False)
    try:
        handle.write(";\n".join(filters) + "\n")
        handle.flush()
        script_path = Path(handle.name)
    finally:
        handle.close()

    cmd += [
        "-filter_complex_script",
        str(script_path),
        "-map",
        "[mix]",
        "-ac",
        str(CHANNELS),
        "-ar",
        str(SAMPLE_RATE),
        "-f",
        "f32le",
        "pipe:1",
    ]
    return cmd, script_path, duration, clip_count, len(groups)


def build_audio_ffmpeg(audio_path: Path) -> tuple[list[str], None, None, int, int]:
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(audio_path),
        "-vn",
        "-ac",
        str(CHANNELS),
        "-ar",
        str(SAMPLE_RATE),
        "-f",
        "f32le",
        "pipe:1",
    ]
    return cmd, None, None, 0, 0


def _db_gain(db: float) -> float:
    return float(10.0 ** (float(db) / 20.0))


def _smoothstep01(x: np.ndarray) -> np.ndarray:
    """Raised-cosine 0..1 curve with zero slope at both ends."""
    x = np.clip(x, 0.0, 1.0)
    return (0.5 - 0.5 * np.cos(np.pi * x)).astype(np.float32)


def _apply_interval_to_block(
    audio: np.ndarray,
    block_start: int,
    start: int,
    end: int,
    fade_samples: int,
    *,
    mode: str,
    frequency: float,
    level_db: float,
    beep_duck_db: float,
    beep_ramp_samples: int,
) -> None:
    """Apply one censor interval without hard gain discontinuities.

    Mute uses a raised-cosine fade to true silence, then fades back up.
    Beep ducks (rather than hard-mutes) the source under a softly-ramped tone.
    The interval list is merged before this function is called, so envelopes do
    not fight each other on overlapping profanity hits.
    """
    block_end = block_start + audio.shape[0]
    fade_left = max(0, start - fade_samples)
    fade_right = end + fade_samples
    if fade_right <= block_start or fade_left >= block_end:
        return

    body_gain = 0.0 if mode == "mute" else _db_gain(beep_duck_db)

    # Smoothly move from unity gain to the censor body gain.
    left0 = max(block_start, fade_left)
    left1 = min(block_end, start)
    if left1 > left0 and start > fade_left:
        global_idx = np.arange(left0, left1, dtype=np.float32)
        t = (global_idx - float(fade_left)) / float(start - fade_left)
        curve = _smoothstep01(t)
        gain = (1.0 + (body_gain - 1.0) * curve)[:, None]
        audio[left0 - block_start : left1 - block_start] *= gain

    body0 = max(block_start, start)
    body1 = min(block_end, end)
    if body1 > body0:
        sl = slice(body0 - block_start, body1 - block_start)
        audio[sl] *= body_gain

        if mode == "beep":
            n = body1 - body0
            rel = np.arange(body0 - start, body1 - start, dtype=np.float64)
            amp = _db_gain(level_db)

            # A plain sine is intentionally used: it masks speech reliably and
            # remains predictable after YouTube normalization. A short raised-
            # cosine attack/release removes the click/ear-hit of a hard tone.
            wave = np.sin(2.0 * math.pi * float(frequency) * rel / float(SAMPLE_RATE)).astype(np.float32)
            interval_len = max(1, end - start)
            ramp_n = min(interval_len // 2, max(1, int(beep_ramp_samples)))
            if ramp_n > 0:
                rel_i = np.arange(body0 - start, body1 - start, dtype=np.float32)
                attack = _smoothstep01(rel_i / float(ramp_n))
                release = _smoothstep01((interval_len - 1 - rel_i) / float(ramp_n))
                wave *= np.minimum(attack, release)
            wave *= amp

            # Centered mono beep in both stereo channels. The source remains at
            # beep_duck_db underneath, preserving room/game ambience.
            audio[sl, 0] += wave
            audio[sl, 1] += wave

    # Smoothly restore unity gain after the censored interval.
    right0 = max(block_start, end)
    right1 = min(block_end, fade_right)
    if right1 > right0 and fade_right > end:
        global_idx = np.arange(right0, right1, dtype=np.float32)
        t = (global_idx - float(end)) / float(fade_right - end)
        curve = _smoothstep01(t)
        gain = (body_gain + (1.0 - body_gain) * curve)[:, None]
        audio[right0 - block_start : right1 - block_start] *= gain

def process_ffmpeg_stream(
    cmd: list[str],
    output_path: Path,
    intervals: list[tuple[float, float]],
    *,
    mode: str,
    frequency: float,
    level_db: float,
    fade_ms: float,
    beep_duck_db: float,
) -> float:
    interval_frames = [
        (
            max(0, int(round(start * SAMPLE_RATE))),
            max(1, int(round(end * SAMPLE_RATE))),
        )
        for start, end in intervals
    ]
    fade_samples = max(1, int(round(max(1.0, float(fade_ms)) * SAMPLE_RATE / 1000.0)))
    beep_ramp_samples = max(1, int(round(min(25.0, max(8.0, float(fade_ms) * 0.25)) * SAMPLE_RATE / 1000.0)))
    bytes_per_frame = CHANNELS * 4
    block_bytes = BLOCK_FRAMES * bytes_per_frame
    output_path.parent.mkdir(parents=True, exist_ok=True)

    frame_cursor = 0
    leftover = b""
    with tempfile.TemporaryFile() as err_file:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=err_file, creationflags=NO_WINDOW)
        assert proc.stdout is not None
        try:
            with sf.SoundFile(
                str(output_path),
                mode="w",
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                subtype="PCM_24",
            ) as out:
                while True:
                    data = proc.stdout.read(block_bytes)
                    if not data:
                        break
                    raw = leftover + data
                    usable = len(raw) - (len(raw) % bytes_per_frame)
                    leftover = raw[usable:]
                    if usable <= 0:
                        continue
                    audio = np.frombuffer(raw[:usable], dtype=np.float32).reshape(-1, CHANNELS).copy()
                    block_end = frame_cursor + audio.shape[0]
                    for start, end in interval_frames:
                        if end + fade_samples <= frame_cursor:
                            continue
                        if start - fade_samples >= block_end:
                            break
                        _apply_interval_to_block(
                            audio,
                            frame_cursor,
                            start,
                            end,
                            fade_samples,
                            mode=mode,
                            frequency=frequency,
                            level_db=level_db,
                            beep_duck_db=beep_duck_db,
                            beep_ramp_samples=beep_ramp_samples,
                        )
                    np.clip(audio, -0.999, 0.999, out=audio)
                    out.write(audio)
                    frame_cursor = block_end
        except Exception:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except Exception:
                proc.kill()
            raise
        finally:
            try:
                proc.stdout.close()
            except Exception:
                pass

        code = proc.wait()
        if leftover:
            # Raw f32 stereo should always end on a full frame boundary.
            raise RuntimeError("ffmpeg returned a truncated raw audio frame")
        if code != 0:
            err_file.seek(0)
            err = err_file.read().decode("utf-8", errors="replace")[-8000:]
            raise RuntimeError(f"ffmpeg could not build timeline audio mix: {err}")

    if frame_cursor <= 0:
        raise RuntimeError("Timeline audio decode produced no samples")
    return frame_cursor / float(SAMPLE_RATE)


def main() -> int:
    p = argparse.ArgumentParser(description="Build a censored full-timeline audio stem from a YouTube ad-safety report")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--audio", help="rendered timeline audio/video media")
    source.add_argument("--manifest", help="file-backed cut-timeline audio manifest")
    p.add_argument("--report", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--summary", required=True)
    p.add_argument("--mode", choices=("beep", "mute"), default="beep")
    p.add_argument("--categories", default="strong_profanity,moderate_profanity,hate_or_slur")
    p.add_argument("--severities", default="high,review")
    p.add_argument("--pad-before", type=float, default=0.08)
    p.add_argument("--pad-after", type=float, default=0.12)
    p.add_argument("--beep-hz", type=float, default=1000.0)
    p.add_argument("--beep-db", type=float, default=-12.0)
    p.add_argument("--fade-ms", type=float, default=70.0)
    p.add_argument("--beep-duck-db", type=float, default=-36.0)
    args = p.parse_args()

    report_path = Path(args.report).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    summary_path = Path(args.summary).expanduser().resolve()
    if not report_path.exists():
        raise FileNotFoundError(report_path)

    source_mode: str
    source_path: Path
    known_duration: float | None = None
    cleanup_path: Path | None = None
    if args.manifest:
        source_mode = "manifest"
        source_path = Path(args.manifest).expanduser().resolve()
        if not source_path.exists():
            raise FileNotFoundError(source_path)
        cmd, cleanup_path, known_duration, clip_count, group_count = build_manifest_ffmpeg(source_path)
        print(
            f"Auto Censor source: cut-timeline manifest clips={clip_count} "
            f"decode_groups={group_count} duration={known_duration:.3f}s",
            flush=True,
        )
    else:
        source_mode = "render"
        source_path = Path(args.audio).expanduser().resolve()
        if not source_path.exists():
            raise FileNotFoundError(source_path)
        cmd, cleanup_path, known_duration, _, _ = build_audio_ffmpeg(source_path)
        print(f"Auto Censor source: rendered media {source_path}", flush=True)

    report = json.loads(report_path.read_text(encoding="utf-8"))
    categories = csv_set(args.categories)
    severities = csv_set(args.severities)
    intervals, selected_events = build_intervals(
        report,
        categories,
        severities,
        known_duration,
        max(0.0, args.pad_before),
        max(0.0, args.pad_after),
    )
    if not intervals:
        if cleanup_path is not None:
            cleanup_path.unlink(missing_ok=True)
        raise RuntimeError("No report events matched the selected Auto Censor categories/severities")

    try:
        duration = process_ffmpeg_stream(
            cmd,
            output_path,
            intervals,
            mode=args.mode,
            frequency=args.beep_hz,
            level_db=args.beep_db,
            fade_ms=max(1.0, args.fade_ms),
            beep_duck_db=min(0.0, args.beep_duck_db),
        )
    finally:
        if cleanup_path is not None:
            cleanup_path.unlink(missing_ok=True)

    # Clamp summary intervals to the actual media duration for rendered-media fallback.
    final_intervals = [(max(0.0, a), min(duration, b)) for a, b in intervals if a < duration and min(duration, b) > a]

    category_counts: dict[str, int] = {}
    severity_counts: dict[str, int] = {}
    for event in selected_events:
        category = str(event.get("category") or "")
        severity = str(event.get("severity") or "review")
        category_counts[category] = category_counts.get(category, 0) + 1
        severity_counts[severity] = severity_counts.get(severity, 0) + 1

    summary = {
        "version": 3,
        "mode": args.mode,
        "fade_ms": max(1.0, args.fade_ms),
        "beep_hz": args.beep_hz,
        "beep_db": args.beep_db,
        "beep_duck_db": min(0.0, args.beep_duck_db),
        "source_mode": source_mode,
        "input": str(source_path),
        "output": str(output_path),
        "duration_seconds": duration,
        "selected_event_count": len(selected_events),
        "merged_interval_count": len(final_intervals),
        "censored_seconds": sum(b - a for a, b in final_intervals),
        "categories": sorted(categories),
        "severities": sorted(severities),
        "category_counts": category_counts,
        "severity_counts": severity_counts,
        "intervals": [{"start": a, "end": b} for a, b in final_intervals],
    }
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
