// The TLS fixture: a thread_local variable with an initial value, reached
// the two ways NDK code reaches one — through a TLS descriptor (the
// default) or initial-exec's GOT slot — so both kinds of TLS relocation are
// exercised by the same source.

static __thread int fixture_tls_counter = 7;

int fixture_tls_bump(void) {
    return ++fixture_tls_counter;
}

int fixture_tls_peek(void) {
    return fixture_tls_counter;
}

// Exported, so it is reached through its symbol rather than the module's
// offset alone: the relocation has to add the symbol's place in the block.
__thread int fixture_tls_exported = 11;

int fixture_tls_exported_peek(void) {
    return fixture_tls_exported;
}
