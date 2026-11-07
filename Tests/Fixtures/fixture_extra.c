// The library the basic fixture imports: one function, so a call across
// two Android images is a call across two loaded libraries.

int fixture_extra(int x) {
    return x + 1;
}
