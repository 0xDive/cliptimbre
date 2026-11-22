"""Render short audio fades for Timeline Mute while keeping the main clips editable."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
from pathlib import Path
import subprocess
import sys

import imageio_ffmpeg

try:
    import av
except ImportError:
    av = None


SAMPLE_RATE = 48000


def source_channels(path: str) -> list[tuple[int, int]]:
    if av is None:
        # Audio-only files still work with the existing SoundFile dependency.
        # For a container, never guess which stream Resolve is using.
        if Path(path).suffix.lower() not in {".wav", ".wave", ".flac", ".aiff", ".aif"}:
            raise ValueError("PyAV is required to resolve the audio streams in this media container")
        import soundfile

        return [(0, channel) for channel in range(soundfile.info(path).channels)]
    try:
        with av.open(path) as container:
            return [
                (stream.index, channel)
                for stream in container.streams.audio
                for channel in range(stream.codec_context.channels)
            ]
    except av.error.FFmpegError as error:
        raise ValueError(str(error)) from error


def resolve_channels(channels: list[tuple[int, int]], mapping: dict | None) -> list[tuple[int, int]]:
    if not channels:
        raise ValueError("the media has no embedded audio")

    if mapping is None:
        if len({index for index, _ in channels}) != 1:
            raise ValueError("Resolve did not identify which audio stream the clip uses")
        return channels

    if mapping.get("linked_audio"):
        raise ValueError("the clip uses linked audio")
    mappings = [track for track in mapping.get("track_mapping", {}).values() if not track.get("mute")]
    if len(mappings) != 1:
        raise ValueError("Resolve did not identify a single active channel map")
    order = mappings[0].get("channel_idx", [])
    if not order or any(not isinstance(channel, int) or not 1 <= channel <= len(channels) for channel in order):
        raise ValueError("the channel map cannot be resolved to embedded audio")
    return [channels[channel - 1] for channel in order]


def render_edge(task: dict, channels: list[tuple[int, int]], output_dir: Path, ffmpeg: str) -> None:
    selected = resolve_channels(channels, task["mapping"])
    n = len(selected)
    samples = max(1, math.ceil(task["duration"] * SAMPLE_RATE - 1e-7))
    filters = [f"aresample={SAMPLE_RATE}", f"apad=whole_len={samples}", f"atrim=end_sample={samples}"]
    for direction, duration in (("in", task["fade_in"]), ("out", task["fade_out"])):
        if duration > 0 and samples > 1:
            length = min(samples - 1, max(1, round(duration * SAMPLE_RATE) - 1))
            start = 0 if direction == "in" else samples - length - 1
            filters.append(f"afade=t={direction}:ss={start}:ns={length}:curve=tri")

    inputs = []
    streams = {stream for stream, _ in selected}
    if len(streams) == 1:
        stream = next(iter(streams))
        pan = "|".join(f"c{out}=c{channel}" for out, (_, channel) in enumerate(selected))
        inputs.append(f"[0:{stream}]pan={n}c|{pan}," + ",".join(filters) + "[out]")
    else:
        for index, (stream, channel) in enumerate(selected):
            inputs.append(f"[0:{stream}]pan=mono|c0=c{channel}[ch{index}]")
        pads = "".join(f"[ch{index}]" for index in range(n))
        inputs.append(f"{pads}amerge=inputs={n}," + ",".join(filters) + "[out]")

    output = output_dir / f"edge_{task['id']:05d}.wav"
    command = [
        ffmpeg, "-nostdin", "-v", "error", "-y", "-threads", "1",
        "-ss", f"{task['offset']:.9f}", "-i", task["path"],
        "-filter_complex_threads", "1", "-filter_complex", ";".join(inputs), "-map", "[out]",
        "-c:a", "pcm_s24le", str(output),
    ]
    completed = subprocess.run(command, capture_output=True, check=False)
    if completed.returncode:
        output.unlink(missing_ok=True)
        raise ValueError(completed.stderr.decode("utf-8", errors="replace").strip())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tasks", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    tasks = json.loads(args.tasks.read_text(encoding="utf-8"))
    media = {}
    for path in {task["path"] for task in tasks}:
        try:
            media[path] = source_channels(path)
        except (OSError, RuntimeError, ValueError) as error:
            print(f"Timeline Mute could not inspect {path}: {error}", file=sys.stderr)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()

    def render(task: dict) -> None:
        try:
            if task["path"] in media:
                render_edge(task, media[task["path"]], args.output_dir, ffmpeg)
        except (OSError, ValueError) as error:
            print(f"Timeline Mute fade {task['id']} unavailable: {error}", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(render, tasks))


if __name__ == "__main__":
    main()
