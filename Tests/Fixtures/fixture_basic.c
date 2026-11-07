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
