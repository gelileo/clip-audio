#ifndef CLIPAUDIO_PYTHON_H
#define CLIPAUDIO_PYTHON_H

/// Narrow C surface over the embedded interpreter. Everything crossing this
/// boundary is a C string holding JSON; no Python objects escape.
/// Thread-safe via PyGILState: callable from any thread, including a GCD
/// queue that migrates between OS threads.

/// Returns 0 on success. On failure returns non-zero and sets *out_err to a
/// malloc'd message the caller must free().
int cpa_initialize(const char *resource_path, char **out_err);

/// Calls clipaudio_resolve.<func>(arg). Pass arg = NULL for a no-arg call.
/// Returns a malloc'd JSON string the caller must free(), or NULL on failure.
char *cpa_call(const char *func, const char *arg);

void cpa_shutdown(void);

#endif
