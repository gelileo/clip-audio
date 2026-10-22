# M1 — Python on Device

**Date:** 2026-10-15, updated 2026-10-19 · **Toolchain:** Xcode 26.2, iOS SDK 26.2, Swift 6.2.3
**Verdict: GATE MET on device. Import 0.34–0.77s against a <2s target.**

The 16–22s figures that dominated this investigation were a measurement artifact: every one was taken with Xcode's debugger attached and/or on a first launch after install. Detached and warm, the same build imports in well under a second.

## Gate

| Criterion | Target | Result |
|---|---|---|
| Python-Apple-Support embedded | — | ✅ CPython 3.14.8, `sys.platform == "ios"` |
| yt-dlp imports | — | ✅ 2026.08.19 |
| Non-YouTube extractor resolves end-to-end | — | ✅ 2/2 probes |
| Import time | < 2s | ✅ **0.34–0.77s on device**, detached and warm (see F6) |
| Resolve returns JSON to Swift | — | ✅ |

### Import time, measured

| Build / condition | Simulator (M-series) | Device (A16) |
|---|---|---|
| Source only, debugger attached | 0.92s | 16.4s |
| Precompiled, debugger attached | 0.37s | 17.6s – 22.1s |
| Precompiled, **detached + warm** | 0.30s | **0.34s – 0.77s** ✅ |

The device/simulator ratio detached (0.77 / 0.30 ≈ 2.5×) is what an A16 versus an M-series core should look like. The earlier 18–60× ratios were the artifact announcing itself, had I read them that way.

Probes: `archive.org` 1.09s (stack health, permissive format) · `soundcloud` 2.23s → `hls_aac_160k` AAC (production selector).

**The simulator proved to be a dangerously unrepresentative proxy — for startup cost specifically.** It under-reported import by 18×. Resolve times, by contrast, tracked closely (1.09/2.23s simulator vs 1.24/2.28s device), because those are network-bound. Any future gate about *compute or startup* must be measured on device; only network-bound numbers transfer.

## Stack

```
SwiftUI → PythonRuntime (serial GCD queue, async/await)
        → C shim (JSON strings only, no Python objects cross)
        → CPython 3.14.8 → yt-dlp → extractor
```

## What it took

**1. The stdlib is not in the XCFramework.** An iOS XCFramework may hold only the library binary, so `Python.xcframework` ships just the 5.9MB interpreter. The stdlib is rsynced into the bundle by a build phase using BeeWare's `install_python` helper.

**2. Extension modules become frameworks.** iOS cannot `dlopen` a bare `.so` from a bundle subdirectory. `install_python` repackages each one into its own signed `.framework` and leaves a `.fwork` pointer file — the PEP 730 mechanism. **67 modules** are converted per build.

**3. `ENABLE_USER_SCRIPT_SANDBOXING` must be `NO`** or Xcode blocks the rsync.

**4. TLS needs explicit wiring.** iOS has no CA bundle where OpenSSL looks. Every network call fails verification until `SSL_CERT_FILE` is pointed at vendored `certifi`. Not optional, and the failure mode is opaque.

**5. GIL across a GCD queue.** A serial `DispatchQueue` does not guarantee a stable OS thread. The shim releases the GIL with `PyEval_SaveThread()` after init and re-acquires per call with `PyGILState_Ensure`, which is correct under thread migration; the simpler initialize-and-hold approach is not.

## F1 — The PRD's size estimate was wrong

Estimated 25–35MB. Actual, Release, device arch:

| Build | Size |
|---|---|
| Untrimmed | **94 MB** |
| Trimmed (current) | **50 MB** |

37MB of the untrimmed bundle was **CPython's own test suite**, which `install_stdlib` copies wholesale. A trim step in the build phase removes it plus `idlelib`, `ensurepip`, `pydoc_data` and similar.

Remaining 50MB: `Frameworks` 26MB (67 extension modules + interpreter), `app_packages` 12MB, stdlib 11MB. A further **~7MB** is available by stripping yt-dlp's 941 extractors to the target set (PRD §7.2) — deferred, since it interacts with the OTA update story.

**Realistic target: ~40MB.** PRD §13 updated.

## F2 — Transient source failure nearly produced a false negative

One run failed with `Unable to extract client id` (SoundCloud). It looked like the trim had broken the stdlib. It had not:

- Desktop with identical vendored packages: passed
- Desktop with cache cleared (ruling out a warm client_id masking a block): passed
- Blocking each removed module (`curses`, `dbm`, `venv`, `tkinter`, `lib2to3`, `distutils`) in turn: none reproduced it
- **Re-running the unchanged trimmed build: passed**

It was site flakiness. The lesson is structural, not incidental: *a single third-party source must not be able to decide a milestone gate.* The self-test now runs two probes with different jobs — `stack` (is the HTTP/extractor machinery alive, permissive format) and `aac` (does the production selector work) — and reports `probes_passed=N/M`.

