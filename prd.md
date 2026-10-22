# ClipAudio — Product Requirements & Technical Design

**Version:** 1.0
**Date:** 2026-10-15
**Status:** M0 ✅ · M1 ✅ · M2 ✅ · M3 deferred. **M4: player built and working on simulator** — link to audio in **3.47s**, HLS itag 234, correct duration, lock-screen metadata and remote commands live, next-item pre-resolution working. Device run pending; background/lock and network-drop criteria not yet tested (`m4/M4-REPORT.md`).
**Supersedes:** `prd-v0-original.md`

---

## 1. Summary

ClipAudio is a personal iOS app that turns a media link into background audio. Paste or share a URL, and the app resolves an audio-only stream entirely on-device and plays it through native iOS audio with lock-screen controls.

Everything runs on the phone. There is no companion daemon, no server, and no network dependency beyond the media source itself and an optional self-update fetch.

The app is built for personal sideloading. Source will be public on GitHub; binaries will not be distributed.

---

## 2. Goals

| # | Goal |
|---|------|
| G1 | Paste or share a URL and hear audio in under 10 seconds |
| G2 | Full background playback: lock screen, Control Center, headphone controls, AirPlay, CarPlay audio |
| G3 | Run the entire extraction chain on-device, including the JavaScript challenge solver and PO token minting |
| G4 | Survive upstream breakage without a Xcode rebuild, via over-the-air component updates |
| G5 | Fail legibly — when extraction breaks, say which stage broke and what to try |

## 3. Non-Goals

| # | Non-goal | Rationale |
|---|----------|-----------|
| N1 | App Store distribution | Extraction utilities are reliably rejected; this is a sideload-only tool |
| N2 | A hosted or multi-user service | Personal tool. "No backend" is a consequence of scope, not a liability strategy |
| N3 | Video playback | Audio-only. Halves the format problem and the bandwidth |
| N4 | Persistent media downloads / offline library | Streaming only in v1. Revisit after the core chain is proven |
| N5 | Broad site support | Target a handful of sources. Every extractor is maintenance surface |
| N6 | Transcoding | No ffmpeg. Format selection is constrained to what AVPlayer natively decodes (§8) |

## 4. Success Criteria

v1 ships when, on a physical device, over cellular, with the app sideloaded:

- A YouTube link resolves to a playing AAC stream in ≤ 10s (p50) / ≤ 20s (p95)
- Playback survives screen lock, app backgrounding, and a 30-second network drop
- A queue of 3 items advances without a gap longer than 3 seconds
- Lock screen shows correct title and artwork
- An OTA component update applies without reinstalling the app
- Resolution succeeds on ≥ 90% of the fixed 24-link regression set (`m0/regression_set.json`)

---

## 5. Platform Constraints

These are fixed properties of iOS and the upstream sources. Every design decision below traces back to one of them.

