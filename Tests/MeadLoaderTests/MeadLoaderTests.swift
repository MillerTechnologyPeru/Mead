#if canImport(Glibc)
import Glibc
#endif
import MeadInterface
import MeadLoaderCore
import Testing

// The interface header's contract: what the providers compile against, and
// the logging the loader's options promise.

@Test func startupInfoVersionIsCurrent() {
    #expect(MEAD_STARTUP_INFO_VERSION == 1)
}

@Test func traceAlwaysWantsAll() {
    #expect(mead_trace_wants("all"))
}

@Test func traceIgnoresOtherCategoriesWithoutTheVariable() {
    setenv("MEAD_TRACE", "", 1)
    #expect(!mead_trace_wants("load"))
}

@Test func traceWantsANamedCategory() {
    setenv("MEAD_TRACE", "bind,init", 1)
    #expect(mead_trace_wants("bind"))
    #expect(mead_trace_wants("init"))
    #expect(!mead_trace_wants("load"))
}
