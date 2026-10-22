#include <Python.h>
#include <string.h>
#include <stdlib.h>
#include "ClipAudioPython.h"

static int g_ready = 0;
static PyObject *g_module = NULL;

/* QuickJS-ng is compiled into this binary; expose it as a builtin module so
 * it needs no .framework and costs nothing at dyld time. Must be appended
 * before the interpreter is initialized. */
PyMODINIT_FUNC PyInit__qjs(void);

static char *cpa_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

/// Collect a Python exception into a malloc'd string, clearing it.
static char *drain_error(void) {
    if (!PyErr_Occurred()) return cpa_strdup("unknown error");
    PyObject *type, *value, *tb;
    PyErr_Fetch(&type, &value, &tb);
    PyErr_NormalizeException(&type, &value, &tb);
    char *out = NULL;
    if (value) {
        PyObject *str = PyObject_Str(value);
        if (str) {
            const char *utf8 = PyUnicode_AsUTF8(str);
            if (utf8) out = cpa_strdup(utf8);
            Py_DECREF(str);
        }
    }
    Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(tb);
    PyErr_Clear();
    return out ? out : cpa_strdup("unparseable error");
}

/// site.addsitedir(path) — preferred over PYTHONPATH so .pth files are honored.
static int add_site_dir(const char *path) {
    PyObject *site = PyImport_ImportModule("site");
    if (!site) return -1;
    PyObject *res = PyObject_CallMethod(site, "addsitedir", "s", path);
    Py_DECREF(site);
    if (!res) return -1;
    Py_DECREF(res);
    return 0;
}

int cpa_initialize(const char *resource_path, char **out_err) {
    if (g_ready) return 0;

    // Keep log output machine-readable.
    setenv("NO_COLOR", "1", 1);
    setenv("PYTHON_COLORS", "0", 1);

    // yt-dlp wants a writable cache dir; the bundle is read-only.
    char cache[1024];
    const char *home_env = getenv("HOME");
    snprintf(cache, sizeof(cache), "%s/Library/Caches", home_env ? home_env : "/tmp");
    setenv("CLIPAUDIO_CACHE", cache, 1);

    if (PyImport_AppendInittab("_qjs", PyInit__qjs) == -1) {
        if (out_err) *out_err = cpa_strdup("PyImport_AppendInittab(_qjs) failed");
        return 8;
    }

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        if (out_err) *out_err = cpa_strdup(status.err_msg ? status.err_msg : "preinit failed");
        return 1;
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.use_system_logger = 1;   // stdout/stderr -> os_log, visible in Console
    config.buffered_stdio = 0;
    config.write_bytecode = 0;      // bundle is read-only; don't try to write .pyc
    config.install_signal_handlers = 0;  // we are a library here, not the main program

    char home[1024];
    snprintf(home, sizeof(home), "%s/python", resource_path);
    wchar_t *whome = Py_DecodeLocale(home, NULL);
    status = PyConfig_SetString(&config, &config.home, whome);
    PyMem_RawFree(whome);
    if (PyStatus_Exception(status)) {
        if (out_err) *out_err = cpa_strdup(status.err_msg ? status.err_msg : "set home failed");
        PyConfig_Clear(&config);
        return 2;
    }

    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) {
        if (out_err) *out_err = cpa_strdup(status.err_msg ? status.err_msg : "config read failed");
        PyConfig_Clear(&config);
        return 3;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        if (out_err) *out_err = cpa_strdup(status.err_msg ? status.err_msg : "init failed");
        return 4;
    }

    // Our pure-Python deps and glue module.
    char buf[1024];
    snprintf(buf, sizeof(buf), "%s/app_packages", resource_path);
    if (add_site_dir(buf) != 0) { if (out_err) *out_err = drain_error(); return 5; }
    snprintf(buf, sizeof(buf), "%s/app", resource_path);
    if (add_site_dir(buf) != 0) { if (out_err) *out_err = drain_error(); return 6; }

    g_module = PyImport_ImportModule("clipaudio_resolve");
    if (!g_module) { if (out_err) *out_err = drain_error(); return 7; }

    g_ready = 1;
    PyEval_SaveThread();   // drop the GIL; callers re-acquire via PyGILState
    return 0;
}

char *cpa_call(const char *func, const char *arg) {
    if (!g_ready || !g_module) return NULL;

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = arg ? PyObject_CallMethod(g_module, func, "s", arg)
                           : PyObject_CallMethod(g_module, func, NULL);
    char *out = NULL;
    if (!result) {
        char *err = drain_error();
        // Surface Python-side crashes in the same JSON shape as normal results.
        size_t n = strlen(err) + 64;
        out = (char *)malloc(n);
        if (out) snprintf(out, n, "{\"ok\":false,\"stage\":\"BRIDGE\",\"error\":\"%s\"}", err);
        free(err);
    } else {
        const char *utf8 = PyUnicode_Check(result) ? PyUnicode_AsUTF8(result) : NULL;
        out = cpa_strdup(utf8 ? utf8 : "{\"ok\":false,\"stage\":\"BRIDGE\",\"error\":\"non-string return\"}");
        Py_DECREF(result);
    }
    PyGILState_Release(gil);
    return out;
}

void cpa_shutdown(void) {
    if (!g_ready) return;
    PyGILState_Ensure();
    Py_CLEAR(g_module);
    Py_FinalizeEx();
    g_ready = 0;
}
