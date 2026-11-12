# LiveSub

<img src="docs/icon.png" width="96" alt="LiveSub icon">

Live subtitles, with a translation, for anything your Mac is playing: a Netflix tab, a video
call, a podcast. Everything runs on your Mac; no audio or text is sent anywhere.
macOS 26.4 or later, Apple silicon.

![Japanese with English beneath](docs/overlay-translation-ja-en.png)

- **Live**: text appears about 0.6 s after it is spoken; its translation about 50 ms later.
- **Original and translation together**, so you can compare them (or show just one).
- **Watch once, replay with no delay**: subtitles are saved as you watch, and when the same
  audio plays again they are shown from the saved copy, slightly ahead of the speech.
- **Japanese, Korean, Spanish, French, English, Chinese and more** as the spoken language;
  translation into English, Simplified or Traditional Chinese, and about 20 other languages.
- **Copy and look up**: one shortcut copies the current sentence; others send it to Claude or
  Google for an explanation.

## Install and open

```bash
./scripts/install.sh
```

builds LiveSub and puts it in Applications. Open it like any app (Spotlight: ⌘Space, "LiveSub").
It has no Dock icon; look for the captions icon in the menu bar. The first time, macOS asks to
let LiveSub record system audio: choose Allow.

Everything is in the menu-bar icon:

- **Spoken Language**, **Translate Into**, **Listen To** (one app, or everything the Mac plays)
- **Show**: original and translation, translation only, or original only
- **Pause**, **Click Through Subtitles**, **Move or Resize Subtitles…**
- **Settings…**: font, size, colors, line spacing, how long subtitles stay, saved subtitles

Drag the subtitles to move them. Hover to see the frame, then drag its top or bottom edge to make
the text larger or smaller, or its left or right edge to change the width.

| Shortcut | Does |
|---|---|
| ⌃⌥C | Copy the current sentence (original and translation) |
| ⌃⌥E | Explain the sentence in Claude (opens your browser) |
| ⌃⌥G | Search the sentence in Google (opens your browser) |
| ⌃⌥T | Show the transcript window, where any text can be selected and copied |

![Appearance settings](docs/settings-appearance.png)

## Privacy and offline use

- Capture, speech recognition and translation all happen on the Mac. During a run the LiveSub
  process holds no network connections (checked with `lsof` and `nettop`).
- The only downloads are Apple's own models, once per language: speech models download
  automatically; translation models ask through Apple's dialog. After that LiveSub works with
  networking off.
- "Explain in Claude" and "Search in Google" open a web page with the sentence in it. They only
  run when you trigger them.
- Saved subtitles live in `~/Library/Application Support/LiveSub/Sessions` (text, timing and an
  audio fingerprint; never audio). Delete them in Settings › Saved Subtitles.

The rest of this file is for developers: how each stage works and what was measured.

## Build

No Xcode needed; the Command Line Tools are enough. Requires macOS 26.4 or later.

```bash
./scripts/build-app.sh        # builds build/LiveSub.app, ad-hoc signed
./scripts/test.sh             # unit tests
```

(The scripts build against the macOS 26 SDK; see `scripts/sdk.sh` for why.)

## Audio capture (command-line check)

1. Start playback in Safari.
2. Run a 30-second capture of Safari only:

   ```bash
   open -n -W --stdout /tmp/livesub.log --stderr /tmp/livesub.log build/LiveSub.app --args capture --app Safari --seconds 30; cat /tmp/livesub.log
   ```

   Leave out `--app Safari` to capture everything the Mac is playing.
3. The first time, macOS asks to let LiveSub record system audio. Allow it. (If you deny it,
   macOS hands LiveSub silence; re-enable under System Settings › Privacy & Security ›
   Screen & System Audio Recording › System Audio Recording Only.)
4. Listen to the result in `captures/`: `…-native.wav` is the raw tap, `…-16k.wav` is what the
   speech recognizer will receive.

Launching through `open` matters: it makes macOS attribute the permission to LiveSub rather
than to your terminal. `livesub list` shows which apps currently have audio.

## How replay works

Live subtitles trail the speech by about 0.6 s, because the recognizer has to hear a word before
it can write it. So LiveSub saves what it produces: while you watch, every sentence, its
translation and its timing are written to
`~/Library/Application Support/LiveSub/Sessions`, together with a compact fingerprint of the
audio (the audio itself is not stored, and cannot be rebuilt from the fingerprint).

When the same audio plays again, LiveSub recognizes it within a second or two, finds the exact
position, and shows the saved subtitles on the clock instead of waiting for the recognizer:
by default 0.1 s *before* each sentence starts (`--lead SECONDS` to change, `--no-save` to turn
saving off). Because it syncs from the audio, pausing and seeking just work; audio that is not
in a saved session falls back to live subtitles and is saved in turn.

