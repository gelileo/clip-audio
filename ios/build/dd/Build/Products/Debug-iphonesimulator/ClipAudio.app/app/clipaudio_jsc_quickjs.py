"""Embedded-QuickJS JS Challenge Provider for yt-dlp.

yt-dlp solves YouTube's n-sig/sig challenges by running the EJS solver on an
external JavaScript runtime, which it *spawns as a subprocess*. iOS allows
neither executing shipped binaries nor JIT, so Deno/Node/Bun are all out.

QuickJS-ng is a JIT-free C interpreter that links into the app binary. This
provider keeps every bit of yt-dlp's EJS machinery and swaps only the one
method that shells out, calling the in-process `_qjs` extension instead.

Importing this module registers the provider (the decorators do the work).
"""
from __future__ import annotations

import _qjs

from yt_dlp.extractor.youtube.jsc._builtin.quickjs import QuickJSJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProvider,
    JsChallengeProviderError,
    JsChallengeRequest,
    register_preference,
    register_provider,
)
from yt_dlp.utils._jsruntime import JsRuntimeInfo

# Generous: the YouTube player JS is large, and an A16 interpreting it without
# JIT is far slower than a desktop. Still bounded so a pathological script
# cannot wedge the app.
SOLVE_TIMEOUT = 60.0
MEMORY_LIMIT = 512 * 1024 * 1024
# Must stay BELOW PythonRuntime.stackSize (16MB). QuickJS uses this as its own
# recursion guard; setting it at or above the real thread stack means a deep
# solve dies with SIGBUS at the guard page instead of raising a catchable
# JS error. Observed on device before the runtime moved off GCD.
STACK_SIZE = 8 * 1024 * 1024


def _version_tuple():
    try:
        return tuple(int(p) for p in _qjs.version().split('.'))
    except Exception:
        return (0, 0, 0)


@register_provider
class EmbeddedQuickJSJCP(QuickJSJCP):
    """QuickJS-ng compiled into the binary rather than spawned."""

    PROVIDER_NAME = 'quickjs-embedded'
    JS_RUNTIME_NAME = 'quickjs-ng'

    @property
    def runtime_info(self) -> JsRuntimeInfo:
        # The base class resolves this by locating an executable. There is no
        # executable: the interpreter is linked in. Report it directly so
        # is_available() does not depend on binary discovery.
        return JsRuntimeInfo(
            name='quickjs-ng',
            path='<embedded>',
            version=_qjs.version(),
            version_tuple=_version_tuple(),
            supported=True,
        )

    def is_available(self, /) -> bool:
        return True

    def _run_js_runtime(self, stdin: str, /) -> str:
        self.logger.debug(
            f'Running embedded QuickJS-ng {_qjs.version()} ({len(stdin)} bytes of JS)')
        try:
            return _qjs.evaluate(
                stdin,
                timeout=SOLVE_TIMEOUT,
                memory_limit=MEMORY_LIMIT,
                stack_size=STACK_SIZE,
            )
        except _qjs.JSError as exc:
            raise JsChallengeProviderError(f'Embedded QuickJS failed: {exc}') from exc


@register_preference(EmbeddedQuickJSJCP)
def preference(provider: JsChallengeProvider, requests: list[JsChallengeRequest]) -> int:
    # Above the stock quickjs provider (850). On iOS nothing else can run, but
    # on desktop this keeps the embedded path exercised during testing.
    return 900
