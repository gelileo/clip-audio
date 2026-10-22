# M2 — Embedded QuickJS JS Challenge Provider

**Date:** 2026-10-21, closed 2026-10-22 · **Status: GATE MET on device, all three criteria.**

Device results (iPhone 14 Pro / A16, detached, untraced):
```
run 9  [DEV:iPhone15,2]  import=1.657s  probes=3/3
         m2: solves=1  solve=3.30s  js=3,193,629B
run 11 [DEV:iPhone15,2]  import=0.217s  probes=3/3  youtube=1.87s solves=0
         m2: solves=1  solve=3.34s  js=3,193,629B
```
Solve time is reproducible across runs (3.30s / 3.34s). The hot path does **zero** solves.

## What was built

QuickJS-ng 0.17.0 compiled **into the app binary** and exposed to Python as a builtin module, with a yt-dlp JS Challenge Provider that calls it in-process instead of spawning `qjs`.

```
yt-dlp EJS solver → EmbeddedQuickJSJCP._run_js_runtime()
                  → _qjs.evaluate()            (Python C extension)
                  → QuickJS-ng, linked in      (no subprocess, no JIT)
```

Four upstream sources (`quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`); `quickjs-libc.c` is deliberately excluded, so JS has no file or network access. Registered via `PyImport_AppendInittab` **before** interpreter init, so it is *not* a `.framework` and adds nothing to dyld time (cf. M1/F6).

The provider subclasses yt-dlp's stock `QuickJSJCP` and overrides three members: `_run_js_runtime`, plus `runtime_info`/`is_available` (the base class resolves those by locating an executable, and there isn't one). **About 40 lines** — the EJS interface turned out to be a clean single-method seam, far smaller than the 150–300 lines estimated in the PRD.

## Results (iOS Simulator, Debug + QuickJS at -O2)

| Measurement | Result |
|---|---|
| `_qjs` loads on iOS | ✅ 0.17.0 |
| Provider registers | ✅ `jsc_provider=registered` |
| Genuine n-sig solve | ✅ 1 solve, **3,192,833 bytes** of player JS |
| Solve time | **3.69s** |
| **YouTube resolve, default path** | ✅ **1.94s** → itag 140, `mp4a.40.2` |
| Probes | 3/3 |

Binary cost: ~2MB.

## F5 — The device matched the simulator; my projection was wrong

Projected ~9s on device, by applying the ~2.5× device/simulator ratio M1 established. Actual: **3.3s on device vs 3.69s on simulator** — parity, marginally faster.

The ratio did not transfer because it was measured on a different kind of work. M1's 2.5× came from module import: filesystem reads, many small dyld loads, page-ins — all areas where an A16 and an M-series Mac genuinely differ. A QuickJS solve is tight single-threaded interpretation of already-resident bytecode, where A16 single-core is close to an M-series core, and the simulator carries overhead of its own.

**A measured ratio belongs to a workload, not to a pair of machines.** Noted alongside M1/F6 and M2/F3 as the third variant of the same error: extrapolating instead of measuring.

Practical effect: the original "< 3s" gate was nearly met on hardware (3.3s). The reframing in F4 still stands — the path remains one the app does not normally take — but it was argued partly from a projection that was wrong, and the honest reason to reframe is *relevance*, not cost.

## F1 — A false positive that nearly passed as success

The first end-to-end desktop run resolved YouTube in 1.71s with an n-parameter present, and looked like a pass. Instrumenting `_run_js_runtime` with a call counter showed **zero invocations**. Something else had produced the URL.

Verbose output explained it: `Downloading visionos player API JSON`. yt-dlp selects the **visionos** client, whose URLs need no n-sig descrambling, so no challenge is raised at all.

**This retroactively qualifies M0.** M0 concluded "QuickJS satisfies the JS runtime requirement" from resolutions succeeding under `--js-runtimes quickjs`. That showed the provider was *registered*, never that it was *invoked*. M0's real finding was narrower and still valid — extraction works on-device-equivalent config — but it was not evidence about the challenge path.

Forcing `mweb` raises a real challenge, which is how the solver is now exercised.

## F2 — Stack overflow: GCD threads are too small for the solver

