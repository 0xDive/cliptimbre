#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

from process_utils import NO_WINDOW

APP = Path(os.environ.get("STREAMER_VOICE_DATA_DIR") or Path.home() / ".streamer_voice")
PROFILES = APP / "profiles"
ACTIVE = APP / "active_profile.txt"
CONFIG = APP / "config.json"


def safe_name(name: str) -> str:
    value = re.sub(r"[^\w .()\-А-Яа-яЁё]+", "_", name.strip(), flags=re.UNICODE).strip(" ._")
    return value or "Streamer"


def profile_dir(name: str) -> Path:
    return PROFILES / safe_name(name)


def active_name() -> str:
    if ACTIVE.exists():
        value = ACTIVE.read_text(encoding="utf-8").strip()
        if value:
            return safe_name(value)
    return "Streamer"


def read_json(path: Path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return fallback


def write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def ensure_profile(name: str) -> tuple[str, Path]:
    name = safe_name(name)
    d = profile_dir(name)
    (d / "refs").mkdir(parents=True, exist_ok=True)
    meta = read_json(d / "profile.json", {})
    if not meta:
        cfg = read_json(CONFIG, {})
        meta = {"version": 1, "name": name, "threshold": float(cfg.get("threshold", 0.35)), "feedback": []}
    meta["name"] = name
    write_json(d / "profile.json", meta)
    return name, d


def list_profiles() -> list[str]:
    if not PROFILES.is_dir():
        return []
    return sorted(
        (p.name for p in PROFILES.iterdir() if safe_name(p.name) == p.name
         and p.is_dir() and ((p / "profile.json").is_file() or (p / "refs").is_dir())),
        key=lambda name: (name.casefold(), name),
    )


def select_profile(name: str, *, existing: bool = False, create: bool = False) -> None:
    if (existing or create) and (not name.strip() or safe_name(name) != name.strip()):
        raise ValueError("Use letters, numbers, spaces, underscores, hyphens, periods or parentheses in a profile name")
    if existing and name not in list_profiles():
        raise ValueError("Voice profile no longer exists")
    if create:
        PROFILES.mkdir(parents=True, exist_ok=True)
        try:
            profile_dir(name).mkdir()
        except FileExistsError as exc:
            raise ValueError("A voice profile with this name already exists") from exc
    name, d = ensure_profile(name)
    ACTIVE.parent.mkdir(parents=True, exist_ok=True)
    ACTIVE.write_text(name + "\n", encoding="utf-8")
    meta = read_json(d / "profile.json", {})
    threshold = meta.get("threshold")
    if threshold is not None and CONFIG.exists():
        cfg = read_json(CONFIG, {})
        cfg["threshold"] = float(threshold)
        write_json(CONFIG, cfg)
    print(name)


def add_reference(name: str, audio: Path, offset: float, duration: float) -> Path:
    import imageio_ffmpeg

    name, d = ensure_profile(name)
    refs = d / "refs"
    existing = sorted(refs.glob("ref_*.wav"))
    idx = 1
    if existing:
        try:
            idx = max(int(p.stem.split("_")[-1]) for p in existing) + 1
        except Exception:
            idx = len(existing) + 1
    out = refs / f"ref_{idx:03d}.wav"
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    cmd = [
        ffmpeg, "-y", "-v", "error",
        "-ss", f"{max(0.0, offset):.9f}",
        "-i", str(audio),
        "-t", f"{max(1.0, duration):.9f}",
        "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(out),
    ]
    proc = subprocess.run(cmd, capture_output=True, check=False, creationflags=NO_WINDOW)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace")[-4000:])
    select_profile(name)
    print(out)
    return out



def add_reference_from_manifest(name: str, manifest: Path, offset: float, duration: float) -> Path:
    from timeline_audio import materialize_manifest_wav

    name, d = ensure_profile(name)
    refs = d / "refs"
    existing = sorted(refs.glob("ref_*.wav"))
    idx = 1
    if existing:
        try:
            idx = max(int(p.stem.split("_")[-1]) for p in existing) + 1
        except Exception:
            idx = len(existing) + 1
    out = refs / f"ref_{idx:03d}.wav"
    materialize_manifest_wav(
        manifest.expanduser().resolve(),
        out,
        input_offset=max(0.0, offset),
        input_duration=max(1.0, duration),
    )
    select_profile(name)
    print(out)
    return out

def calibrate(feedback: list[dict], current: float) -> float:
    pos = sorted(float(x["score"]) for x in feedback if x.get("label") == "correct")
    neg = sorted(float(x["score"]) for x in feedback if x.get("label") == "wrong")
    if pos and neg:
        candidates = sorted(set([current] + pos + neg + [(a+b)/2 for a in neg for b in pos if a < b]))
        best = current
        best_metric = -1.0
        for t in candidates:
            tp = sum(s >= t for s in pos) / len(pos)
            tn = sum(s < t for s in neg) / len(neg)
            metric = 0.5 * (tp + tn) - 0.03 * abs(t - current)
            if metric > best_metric:
                best_metric = metric
                best = t
        return float(max(0.05, min(0.95, best)))
    if neg:
        return float(max(current, min(0.95, max(neg) + 0.025)))
    if pos:
        return float(min(current, max(0.05, min(pos) - 0.025)))
    return current


def add_feedback(name: str, score: float, label: str) -> float:
    name, d = ensure_profile(name)
    meta_path = d / "profile.json"
    meta = read_json(meta_path, {"name": name, "feedback": []})
    feedback = list(meta.get("feedback") or [])
    feedback.append({"label": label, "score": float(score)})
    feedback = feedback[-200:]
    cfg = read_json(CONFIG, {})
    current = float(meta.get("threshold") if meta.get("threshold") is not None else cfg.get("threshold", 0.35))
    new_threshold = calibrate(feedback, current)
    meta["feedback"] = feedback
    meta["threshold"] = new_threshold
    write_json(meta_path, meta)
    cfg["threshold"] = new_threshold
    write_json(CONFIG, cfg)
    print(f"{new_threshold:.6f}")
    return new_threshold


def clear_refs(name: str) -> int:
    _, d = ensure_profile(name)
    count = 0
    for p in (d / "refs").glob("ref_*.wav"):
        p.unlink(missing_ok=True)
        count += 1
    print(count)
    return count


def status(name: str) -> dict:
    name, d = ensure_profile(name)
    meta = read_json(d / "profile.json", {})
    refs = sorted((d / "refs").glob("ref_*.wav"))
    payload = {
        "name": name,
        "references": len(refs),
        "threshold": meta.get("threshold"),
        "correct_feedback": sum(1 for x in meta.get("feedback", []) if x.get("label") == "correct"),
        "wrong_feedback": sum(1 for x in meta.get("feedback", []) if x.get("label") == "wrong"),
    }
    print(json.dumps(payload, ensure_ascii=False))
    return payload


def main() -> int:
    global APP, PROFILES, ACTIVE, CONFIG
    p = argparse.ArgumentParser()
    p.add_argument("--data-dir", type=Path, default=APP)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("select")
    s.add_argument("name")
    select_mode = s.add_mutually_exclusive_group()
    select_mode.add_argument("--existing", action="store_true")
    select_mode.add_argument("--create", action="store_true")
    sub.add_parser("list")

    a = sub.add_parser("add-reference")
    a.add_argument("--profile", default=None)
    source = a.add_mutually_exclusive_group(required=True)
    source.add_argument("--audio")
    source.add_argument("--manifest")
    a.add_argument("--offset", type=float, required=True)
    a.add_argument("--duration", type=float, default=10.0)

    f = sub.add_parser("feedback")
    f.add_argument("--profile", default=None)
    f.add_argument("--score", type=float, required=True)
    f.add_argument("--label", choices=["correct", "wrong"], required=True)

    c = sub.add_parser("clear-references")
    c.add_argument("--profile", default=None)

    st = sub.add_parser("status")
    st.add_argument("--profile", default=None)

    args = p.parse_args()
    APP = args.data_dir
    PROFILES = APP / "profiles"
    ACTIVE = APP / "active_profile.txt"
    CONFIG = APP / "config.json"
    sys.stdout.reconfigure(encoding="utf-8")
    if args.cmd == "select":
        select_profile(args.name, existing=args.existing, create=args.create)
    elif args.cmd == "list":
        print("\n".join(list_profiles()))
    elif args.cmd == "add-reference":
        if args.manifest:
            add_reference_from_manifest(args.profile or active_name(), Path(args.manifest), args.offset, args.duration)
        else:
            add_reference(args.profile or active_name(), Path(args.audio).expanduser().resolve(), args.offset, args.duration)
    elif args.cmd == "feedback":
        add_feedback(args.profile or active_name(), args.score, args.label)
    elif args.cmd == "clear-references":
        clear_refs(args.profile or active_name())
    elif args.cmd == "status":
        status(args.profile or active_name())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
