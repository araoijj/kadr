<p align="center"><img src="Resources/AppIcon-1024.png" width="160" alt="Kadr"></p>

<h1 align="center">Kadr</h1>

<p align="center"><b>Fast, free RAW photo culling for macOS.</b><br>
Browse hundreds of RAW files instantly, rate them, find blinks, blur, bursts and duplicates — and hand the keepers to Capture One or Lightroom.</p>

<p align="center"><b>English</b> · <a href="README.ru.md">Русский</a> · <a href="https://github.com/araoijj/kadr/releases/latest"><b>Download</b></a></p>

---

Kadr (Russian for “frame”) is a lightweight native macOS app for the first stage of working with a shoot: skim through hundreds of RAW files, pick the best ones and send them on to editing. Ratings are written to standard XMP sidecars, so Capture One, Lightroom, Bridge and darktable see them right away.

It is built in SwiftUI with Core Image and Apple Vision — no Electron, no subscription, no cloud. Everything runs offline on your Mac.

## Features

### Culling
- **Instant, sharp RAW browsing.** Kadr shows the JPEG preview embedded by the camera right away (~20 ms per frame), then swaps in the RAW decoded at screen resolution with the camera’s colors (~0.6 s, the next frame is prepared in advance) — embedded previews are often only 1616 px and look soft on Retina screens.
- **Culling mode (O):** viewing progress, kept / rejected / undecided counters, queues (“Undecided”, “Possible defects”, “Quick pass” — burst leaders and single frames), faces at 100% in a side column, and a summary with next steps. Turn **Hints** off for fully manual culling.
- **AI culling — on demand.** Opening a folder only runs light indexing (EXIF, bursts, duplicates; ~15 ms per frame). The heavy AI analysis runs when you click **Run AI Analysis** (⌥⌘A) in Culling mode, with progress and a Stop button — or automatically, if you enable it in Settings.
- **Offline reject detection:** out-of-focus shots (judged by the face or main subject, compared within the same scene), **blinks** and closed eyes, blown highlights on the subject, underexposure, utility shots, duplicates, “weaker than the rest of the burst”; a tilted horizon is flagged as fixable, with a one-click **Straighten**. A strictness slider and a 0–100 frame score. Bulk actions ask for confirmation and can be undone.
- **Blink detection with MediaPipe.** A face mesh model built into the app (Google MediaPipe Face Landmarker, converted to Core ML, ~12 ms per face on the Neural Engine) tells a real blink from squinting, laughing, looking aside or looking down. A frame counts as a blink when both eyes are closed and another frame of the same burst shows the same pose with eyes open.
- **Tournament (T):** compare a burst or a selection in pairs, ← or → picks the better one; the winner gets a ★, the rest can be rejected.
- **Scenes:** the shoot is split automatically at pauses (10 minutes by default), with per-scene culling progress.
- **Bursts and duplicates.** Similar consecutive frames (bursts, brackets) are grouped and the sharpest one is marked; exact file copies are detected.
- **Compare 2–4 frames** side by side with shared zoom and pan.
- **Keyboard-first.** P / X / U to keep / reject / clear, 1–5 stars, color labels, auto-advance.
- **Works on selections.** ⌘/⇧-click, ⇧-arrows, ⌘A, rubber-band selection; ratings and labels apply to everything selected.
- **Never deletes.** Rejects are moved to an `_Отклонённые` (“rejected”) subfolder, and only when you ask.

### Viewing and organizing
- **XMP sidecars** compatible with Capture One / Lightroom / Bridge / darktable; unknown fields in existing XMP files are preserved.
- **Zoom up to 800%** with a navigator: only the visible part of the RAW is decoded at full resolution.
- **Sidebar with two tabs:** *Folders* (the open folder, places, drives and memory cards) and *Filters* (ratings, colors, lenses, dates, scenes, AI culling, bursts). Folders: favorites, recents, attached drives and memory cards, a folder tree with photo counts, and an “include subfolders” mode.
- **Sorting and grouping** by capture time, name, rating, lens, folder, size; groups by day, folder, lens, rating, scene.
- **Memory card import:** files are sorted into per-day folders, already imported files are skipped, every copy is verified by size, and the card can be ejected afterwards.
- **Analysis index.** Sharpness, bursts and EXIF are cached in `~/Library/Application Support/Kadr/Index`; reopening a folder only re-analyzes new or changed files, in the background, at low priority.

### Quick edits and export
- **Lightroom-style controls:** exposure ±5 EV, white balance in Kelvin from the RAW “as shot” value, tint, contrast, highlights, shadows, clarity, vibrance, saturation, toning, vignette, grain — live on the RAW (~25 ms per slider move). A **Camera matching** profile starts from the camera’s own JPEG colors.
- **Styles and LUTs:** ~36 built-in recipes (portrait, landscape, cinema, black & white, film looks), your own presets, `.cube` and HaldCLUT LUTs with adjustable strength; a free film LUT pack downloads from within the app.
- **Crop and straighten (R)** with Instagram formats (4:5, 1:1, 9:16, 1.91:1) and classic ratios.
- **Before / after split (Y)** and an undo history journal (⌘Z / ⇧⌘Z, up to 100 steps per folder, kept between launches).
- **Save to folder:** original RAW+XMP (copy or move) or JPEG with size, quality (with a file-size estimate), watermark and file-name template; export presets for Instagram feed, Stories/Reels and web.
- Edits are stored in a hidden `.kadr/edits.json` inside the shoot folder — originals and XMP files are never modified by edits.

