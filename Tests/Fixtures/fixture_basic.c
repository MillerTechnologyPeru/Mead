// The loader's basic fixture: what a game library looks like to mead —
// functions to call, a global its constructor sets, a string constant, an
// import from another library, and an import nothing answers, which binds
// to mead's stub and is never called.

#include <stddef.h>

int fixture_state = 0;

// An import the loader must resolve from libfixture_extra.so.
int fixture_extra(int x);

// An import nothing answers: the address mead's stub gives, never called.
int mead_missing_function(int x);
int (*const fixture_unanswered)(int) = mead_missing_function;

__attribute__((constructor)) static void constructed(void) {
    fixture_state = 42;
}

int fixture_add(int a, int b) {
    return a + b;
}

const char *fixture_string(void) {
    return "mead";
}

int fixture_use_extra(int x) {
    return fixture_extra(x);
}

// Calls what nothing answers, for the stub to report itself.
int fixture_call_missing(int x) {
    return mead_missing_function(x);
}

// Weak imports: one libfixture_extra.so defines and one nothing does.
__attribute__((weak)) int fixture_extra_weak(void);
__attribute__((weak)) int fixture_nowhere(void);

int fixture_weak_found(void) {
    return fixture_extra_weak ? fixture_extra_weak() : 0;
}

int fixture_weak_missing_is_null(void) {
    return fixture_nowhere == NULL;
}

// Defined by libfixture_extra.so too. This one, the root's, is the one both
// libraries are to bind to.
int fixture_interposed(void) {
    return 2;
}

// Named as a function mead's loader makes return at once.
__attribute__((used, visibility("default")))
long fixture_skipped(void) __asm__("_ZN9Microsoft12Applications6Events19TelemetrySystemBase5startEv");
long fixture_skipped(void) { return fixture_state + 7; }
