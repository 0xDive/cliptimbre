#!/usr/bin/env python3
"""Install or remove the ClipTimbre panel for DaVinci Resolve Studio."""

from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import venv

ROOT = Path(__file__).resolve().parent
VERSION = (ROOT / "VERSION").read_text(encoding="ascii").strip()
DATA = Path(os.environ.get("STREAMER_VOICE_DATA_DIR") or Path.home() / ".streamer_voice").resolve()
SOURCE_LAUNCHER = ROOT / "resolve_lua" / "launcher" / "ClipTimbre.lua"
LAUNCHER_HEADER = b"-- ClipTimbre "


def utility_directory() -> Path:
    if sys.platform == "darwin":
        scripts = Path.home() / "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts"
    elif sys.platform == "win32":
        scripts = Path(os.environ["APPDATA"]) / "Blackmagic Design/DaVinci Resolve/Support/Fusion/Scripts"
    elif sys.platform.startswith("linux"):
        scripts = Path.home() / ".local/share/DaVinciResolve/Fusion/Scripts"
    else:
        raise RuntimeError(f"No Resolve desktop installer for {sys.platform}")
    return scripts / "Utility"


def check_runtime(python: Path) -> bool:
    check = (
        "import torch, torchaudio, silero_vad, soundfile, imageio_ffmpeg; "
        "from speechbrain.inference.speaker import SpeakerRecognition; "
        "import importlib.util, subprocess; "
        "assert any(importlib.util.find_spec(m) for m in ('faster_whisper', 'mlx_whisper', 'whisper')); "
        "subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-version'], stdout=subprocess.DEVNULL, check=True)"
    )
    return subprocess.run([str(python), "-B", "-c", check], check=False).returncode == 0


def runtime(pytorch_index: str | None) -> None:
    machine = platform.machine().lower()
    intel_mac = sys.platform == "darwin" and machine == "x86_64"
    environment = DATA / ".venv"
    python = environment / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    if python.is_file() and not pytorch_index and check_runtime(python):
        print(f"Using the existing audio runtime at {environment}")
        return

    if not (3, 10) <= sys.version_info[:2] <= ((3, 11) if intel_mac else (3, 14)):
        raise RuntimeError("Use Python 3.10–3.11 on Intel Mac or Python 3.10–3.14 on other desktops")
    if getattr(sys, "_is_gil_enabled", lambda: True)() is False:
        raise RuntimeError("Use a standard Python build with the GIL enabled")
    if sys.platform == "win32" and machine in {"arm64", "aarch64"} and not pytorch_index:
        raise RuntimeError("Use x64 Python on Windows on Arm for the default runtime")
    if not python.is_file():
        venv.EnvBuilder(with_pip=True).create(environment)

    pip = [str(python), "-m", "pip", "--disable-pip-version-check", "install"]
    torch_version = "2.2.2" if intel_mac else "2.11.0"
    wheel_index = pytorch_index
    if not wheel_index and sys.platform != "darwin":
        wheel_index = "https://download.pytorch.org/whl/cpu"
    torch_args = ["--index-url", wheel_index] if wheel_index else []
    if pytorch_index:
        torch_args.append("--force-reinstall")
    packages = [f"torch=={torch_version}", f"torchaudio=={torch_version}"]
    subprocess.run([*pip, *torch_args, *packages], check=True)

    requirements = ["-r", str(ROOT / "requirements.txt")]
    if intel_mac:
        requirements.append("numpy<2")
    if pytorch_index and sys.platform == "win32":
        requirements.append("openai-whisper")
    subprocess.run([*pip, *requirements, *packages], check=True)
    if not check_runtime(python):
        raise RuntimeError("The installed Python audio runtime could not be loaded")


def publish(source: Path, destination: Path) -> None:
    fd, pending = tempfile.mkstemp(dir=destination.parent)
    os.close(fd)
    try:
        shutil.copyfile(source, pending)
        shutil.copymode(source, pending)
        os.replace(pending, destination)
    finally:
        Path(pending).unlink(missing_ok=True)


def owned_legacy_launchers(utility: Path) -> list[Path]:
    launchers = []
    for path in utility.glob("Streamer Voice*.lua"):
        with path.open("rb") as stream:
            header = stream.readline()
        match = re.match(rb"-- Streamer Voice (\d+)\.(\d+)\.(\d+)", header)
        if not match:
            continue
        if tuple(map(int, match.groups())) > tuple(map(int, VERSION.split("."))):
            raise RuntimeError(f"A newer installation is in {path}")
        launchers.append(path)
    return launchers


def install(utility: Path, pytorch_index: str | None) -> None:
    legacy_launchers = owned_legacy_launchers(utility)
    launcher = utility / SOURCE_LAUNCHER.name
    if launcher.is_file() and not launcher.read_bytes().startswith(LAUNCHER_HEADER):
        raise RuntimeError(f"A different Resolve script is already using {launcher}")

    for directory in ("tmp", "cache", "profiles/Streamer/refs", "backend", "resolve"):
        (DATA / directory).mkdir(parents=True, exist_ok=True)
    runtime(pytorch_index)

    files = {
        **{DATA / "backend" / p.name: p for p in (ROOT / "backend").glob("*.py")},
        DATA / "resolve/streamer_voice_common.lua": ROOT / "resolve_lua/streamer_voice_common.lua",
        DATA / "VERSION": ROOT / "VERSION",
        launcher: SOURCE_LAUNCHER,
    }
    installed_files = list(legacy_launchers) + [
        path for path, source in files.items() if path.is_file() and path.read_bytes() != source.read_bytes()
    ]
    if installed_files:
        backup = DATA / "backups" / datetime.now().strftime("cliptimbre-before-%Y%m%d-%H%M%S-%f")
        for path in installed_files:
            relative = Path("menu") / path.name if path.parent == utility else path.relative_to(DATA)
            destination = backup / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
        print(f"Previous plugin files saved at {backup}")

    for filename, source in {
        "config.json": "config.example.json",
        "ad_safety_terms.json": "ad_safety_terms.default.json",
    }.items():
        if not (DATA / filename).exists():
            publish(ROOT / source, DATA / filename)
    try:
        with (DATA / "active_profile.txt").open("x", encoding="utf-8") as active:
            active.write("Streamer\n")
    except FileExistsError:
        pass

    utility.mkdir(parents=True, exist_ok=True)
    for target, source in files.items():
        publish(source, target)
    for older in legacy_launchers:
        older.unlink()
    print(f"Installed ClipTimbre {VERSION} at {launcher}")
    print("Open Workspace > Scripts > ClipTimbre in DaVinci Resolve Studio.")


def uninstall(utility: Path) -> None:
    launcher = utility / SOURCE_LAUNCHER.name
    if launcher.is_file() and launcher.read_bytes().startswith(LAUNCHER_HEADER):
        launcher.unlink()
        print("Removed the ClipTimbre menu item.")
    print(f"ClipTimbre runtime and user files are in {DATA}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="remove the ClipTimbre menu script")
    parser.add_argument("--scripts-dir", type=Path, help="custom Resolve Fusion/Scripts directory")
    parser.add_argument("--pytorch-index", help="wheel index for a matching PyTorch and TorchAudio GPU build")
    args = parser.parse_args()
    utility = args.scripts_dir.expanduser() / "Utility" if args.scripts_dir else utility_directory()
    if args.uninstall:
        uninstall(utility)
    else:
        install(utility, args.pytorch_index)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"ClipTimbre installer: {exc}") from exc
