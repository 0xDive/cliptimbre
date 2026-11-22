# Changelog

## 0.16.0

- Consolidated the installed Streamer Voice 0.16.0 source and renamed the panel to ClipTimbre.
- Fixed clipping and overlapping controls in the Resolve panel. The dashboard now handles an empty timeline context.
- Bound the YouTube table, counters and runtime metadata to the current project and timeline. Added a scrollable context field for selected findings.
- Added a saved voice profile dropdown and a separate creation field.
- Preserved voice profiles, cut-timeline audio, YouTube Safety, all three Auto Censor modes, diagnostics and the existing data directory.
- Retained batched speaker recognition, the embedding cache, and reuse of speech regions for pause marking.
- Tighten Pauses uses native ripple deletion at existing clip boundaries. Timeline Mute renders short fades around the preserved mute gaps.
- Added user-level install and upgrade instructions, starter rules and local repository checks.
