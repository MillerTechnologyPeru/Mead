// The library fixture_order_root.c needs: its constructor has to have run
// by the time the root's does.

int fixture_order_leaf_ready = 0;

__attribute__((constructor)) static void constructed(void) {
    fixture_order_leaf_ready = 1;
}