```bash
build/LiveSub.app/Contents/MacOS/livesub sessions            # list saved sessions
build/LiveSub.app/Contents/MacOS/livesub sessions --delete all
```

How it works: `AudioFingerprinter` produces a 32-bit sub-fingerprint every 16 ms (band-energy
differences, after Haitsma & Kalker); `SessionMatcher` votes on alignments through an index of
those values, confirms by bit error rate, then keeps verifying, notices pauses and re-locks
after seeks. Measured:

| Test | Result |
|---|---|
| Time to find the position after a seek | 0.9-1.7 s of audio |
| Position error | under 10 ms |
| Same audio re-encoded as 48 kbps AAC at half volume | locks, bit error rate 0.18 (limit 0.30) |
| Unrelated audio | never locks |
| Saved subtitle on screen relative to the start of its speech | 85 ms early (p95 60 ms early) |
| Pause for 3 s (silence or no audio at all), then resume | stays in sync |

## Skipping back

The session being watched is matched against itself too: audio becomes findable about 5 s
after it was heard. Skip back 10 seconds and LiveSub recognizes the stretch about a second
later, commits whatever the recognizer still held as tentative, and shows the saved sentences
and translations on time. Text heard during a replay is not saved twice, and a recognizer
result that runs across the jump is trimmed to its new words. Measured on a recording
(skip back 9 s): back in sync 1.0 s after the jump; saved subtitle 80 ms early.

To keep saved text fresh, the pipeline asks the recognizer to commit after 9 s without a final
result. Committing at every pause is available as a setting ("Finish sentences at pauses"):
it marks sentences complete about 0.45 s sooner and shows translations about 0.3 s sooner, but
the recognizer loses its look-ahead and context, which cost a correctly heard word on the test
recording, so it is off by default.

## Translation

```bash
open build/LiveSub.app
```

now shows each sentence with its translation beneath, translating into your Mac's first
preferred language (English here). To choose:

```bash
open -n build/LiveSub.app --args overlay --app Chrome --lang ko-KR --to zh-Hans
```

