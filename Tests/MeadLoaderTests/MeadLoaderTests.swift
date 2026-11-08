#if canImport(Glibc)
import Glibc
#endif
import MeadInterface
import MeadLoaderCore
import Testing

// The interface header's contract: what the providers compile against, and
// the logging the loader's options promise. The trace tests set MEAD_TRACE,
// so they run one at a time.

@Test func startupInfoVersionIsCurrent() {
    #expect(MEAD_STARTUP_INFO_VERSION == 2)
}

@Test func traceAlwaysWantsAll() {
    #expect(mead_trace_wants("all"))
}

@Suite(.serialized) struct TraceCategories {
    @Test func ignoresCategoriesWithoutTheVariable() {
        setenv("MEAD_TRACE", "", 1)
        #expect(!mead_trace_wants("load"))
    }

    @Test func wantsANamedCategory() {
        setenv("MEAD_TRACE", "bind,init", 1)
        #expect(mead_trace_wants("bind"))
        #expect(mead_trace_wants("init"))
        #expect(!mead_trace_wants("load"))
    }
}
