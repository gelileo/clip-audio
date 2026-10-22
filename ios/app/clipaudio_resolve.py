"""ClipAudio extraction glue.

Single entry point called from Swift across the C shim. Everything returns a
JSON string so the bridge stays dumb: no object marshalling across the boundary.

Runs unmodified on desktop and on-device, so it can be tested without Xcode.
"""
import json
import os
import sys
import time

# Populated by boot()
_STATE = {"booted": False, "import_secs": None, "ytdlp_version": None}

# PRD section 8. Two constraints stack here:
#  - AAC only: iOS has no WebM demuxer, so Opus (249/250/251) is unplayable.
#  - Prefer YouTube's HLS renditions (234/233) over the DASH m4a (140).
#    M4 measured 1.0s vs 58s to first audio, and itag 140 also reports 2x the
#    true duration because AVFoundation misreads its fragmented-MP4 timescale.
#    HLS is equal or better quality (133,215 vs 129,476 bps, both AAC-LC 44.1k).
# 140 stays as fallback: HLS was absent for 2 of 10 regression videos.
SELECTOR = (
    "234/233/"
    "bestaudio[ext=m4a][protocol^=https]/"
    "bestaudio[acodec^=mp4a]/"
    "bestaudio[ext=m4a]"
)


def _configure_tls():
    """iOS has no system CA bundle at a path OpenSSL will find. Point at certifi."""
    try:
        import certifi
    except ImportError:
        return None
    path = certifi.where()
    os.environ.setdefault("SSL_CERT_FILE", path)
    os.environ.setdefault("REQUESTS_CA_BUNDLE", path)
    return path


def _count_ext_modules():
    """How many loaded modules are C extensions (one .framework each on iOS).

    Detect by loader type, not by path suffix: PEP 730 resolves a .fwork
    pointer to a framework binary with no extension, so suffix matching
    silently reports zero.
    """
    from importlib.machinery import ExtensionFileLoader
    n, sample = 0, []
    for m in list(sys.modules.values()):
        spec = getattr(m, "__spec__", None)
        if spec is not None and isinstance(getattr(spec, "loader", None), ExtensionFileLoader):
            n += 1
            if len(sample) < 3:
                sample.append((spec.name, (spec.origin or "")[-60:]))
    return {"count": n, "sample": sample}


def _bump_run_counter():
    """Launch number. Every measurement so far was a first launch after a
    fresh install, which pays one-off signature-validation costs. Run 2+
    shows steady state."""
    try:
        d = os.environ.get("CLIPAUDIO_DOCS") or os.path.expanduser("~/Documents")
        f = os.path.join(d, "runcount.txt")
        n = 0
        if os.path.exists(f):
            with open(f) as fh:
                n = int((fh.read() or "0").strip() or 0)
        n += 1
        with open(f, "w") as fh:
            fh.write(str(n))
        return n
    except Exception:
        return -1


def _bytecode_mode():
    """Report whether we are running precompiled. 'source' here means every
    cold start is paying full parse cost."""
    try:
        import json as _j
        f = getattr(_j, "__file__", "") or ""
        return "pyc" if f.endswith(".pyc") else "source"
    except Exception:
        return "?"


