# ClipTimbre for DaVinci Resolve

A DaVinci Resolve Studio panel for finding a selected voice, shortening pauses and reviewing dialogue before export. Audio processing runs locally.

[Русский](README.ru.md) · [Releases](https://github.com/0xDive/cliptimbre/releases)

![ClipTimbre dashboard in DaVinci Resolve Studio](docs/screenshots/dashboard.png)

[Settings screenshot](docs/screenshots/settings.png)

## Install and uninstall

Install **DaVinci Resolve Studio 21** and **Python 3.12** (**3.11** on Intel Macs). On Windows on Arm, use x64 Python. Close Resolve before installing or uninstalling.

For a tagged version, follow the instructions on its release page. To use this checkout, run the matching command from this directory.

| Platform | Install | Uninstall |
| --- | --- | --- |
| macOS | `bash ./install_macos.sh` | `bash ./uninstall_macos.sh` |
| Windows | `.\install_windows.cmd` | `.\uninstall_windows.cmd` |
| Linux | `bash ./install_linux.sh` | `bash ./uninstall_linux.sh` |

Start Resolve and open **Workspace → Scripts → ClipTimbre**. The first install downloads Python packages. Speaker recognition and transcription download model weights on first use.

Installation preserves existing settings and voice profiles. Uninstall removes the menu item and keeps local data and the Python runtime. Fresh Windows and Linux installs use CPU PyTorch wheels by default. Pass `--pytorch-index URL` to install a compatible GPU build. Fresh Apple Silicon installs include MLX Whisper.

On Linux, use `zenity` for dialogs. Ripple Delete inside clips requires X11 and `xdotool` on Linux, and Accessibility permission on macOS. The panel was tested in Resolve Studio 21.0.4 on macOS. Windows and Linux still need testing in Resolve. [Studio feature matrix](https://documents.blackmagicdesign.com/SupportNotes/DaVinci_Resolve_Studio_21_Features.pdf)

## Use

1. **Voice.** Select or create a voice profile. Save samples in the active profile or set a temporary reference from the playhead. **Find voice** marks matches. **Correct** and **Wrong** calibrate the profile threshold.
2. **Pauses.** After finding matches, mark and review pauses before running **Tighten pauses**. It creates a timeline backup by default and uses native Ripple Delete at clip boundaries.
3. **YouTube Safety.** Scan the current timeline with local Whisper transcription. Select a flagged phrase to read its context. **Edit risk rules** opens the local rules file. The scan helps with editorial review.
4. **Auto Censor.** Choose **Beep**, **Smooth Mute** or **Timeline Mute** to create a processed timeline copy. Timeline Mute keeps separate tracks and adds fades when audio can be mapped to the source. Keep the generated WAV files while the project references them.

**Diagnostics → Open data folder** opens the settings and reports. Set `"audio_source_mode": "render"` in `config.json` to analyze the processed Resolve mix.

## Development

`backend/` contains audio processing, `resolve_lua/` contains the panel and timeline integration, and `install.py` manages installation. Run `python -m unittest discover -s tests` for installer tests.

## License

[AGPLv3](LICENSE) · [DaVinci Resolve interoperability permission](LICENSE-RESOLVE-EXCEPTION.md)
