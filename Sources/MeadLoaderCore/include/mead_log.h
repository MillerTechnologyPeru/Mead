#ifndef MEAD_LOG_H
#define MEAD_LOG_H

// The loader's logging. mead_trace prints when MEAD_TRACE names its category
// (comma-separated: load, bind, init, or all); mead_fatal always prints and
// exits, as the loader never recovers from what it reports.

#ifdef __cplusplus
extern "C" {
#endif

void mead_fatal(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));
void mead_trace(const char *category, const char *format, ...) __attribute__((format(printf, 2, 3)));

// Whether MEAD_TRACE names `category`, checked once and cached.
bool mead_trace_wants(const char *category);

#ifdef __cplusplus
}
#endif

#endif
