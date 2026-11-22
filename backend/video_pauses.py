#!/usr/bin/env python3
"""Find possible playback holds in file-backed timeline video."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


MIN_HOLD = 1.2
MOTION_CONTEXT = 0.35
FREEZE_EVENT = re.compile(r"lavfi\.freezedetect\.freeze_(start|end):\s*([0-9.]+)")


def parse_crop(value: str) -> tuple[int, int, int, int]:
    try:
        x, y, width, height = (int(field) for field in value.split(","))
    except ValueError as exc:
        raise ValueError("Crop must contain x,y,width,height percentages") from exc
    if not (x >= 0 and y >= 0 and width >= 10 and height >= 10 and x + width <= 100 and y + height <= 100):
        raise ValueError("Crop must fit in the frame and cover at least 10% of each dimension")
    return x, y, width, height


def freeze_candidates(log: str, duration: float) -> list[tuple[float, float]]:
    freezes: list[list[float | None]] = []
    for kind, raw in FREEZE_EVENT.findall(log):
        seconds = float(raw)
        if kind == "start":
            freezes.append([seconds, None])
        elif freezes and freezes[-1][1] is None:
            freezes[-1][1] = seconds
    holds = []
    for index, (start, end) in enumerate(freezes):
        if end is None or end - start + 1e-6 < MIN_HOLD:
            continue
        before = freezes[index - 1][1] if index else 0.0
        after = freezes[index + 1][0] if index + 1 < len(freezes) else duration
        # A hold must have moving material before it and after it inside the same clip.
        if before is not None and start - before >= MOTION_CONTEXT and after - end >= MOTION_CONTEXT:
            holds.append((start, end))
    return holds


def scan_clip(ffmpeg: str, clip: dict, crop: tuple[int, int, int, int]) -> list[tuple[float, float]]:
    x, y, width, height = crop
    offset, duration = float(clip["source_offset"]), float(clip["duration"])
    filters = (
        f"setpts=PTS-STARTPTS,crop=iw*{width}/100:ih*{height}/100:iw*{x}/100:ih*{y}/100,"
        f"fps=10,scale=160:90,format=gray,freezedetect=n=-50dB:d={MOTION_CONTEXT}"
    )
    proc = subprocess.run(
        [ffmpeg, "-nostdin", "-hide_banner", "-nostats", "-threads", "2",
         "-ss", f"{offset:.9f}", "-t", f"{duration:.9f}", "-i", clip["path"],
         "-map", "0:v:0", "-an", "-sn", "-dn", "-filter_threads", "1",
         "-vf", filters, "-f", "null", "-"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors="replace", check=False,
    )
    if proc.returncode:
        raise RuntimeError(proc.stderr[-2500:].strip())
    return freeze_candidates(proc.stderr, duration)


def main() -> int:
    import imageio_ffmpeg

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--crop", default="0,0,100,100")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    crop = parse_crop(args.crop)
    clips = json.loads(args.manifest.read_text(encoding="utf-8"))["clips"]
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    holds = []
    scanned = 0
    for clip in clips:
        try:
            candidates = scan_clip(ffmpeg, clip, crop)
        except RuntimeError as exc:
            print(exc, file=sys.stderr)
            continue
        scanned += 1
        origin = float(clip["timeline_start"])
        holds.extend((origin + start, origin + end) for start, end in candidates)
    if not scanned:
        raise RuntimeError("No clips could be decoded as video")
    lines = [f"# scanned\t{scanned}"]
    lines.extend(f"{start:.6f}\t{end:.6f}" for start, end in sorted(holds))
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError) as exc:
        raise SystemExit(str(exc)) from exc
