# Side by Side

A tiny Alfred workflow for comparing a compressed video with its original.

Select exactly two versions of a video, invoke the File Action, and mpv opens
one window: the compressed file supplies the left half, the original supplies
the right half. Together they rebuild the whole frame, so the quality difference
is visible without flipping between players.

The smaller file is treated as the compressed version and goes on the left.
The bigger file is treated as the original and goes on the right.

```
┌──────────────────────────┬──────────────────────────┐
│ 42.1 MB · −68%           │                131.5 MB  │
│ compressed · 3.1× smaller│                 original │
│                          │                          │
│     compressed half      │      original half       │
│                          │                          │
└──────────────────────────┴──────────────────────────┘
```

## Install

Requires macOS, Alfred 5 with the Powerpack (File Actions), and Homebrew.

Download from Releases, or build it yourself:

```sh
brew install mpv ffmpeg
./build.sh
open SideBySide.alfredworkflow
```

Alfred will ask to import the workflow. The workflow uses the Apple silicon
Homebrew paths (`/opt/homebrew/bin`). On an Intel Mac, set `SBS_MPV_BIN` and
`SBS_FFPROBE_BIN` as workflow environment variables in Alfred (or edit the
defaults at the top of `sbs.sh`).

## Use

1. In Finder or Alfred, select exactly two video files. They can have different
   extensions and codecs (`mp4`, `mkv`, `mov`, `avi`, `webm`, `ts`, …).
2. Open Alfred's File Actions and choose **Compare Two Videos Side by Side**.
3. The player opens maximised, muted and looping, so you can keep looking at
   the same moment. A thin progress line along the bottom shows the current
   position and total length.

The left label shows the compressed file's size and the percentage saved. If
the original is at least 1.2× larger, it also shows how many times smaller the
compressed file is. The right label shows the original's size.

mpv's normal keyboard controls still work, even though the on-screen controls
are hidden: `space` pause, `←`/`→` seek, `f` fullscreen, `m` unmute, `q` quit.
The timeline follows those seeks. System media keys are ignored so a stray
play/pause event from another app cannot stop the comparison.

## How it works

`info.plist` is the Alfred workflow: a multi-file File Action connected to a
Run Script action.

`sbs.sh` checks that exactly two readable video files were passed, sorts them by
byte size, reads the original's resolution and rotation with `ffprobe`, then
launches mpv detached. Both inputs are scaled to the original's displayed
resolution, rotated with the correct transpose filter when needed, cropped to
one half, and joined with FFmpeg's `hstack` filter:

```text
[vid1] scale/crop left half ─┐
                             ├─ hstack ── one frame
[vid2] scale/crop right half ┘
```

`[vid1]` is the compressed main file; `[vid2]` is the original, loaded with
`--external-file`. Because both halves are decoded in one pipeline and joined
by timestamp, playback stays in sync without any extra work.

`sbs.lua` draws the size labels, the centre seam, and the bottom timeline with
mpv's OSD overlay. It redraws on window resize, stays sharp at any size, and
adds no video processing.

## Notes and limits

- The split is fixed at the centre. Dragging the seam, swapping sides, and
  opening files from the command line are not in this version.
- Rotation metadata is applied per file. If one version has lost its rotation
  metadata while the other still has it, the halves may not line up.
- If the files have different lengths or frame rates, playback follows
  timestamps and the shorter input holds its last frame. Looping restarts both
  inputs.
- HDR is converted consistently on both sides but is not otherwise optimised.
- The split-and-join filter runs on the CPU. It is comfortable at 1080p and
  should be acceptable at 4K on Apple silicon; the hardware decoder is used for
  decode.
- The larger file is assumed to be the original. If a "compressed" file is
  actually larger, it will be shown on the right.

## Troubleshooting

If a notification appears, it names the missing tool or the file that could not
be read. Check that both Homebrew binaries exist:

```sh
/opt/homebrew/bin/mpv --version
/opt/homebrew/bin/ffprobe -version
```

The workflow writes mpv's output and the exact filter graph to its Alfred cache:

```text
~/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.paraversal.side-by-side/side-by-side.log
```

`SBS_MPV_BIN` and `SBS_FFPROBE_BIN` override the binary paths. Setting
`alfred_workflow_cache` redirects the log, which is useful when testing the
script outside Alfred.

## Layout

```text
video-side-by-side-workflow/
├── info.plist   Alfred workflow definition
├── sbs.sh       validation, size sorting, ffprobe, filter graph, mpv launch
├── sbs.lua      size labels, timeline and seam overlay
├── icon.png     workflow icon (1024 px, transparent)
├── build.sh     builds SideBySide.alfredworkflow
└── README.md
```

## Build

```sh
./build.sh
```

This creates `SideBySide.alfredworkflow` in the project folder. It does not
install or open anything; double-click the file (or use `open`) to import it
into Alfred.
