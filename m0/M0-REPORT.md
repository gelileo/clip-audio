# M0 — Desktop Feasibility Report

**Date:** 2026-10-15 · **Host:** macOS (Apple Silicon) · **Verdict: GATE MET — proceed to M1**

## Result

**24/24 links resolved to a playable AAC stream (100%)** against a 90% gate.

| Metric | Value | Budget (PRD §4) |
|---|---|---|
| Resolve p50 | 2.01s | — |
| Resolve p95 | 2.74s | 20s |
| Resolve max | 5.70s | — |
| Format | itag 140 (AAC-LC 129k m4a) on **all 24** | AAC required |
| Byte verification | HTTP 206 + `audio/mp4` + valid `ftyp` on all 24 | must serve bytes |

Timings are on an M-series Mac; a phone will be slower, but there is ~7x margin to the p95 budget.

## Toolchain under test

| Component | Version |
|---|---|
| yt-dlp | 2026.08.19 |
| quickjs-ng (`qjs`) | 0.17.0 — 72KB binary, 1.1MB installed |
| yt-dlp-ejs | 0.8.0 (ships as a Python package) |

Run under `--no-js-runtimes --js-runtimes quickjs`, which yt-dlp confirmed:

```
[debug] JS runtimes: quickjs-ng-0.17.0
[debug] [youtube] [jsc] JS Challenge Providers: bun (unavailable), deno (unavailable),
                                                node (unavailable), quickjs
[debug] [youtube] [pot] PO Token Providers: none
```

Deno/node/bun were genuinely excluded. QuickJS did the challenge work.

## Findings

**F1 — QuickJS alone is sufficient. Constraint C1/C2 is satisfiable.**
The only JS runtime that can be linked into an iOS binary is also one that fully solves YouTube's current challenges. This was the primary unknown. It is resolved.

**F2 — No PO token was required.** `PO Token Providers: none`, and all 24 URLs returned HTTP 206.
This is the single biggest de-risking of the project: §7.4, previously flagged the highest-variance milestone, is **not on the v1 critical path**. Build M3 as a fallback behind an interface, not as a blocker.
*Caveat:* tested from a residential IP on desktop. YouTube's bot heuristics are IP- and behavior-sensitive; a phone on cellular may be treated differently. This finding lowers the probability, not the need for a plan.

**F3 — The AAC-only constraint (C4) costs nothing.** Every link in every category offered itag 140. No fallback to 139 was needed, and Opus was never the only option. Dropping ffmpeg/transcoding (N6) is free.

**F4 — Multi-track dubbed audio is a real correctness hazard.** One podcast exposed **21 language variants of itag 140 at identical bitrate** (`140-0` Arabic … `140-20` en-US original). Our selector picked the original, but only via yt-dlp's implicit default sort. A bitrate-based tiebreak would be a coin flip between languages. **The original/default track must be pinned explicitly** (see PRD §8).

**F5 — EJS ships as a pip-installable package.** `yt-dlp-ejs` is a normal Python package, so no `--remote-components` network fetch is required at runtime. Simplifies the OTA story (PRD §9) considerably — the solver updates like any other wheel.

**F6 — itag 140 carries the `dash` brand** (`ftypdash`). It is a complete MP4, but DASH-initialized. **Whether AVPlayer plays it progressively is still unproven** and remains an M4 question. This is now the largest untested assumption in the chain.

## Not covered

- Age-restricted / members-only content (no sample in set) — expected to still need auth or PO token
- Cellular / mobile IP behavior
- Non-YouTube sources
- Any iOS execution whatsoever — this validated the chain, not the port

## Artifacts

- `regression_set.json` — fixed 24-link set, 6 categories. Keep stable for comparability.
- `m0_probe.py` — harness. Re-runnable: `python3 m0_probe.py`
- `results/m0_results.json` — full per-link output
