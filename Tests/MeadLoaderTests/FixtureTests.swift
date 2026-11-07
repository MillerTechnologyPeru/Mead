#if canImport(Glibc)
import Glibc
#endif
import MeadLoaderCore
import Testing

// Loads the NDK-built fixtures with mead itself and calls into them,
// unmodified, as Docker builds them into .build/mead-fixtures.

private func fixture(_ name: String) -> UnsafeMutableRawPointer? {
    let path = ".build/mead-fixtures/" + name
    guard let handle = mead_load_library(path, nil) else {
        Issue.record("cannot load \(path)")
        return nil
    }
    return handle
}

@Test func basicFixtureComputesAndRunsItsConstructor() {
    guard let handle = fixture("libfixture_basic.so") else { return }
    let add = unsafeBitCast(mead_find_symbol(handle, "fixture_add"),
                            to: (@convention(c) (Int32, Int32) -> Int32).self)
    #expect(add(20, 22) == 42)
    let state = unsafeBitCast(mead_find_symbol(handle, "fixture_state"),
                              to: UnsafeMutablePointer<Int32>.self)
    #expect(state.pointee == 42)
    let string = unsafeBitCast(mead_find_symbol(handle, "fixture_string"),
                               to: (@convention(c) () -> UnsafePointer<CChar>).self)()
    #expect(String(cString: string) == "mead")
}

@Test func importsResolveAcrossImages() {
    guard let handle = fixture("libfixture_basic.so") else { return }
    let use = unsafeBitCast(mead_find_symbol(handle, "fixture_use_extra"),
                            to: (@convention(c) (Int32) -> Int32).self)
    #expect(use(42) == 43)
    // The import nothing answers bound to mead's stub: an address in the
    // fixture's data, found, not a hole.
    #expect(mead_find_symbol(handle, "fixture_unanswered") != nil)
}

@Test func tlsFixturesHoldTheirCounts() {
    guard let descriptor = fixture("libfixture_tls.so") else { return }
    let bump = unsafeBitCast(mead_find_symbol(descriptor, "fixture_tls_bump"),
                             to: (@convention(c) () -> Int32).self)
    #expect(bump() == 8)
    #expect(bump() == 9)

    guard let initialExec = fixture("libfixture_tls_ie.so") else { return }
    let peek = unsafeBitCast(mead_find_symbol(initialExec, "fixture_tls_peek"),
                             to: (@convention(c) () -> Int32).self)
    #expect(peek() == 7)
}

@Test func packedAndRelativeRelocationsBindTheSame() {
    for name in ["libfixture_packed.so", "libfixture_relr.so"] {
        guard let handle = fixture(name) else { continue }
        let add = unsafeBitCast(mead_find_symbol(handle, "fixture_add"),
                                to: (@convention(c) (Int32, Int32) -> Int32).self)
        #expect(add(1, 2) == 3)
        let state = unsafeBitCast(mead_find_symbol(handle, "fixture_state"),
                                  to: UnsafeMutablePointer<Int32>.self)
        #expect(state.pointee == 42, "\(name): its constructor ran")
    }
}