| ID | Constraint | Consequence |
|----|-----------|-------------|
| C1 | iOS forbids JIT for third-party in-process code | Deno, Node, and Bun are unusable as JS runtimes |
| C2 | iOS forbids `fork`/`exec` of shipped binaries | A JS runtime must be *linked in*, not spawned as a subprocess |
| C3 | WKWebView runs out-of-process and *does* receive the JIT entitlement | Real WebKit is available for BotGuard-class work |
| C4 | iOS has no WebM demuxer | Opus audio (itags 249/250/251) is unplayable. AAC only |
| ~~C5~~ | ~~Header injection requires a custom URL scheme~~ | **Retired at M4.** The resolved URL serves HTTP 206 with no headers at all; no resource loader or localhost proxy is needed for this purpose |
| C15 | itag 140 is a **fragmented MP4** (`moov` 699B + `mvex` + `sidx` + ~120 `moof`/`mdat` pairs) | AVFoundation walks every fragment before producing audio (~58s) and misreads the timescale as 22050, reporting 2× duration. Prefer HLS (§8); fMP4-over-HLS is handled natively (M4) |
| C6 | Backgrounded WKWebView JavaScript is throttled | PO tokens must be minted while foregrounded and cached |
| C7 | yt-dlp's Python `jsinterp` is no longer sufficient for YouTube | An external JS runtime is mandatory (see §7.3). **M0: QuickJS satisfies this** |
| C8 | Resolved CDN URLs expire (~6h) and are IP-bound | Never persist resolved URLs; persist source links and re-resolve |
| C9 | Background audio mode keeps the app alive *while audio plays*, not while idle | The next item must be pre-resolved before the current one ends |
| C10 | The app bundle is read-only, so Python can never cache bytecode, and Python-Apple-support ships source only | Precompile at build time. *Measured impact is modest — parsing is ~0.004s/module (M1/F6); retained as correct practice for an immutable bundle, not as a fix* |
| C13 | GCD worker threads get a 512KB stack on iOS; interpreting ~3MB of player JS recurses far past it | Python runs on a dedicated `Thread` with a 16MB stack, and QuickJS's own limit is set below it so it raises a JS error instead of SIGBUS (M2/F2) |
| C14 | Xcode Debug compiles C at `-O0`, making QuickJS ~4.3× slower | Third-party C carries explicit `-O2` in all configurations; Debug timings are otherwise meaningless (M2/F3) |
| C12 | PEP 730 requires one framework per C extension; 31 load at startup, against Apple's ~6 guidance | ~300ms at launch detached, so acceptable. But it makes debugger-attached profiling useless (~24× inflation) and would worsen if the extension count grows (M1/F6) |
| C11 | Xcode build phases run with a restricted PATH where `python3` is macOS's system 3.9 | Any build step using a host interpreter must assert the version (M1/F4) |

---

## 6. User Stories

**US-01 — Share to play.** From any app, I share a link to ClipAudio and audio begins. *This is the primary entry point.* Paste is the fallback, not the main flow.

**US-02 — Paste to play.** I open the app and it offers the URL already on my clipboard as a one-tap suggestion.

**US-03 — Background control.** With my phone locked, I see the title and artwork on the lock screen and can play, pause, and skip from there, from Control Center, or from headphone buttons.

**US-04 — Queue.** I can add links to a queue. The next item is resolved before the current one ends, so playback does not stall at the boundary.

**US-05 — Persistent history.** Previously played links persist across launches and can be replayed with one tap. Links are stored; resolved URLs are not (C8).

**US-06 — Legible failure.** When resolution fails, I am told which stage failed — network, challenge solver, PO token, format availability, or playback — and what action might help.

**US-07 — Self-update.** The app can refresh its extraction components in the background and tell me what version it is running.

**US-08 — Sign-in (optional).** I can sign in to the source site inside the app's WebView to reach age-gated or members-only content.

---

## 7. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     ClipAudio (Swift / SwiftUI)              │
│                                                              │
│  Share Extension ──┐                                         │
│  Paste / History ──┼──> ResolutionCoordinator (Swift actor)  │
│                    │            │                            │
│                    │            v                            │
│  ┌─────────────────┴────────────────────────────────────┐    │
│  │          Embedded CPython 3.13+ (PEP 730)            │    │
│  │                      yt-dlp                          │    │
│  │                        │                             │    │
│  │        ┌───────────────┴───────────────┐             │    │
│  │        v                               v             │    │
│  │  JSI Provider Plugin            PO Token Plugin      │    │
│  │  (yt-dlp JS runtime iface)      (yt-dlp-get-pot)     │    │
│  └────────┬───────────────────────────────┬─────────────┘    │
│           │ C ABI                         │ C ABI            │
│           v                               v                  │
│  ┌────────────────────┐        ┌──────────────────────┐      │
│  │ QuickJS-ng (static)│        │ WKWebView (JIT, OOP) │      │
│  │ EJS solver scripts │        │ BotGuard + cookies   │      │
│  └────────────────────┘        └──────────────────────┘      │
│                                                              │
│           │ format URL + required headers                    │
│           v                                                  │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ AVAssetResourceLoaderDelegate (header injection)     │    │
│  │ AVQueuePlayer + AVAudioSession(.playback)            │    │
│  │ MPNowPlayingInfoCenter + MPRemoteCommandCenter       │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### 7.1 Python Runtime

