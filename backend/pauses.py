#!/usr/bin/env python3
from __future__ import annotations

import argparse
from bisect import bisect_right
import json
import sys
from pathlib import Path

def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def normalize_speech(speech: list[tuple[float, float]]) -> list[tuple[float, float]]:
    if not speech:
        return []
    speech = sorted(speech)
    out: list[list[float]] = []
    for start, end in speech:
        if end <= start:
            continue
        if not out or start > out[-1][1]:
            out.append([start, end])
        else:
            out[-1][1] = max(out[-1][1], end)
    return [(a, b) for a, b in out]


def speech_inside_segment(speech: list[tuple[float, float]], start: float, end: float) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    index = bisect_right(speech, start, key=lambda span: span[1])
    while index < len(speech):
        s, e = speech[index]
        if s >= end:
            break
        out.append((max(start, s), min(end, e)))
        index += 1
    return out


def find_pause_candidates(
    segments: list[dict],
    speech: list[tuple[float, float]],
    *,
    min_pause: float,
    target_pause: float,
    max_auto_pause: float,
    review_max_pause: float,
    edge_protect: float,
    min_delete: float,
    speech_matches: list[dict] | None = None,
) -> list[dict]:
    pauses: list[dict] = []
    speech = normalize_speech(speech)
    regions = normalize_speech([(float(seg["start"]), float(seg["end"])) for seg in segments])
    matches = normalize_speech([
        (float(seg["start"]), float(seg["end"])) for seg in (speech_matches or [])
    ])
    if not regions:
        return []

    def confirmed(start: float, end: float) -> bool:
        overlap = sum(b - a for a, b in speech_inside_segment(matches, start, end))
        return overlap >= min(0.18, (end - start) * 0.60)

    for (left_start, gap_start), (gap_end, right_end) in zip(speech, speech[1:]):
        gap = gap_end - gap_start
        if not min_pause <= gap <= review_max_pause:
            continue
        index = bisect_right(regions, gap_start, key=lambda span: span[0]) - 1
        inside = index >= 0 and gap_end <= regions[index][1]
        both_sides = confirmed(max(left_start, gap_start - 0.9), gap_start) and confirmed(
            gap_end, min(right_end, gap_end + 0.9)
        )
        if not inside and not both_sides:
            continue
        # Older reports contain only grouped voice ranges. Keep their existing
        # safety margin until a fresh scan provides independent speaker evidence.
        safely_inside = inside and gap_start >= regions[index][0] + edge_protect and gap_end <= regions[index][1] - edge_protect
        keep = min(target_pause, gap)
        delete_start = gap_start + keep * 0.5
        delete_end = gap_end - keep * 0.5
        delete_duration = max(0.0, delete_end - delete_start)
        if delete_duration < min_delete:
            continue
        if gap > max_auto_pause:
            reason = "long"
        elif not safely_inside:
            reason = "near_boundary"
        elif speech_matches is not None and not both_sides:
            reason = "unconfirmed_voice"
        else:
            reason = ""
        pauses.append({
            "index": len(pauses) + 1,
            "streamer_segment": max(1, index + 1),
            "start": gap_start,
            "end": gap_end,
            "duration": gap,
            "target": keep,
            "delete_start": delete_start,
            "delete_end": delete_end,
            "delete_duration": delete_duration,
            "action": "review" if reason else "auto",
            "reason": reason,
        })
    return pauses


