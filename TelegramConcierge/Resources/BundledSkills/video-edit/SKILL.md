---
name: video-edit
description: "Reliably edit video files with ffmpeg and ffprobe: trim, join, transcode, resize, crop, speed-change, mix audio, add text/subtitles, make GIFs, and verify the result visually and with metadata."
---

# Video Edit Skill

Use this skill for practical video edits that can be done reliably with `ffmpeg`. The goal is not to memorize filters; the goal is to inspect the input, choose the least destructive operation, create a new output file, and verify that the edit is actually correct.

**Dependencies**: ffmpeg and ffprobe (required — install with `brew install ffmpeg` after telling the user). On an unfamiliar machine, run `python3 ${CLAUDE_SKILL_DIR}/skills_doctor.py` once — it reports every dependency of the document/media skills with install commands. Never `pip install` into the system Python; Briglia's own Python packages live in its private environment (`briglia-python`, `briglia python-env install`).

Do not overwrite the original media unless the user explicitly asks.

`${CLAUDE_SKILL_DIR}/recipes.md` contains the full command cookbook (cuts, joins, resize/crop/rotate, compression, speed changes, audio work, text/subtitles/watermarks, transitions, GIFs) plus a symptom→fix table. Read it when you need a concrete command shape; do not paste it wholesale into your reasoning.

## Reliable Workflow

1. Inspect the input: `python3 ${CLAUDE_SKILL_DIR}/probe_video.py input.mp4` (JSON summary of duration, streams, codecs, dimensions, frame rate, audio).
2. Decide stream copy vs re-encode (below).
3. Decide how audio should be handled: keep, remove, replace, mix, or retime.
4. Run the ffmpeg command into a new output file.
5. Verify metadata by probing the output.
6. Verify visually: `probe_video.py output.mp4 --frames 6 --out-dir qa` extracts frames spread across the duration — inspect them. Sample extra frames around edit points.
7. If the edit touched audio, verify the audio too (below) — never ship an audio change unchecked.
8. Fix objective defects and repeat up to 3 times.

Metadata proves the file parses. Visual frames prove the edit looks right. Use both.

## Locating Events And Cut Points

Do not pull dozens of individual frames to find a moment. Cheapest first:

- `probe_video.py input.mp4 --sheet` renders ONE contact-sheet image (default 6x5 timestamped thumbnails covering the whole file). Inspect it, narrow to a window, then confirm with one or two full frames via `--at <seconds>`. Use `--sheet 8x6` for longer videos.
- `--scenes` returns hard-cut timestamps numerically (scene-change detection, threshold 0.4; lower catches softer cuts). Trim on those instead of eyeballing.
- `--silence` returns silence intervals — speech boundaries, dead air to cut, where to place a voiceover. Tune with `--silence-noise -40dB --silence-duration 1.0`.

All modes combine in one call and emit a single JSON report.

## Audio QA

You cannot listen, but you can still verify audio rigorously:

```bash
python3 ${CLAUDE_SKILL_DIR}/probe_video.py output.mp4 --audio --out-dir qa
```

This returns mean/peak volume and EBU R128 integrated loudness, plus a waveform PNG (add `--spectrogram` for a frequency view). Inspect the waveform image: a mute shows as a flat gap, a fade as a ramp, music-under-speech as a visible level difference. Cross-check numbers — e.g. after mixing music at 0.25, integrated loudness should be close to the original speech-only loudness; if it jumped several LU, the mix is wrong. Compare input vs output reports when retiming or replacing audio.

## Subtitles And Transcripts

The `transcribe_media` tool (separate from this skill's scripts) transcribes any audio/video file using the provider configured in Settings, and with `format='srt'` writes a timestamped .srt next to the input. Typical flow: `transcribe_media {path, format: 'srt'}` → review/correct the SRT text → burn it in or attach it as a soft track (see recipes.md). Use the `language` parameter when you know the spoken language. For plain transcripts (meeting notes, quote extraction), use `format='text'`.

## Stream Copy Or Re-Encode

Prefer stream copy (`-c copy`) when it is correct: container change only, fast rough trim at keyframes, concatenating already-matching clips.

Re-encode when the edit changes pixels, timing, or audio samples: frame-accurate trim, resize/crop/rotate/overlay/subtitles, speed changes, compression or codec change, normalizing clips before concat or transitions, mixing/fading/replacing audio.

Good distribution defaults for MP4:

```bash
-c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 192k
```

CRF 18 near-lossless, 20-23 normal delivery, 26-30 aggressive compression.

## Sharp Edges

These cause most real failures — they apply regardless of which recipe you use:

- In zsh, quote optional maps such as `-map '0:a?'` — `?` is a glob character.
- `atempo` only accepts 0.5–2.0 per filter; chain it for larger changes (`atempo=2.0,atempo=2.0` for 4x).
- After every `trim`/`atrim`, reset timestamps with `setpts=PTS-STARTPTS` / `asetpts=PTS-STARTPTS`, or audio desyncs.
- H.264 needs even dimensions: use `scale=-2:720` or pad/crop to even sizes.
- Phone/web compatibility needs `-pix_fmt yuv420p` with H.264/AAC.
- Concat and `xfade` require inputs matching in codec, resolution, fps, pixel format, and audio shape — normalize first when in doubt.
- Stream-copy trims land on keyframes: starts/ends can be slightly off. Re-encode for frame accuracy.
- GIFs need the two-pass palette (`palettegen` → `paletteuse`) or they look terrible.
- `reverse` buffers the whole clip in memory — split long clips first.
- Music under speech is usually 0.15–0.35 volume.

## Stopping Criterion

Ship when metadata matches the requested edit and sampled frames/audio prove the visible result is correct: right duration, right content, no black/frozen sections, no unexpected crop, overlays/subtitles appear at the right time, audio is present or absent by design, and the output plays in the intended format.

For complex color grading, stabilization, denoising, chroma key, motion graphics, or multi-track editorial timelines, tell the user ffmpeg can attempt it but a real editor such as Final Cut, Premiere, or DaVinci Resolve is usually the better tool.