def boot():
    """Import yt-dlp and report environment. Measures the M1 gate (<2s).

    The import cost is measured on the FIRST call only. Later calls hit
    sys.modules and would report ~0, which silently invalidates the gate.
    """
    if _STATE["booted"]:
        return json.dumps({
            "ok": True, "cached": True,
            "import_secs": round(_STATE["import_secs"], 3),
            "ytdlp_version": _STATE["ytdlp_version"],
            "python": sys.version.split()[0], "platform": sys.platform,
            "ca_bundle": os.environ.get("SSL_CERT_FILE"), "prefix": sys.prefix,
        })
    t0 = time.monotonic()

    # The 2026-10-19 device run put ~8s in this one call -- importing certifi,
    # a two-file package. That is the cost of the FIRST import in the process,
    # not of certifi. Measured separately now.
    t_first0 = time.monotonic()
    ca = _configure_tls()
    t_firstimport = time.monotonic() - t_first0

    # Hypothesis under test: cost is per-extension-module dyld load + signature
    # validation on device (each C extension is its own .framework via .fwork),
    # NOT Python parsing. Compare pure-Python modules against C extensions of
    # similar size. If ext >> pure, the bottleneck is dyld, not Python.
    def _timed(mods):
        out, total = {}, 0.0
        for m in mods:
            if m in sys.modules:
                out[m] = "preloaded"
                continue
            t = time.monotonic()
            try:
                __import__(m)
                d = time.monotonic() - t
                out[m] = round(d, 3)
                total += d
            except Exception as exc:
                out[m] = f"err:{type(exc).__name__}"
        return out, round(total, 3)

    # C extensions chosen to be ones interpreter startup does NOT already load,
    # so the probe measures a real dyld framework load rather than a cache hit.
    pure_detail, t_pure = _timed(["fractions", "statistics", "dataclasses", "difflib"])
    ext_detail, t_ext = _timed(["unicodedata", "mmap", "fcntl", "termios", "ctypes"])

    t_std0 = time.monotonic()
    for m in ("json", "ssl", "http.client", "email.utils", "urllib.request", "xml.etree.ElementTree"):
        try:
            __import__(m)
        except Exception:
            pass
    t_stdlib = time.monotonic() - t_std0

    t_yt0 = time.monotonic()
    try:
        import yt_dlp
    except Exception as exc:
        return json.dumps({
            "ok": False, "stage": "IMPORT", "error": f"{type(exc).__name__}: {exc}",
        })
    t_ytdlp = time.monotonic() - t_yt0

    # Registers the embedded-QuickJS JS Challenge Provider. Import only -
    # the decorators in that module do the registration.
    t_jsc0 = time.monotonic()
    jsc_status, qjs_ver = "absent", None
    try:
        import _qjs
        qjs_ver = _qjs.version()
        import clipaudio_jsc_quickjs  # noqa: F401
        _install_solve_counter(clipaudio_jsc_quickjs)
        jsc_status = "registered"
    except Exception as exc:
        jsc_status = f"error:{type(exc).__name__}:{exc}"[:120]
    t_jsc = time.monotonic() - t_jsc0
    secs = time.monotonic() - t0

    _STATE.update(booted=True, import_secs=secs, ytdlp_version=yt_dlp.version.__version__)
    return json.dumps({
        "ok": True,
        "cached": False,
        "import_secs": round(secs, 3),
        "t_firstimport": round(t_firstimport, 3),
        "t_pure": t_pure,
        "t_ext": t_ext,
        "pure_detail": pure_detail,
        "ext_detail": ext_detail,
        "t_stdlib": round(t_stdlib, 3),
        "t_ytdlp": round(t_ytdlp, 3),
        "bytecode": _bytecode_mode(),
        "qjs_version": qjs_ver,
        "jsc_provider": jsc_status,
        "t_jsc_import": round(t_jsc, 3),
        "ext_modules_loaded": _count_ext_modules(),
        "run": _bump_run_counter(),
        "ytdlp_version": yt_dlp.version.__version__,
        "python": sys.version.split()[0],
        "platform": sys.platform,
        "ca_bundle": ca,
        "prefix": sys.prefix,
    })


def _js_runtime_report():
    """Which JS challenge providers are live? Expected empty until M2 links QuickJS."""
    try:
        from yt_dlp.extractor.youtube.jsc import _registry  # noqa: F401
        return "registry-present"
    except Exception:
        return "unavailable"


