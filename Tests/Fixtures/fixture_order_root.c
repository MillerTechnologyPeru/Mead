// Records, in its constructor, whether the library it needs was already
// initialized: dependencies come first.

extern int fixture_order_leaf_ready;

int fixture_order_root_saw_leaf = -1;

__attribute__((constructor)) static void constructed(void) {
    fixture_order_root_saw_leaf = fixture_order_leaf_ready;
}