`--to` takes `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, … or `none`; `--translation-only` hides the
original. The menu-bar icon has Show › Original and Translation / Translation Only / Original
Only. Simplified and Traditional Chinese are separate targets.

![Japanese with English beneath](docs/overlay-translation-ja-en.png)
![Korean with Simplified Chinese beneath](docs/overlay-translation-ko-zh.png)

- **Translator: Apple's Translation framework**, on-device, using the low-latency strategy
  added in macOS 26.4. Measured 25-50 ms per sentence once warm (the app warms it at start).
- **Model downloads** are one-time and must go through Apple's own confirmation dialog;
  LiveSub opens a small window explaining it when a pair is missing. To pre-download:
  `open -n build/LiveSub.app --args translation-setup --lang ja-JP,ko-KR --to en,zh-Hans,zh-Hant`.
  Tested: Japanese, Korean, Spanish and French into English and Simplified Chinese.
- **No waiting for finals.** A sentence is translated the moment its closing punctuation
  appears in the partial text. A revised sentence is simply translated again.
- **Whole sentences by default.** A translation is shown once its sentence is complete.
  "Translate while a sentence is still being spoken" (Settings) adds a running translation that
  refreshes as the sentence grows.
- **Reading time.** When only one sentence fits, a finished translation stays for a reading
  time (1 s plus 60 ms per character, up to 3 s) before the next sentence replaces it.

Where the time goes, measured on live Netflix playback (Japanese → Chinese): a word appears
0.77 s after it is spoken; the recognizer marks the sentence complete 0.3 s after that;
translating takes 0.07 s. The recognizer is the bottleneck, not translation.

macOS lets an app keep only 5 speech languages reserved for offline use; `livesub languages`
shows which are kept, and LiveSub releases the least recently used one when a sixth is needed.

Measured on a Japanese recording (Korean, Spanish and French are within ~20 ms of this):

| Stage | p50 | p95 |
|---|---|---|
| word spoken → original text on screen | 620 ms | 1070 ms |
| translation request | 50 ms | 72 ms |
| sentence complete on screen → translation shown | 50 ms | 72 ms |
| in-progress text → provisional translation shown | 34 ms | 73 ms |

So a finished sentence has its translation on screen about 0.7 s after its last word (p95 about
1.15 s), against a target of 3 s.

## The overlay

Start playback in any app, then:

```bash
open build/LiveSub.app
```

That shows Japanese subtitles for everything the Mac is playing. A captions icon appears in the
menu bar: Pause, Click Through Subtitles, Move or Resize Subtitles…, Reset Position, Quit.
To pick the app and language:

```bash
open -n build/LiveSub.app --args overlay --app Chrome --lang ko-KR
```

Other options: `--font-size 30`, `--lines 2`, `--click-through`, `--idle-seconds 5`,
`--file AUDIO` (replay a recording silently), `--seconds N` (quit automatically).

How it behaves:

- A borderless panel that never takes keyboard focus, floats above full-screen video on every
  Space, and is transparent outside the subtitle pill so clicks elsewhere reach the video.
- Shows the last 2 lines, always starting at a sentence boundary. Text the recognizer is still
  revising is dim; text it has repeated unchanged is bright.
- Fades out after 5 s without speech. Drag the pill to move it; hover to see the frame and drag
  its left or right edge to resize. Position and width are remembered.
- If macOS is waiting on the audio permission, the overlay says so.

![Overlay with a partial sentence](docs/overlay-partial.png)

Measured: recognizer output → drawn on screen 4 ms p50, 15 ms p95 (the app opts out of App Nap;
without that a background app's drawing lagged ~100 ms at p95).

## Transcription (command-line check)

```bash
build/LiveSub.app/Contents/MacOS/livesub languages     # what can be transcribed, and what is installed
```

Play something in Chrome (or Safari), then watch the transcript scroll for 60 seconds:

```bash
open -n --stdout /tmp/livesub.log --stderr /tmp/livesub.log build/LiveSub.app --args transcribe --app Chrome --lang ja-JP --seconds 60; sleep 1; tail -f /tmp/livesub.log
```

`~` lines are partial (volatile) text, `✓` lines are final. A latency table prints every 10 s.
To replay a recording through the same pipeline silently, at real-time pace:

```bash
build/LiveSub.app/Contents/MacOS/livesub transcribe --lang ja-JP --file captures/NAME-native.wav
```

### Recognizer choice

- **SpeechAnalyzer + SpeechTranscriber** (macOS 26) is the primary recognizer: 30 locales
  (English, Spanish, French, German, Italian, Portuguese, Japanese, Korean, Mandarin,
  Cantonese), streaming with partial results, no third-party dependency, models managed by
  macOS. The model loads in under 0.1 s once installed.
- **DictationTranscriber** (same framework) is the automatic fallback for 24 more locales
  (Arabic, Russian, Hindi, Dutch, Turkish, Thai, Vietnamese, …). No punctuation in its output.
- A Whisper-based backend can still be added behind `ASRBackend` for languages neither covers.

### Measured latency (this Mac, 100 ms chunks)

| Stage | p50 | p95 |
|---|---|---|
| capture → recognizer input (live tap) | 27 ms | 32 ms |
| word spoken → first shown, English live | 690 ms | 1031 ms |
| word spoken → first shown, Japanese recording | 620 ms | 1070 ms |
| last word → final text | ~1.0 s | ~1.2 s |

"Word spoken → first shown" is cross-checked: partial results report optimistic word timing
(they claim ~30 ms), so LiveSub records when each word first appeared and compares it with the
accurate per-word timing in the final result (`WordLatencyTracker`).

Chunk size sweep on the Japanese recording (p50 / p95): 20 ms 636 / 1047, 50 ms 656 / 1060,
100 ms 620 / 1069, 250 ms 772 / 1159. Below 100 ms nothing improves, so 100 ms is the default;
the recognizer's own look-ahead (~0.5 s) dominates.

Known limits so far: in continuous speech the recognizer finalizes a whole passage at once
(up to ~14 s after the passage started), so translation will need to work from stable partial
sentences rather than wait for finals. Punctuation-only output from music is dropped.

### Permission prompts while developing

The app is ad-hoc signed, so macOS treats every rebuild as a new app and asks again for the
System Audio Recording permission. A build you keep using only asks once.

## Design notes

- **Capture: Core Audio process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap` +
  private aggregate device). Chosen over ScreenCaptureKit because it needs only the audio
  permission (no Screen Recording), never touches video (DRM is a non-issue), and delivers
  ~10 ms buffers. Core Audio does the mono mixdown.
- Browsers play audio from helper processes (Safari: `com.apple.WebKit.GPU`; Chrome:
  `com.google.Chrome.helper`). LiveSub groups helpers under their app and re-points the tap
  when helpers come and go.
- `AudioConditioner` resamples to 16 kHz mono, cuts 100 ms chunks (tunable with `--chunk-ms`)
  and measures level for the voice gate (`--gate-db`).
- Every stage is timestamped against the audio's capture host time; `LatencyStats` prints
  p50/p95 per stage.

Measured on this Mac (48 kHz output, 100 ms chunks): tap→callback 32 ms, resample+chunk work
0.2 ms, newest sample is ~27 ms old (p95 32 ms) when a chunk is ready for the recognizer.

## License

LiveSub is released under the [PolyForm Noncommercial License 1.0.0](LICENSE.md): you may use,
modify and share it for any noncommercial purpose; commercial use is not permitted. The software
is provided as is, without any warranty, and the author is not liable for any damages arising
from it.
