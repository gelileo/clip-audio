# M4 — Playback (in progress)

**Date:** 2026-10-22 · **Status: blocking question answered; player built and working on simulator. Device run pending.**

Player, iOS Simulator, via the real `AudioPlayer`:
```
first_audio=3.47s  fmt=234(HLS)  duration=1203.4 (correct)  advanced=3.00s/3s
now-playing: title+artist+artwork+duration all set
remote commands: play/next/seek enabled
prefetched_next=true
```
With HLS selected, the in-app playback probe now loads in **0.39s / 0.84s**, against 59s for itag 140 — the format change confirmed in situ.

M0 flagged "will AVPlayer play a `ftypdash`-branded m4a?" as the largest untested
assumption in the project. It is now answered, and the answer changes the format policy.

## Verdict

**Yes, it plays — but unusably slowly. Use YouTube's HLS audio renditions instead.**

| Format | Time to first audio | Duration reported | Quality |
|---|---|---|---|
| itag 140 (DASH m4a) | **57.95s** | 2406.9s ❌ (exactly 2×) | AAC-LC 44.1k/2ch, 129,476 bps |
| **itag 234 (HLS)** | **1.00s** | 1203.4s ✅ | AAC-LC 44.1k/2ch, **133,215 bps** |
| itag 233 (HLS) | 1.07s | 1203.4s ✅ | AAC-LC |

**58× faster, correct duration, marginally better bitrate.** There is no quality tradeoff.

Confirmed on both macOS and the iOS Simulator; the simulator measured `load_secs=59.01`
for itag 140 and did play (`advanced_secs=3.61`, `audio_fmt='mp4a'`).

## Why itag 140 is slow — root cause

Box structure of a resolved itag 140 stream:

```
ftyp 24 · moov 699 · (mvhd, mvex, trak) · sidx 1484 · moof 1816 · mdat 160307 · moof · mdat …
```

It is a **fragmented MP4**. The `moov` is 699 bytes and carries an `mvex` box but no sample
table; all timing lives in ~120 `moof` fragments spread through the 19.5MB file. AVFoundation
walks every fragment before producing audio.

It also misreads the timescale: `ffprobe` gives `duration_ts=53072896`, `time_base=1/44100`
→ 1203.47s. AVFoundation reports 2406.9s, which is `53072896/22050` — it is interpreting the
timescale as 22050. A 2× duration error would break the scrubber, progress display and seeking.

HLS avoids both problems because AVFoundation consumes fMP4-over-HLS natively; that is the
packaging iOS is designed around.

## Things that turned out NOT to be the problem

- **Header injection.** The resolved URL serves HTTP 206 with *no headers at all*. PRD §7.5
  and C5 assumed a custom URL scheme plus `AVAssetResourceLoaderDelegate` would be needed to
  attach `User-Agent`/`Referer`/`Cookie`. Not required. That machinery is unnecessary.
- **Throttling.** Suspected, because the hot path performs zero n-sig solves. Measured 9.6 MB/s;
  the full 19.5MB file would transfer in ~2s. The visionos client's URLs carry **no `n`
  parameter at all**, so there is nothing to descramble and nothing to throttle.
- **Out-of-band MIME type.** Appeared to give a 570× speedup on macOS (57.16s → 0.10s). It did
  not: on iOS, `mimeType` measured 58.97s against `plain` at 59.01s. The macOS result was an
  ordering artifact — three probes ran sequentially against one URL, so probes 2 and 3 hit a
  warm cache. Corrected before it reached the design.
- **My probe forcing `.duration`.** A fragmented MP4 needs a full fragment walk to compute
  duration, so this looked like self-inflicted cost. Measured without it: 57.95s to first
  audio regardless.

## Availability gap

HLS audio is present for **8 of 10** videos in the regression set. Both misses were in the
`podcast_long` category. So HLS is the preferred path, not the only path, and itag 140 remains
the fallback — carrying a ~58s startup cost that is not yet solved.

**Open:** what to do for the ~20% with no HLS rendition. Candidates, untested:
serve a locally generated HLS manifest over the remote fMP4 using its `sidx` index
(AVFoundation is fast at exactly this); accept a long spinner; or probe other clients for a
progressive or HLS variant of those videos.

## Consequences for the PRD

- **§8 format policy rewritten.** Preference becomes `234/233` (HLS) → `140` (fallback).
  The AAC-only constraint (C4) still holds — Opus in WebM remains undecodable.
- **C5 retired.** Header injection is not required.
- **New constraint C15** covering fragmented-MP4 cost and the timescale misread.
- **§15 Q3 answered.**

## Player — built

| Component | State |
|---|---|
| `AVQueuePlayer` + queue management | ✅ |
| `AVAudioSession(.playback, policy: .longFormAudio)` | ✅ |
| `UIBackgroundModes: [audio]` | ✅ verified in the built bundle |
| `MPNowPlayingInfoCenter` (title, artist, artwork, duration, elapsed) | ✅ |
| `MPRemoteCommandCenter` (play/pause/next/prev/seek/±skip) | ✅ 8 targets |
| Next-item pre-resolution (C9) | ✅ `prefetched_next=true` |
| Stall + failure recovery (re-resolve once, PRD §10) | ✅ built, not yet exercised |
| `StreamSource` protocol seam (PRD §13 SABR insurance) | ✅ |

`Track` holds only the source link; resolved URLs are ephemeral and marked stale after 3h (C8).

### §4 criteria

| Criterion | State |
|---|---|
| Link → playing audio ≤10s p50 | ✅ 3.47s (simulator) |
| Lock screen shows title and artwork | ✅ |
| Queue advances without a >3s gap | ◐ pre-resolution confirmed; advance not yet timed |
| Survives lock, backgrounding, 30s network drop | ◻ not yet tested |
| ≥90% of the regression set | ◻ not re-run through the player |

## A bug worth recording

Making `PlayerView` the root view silently disabled the self-test, because it
only ran from `M1HarnessView.task` — now behind a sheet nobody opened. The run
produced an empty container, which reads exactly like a crash. Checking for a
crash report (there was none, only the old M2 one) is what distinguished
"didn't run" from "ran and died". Same family as M2/F1: confirm the code under
test actually executed.

**Open:** the self-test currently runs automatically from `PlayerView.task` and
drives real playback, queueing two tracks on every launch. That is development
instrumentation and must be gated behind a debug flag before the app is usable.

## Artifacts

- `ios/ClipAudio/PlaybackProbe.swift` — in-app probe; reports load time, playability, real clock advance
- `ios/tools/avprobe.swift`, `ios/tools/avplay.swift` — macOS harnesses for triaging AVFoundation
  strategies in seconds rather than simulator cycles. **Caveat: run each strategy against a fresh
  URL** — sequential probes against one URL produced the false MIME-type result above.