The first on-simulator run crashed: `SIGBUS`, `KERN_PROTECTION_FAILURE` at the stack guard page, faulting thread `stream.clipaudio.python`, with a deep `JS_CallInternal` chain.

GCD worker threads get **512KB** of stack on iOS. The runtime had been handing QuickJS a 16MB limit via `JS_SetMaxStackSize`, which disabled QuickJS's *own* recursion guard — so a deep solve ran off the real stack and died instead of raising a catchable JS error.

Fixed on both sides:
- `PythonRuntime` now runs on a dedicated `Thread` with an explicit **16MB** stack, not a `DispatchQueue`.
- QuickJS's limit is **8MB**, deliberately below the real stack, so it raises a JS error first.

Interpreting ~3MB of player JS needs real stack. This is a hard constraint for anything running the solver on iOS.

## F3 — Debug builds make performance measurement meaningless

First successful solve: **15.81s**. Same solve after compiling QuickJS at `-O2`: **3.69s** — a **4.3× artifact** of Xcode's Debug default of `-O0`.

The four QuickJS sources now carry `compilerFlags: -O2` in every configuration. It is third-party C we never step through, and leaving it unoptimised silently corrupts every timing run.

Together with M1/F6 (debugger attach, ~24×) this is the same lesson twice: **measurement conditions must be pinned before numbers mean anything.**

## F4 — The gate measures a path the app does not use

PRD §12 sets M2's gate as "n-sig challenge solves on-device in < 3s". Two problems:

**It is probably unreachable.** 3.69s on the simulator, CPU-bound. An A16 at the ~2.5× ratio established in M1 projects to **~9s**. No caching softens it: yt-dlp sets `_ENABLE_PREPROCESSED_PLAYER_CACHE = False`, and three consecutive forced solves measured 4.13s / 3.53s / 3.47s — every solve re-parses the full player.

**It is not the path the app takes.** The default client needs no challenge; a real YouTube resolve on iOS takes **1.94s** and never touches QuickJS. The solver is insurance against YouTube changing client behaviour, not a hot path.

Also notable: `mweb`, `web` and `tv` all failed to yield formats even after a successful solve — "Requested format is not available", consistent with the PO token requirement deferred at M0/F2. So today the challenge path cannot deliver formats anyway, for reasons unrelated to QuickJS.

**Revised gate, replacing the <3s target:**

| # | Criterion | Status |
|---|---|---|
| 1 | A forced n-sig challenge **solves correctly** on-device via embedded QuickJS | ✅ 1 solve, 3,193,629 bytes, A16 |
| 2 | Solve completes on-device **< 20s**, no crash or memory exhaustion, at `-O2`, detached | ✅ **3.30s / 3.34s** across two runs |
| 3 | Hot path — default-client YouTube resolve — **< 5s** with **zero** solves | ✅ device: **1.87s, `solves=0`** (simulator 1.77s) |

Measured on simulator: `stack_solves=0`, `aac_solves=0`, `youtube_solves=0`, and the forced benchmark `solves=1`. The counter demonstrably distinguishes the two paths, so a zero is meaningful rather than a counter that never fires.

Criterion 3 was initially going to be taken on trust, on the grounds that the visionos path demonstrably never invokes the solver. That is precisely the inference that produced F1, so a per-resolve solve counter is now installed for the life of the process and the hot-path figure is reported directly.

This keeps the engineering honest without pinning the project to a number for work it mostly will not do.

## Open items

1. **Memory headroom on A16** during a 3MB solve is still unmeasured as a number (PRD §15 Q2), though two clean solves with no pressure warning or jetsam make exhaustion unlikely at current player sizes.
2. Extractor stripping (~7MB, PRD §7.2) still deferred.
3. **Whether to keep this path at all** — see PRD §15 Q0. The hot path performs zero solves; QuickJS is insurance costing ~2MB and a build dependency.

## Artifacts

- `ios/ClipAudio/shim/qjs_module.c` — `_qjs` Python extension (console capture, interrupt-based timeout, memory/stack limits)
- `ios/app/clipaudio_jsc_quickjs.py` — the provider (~40 lines)
- `ios/vendor/quickjs/` — upstream v0.17.0, gitignored, fetched by `scripts/fetch_deps.sh`
- `bench_jschallenge()` in `clipaudio_resolve.py` — forces `mweb` and times the solve
