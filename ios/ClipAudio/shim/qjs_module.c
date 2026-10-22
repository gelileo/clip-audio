/* _qjs: a Python extension wrapping QuickJS-ng.
 *
 * Exists because yt-dlp's EJS solver expects to *spawn* a `qjs` binary, and
 * iOS permits neither executing shipped binaries nor JIT. QuickJS-ng is a
 * JIT-free C interpreter, so it links straight into the app and this module
 * substitutes an in-process call for the subprocess.
 *
 * Compiled into the app binary and registered via PyImport_AppendInittab, so
 * it is NOT a separate .framework and costs nothing at dyld time.
 *
 * Contract: evaluate(source) -> whatever the script wrote via console.log.
 * That is exactly what EJSBaseJCP._run_js_runtime must return.
 */
#include <Python.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include "quickjs.h"

typedef struct {
    char  *buf;
    size_t len, cap;
    double deadline;     /* monotonic seconds; 0 = none */
} Ctx;

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int out_append(Ctx *c, const char *s, size_t n) {
    if (c->len + n + 1 > c->cap) {
        size_t cap = c->cap ? c->cap : 4096;
        while (cap < c->len + n + 1) cap *= 2;
        char *p = (char *)realloc(c->buf, cap);
        if (!p) return -1;
        c->buf = p; c->cap = cap;
    }
    memcpy(c->buf + c->len, s, n);
    c->len += n;
    c->buf[c->len] = '\0';
    return 0;
}

/* The solver's only output channel. */
static JSValue js_console_log(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    Ctx *c = (Ctx *)JS_GetContextOpaque(ctx);
    for (int i = 0; i < argc; i++) {
        size_t n = 0;
        const char *s = JS_ToCStringLen(ctx, &n, argv[i]);
        if (!s) return JS_EXCEPTION;
        if (i) out_append(c, " ", 1);
        out_append(c, s, n);
        JS_FreeCString(ctx, s);
    }
    out_append(c, "\n", 1);
    return JS_UNDEFINED;
}

/* Bounds runaway scripts; without it a hostile or buggy player JS hangs the app. */
static int interrupt_cb(JSRuntime *rt, void *opaque) {
    (void)rt;
    Ctx *c = (Ctx *)opaque;
    if (c->deadline > 0.0 && now_sec() > c->deadline) return 1;
    return 0;
}

static char *describe_exception(JSContext *ctx) {
    JSValue exc = JS_GetException(ctx);
    const char *s = JS_ToCString(ctx, exc);
    char *out = NULL;
    if (s) {
        /* A stack property, when present, is far more useful than the message. */
        JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
        const char *st = JS_IsUndefined(stack) ? NULL : JS_ToCString(ctx, stack);
        size_t n = strlen(s) + (st ? strlen(st) + 2 : 0) + 1;
        out = (char *)malloc(n);
        if (out) {
            if (st) snprintf(out, n, "%s\n%s", s, st);
            else    snprintf(out, n, "%s", s);
        }
        if (st) JS_FreeCString(ctx, st);
        JS_FreeValue(ctx, stack);
        JS_FreeCString(ctx, s);
    }
    JS_FreeValue(ctx, exc);
    return out ? out : strdup("unknown JS exception");
}

static PyObject *QjsError;

static PyObject *qjs_evaluate(PyObject *self, PyObject *args, PyObject *kwds) {
    (void)self;
    const char *src = NULL;
    Py_ssize_t srclen = 0;
    double timeout = 60.0;
    unsigned long long memlimit = 512ULL * 1024 * 1024;
    unsigned long long stacksize = 8ULL * 1024 * 1024;
    static char *kwlist[] = {"source", "timeout", "memory_limit", "stack_size", NULL};

    if (!PyArg_ParseTupleAndKeywords(args, kwds, "s#|dKK", kwlist,
                                     &src, &srclen, &timeout, &memlimit, &stacksize))
        return NULL;

    Ctx c = {0};
    char *err = NULL, *out = NULL;
    size_t outlen = 0;
    int failed = 0;

    /* JS execution does not touch Python; let other threads run. */
    Py_BEGIN_ALLOW_THREADS
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { failed = 1; err = strdup("JS_NewRuntime failed"); goto done;  }
    JS_SetMemoryLimit(rt, (size_t)memlimit);
    JS_SetMaxStackSize(rt, (size_t)stacksize);

    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { failed = 1; err = strdup("JS_NewContext failed"); JS_FreeRuntime(rt); goto done; }

    c.deadline = timeout > 0.0 ? now_sec() + timeout : 0.0;
    JS_SetContextOpaque(ctx, &c);
    JS_SetInterruptHandler(rt, interrupt_cb, &c);

    /* Minimal console shim: the solver calls console.log, nothing else. */
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue console = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, console, "log",
                      JS_NewCFunction(ctx, js_console_log, "log", 1));
    JS_SetPropertyStr(ctx, console, "error",
                      JS_NewCFunction(ctx, js_console_log, "error", 1));
    JS_SetPropertyStr(ctx, global, "console", console);
    JS_FreeValue(ctx, global);

    JSValue res = JS_Eval(ctx, src, (size_t)srclen, "<ejs>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(res)) {
        failed = 1;
        err = describe_exception(ctx);
    }
    JS_FreeValue(ctx, res);

    if (!failed && c.buf) { out = c.buf; outlen = c.len; c.buf = NULL; }

    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
done:
    Py_END_ALLOW_THREADS

    free(c.buf);
    if (failed) {
        PyErr_SetString(QjsError, err ? err : "unknown error");
        free(err);
        return NULL;
    }
    PyObject *py = PyUnicode_DecodeUTF8(out ? out : "", (Py_ssize_t)outlen, "replace");
    free(out);
    return py;
}

static PyObject *qjs_version(PyObject *self, PyObject *noargs) {
    (void)self; (void)noargs;
    return PyUnicode_FromFormat("%d.%d.%d", QJS_VERSION_MAJOR, QJS_VERSION_MINOR, QJS_VERSION_PATCH);
}

static PyMethodDef Methods[] = {
    {"evaluate", (PyCFunction)qjs_evaluate, METH_VARARGS | METH_KEYWORDS,
     "evaluate(source, timeout=60.0, memory_limit=..., stack_size=...) -> console output"},
    {"version", qjs_version, METH_NOARGS, "QuickJS-ng version string"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef moduledef = {
    PyModuleDef_HEAD_INIT, "_qjs", "Embedded QuickJS-ng for yt-dlp's EJS solver", -1, Methods,
};

PyMODINIT_FUNC PyInit__qjs(void) {
    PyObject *m = PyModule_Create(&moduledef);
    if (!m) return NULL;
    QjsError = PyErr_NewException("_qjs.JSError", NULL, NULL);
    Py_INCREF(QjsError);
    if (PyModule_AddObject(m, "JSError", QjsError) < 0) { Py_DECREF(m); return NULL; }
    return m;
}
