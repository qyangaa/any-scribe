# Any Scribe

A local macOS menu-bar app that records and **live-transcribes meetings** — capturing **both your
microphone and the Mac's system audio output** (everything any meeting app plays, not a specific app)
and labeling them separately as **`Me`** and **`Them`**.

Everything runs **on-device** with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (Metal GPU
accelerated). No audio ever leaves your machine.

- One click (or a global hotkey) to start/stop. A red ● + timer shows it's recording.
- Live transcript window with `Me`/`Them` lines as you talk.
- Auto-saves a timestamped Markdown transcript to a folder you choose.
- Chinese / English / mixed code-switching supported (multilingual model).

## Download & run

1. Download `AnyScribe-x.y.z.dmg` from the [Releases](../../releases) page.
2. Open the DMG and drag **Any Scribe** to **Applications**. Launch it — a waveform icon appears in
   the menu bar (there's no Dock icon).
3. **First launch:** grant **Microphone** and **Screen Recording** in System Settings → Privacy &
   Security (Screen Recording is what lets it hear the meeting's system audio). Quit and reopen after
   granting Screen Recording.
4. Open **Settings** (right-click the icon) and **download a model** (e.g. `large-v3-turbo` for
   Chinese/mixed, `small.en` for English-only). One-time ~0.5–1.6 GB download.
5. **Left-click the icon (or press ⌥⌘R) to start.** Talk + let the meeting play. Click again to stop;
   the transcript is saved to your chosen folder.

Releases are signed with a Developer ID and **notarized**, so they open without Gatekeeper warnings.
The whisper engine is **bundled inside the app** — no Homebrew or extra setup required. Use
**headphones** for the cleanest separation (built-in echo cancellation is on by default for speakers).

## How it works

```
microphone ──▶ AVAudioEngine ──▶ ChunkPipeline ─┐
                                                 ├─▶ whisper-server ─▶ TranscriptWriter ─▶ markdown + live.txt
system out ──▶ ScreenCaptureKit ─▶ ChunkPipeline ┘
```

- **System audio** via **ScreenCaptureKit** (macOS 13+) — the generic output mix, no virtual audio
  driver, not tied to any single app.
- **Microphone** via **AVAudioEngine** with Voice-Processing echo cancellation (subtracts speaker
  bleed so the meeting audio doesn't leak into your mic).
- Each stream is downmixed to 16 kHz mono, sliced into overlapping windows, and streamed to a local
  `whisper-server`. Lines are merged in timestamp order, de-duplicated, and written as Markdown plus a
  tail-able `*.live.txt`.

## Using it

Two modes on one engine:

- **Meeting transcription (long-form):** left-click the menu-bar icon, or tap the global shortcut
  (default **⌥⌘R**), to start/stop. Captures mic + system audio, labels `Me`/`Them`, saves Markdown.
- **Voice input (push-to-talk):** **hold** the voice-input hotkey (default **⌥D**), speak, and
  **release** — the text is transcribed and **pasted at your cursor** in whatever app is focused.
  Requires the **Accessibility** permission (to paste); grant it in Settings → Voice input on first use.

Other:
- **Right-click the icon** for the menu: Settings, Show Live Transcript, Open Transcripts Folder, Quit.
- **Vocabulary:** add your names/jargon in Settings so both modes spell them correctly (Whisper is
  biased toward those words). One per line.
- **Settings:** folder, language, model (+ download), the two shortcuts, vocabulary, echo/cross-talk.
  Persisted to `~/.config/anyscribe/config.json`.

## Configuration

`~/.config/anyscribe/config.json` (see [`config.example.json`](config.example.json)):

| Key | Meaning |
| --- | --- |
| `outputDir` | Where transcripts are written. |
| `model` | Whisper model, e.g. `large-v3-turbo`, `small.en`. `.en` models are English-only — use a multilingual model for Chinese/mixed. |
| `language` | `zh`, `en`, … or `auto`. Don't force a language the speaker isn't using — Whisper will *translate* instead of transcribe. Use `auto` for mixed zh+en. |
| `micLanguage` / `systemLanguage` | Per-stream language override, or `null` to use `language`. |
| `prompt` | Optional initial prompt to bias decoding (domain vocab), or `null`. |
| `vocabulary` | List of your words/names/jargon; biases recognition toward correct spellings in both modes. |
| `echoCancellation` | Apple Voice-Processing AEC on the mic. Default on (keep it for speakers). |
| `dedupeCrossTalk` | Drop residual echo duplicates across streams. Default on. |
| `serverIdleMinutes` | Keep the whisper-server warm this long after a recording (instant restarts), then free its RAM. Default 5. |
| `micLabel` / `systemLabel` | Speaker labels (default `Me` / `Them`). |
| `chunkSeconds` / `overlapSeconds` | Sliding-window size and overlap. |
| `whisperServerBin` | Override the whisper-server path (defaults to the bundled engine, then Homebrew). |

## Build from source

Requirements: Apple Silicon, macOS 13+, Xcode/CLT, `cmake` (`brew install cmake`).

```sh
# 1. Build the Metal whisper-server the app bundles (one-time)
git clone --depth 1 https://github.com/ggerganov/whisper.cpp ~/.local/share/anyscribe/whisper.cpp
cmake -S ~/.local/share/anyscribe/whisper.cpp -B ~/.local/share/anyscribe/whisper.cpp/build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_NATIVE=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_EXAMPLES=ON
cmake --build ~/.local/share/anyscribe/whisper.cpp/build -j

# 2. Build & assemble the app (bundles the engine above)
./make-signing-cert.sh     # optional: stable local identity so macOS permissions persist
./package-app.sh           # → AnyScribe.app
open AnyScribe.app
```

There's also a CLI front-end (`scribe`) sharing the same engine:

```sh
swift run scribe init
swift run scribe check --download
swift run scribe start      # Ctrl-C to stop
```

## Releasing

Push a `v*` tag → GitHub Actions builds, signs, notarizes, and publishes the DMG. See
[`RELEASING.md`](RELEASING.md) for the required repo secrets.

## Caveats

- **Permissions** (Microphone + Screen Recording) are granted to the app in System Settings; Screen
  Recording needs an app relaunch to take effect.
- **Speakers vs headphones:** echo cancellation + cross-talk dedup are on by default for speaker use;
  headphones still give the cleanest separation.
- Near-silent windows and common Whisper hallucinations (`[music]`, "Thanks for watching", Chinese
  subtitle spam, etc.) are filtered out.

## Project layout

```
Sources/ScribeCore/    shared engine: Recorder, capture, pipeline, whisper client/server/manager,
                       transcript writer, config, model downloader
Sources/scribe/        CLI front-end (init | check | start)
Sources/AnyScribe/     menu-bar app (status item, settings, live transcript, global shortcut)
package-app.sh         build + bundle engine + sign → AnyScribe.app
make-dmg.sh            package (+ notarize) → AnyScribe-<version>.dmg
make-signing-cert.sh   local self-signed identity (dev convenience)
.github/workflows/     tag-triggered notarized release
```