- **CPython 3.13 or later**, embedded via BeeWare's `Python-Apple-Support` XCFramework. iOS is an officially supported platform as of PEP 730; this is no longer an unsupported hack.
- Runs on a **dedicated serial thread**, never the main thread. The GIL must not block SwiftUI.
- Swift talks to it through a narrow C shim exposing exactly three calls: `initialize`, `resolve(url, options) -> JSON`, `shutdown`. No PythonKit — it `dlopen`s a system libpython that iOS does not have.
- Stdlib trimmed in the build phase: drop `test`, `idlelib`, `ensurepip`, `pydoc_data`, `tkinter`, `turtledemo`. **Not optional** — `install_stdlib` copies CPython's own 37MB test suite into the bundle otherwise (M1/F1).

- **Precompile to bytecode in the build phase** (`compileall -b --invalidation-mode unchecked-hash`) and ship sourceless `.pyc`. See C10 — this is a startup requirement, not an optimization. Assert the host interpreter version first (C11): the step deletes sources, so a wrong-magic compile yields an app with no loadable Python.

**M1 verified (2026-10-15), with three things that are not obvious up front:**
- *The stdlib is not in the XCFramework.* An iOS XCFramework may carry only the library binary, so the stdlib is rsynced in by a build phase (BeeWare's `install_python`), and `ENABLE_USER_SCRIPT_SANDBOXING` must be `NO` or Xcode blocks it.
- *Extension modules must become frameworks.* iOS cannot `dlopen` a bare `.so` from a bundle subdirectory; each is repackaged into a signed `.framework` with a `.fwork` pointer left behind (PEP 730). 67 modules per build.
- *TLS needs explicit wiring.* iOS ships no CA bundle where OpenSSL looks. Every network call fails verification until `SSL_CERT_FILE` points at vendored `certifi`, and the failure mode is opaque.

### 7.2 yt-dlp

- Vendored as a wheel, importable from either the app bundle or `Documents/components/` (§9).
- **Lazy extractors enabled**, extractor set stripped to the target sites. Importing all of yt-dlp's extractors on a phone is measurably slow.
- Invoked in-process via the `YoutubeDL` Python API, not a CLI subprocess (C2).

### 7.3 JavaScript Interpreter (JSI) Provider — *novel component*

YouTube's n-signature and related challenges are no longer solved in Python. yt-dlp delegates to an external runtime running the AST-based [`yt-dlp/ejs`](https://github.com/yt-dlp/ejs) solver.

Of yt-dlp's supported runtimes — Deno, Node, Bun, QuickJS, QuickJS-ng — only **QuickJS-ng** is viable on iOS: it is a small C interpreter with no JIT (C1) that links statically into the app binary rather than being spawned (C2). That Deno ships an opt-in `jitless=true` mode is good evidence the solver does not require JIT at all.

**Requirement:** QuickJS-ng ≥ 0.12.0 (or upstream QuickJS ≥ 2025-04-26). Older builds lack optimizations that yt-dlp documents as causing multi-minute execution times.

**M0 verified (2026-10-15):** quickjs-ng 0.17.0 solved the challenge for 24/24 links at p50 2.0s / p95 2.7s, with `deno`, `node` and `bun` confirmed unavailable. The 72KB binary / 1.1MB install also confirms the size budget. *The primary project unknown is resolved: the only JS runtime that can be linked into an iOS binary is also one that fully works.*

**Work to be done:** a pure-Python plugin implementing yt-dlp's external-JS-runtime interface whose `execute` path calls into linked QuickJS via a Python C extension instead of spawning `qjs`. The interface is a deliberate abstraction point, so this is implementing a documented backend rather than patching internals. Estimated 150–300 lines plus the C extension. Prior art for embedding-instead-of-spawning exists in the `ytdlp-ejs` Rust crate.

**Watch for:** QuickJS cannot reliably execute from stdin, so yt-dlp's stock path writes a temp file per execution. In-process, pass source as a string and skip the filesystem entirely.

### 7.4 PO Token Provider — *deferred: build behind an interface, not on the critical path*

YouTube requires a Proof-of-Origin token on most format requests. Without one: HTTP 403, missing formats, or a bot-check wall. The `ios` client requires a GVS token and does not support account cookies; yt-dlp's recommended fallback is the `mweb` client plus a token.

**This is where iOS has a genuine structural advantage.** Minting a token means executing BotGuard in an environment that passes its checks. WKWebView is real WebKit, running out-of-process with the JIT entitlement (C3), and Mobile Safari is a first-class YouTube client. That is a more legitimate environment than the headless jsdom setups server-side users fight with.

**Work to be done:** a provider plugin against the `yt-dlp-get-pot` framework that calls Swift → WKWebView → BotGuard → token → Python.

**Design notes:**
- Mint eagerly while foregrounded; cache with TTL (C6). Never block a resolve on a cold mint if a warm token exists.
- The same WebView holds the signed-in session for US-08, and its cookie jar is shared with the resolver.
- Extraction and playback share one device and one IP, so the IP-binding failure mode (C8) that plagues split client/server designs does not apply here.

**M0 finding (2026-10-15) — this component is not required for v1.** All 24 regression links resolved and served bytes with `PO Token Providers: none`. Scope M3 as a *fallback* behind a `TokenProvider` protocol that returns nil by default; do not block v1 on it.

**Why it still gets built:** M0 ran from a residential desktop IP. YouTube's bot heuristics are IP- and behavior-sensitive, and a phone on cellular is a different fingerprint. Age-restricted and members-only content was not covered by the set and is expected to need it regardless. The finding lowers the probability, not the need for a plan.

**Known limitation:** upstream providers warn tokens no longer reliably defeat bot checks in all cases. Real WebKit is the best available shot, not a guarantee.

### 7.5 Playback

- `AVQueuePlayer` with `AVAudioSession` category `.playback`, Background Mode **Audio, AirPlay, and Picture in Picture** enabled.
- **Header injection:** resolved CDN URLs need `User-Agent`, `Referer`, and sometimes `Cookie`. Because `AVPlayer` ignores the resource loader for `https` (C5), wrap the URL in a custom scheme — `clipaudio-stream://` — and have `AVAssetResourceLoaderDelegate` rewrite it to `https` with the correct headers attached. A localhost HTTP proxy is the fallback if the delegate path proves unreliable for range requests.
- `MPNowPlayingInfoCenter` populated with title, uploader, duration, and artwork. `MPRemoteCommandCenter` wired for play/pause/next/previous/seek.
- `AVPlayerItem.status` and `.isPlaybackLikelyToKeepUp` observed for stall detection and reconnect.

---

## 8. Format Selection Policy

iOS cannot decode Opus in WebM (C4) and the app does not transcode (N6). Format selection is therefore hard-constrained to the AAC ladder:

```
234/233/bestaudio[ext=m4a][protocol^=https]/bestaudio[acodec^=mp4a]/bestaudio[ext=m4a]
```

**Prefer YouTube's HLS audio renditions (itags 234/233) over the DASH m4a (140).** M4 measured
time-to-first-audio at **1.0s for HLS versus 58s for itag 140**, with HLS also reporting the
correct duration and a marginally higher bitrate (133,215 vs 129,476 bps, both AAC-LC 44.1kHz
stereo). itag 140 is a *fragmented* MP4 (see C15) and AVFoundation handles it badly; it handles
fMP4-over-HLS natively. Keep 140 as fallback: HLS was present for only 8 of 10 regression videos.

**Language track pinning — required, not optional.** M0 found a single podcast exposing **21 dubbed variants of itag 140 at identical 129k** (`140-0` Arabic through `140-20` en-US original). Bitrate cannot break that tie. yt-dlp's implicit default sort happened to pick the original, but the app must not depend on implicit behavior: select on `language_preference` (the original/default track scores highest) and assert the chosen format's `language` matches the video's default audio language. Getting this wrong means serving a Hindi dub of an English podcast — a silent, user-visible correctness bug, not a crash.

| itag | Codec | Bitrate | Use |
|------|-------|---------|-----|
| 141 | AAC | ~256k | Preferred when present (rare, premium) |
| 140 | AAC | ~128k | **Default target.** Present for essentially all content |
| 139 | AAC | ~48k | Low-bandwidth fallback |
| 251/250/249 | Opus/WebM | — | **Rejected — undecodable on iOS** |

If no AAC format is returned, the resolve fails with a distinct, user-visible reason (`NO_COMPATIBLE_FORMAT`). It must not silently pick an Opus stream that then fails at the player layer.

---

## 9. Update Strategy

Frozen extraction code inside a sideloaded IPA has a half-life measured in weeks. Three tiers of component, each updatable without Xcode:

| Component | Source | Cadence |
|-----------|--------|---------|
| EJS solver scripts | `yt-dlp-ejs` **pip package** (M0: v0.8.0 bundled; no `--remote-components` fetch needed) | Most frequent — this is the piece YouTube breaks |
| yt-dlp wheel | PyPI or GitHub release | Weekly-ish |
| App binary | Xcode rebuild + resign | Rare |

**Mechanism:** components are fetched into `Documents/components/<version>/` and that path is prepended to `sys.path`. A known-good copy ships in the bundle as the floor. Every update is staged, validated against a built-in smoke test (resolve one known-stable URL) before being promoted, and rolled back automatically on failure. The current component versions are shown in Settings (US-07).

That EJS ships as separately-fetchable remote components is fortunate: the fastest-rotting part of the chain updates independently of everything else.

---

## 10. Failure Modes

Resolution is a pipeline. Every stage reports a distinct error so failures are diagnosable without a debugger attached.

| Stage | Failure | User-facing message | Recovery |
|-------|---------|---------------------|----------|
| Network | No connectivity | "No connection" | Retry on reachability |
| Extractor | Unsupported / dead URL | "Can't read this link" | None |
| JSI | Solver threw or timed out | "Extraction engine out of date" | Prompt component update |
| PO token | Mint failed or rejected | "Verification failed — try signing in" | Open WebView for sign-in |
| Format | No AAC available | "No compatible audio format" | None — explain the codec limit |
| Playback | 403 / stall | "Stream rejected, re-resolving" | Re-resolve once (URL may have expired), then surface |
| Geo / paywall | Region or sign-in wall | "Not available in your region" or "Sign-in required" | Offer sign-in |

**Degradation ladder on resolve failure:** retry current client → fall back to `mweb` + fresh PO token → fall back to a lower-bitrate AAC itag → fail with the most specific error reached.

---

## 11. Lifecycle & Background Behavior

- Audio-only background mode keeps the process alive while audio is playing, not while it is idle (C9).
- **Pre-resolution:** when a queue item begins playing, resolution of the next item starts immediately. A resolve that begins at track-end will likely be suspended.
- **Token warming:** PO tokens are minted on foreground and on a timer while foregrounded, then cached. Backgrounded WKWebView JS is throttled (C6), so a cold mint while backgrounded is expected to fail and must not be on the critical path.
- Share Extension performs **no extraction** — it hands the URL to the host app via an App Group and returns immediately. Extensions have tight memory limits that an embedded Python runtime will not survive.

---

## 12. Build Plan — Validation Before Investment

Each milestone has an explicit gate. Do not proceed past a failed gate; re-scope instead.

**M0 — Desktop feasibility (no Xcode). ✅ PASSED 2026-10-15.**
Confirmed on macOS that `yt-dlp --no-js-runtimes --js-runtimes quickjs` yields a byte-verified playable AAC URL across the 24-link regression set.
**Gate: ≥ 90% — MET at 24/24 (100%).** No PO token provider required. Full writeup in `m0/M0-REPORT.md`; re-run with `python3 m0/m0_probe.py`.

**M1 — Python on device. ✅ PASSED on device 2026-10-21.**
CPython 3.14.8 embedded (`sys.platform == "ios"`), yt-dlp 2026.08.19 imports, non-YouTube extraction resolves end-to-end and returns JSON to Swift.
**Gate: import < 2s — MET at 0.34–0.77s** on an iPhone 14 Pro, detached and warm.
The 16–22s readings that dominated this milestone were an artifact of Xcode's debugger (~24× inflation; lldb is notified on each of 31 extension-module framework loads) compounded by first-launch-after-install validation. No structural fix was needed. Writeup in `m1/M1-REPORT.md`.

**M2 — QuickJS JSI provider. Built; simulator-verified; device pending.**
QuickJS-ng 0.17.0 compiled into the binary, exposed to Python via `PyImport_AppendInittab` (not a framework, so no dyld cost), provider registered, EJS solver executing in-process. Simulator: a genuine n-sig solve over **3.19MB** of player JS in **3.69s**; a default-client YouTube resolve in **1.94s**. Provider is ~40 lines — the EJS seam is a single method.

**Gate revised and MET on device (2026-10-22).** The original "< 3s on-device" targeted a path the app does not take: the default client needs no challenge. Replaced by three criteria, all met on an A16 — (1) a forced challenge **solves correctly**: ✅ 3,193,629 bytes; (2) completes **< 20s** without crashing: ✅ **3.30s / 3.34s**; (3) the **hot path** stays **< 5s** with **zero** solves: ✅ **1.87s, solves=0**. Note the original 3s target was nearly met anyway (3.3s) — the reframing is justified by relevance, not cost; an earlier ~9s projection was wrong (M2/F5). Rationale in `m2/M2-REPORT.md` F4.

**M3 — PO token provider. ~3–7 days. Now optional — reorder after M4.**
M0 showed tokens are not currently needed, so M3 drops off the critical path. Ship the `TokenProvider` protocol returning nil in M2, and build the WKWebView implementation only if on-device testing produces 403s or bot checks.
**Gate (when built):** a YouTube AAC URL returns HTTP 206 for a range request from the device.

**M4 — Playback. In progress.**
**Blocking question answered first, as planned.** itag 140 *is* playable but takes **57.95s** to
first audio and reports **2× the true duration**, because it is a fragmented MP4 (C15).
**YouTube's HLS renditions (234/233) start in ~1.0s** with correct duration and equal quality,
so the format policy (§8) now prefers HLS. Neither a resource loader nor a localhost proxy is
needed — headers are not required at all (C5 retired).
Still to build: `AVQueuePlayer`, `AVAudioSession(.playback)`, `MPNowPlayingInfoCenter`,
`MPRemoteCommandCenter`, background mode, stall/reconnect, next-item pre-resolution (C9).
**Open:** ~20% of videos offer no HLS rendition and fall back to a 58s start. Writeup in `m4/M4-REPORT.md`.
**Gate:** all §4 success criteria pass.

**M5 — Shell. ~3–5 days.**
Share extension, history persistence, settings, OTA updater, error surfaces.

**Total: roughly 3–5 weekends**, assuming Swift fluency. With M0 passed and M3 deferred, **M4 (AVPlayer vs. DASH-branded m4a) is now the dominant risk.**

**Deliberate ordering note:** no UI is built before M2 resolves a URL on-device. A single button that prints a format list is the artifact that proves the port.

---

## 13. Risk Register

| Risk | Severity | Likelihood | Mitigation |
|------|----------|-----------|------------|
| **SABR migration** — YouTube retires progressive URLs in favor of server-side adaptive streaming | **Existential** | Medium, rising | Put the player behind a `StreamSource` protocol now so a UMP/SABR fetcher feeding a local server can be swapped in without touching the player layer |
| PO tokens become required and WebKit minting fails | High | **Lowered by M0** — not needed at all as of 2026-10-15 | Sign-in session; fall back across clients; keep `TokenProvider` interface stubbed so it can be filled without rework |
| QuickJS too slow for future solvers | Medium | Low — M0 measured 2.0s p50 on desktop | Re-measure on device at M2; JavaScriptCore is a fallback engine |
| Extractor rot between rebuilds | Medium | **Certain** | §9 OTA updates — this is the whole reason that section exists |
| Free-tier cert 7-day expiry | Low | Certain | Paid developer account ($99/yr) for 1-year certs |
| Binary size | Low | **Was underestimated** | M1 measured **94MB untrimmed, 50MB trimmed** (Release, device arch) against a 25–35MB estimate. 37MB was CPython's test suite. A further ~7MB available by stripping yt-dlp's 941 extractors. Realistic target **~40MB** |
| **AVPlayer rejects DASH-branded m4a** | **High** | Unknown — untested | Localhost HTTP proxy fallback; test at the top of M4 |
| Wrong dub served on multi-track video | Medium | High if unhandled | Pin original track explicitly (§8); assert language on every resolve |
| **Flaky source produces a false gate result** | Medium | Observed at M1 | A single third-party source must never decide a gate. Self-tests run ≥2 probes (`stack` + `aac`) and report `probes_passed=N/M`. M0's 24/24 is a point-in-time sample, not a stable rate — re-run for cadence |
| **No HLS rendition for some videos** | Medium | 2 of 10 in the regression set | Those fall back to itag 140 and a ~58s start, which is not shippable. Local HLS manifest over the remote fMP4 is the most promising untested fix (M4) |
| **Success claimed without proving the code ran** | High | **Observed at M2** | A resolve "succeeded" with zero solver invocations — a different client path produced it. Also retroactively qualifies M0's QuickJS conclusion. Instrument for *invocation*, not just outcome, before claiming a component works (M2/F1) |
| **Profiling conditions not captured in the data** | High | **Cost M1 three wrong conclusions, M2 one** | A debugger-attached, fresh-install launch inflated import ~24×, and was read as steady state three times. Every timing record must carry its conditions — `[debugger]` via `P_TRACED`, run number, device-vs-simulator. Applies directly to M2's QuickJS timing |
| Simulator numbers mislead on compute | Medium | Observed at M1 | Detached, the device/simulator ratio is a sane ~2.5×. Under a debugger it looked like 18–60×. Still measure compute gates on device, but a wild ratio is evidence of an artifact, not of slow hardware |
| Cold-start regresses to source | Medium | Low now | `boot()` reports `bytecode=pyc`; the self-test emits it so a regression cannot pass silently |

---

## 14. Distribution

- **Source:** public GitHub repository, MIT or similar.
- **Binaries:** not distributed. Build locally in Xcode, or sideload a personal build via AltStore or Sideloadly.
- **Signing:** paid Apple Developer account recommended — free provisioning expires every 7 days and caps at 3 apps.
- **Dependencies:** yt-dlp and EJS are fetched at runtime, not vendored into the repo, which keeps the repository itself free of extraction code.

**Legal posture, stated plainly:** extracting streams is contrary to YouTube's Terms of Service regardless of where the code runs. For personal use this is a civil ToS matter, and the mitigation is not distributing binaries — not where the parsing happens. Note also that a public repository bundling YouTube extraction carries nonzero DMCA risk; the RIAA attempted exactly this against youtube-dl in 2020, GitHub reinstated the project and now maintains a developer defense fund. Worth knowing before choosing which account hosts it.

---

## 15. Open Questions

0. **Is the JS challenge path worth maintaining at all?** The default client needs no solve, and clients that do raise one still cannot deliver formats without a PO token. QuickJS is insurance whose premium is ~2MB of binary and a build dependency. Revisit if the default path stays challenge-free through M4.
1. **Target sites beyond YouTube?** Each additional extractor is maintenance surface (N5). SoundCloud is the obvious second, and is far less hostile.
2. **Does the EJS solver fit QuickJS's memory ceiling** on an older device? *(M0 gave no signal — desktop RAM is not a constraint. The target device is an iPhone 14 Pro / A16, so M2 answers this.)*
3. ~~**Will `AVPlayer` play a `ftypdash`-branded m4a progressively?**~~ **Answered at M4:** yes, but in ~58s with a 2× duration error. Use HLS instead.
4. ~~**Is the resource-loader header-injection path reliable?**~~ **Moot at M4:** no headers are needed.
5. **What to do for the ~20% of videos with no HLS rendition?** Untested options: generate a local HLS manifest over the remote fMP4 using its `sidx`; accept a long spinner; or probe other clients. Decide during M4.
4. **Should history store resolved metadata** (title, artwork, duration) so the list renders without re-resolving? Probably yes — cheap, and it makes the app usable offline for browsing.
5. **CarPlay?** Not in v1, but the now-playing wiring is most of the work.