def main() -> int:
    from timeline_audio import SAMPLE_RATE, decode_mono_16k, load_manifest_mono_16k, source_identity

    p = argparse.ArgumentParser(description="Find removable silent pauses inside known streamer regions")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--audio")
    source.add_argument("--manifest")
    source.add_argument("--cached-render", action="store_true")
    p.add_argument("--rendered", action="store_true")
    p.add_argument("--input-offset", type=float, default=0.0)
    p.add_argument("--input-duration", type=float, default=None)
    p.add_argument("--result", required=True, help="latest_result.json from speaker search")
    p.add_argument("--analysis-id")
    p.add_argument("--plan-id")
    p.add_argument("--min-pause", type=float, default=0.80)
    p.add_argument("--target-pause", type=float, default=0.22)
    p.add_argument("--max-auto-pause", type=float, default=4.0)
    p.add_argument("--review-max-pause", type=float, default=8.0)
    p.add_argument("--edge-protect", type=float, default=1.5)
    p.add_argument("--min-delete", type=float, default=0.35)
    p.add_argument("--vad-pad-ms", type=int, default=20)
    p.add_argument("--vad-min-silence-ms", type=int, default=120)
    p.add_argument("--output", required=True)
    p.add_argument("--output-json")
    args = p.parse_args()

    audio_path = Path(args.audio).expanduser().resolve() if args.audio else None
    manifest_path = Path(args.manifest).expanduser().resolve() if args.manifest else None
    result_path = Path(args.result).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    payload = json.loads(result_path.read_text(encoding="utf-8"))
    if args.analysis_id is not None and payload.get("analysis_id") != args.analysis_id:
        raise RuntimeError("Find Streamer results changed. Run Find Streamer again")
    segments = payload.get("segments") or []
    vad = payload.get("vad") or {}
    identity = None if args.cached_render else source_identity(
        audio_path, manifest_path, args.input_offset, args.input_duration
    )
    if identity and vad and vad["source"] != identity and not (args.rendered and vad.get("rendered")):
        raise RuntimeError("The source audio changed after Find Streamer")
    reusable = (
        "regions_samples" in vad
        and (args.vad_pad_ms, args.vad_min_silence_ms) == (vad["pad_ms"], vad["min_silence_ms"])
        and (identity == vad["source"] or (args.cached_render and vad.get("rendered")))
    )
    if reusable:
        duration = float(payload["duration_seconds"])
        detected = vad["regions_samples"]
        log("Using speech regions from Find Streamer")
    else:
        if args.cached_render:
            raise RuntimeError("No matching rendered speech regions; run Find Streamer again")
        import torch
        from silero_vad import get_speech_timestamps, load_silero_vad

        torch.set_num_threads(1)
        if manifest_path is not None:
            samples = load_manifest_mono_16k(manifest_path, args.input_offset, args.input_duration, log=log)
        else:
            assert audio_path is not None
            samples = decode_mono_16k(audio_path, args.input_offset, args.input_duration, log=log)
        wav = torch.from_numpy(samples)
        minimum, maximum = torch.aminmax(wav)
        peak = max(-minimum.item(), maximum.item())
        if peak > 1.0:
            wav.div_(peak)
        duration = wav.numel() / SAMPLE_RATE
        timestamps = get_speech_timestamps(
            wav, load_silero_vad(), sampling_rate=SAMPLE_RATE, threshold=0.5,
            min_speech_duration_ms=250, speech_pad_ms=max(0, args.vad_pad_ms),
            min_silence_duration_ms=max(30, args.vad_min_silence_ms), return_seconds=False,
        )
        detected = [(span["start"], span["end"]) for span in timestamps]
        if source_identity(audio_path, manifest_path, args.input_offset, args.input_duration) != identity:
            raise RuntimeError("The source audio changed during the pause scan")
    speech = [(start / SAMPLE_RATE, end / SAMPLE_RATE) for start, end in detected]
    log(f"pause scan VAD regions: {len(speech)}")

    pauses = find_pause_candidates(
        segments,
        speech,
        min_pause=max(0.1, args.min_pause),
        target_pause=max(0.0, args.target_pause),
        max_auto_pause=max(args.min_pause, args.max_auto_pause),
        review_max_pause=max(args.max_auto_pause, args.review_max_pause),
        edge_protect=max(0.0, args.edge_protect),
        min_delete=max(0.05, args.min_delete),
        speech_matches=payload.get("speech_matches"),
    )

    auto = [x for x in pauses if x["action"] == "auto"]
    review = [x for x in pauses if x["action"] == "review"]
    total_delete = sum(float(x["delete_duration"]) for x in auto)
    log(
        f"pause candidates: total={len(pauses)} auto={len(auto)} review={len(review)} "
        f"auto_delete={total_delete:.3f}s"
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# start\tend\tduration\ttarget\tdelete_start\tdelete_end\tdelete_duration\taction\tstreamer_segment\treason"]
    if args.plan_id:
        lines.insert(0, f"# plan {args.plan_id}")
    for x in pauses:
        lines.append(
            f"{x['start']:.6f}\t{x['end']:.6f}\t{x['duration']:.6f}\t{x['target']:.6f}\t"
            f"{x['delete_start']:.6f}\t{x['delete_end']:.6f}\t{x['delete_duration']:.6f}\t"
            f"{x['action']}\t{x['streamer_segment']}\t{x['reason']}"
        )
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    if args.output_json:
        out_json = Path(args.output_json).expanduser().resolve()
        out_json.parent.mkdir(parents=True, exist_ok=True)
        out_json.write_text(
            json.dumps(
                {
                    "version": 1,
                    "duration_seconds": duration,
                    "settings": {
                        "min_pause": args.min_pause,
                        "target_pause": args.target_pause,
                        "max_auto_pause": args.max_auto_pause,
                        "review_max_pause": args.review_max_pause,
                        "edge_protect": args.edge_protect,
                        "min_delete": args.min_delete,
                    },
                    "auto_count": len(auto),
                    "review_count": len(review),
                    "auto_delete_seconds": total_delete,
                    "pauses": pauses,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