def resolve(arg):
    """Resolve a URL to one audio stream. Returns a JSON string, never raises.

    `arg` is a bare URL, or a JSON object {"url": ..., "format": ...} so a
    caller can override the production AAC selector (used by the self-test to
    separate 'is the HTTP/extractor stack alive' from 'does AAC selection work').
    """
    selector = SELECTOR
    url = arg
    if isinstance(arg, str) and arg.lstrip().startswith("{"):
        try:
            spec = json.loads(arg)
            url = spec.get("url", "")
            selector = spec.get("format") or SELECTOR
        except ValueError:
            pass
    if not _STATE["booted"]:
        boot()
    try:
        import yt_dlp
    except Exception as exc:
        return json.dumps({"ok": False, "stage": "IMPORT", "error": str(exc)})

    opts = {
        "format": selector,
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
        # A dead host otherwise blocks for the default timeout, long enough that
        # a killed launch loses its measurement.
        "socket_timeout": 15,
        "cachedir": os.path.join(
            os.environ.get("CLIPAUDIO_CACHE", os.path.expanduser("~")), "ytdlp-cache"
        ),
    }
    t0 = time.monotonic()
    solves_before = SOLVES["count"]
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            info = ydl.sanitize_info(info)
    except Exception as exc:
        return json.dumps({
            "ok": False, "stage": "EXTRACT",
            "error": f"{type(exc).__name__}: {exc}"[:400],
            "secs": round(time.monotonic() - t0, 2),
        })

    fmt = info
    if "requested_downloads" in info and info["requested_downloads"]:
        fmt = info["requested_downloads"][0]

    if not fmt.get("url"):
        return json.dumps({"ok": False, "stage": "NO_COMPATIBLE_FORMAT",
                           "error": "no AAC format returned"})

    return json.dumps({
        "ok": True,
        "secs": round(time.monotonic() - t0, 2),
        "solves": SOLVES["count"] - solves_before,
        "title": info.get("title"),
        "uploader": info.get("uploader"),
        "duration": info.get("duration"),
        "thumbnail": info.get("thumbnail"),
        "extractor": info.get("extractor"),
        "format_id": fmt.get("format_id"),
        "acodec": fmt.get("acodec"),
        "abr": fmt.get("abr"),
        "ext": fmt.get("ext"),
        "protocol": fmt.get("protocol"),
        "language": fmt.get("language"),
        "url": fmt.get("url"),
        "http_headers": fmt.get("http_headers") or {},
    })


def bench_jschallenge(url=None):
    """M2 gate: force a client that requires an n-sig solve and time it.

    The default client (visionos) needs no JS challenge at all, so a normal
    resolve never exercises the solver. This forces `mweb`, which does.

    Format selection afterwards usually fails without a PO token, but the
    solve has already happened by then, so the timing is still valid - that
    is what we are measuring.
    """
    if not _STATE["booted"]:
        boot()
    url = url or "https://www.youtube.com/watch?v=iG9CE55wbtY"
    try:
        import yt_dlp
        import clipaudio_jsc_quickjs as plugin
    except Exception as exc:
        return json.dumps({"ok": False, "stage": "IMPORT", "error": str(exc)})

    stats = {"solves": 0, "js_bytes": 0, "secs": 0.0}
    original = plugin.EmbeddedQuickJSJCP._run_js_runtime

    def instrumented(self, stdin, /):
        t = time.monotonic()
        try:
            return original(self, stdin)
        finally:
            stats["solves"] += 1
            stats["js_bytes"] += len(stdin)
            stats["secs"] += time.monotonic() - t

    plugin.EmbeddedQuickJSJCP._run_js_runtime = instrumented
    opts = {
        "format": SELECTOR,
        "quiet": True, "no_warnings": True, "skip_download": True,
        "socket_timeout": 20,
        "js_runtimes": {},        # no external runtime may be discovered
        "cachedir": False,
        "extractor_args": {"youtube": {"player_client": ["mweb"]}},
    }
    t0 = time.monotonic()
    outcome = "ok"
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.extract_info(url, download=False)
    except Exception as exc:
        outcome = f"{type(exc).__name__}: {exc}"[:160]
    finally:
        plugin.EmbeddedQuickJSJCP._run_js_runtime = original

    return json.dumps({
        "ok": stats["solves"] > 0,
        "solves": stats["solves"],
        "js_bytes": stats["js_bytes"],
        "solve_secs": round(stats["secs"], 2),
        "total_secs": round(time.monotonic() - t0, 2),
        "qjs": _qjs_version(),
        "extract_outcome": outcome,
    })


SOLVES = {"count": 0, "secs": 0.0, "bytes": 0}


def _install_solve_counter(plugin):
    """Count every challenge solve for the life of the process.

    Criterion 3 of the M2 gate requires the hot path to perform zero solves.
    The default client is believed not to need one, but believing is what went
    wrong in M2/F1 - so count them.
    """
    if getattr(plugin, "_counter_installed", False):
        return
    original = plugin.EmbeddedQuickJSJCP._run_js_runtime

    def counting(self, stdin, /):
        t = time.monotonic()
        try:
            return original(self, stdin)
        finally:
            SOLVES["count"] += 1
            SOLVES["bytes"] += len(stdin)
            SOLVES["secs"] += time.monotonic() - t

    plugin.EmbeddedQuickJSJCP._run_js_runtime = counting
    plugin._counter_installed = True
    plugin._uncounted_run_js_runtime = original


def _qjs_version():
    try:
        import _qjs
        return _qjs.version()
    except Exception:
        return None