### Languages
English, Русский, Español, Italiano — chosen in Settings or taken from the system.

Supports RAW files from Sony, Canon, Nikon, Fujifilm, Olympus, Panasonic, Pentax, DNG, plus JPEG, HEIC, PNG and TIFF — anything macOS can read.

## Install

Download the latest build from **[Releases](https://github.com/araoijj/kadr/releases/latest)**.

- Requires a Mac with **Apple Silicon** and **macOS 14 Sonoma** or later; reject detection needs **macOS 15 Sequoia** or later.
- Unzip and move **Kadr** to *Applications*.
- The app is not notarized by Apple. On first launch, right-click it → **Open** → **Open**, or run `xattr -dr com.apple.quarantine /Applications/Kadr.app`.

## Keyboard shortcuts

| Key | Action |
|---|---|
| ← → ↑ ↓ | browse (with ⇧ — extend selection) |
| P / X / U | keep (★ if unrated) / reject / clear decision |
| O | Culling mode |
| T | tournament: ← / → picks the better frame |
| 1–5 / 0 | set / clear rating |
| 6–9 | color label: red, yellow, green, blue |
| Space / Enter | grid ↔ single frame |
| Z / double-click | 100% at the click point / fit |
| ⌘+ / ⌘− / ⌘0 / ⌘1 | zoom in / out / fit / 100% |
| I | info panel |
| S | copy selection to the save folder |
| ⌘S | “Save to folder” window |
| ⌘A / ⇧⌘A | select all / select burst |
| ⌘⌫ | move rejects to the `_Отклонённые` subfolder |
| E | Edit panel |
| \\ | show original |
| Y | before / after split |
| R | crop; Enter — done, Esc — cancel |
| C | compare selected frames (or the burst) |
| ⇧⌘C / ⇧⌘V | copy / paste edits |
| ⇧⌘O | open in Capture One |
| ⌘I | import from memory card |
| ⌘Z / ⇧⌘Z / ⌘Y | undo / redo / history |
| right-click | actions for the frame or selection |

## Build from source

You need macOS 14+ and the Command Line Tools — Xcode is not required:

```sh
xcode-select --install   # if not installed yet
./build.sh               # → build/Kadr.app and ~/Applications/Kadr.app
```

The icon is drawn in code: `swift tools/make-icon.swift Resources/AppIcon-1024.png`.

UI strings go through `tr()` (`Sources/Kadr/I18n.swift`); translations live in `tools/i18n/all.json` (Russian → en, es, it). To add a string: `python3 tools/i18n.py wrap && python3 tools/i18n.py extract`, add the translation to `all.json`, then `python3 tools/i18n.py build`.

| File | What’s inside |
|---|---|
| `ImageStore.swift` | previews and EXIF (ImageIO), RAW decoding (CIRAWFilter), dHash and sharpness |
| `Library.swift` | the model: folder, filters, selection, ratings, bursts, file operations |
| `CullAnalysis.swift`, `Cull.swift`, `FaceMesh.swift` | reject detection: Apple Vision, MediaPipe face mesh, verdicts and thresholds |
| `Sidecar.swift` | XMP read / write |
| `Edit.swift`, `Renderer.swift` | edit settings, styles, LUTs, the Core Image pipeline and render cache |
| `Exporter.swift` | saving originals or JPEG, watermark, file-name template |
| `*View.swift`, `Sidebar.swift`, `InfoPanel.swift` | SwiftUI interface |

## Acknowledgements

Thanks to everyone whose work Kadr builds on:

- Film emulation LUTs — [t3mujinpack](https://github.com/t3mujin/t3mujinpack) © João Almeida, MIT license. Not bundled: Kadr downloads them from GitHub on request and keeps the author’s license next to them.
- Face mesh for blink detection — [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker) © Google, Apache 2.0 license. Converted to Core ML and bundled with the app (`Contents/Resources/FaceMesh`, with the license and a NOTICE); the models are not in the repository — `build.sh` fetches them from the [`models-1` release](https://github.com/araoijj/kadr/releases/tag/models-1).
- Apple Vision, Core Image and ImageIO, which do the heavy lifting on device.

## License

[PolyForm Noncommercial 1.0.0](LICENSE) © 2026 Aleksandr Kozlov

The source code is open: you are free to download, study, modify and share your own versions **for any noncommercial purpose** — personal use, hobby, study, research, and use by nonprofit and educational organizations. Commercial use (selling it, building it into a paid product or service, or using it in a company’s work) requires written permission from the author.
