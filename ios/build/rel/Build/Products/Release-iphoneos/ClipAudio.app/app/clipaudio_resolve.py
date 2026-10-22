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

# Matches PRD section 8. AAC only: iOS has no WebM demuxer, so Opus is unplayable.
SELECTOR = (
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
    ca = _configure_tls()
    try:
        import yt_dlp
    except Exception as exc:
        return json.dumps({
            "ok": False, "stage": "IMPORT", "error": f"{type(exc).__name__}: {exc}",
        })
    secs = time.monotonic() - t0

    _STATE.update(booted=True, import_secs=secs, ytdlp_version=yt_dlp.version.__version__)
    return json.dumps({
        "ok": True,
        "cached": False,
        "import_secs": round(secs, 3),
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


def resolve(url):
    """Resolve a URL to one AAC audio stream. Returns a JSON string, never raises."""
    if not _STATE["booted"]:
        boot()
    try:
        import yt_dlp
    except Exception as exc:
        return json.dumps({"ok": False, "stage": "IMPORT", "error": str(exc)})

    opts = {
        "format": SELECTOR,
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
        "cachedir": os.path.join(
            os.environ.get("CLIPAUDIO_CACHE", os.path.expanduser("~")), "ytdlp-cache"
        ),
    }
    t0 = time.monotonic()
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
