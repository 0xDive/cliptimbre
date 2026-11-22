# ClipTimbre for DaVinci Resolve

Find a selected voice, mark or shorten pauses, and review potentially sensitive dialogue before exporting. ClipTimbre runs in DaVinci Resolve Studio and processes audio on your computer. It was previously called Streamer Voice.

[Инструкция на русском](README.ru.md) · [Changelog](CHANGELOG.md)

![ClipTimbre dashboard in DaVinci Resolve Studio](docs/screenshots/dashboard.png)

[Settings screenshot](docs/screenshots/settings.png)

## Install

Use **DaVinci Resolve Studio 21** from Blackmagic Design and a standard **Python 3.12** installation (**3.11** on Intel Macs). Close Resolve, then run the matching command from this directory.

| Platform | Command |
| --- | --- |
| macOS | `./install_macos.sh` |
| Windows | `.\install_windows.cmd` |
| Linux | `python3.12 install.py` |

On Windows on Arm, use x64 Python. On Linux, install `zenity` for dialogs and `xdotool` for range-based pause removal on X11. macOS is verified in Resolve Studio 21.0.4. The Windows and Linux paths have yet to be verified in live Resolve sessions. The panel requires Resolve's desktop Scripting API. [Blackmagic feature matrix](https://documents.blackmagicdesign.com/SupportNotes/DaVinci_Resolve_Studio_21_Features.pdf)

Restart Resolve and open **Workspace → Scripts → ClipTimbre**. The first install downloads Python packages. Speaker recognition and transcription download model weights when first used.

The installer reuses a working runtime and existing Streamer Voice data in `~/.streamer_voice`. It backs up replaced scripts and installs one menu item. Fresh Apple Silicon installs include MLX Whisper. Fresh Windows and Linux installs use CPU PyTorch wheels by default. Pass `--pytorch-index URL` to select a compatible GPU build.

Run the installation command for your platform with `--uninstall` to remove the menu item. Profiles, settings, generated media and runtime files stay in the data directory.

## Use

1. **Voice.** Choose a saved voice profile from the dropdown or enter a name to create one. Save samples in the active profile or set a temporary reference from the playhead. Find matching speech and navigate its duration markers. **Correct** and **Wrong** calibrate the profile threshold.
2. **Pauses.** Run **Find voice**, then mark pauses inside matches. Review the markers before **Tighten pauses**. By default, Tighten creates a backup. Clip-aligned pauses use Resolve's native ripple delete. Range edits inside clips need Accessibility on macOS and X11 with `xdotool` on Linux.
3. **YouTube Safety.** Scan the current timeline with local Whisper transcription. Select a flagged phrase to read its context in the scrollable panel. Changing projects or timelines clears any mismatched report from view. **Edit risk rules** opens the local rules file. New installs include starter English and Russian rules. The scan is an editorial aid and does not predict YouTube decisions.
4. **Auto Censor.** Choose **Beep**, **Smooth Mute**, or **Timeline Mute** to create a processed timeline copy. Timeline Mute leaves gaps on the existing tracks and uses short rendered edge clips for fades when the source mapping can be resolved. Keep these WAVs in place while the project references them.

Set `"audio_source_mode": "render"` in `~/.streamer_voice/config.json` if analysis needs the processed Resolve mix. The **Diagnostics** page opens the log and data folder. Reports, media paths, profiles and generated audio stay in the local data directory.

## Source and verification

- `backend/` contains speaker analysis, transcription and audio processing.
- `resolve_lua/` contains the panel and timeline integration.
- `install.py` installs the panel, runtime and starter configuration.

Run `python -m compileall -q backend install.py` to check Python syntax. Run `luajit -b resolve_lua/launcher/ClipTimbre.lua /dev/null` and `luajit -b resolve_lua/streamer_voice_common.lua /dev/null` to check the Lua sources.

Before release, verify menu startup, settings, a single-clip and a cut timeline, pause markers, and all three censor modes in a disposable Resolve project. Make sure a report attached to an issue contains no private transcript or local media path.