This also means **M0's 24/24 should be read as a point-in-time sample, not a stable rate.** Re-running it periodically to learn the breakage *cadence* matters more than the single number.

## F3 — Device gate failed at 16.4s: no precompiled bytecode

The first device run returned `import_secs=16.417` against a <2s gate — 18× the simulator.

The diagnostic that mattered: **resolve times were essentially unchanged** (1.24s / 2.28s on device vs 1.09s / 2.23s on simulator). An A16 is not 18× slower at general work. The cost was specific to import.

**Cause.** Python-Apple-support ships the stdlib as **1868 `.py` files and zero `.pyc`**. The app bundle is read-only and the shim sets `write_bytecode = 0`, so nothing is ever cached. Every cold start reparsed **~20MB of Python source** (≈10MB stdlib + ≈10MB packages). On an A16 that is 16 seconds.

This was pre-existing, not caused by the earlier trim step — the bytecode was never there to delete.

**Fix.** A build phase now precompiles with `compileall -b --invalidation-mode unchecked-hash`, then deletes each `.py` only where a `.pyc` was actually produced. `unchecked-hash` means Python never stats or validates — correct for an immutable bundle. The app now ships **0 `.py` / 1597 `.pyc`**.

Simulator import fell 0.92s → **0.37s** (`t_stdlib` 0.079s, `t_ytdlp` 0.177s), and `boot()` now reports `bytecode=pyc` so a regression to source cannot pass unnoticed.

**Expected device result is genuinely uncertain.** Naively scaling the old 18× ratio gives ~6.6s and a continued fail, but that ratio measured *compilation*, which is gone; unmarshalling bytecode should scale far closer to raw CPU. This needs the device, not arithmetic.

Bundle went 55MB → 57MB: sourceless `.pyc` is marginally larger than the `.py` it replaces here, so this buys startup, not size.

## F4 — A trap that would have shipped a broken app

The precompile step needs a host interpreter whose bytecode magic matches the target (3.14). **Xcode build phases run with a restricted PATH in which `python3` is macOS's system 3.9.**

Had the step run unguarded it would have emitted 3.9-magic `.pyc`, then deleted the `.py` sources — producing an app with no loadable Python at all, discovered only at runtime. A version assertion caught it on the first build. Discovery now searches explicit candidates, honours `CLIPAUDIO_HOST_PYTHON`, derives the target version from the installed stdlib rather than hardcoding, and fails the build loudly if no match exists.

Generalisable: any build step that *deletes* an input after transforming it must verify the transform first.

## F5 — The bytecode fix did not work; the cause is elsewhere

Second device run, with `bytecode=pyc` confirmed: **17.6s**, marginally *worse* than the 16.4s source build. Precompilation bought nothing on device. The F3 diagnosis was wrong — source parsing was never the dominant cost.

What the phase breakdown showed:

| Phase | Device | Simulator |
|---|---|---|
| `_configure_tls()` — just `import certifi` | **~8.0s** | 0.13s |
| 6 stdlib imports | 3.5s | 0.08s |
| `import yt_dlp` | 6.1s | 0.15s |
| **total import** | **17.6s** | **0.40s** |

Eight seconds to import a two-file package is not parsing. It is the cost of the *first* import in the process.

**Current hypothesis: per-framework dyld load and code-signature validation.** PEP 730 forbids binary modules in `lib-dynload`, so every C extension ships as its own framework. Instrumentation confirms **31 extension modules loaded**, with origins like `ClipAudio.app/Frameworks/_json.framework/_json`. Apple's own guidance is to stay near ~6 dynamic frameworks; a known iOS failure mode is dyld spending launch time loading signatures per image. The Simulator does not enforce signing, which explains why it reports 0.40s and is structurally incapable of surfacing this.

### Third device run (2026-10-21) — cost isolated to ~0.45s per C extension

Per-module probes, device vs simulator:

| Pure Python | Device | | C extension | Device |
|---|---|---|---|---|
| `dataclasses` | **0.004s** | | `ctypes` | 0.507s |
| `fractions` | **0.005s** | | `mmap` | 0.421s |
| `difflib` | 0.680s | | `termios` | 0.448s |
| `statistics` | 1.755s | | `unicodedata` | 0.488s |

Pure-Python modules whose dependencies are already resident cost **~0.004s** — parsing is genuinely free, confirming F3's fix addressed a non-problem. The two expensive "pure" modules are not pure in effect: `statistics` pulls `_statistics`, `_random` and `_decimal`; `difflib` pulls `_heapq`. Every slow import tracks the number of *new C extensions* it loads, at a strikingly uniform **~0.45s each**.

**31 extension modules × ~0.45s ≈ 14s**, against 22.1s total import. That is the bottleneck, and it is dyld, not Python.

