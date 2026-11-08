// The library the basic fixture imports: one function, so a call across
// two Android images is a call across two loaded libraries.

int fixture_extra(int x) {
    return x + 1;
}

// What the basic fixture imports weakly.
int fixture_extra_weak(void) {
    return 5;
}

// The basic fixture defines this too. Being preemptible, the call below
// goes to the definition nearest the root of the load, not this one.
int fixture_interposed(void) {
    return 1;
}

int fixture_call_interposed(void) {
    return fixture_interposed();
}