**Two confounds remain unseparated, and both inflate precisely this cost:**
- Every device measurement has been `run=1` — a first launch after a fresh install, paying one-off signature validation.
- Every device measurement was launched *from Xcode*, which attaches lldb. The debugger is notified on every dylib load; with 31 frameworks that is 31 extra stop-and-notify cycles.

Until a run is taken detached and warm, the ~0.45s figure is an upper bound of unknown tightness. The harness now appends one line per launch to `Documents/history.txt`, displays it in-app (no console needed), and labels each run via a real `P_TRACED` check so traced runs cannot be mistaken for clean ones.

**Not yet distinguished:**
- **H1 — first-launch only.** Every device measurement so far was the first launch after a fresh install. Signature validation results are cached, so run 2 could be dramatically faster. A `run=N` counter now persists across launches to settle this.
- **H2 — steady-state per-framework cost.** If run 2 is also slow, the fix is structural: statically link extension modules into the interpreter instead of 31 frameworks, which means a custom CPython build.
- **H3 — Debugger attach.** lldb is notified per dylib load. Untested detached.
- **H4 — Debug vs Release build.** Release has not been run on device.

**If H2 survives** — steady-state, detached, still seconds — the remedy is to stop shipping 31 dynamic frameworks. Options, roughly in order of cost: trim which extensions the stdlib actually pulls in; statically link extension modules into a custom CPython build; or accept the cost and move it off the launch path behind a splash screen, which hides rather than fixes it.

**Bytecode precompilation retained** despite not helping here: it is correct for a read-only bundle, is a 2.5× win on simulator, and the 16.4 → 17.6s difference is within run-to-run noise. Its value on device is unproven.

**Method note.** I proposed the bytecode fix from a plausible mechanism and a 20MB source figure, without an experiment isolating parse cost from load cost. The phase timings that disproved it took one round to add and should have come first. Cheap instrumentation before a confident fix.

## F6 — The bottleneck was the debugger, not the design

Final measurements, same build:

| Run | Import | Condition |
|---|---|---|
| 3 | 18.432s | debugger attached |
| 6 | **0.338s** | detached, warm |
| 7 | **0.766s** | detached, warm |

**~24× inflation from attaching lldb.** Xcode's debugger is notified on every dylib load; with 31 extension-module frameworks (PEP 730 mandates one per C extension) that is 31 stop-and-notify cycles on the launch path.

This also corrects F5's arithmetic. The "~0.45s per C extension" figure was measured under the debugger. Detached, the same four extensions import in 0.032–0.06s total — roughly **10ms each, not 450ms**. The hypothesis was directionally right (cost does scale with extension loads) but the magnitude was almost entirely debugger overhead, and that is where the conclusion went wrong.

**No structural fix is needed.** Static linking of extension modules, raised in F5 as the likely remedy, is not warranted. 31 frameworks cost roughly 300ms at startup, once.

### Method

Three wrong calls in a row on this one gate, each from reasoning ahead of measurement:

1. **F3** — blamed source parsing, shipped bytecode precompilation. Wrong; parsing was ~0.004s per module.
2. **F5** — blamed per-framework dyld cost at 0.45s each. Directionally right, magnitude wrong by ~45×.
3. Throughout — treated numbers from a debugger-attached, fresh-install launch as if they described steady state.

The common error was not having the measurement *conditions* in the data. A `[debugger]` tag cost a few lines and would have exposed the artifact on the first device run; it was added only after three rounds of theorising. For M2: instrument the conditions before interpreting the numbers, and never read a profile taken under a debugger as steady state.

## Open items

1. **Only two detached samples**, varying 0.338s / 0.766s. Both pass, but the spread is unexplained. Worth a few more readings during M2 rather than a dedicated round.
2. **Harness gaps found while closing this out**, deferred: history is appended only after the network probes, so a launch killed mid-probe records nothing; there is no device-vs-simulator tag in the history line; the `archive.org` probe is stale and hits a long timeout (hence `probes=1/2`); `socket_timeout` is unset.
3. **CLI device builds still unsigned.** Xcode holds only `kunlu@macpractice.com` (team `2X7ATMB9B3`), which was declined for this project. `Local.xcconfig` no longer pins a team, so Xcode's own Signing & Capabilities selection governs and a UI build works; command-line device builds will not until a usable team is configured.
3. **A16 memory headroom unknown** (PRD §15 Q2). The target device is an iPhone 14 Pro, so this will be answered at M2.

## Artifacts

- `ios/` — xcodegen project. `project.yml` is source of truth; `.xcodeproj` is generated and gitignored.
- `ios/README.md` — build instructions and embedding notes.
- `ios/ClipAudio/SelfTest.swift` — gate harness, writes `Documents/m1gate.txt`.
- Verify: `cat "$(xcrun simctl get_app_container <udid> stream.clipaudio.app data)/Documents/m1gate.txt"`
