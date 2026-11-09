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
    // A test can land on any thread, so it sets its own up as pthread_create
    // will; that also resets what an earlier test left on this one.
    mead_tlv_thread_init()
    let bump = unsafeBitCast(mead_find_symbol(descriptor, "fixture_tls_bump"),
                             to: (@convention(c) () -> Int32).self)
    #expect(bump() == 8)
    #expect(bump() == 9)

    guard let initialExec = fixture("libfixture_tls_ie.so") else { return }
    mead_tlv_thread_init()
    let peek = unsafeBitCast(mead_find_symbol(initialExec, "fixture_tls_peek"),
                             to: (@convention(c) () -> Int32).self)
    #expect(peek() == 7)
}

@Test func exportedThreadLocalIsFoundThroughItsSymbol() {
    for name in ["libfixture_tls.so", "libfixture_tls_ie.so"] {
        guard let handle = fixture(name) else { continue }
        mead_tlv_thread_init()
        let peek = unsafeBitCast(mead_find_symbol(handle, "fixture_tls_exported_peek"),
                                 to: (@convention(c) () -> Int32).self)
        #expect(peek() == 11, "\(name)")
        let exported = unsafeBitCast(mead_find_symbol(handle, "fixture_tls_exported"),
                                     to: UnsafeMutablePointer<Int32>.self)
        #expect(exported.pointee == 11, "\(name): dlsym gives this thread's copy")
    }
}

// What a new thread sees once the bionic shim's pthread_create has set it up.
private nonisolated(unsafe) var peekedOnThread: Int32 = 0
private nonisolated(unsafe) var bumpedOnThread: Int32 = 0
private nonisolated(unsafe) var tlsPeek: (@convention(c) () -> Int32)?
private nonisolated(unsafe) var tlsBump: (@convention(c) () -> Int32)?

@Test func aNewThreadStartsFromTheInitialImage() {
    guard let handle = fixture("libfixture_tls.so") else { return }
    tlsPeek = unsafeBitCast(mead_find_symbol(handle, "fixture_tls_peek"),
                            to: (@convention(c) () -> Int32).self)
    tlsBump = unsafeBitCast(mead_find_symbol(handle, "fixture_tls_bump"),
                            to: (@convention(c) () -> Int32).self)
    mead_tlv_thread_init()
    let before = tlsPeek!()
    var thread = pthread_t()
    let created = pthread_create(&thread, nil, { _ in
        mead_tlv_thread_init()
        peekedOnThread = tlsPeek!()
        bumpedOnThread = tlsBump!()
        return nil
    }, nil)
    #expect(created == 0)
    pthread_join(thread, nil)
    #expect(peekedOnThread == 7)
    #expect(bumpedOnThread == 8)
    #expect(tlsPeek!() == before, "the other thread's bump stayed on its own thread")
}

@Test func weakImportsTakeADefinitionWhenThereIsOne() {
    guard let handle = fixture("libfixture_basic.so") else { return }
    let found = unsafeBitCast(mead_find_symbol(handle, "fixture_weak_found"),
                              to: (@convention(c) () -> Int32).self)
    #expect(found() == 5)
    let missing = unsafeBitCast(mead_find_symbol(handle, "fixture_weak_missing_is_null"),
                                to: (@convention(c) () -> Int32).self)
    #expect(missing() == 1)
}

@Test func theRootsDefinitionBeatsADependencysOwn() {
    guard let handle = fixture("libfixture_basic.so") else { return }
    let call = unsafeBitCast(mead_find_symbol(handle, "fixture_call_interposed"),
                             to: (@convention(c) () -> Int32).self)
    #expect(call() == 2)
}

@Test func dependenciesInitializeBeforeWhatNeedsThem() {
    guard let handle = fixture("libfixture_order_root.so") else { return }
    let saw = unsafeBitCast(mead_find_symbol(handle, "fixture_order_root_saw_leaf"),
                            to: UnsafeMutablePointer<Int32>.self)
    #expect(saw.pointee == 1)
}

@Test func anUnansweredImportNamesItselfAndReturnsZero() {
    guard let handle = fixture("libfixture_basic.so") else { return }
    let call = unsafeBitCast(mead_find_symbol(handle, "fixture_call_missing"),
                             to: (@convention(c) (Int32) -> Int32).self)
    // The trace formats the name with %s: handed anything but the name,
    // such as this argument, it would crash.
    setenv("MEAD_UNIMPLEMENTED", "1", 1)
    setenv("MEAD_TRACE", "stub", 1)
    defer {
        unsetenv("MEAD_UNIMPLEMENTED")
        unsetenv("MEAD_TRACE")
    }
    #expect(call(42) == 0)
}

@Test func everyMissingImportIsListedByName() {
    guard fixture("libfixture_basic.so") != nil else { return }
    let total = mead_fixups_missing_total()
    #expect(total >= 1, "at least the one the fixture imports and nothing answers")
    var names: [String] = []
    for index in 0..<total {
        var wanted = 0
        guard let name = mead_fixups_missing_at(index, &wanted) else {
            Issue.record("no name at \(index)")
            continue
        }
        #expect(wanted >= 1)
        names.append(String(cString: name))
    }
    #expect(names.contains("mead_missing_function"))
}

@Test func theProviderAnswersOnlyWhatItsTableSays() {
    guard fixture("libfixture_basic.so") != nil else { return }
    #expect(mead_deps_provider_symbol("strlen") != nil)
    // In glibc, and reachable through the provider's own dependencies, but
    // nothing Android code may be handed.
    #expect(mead_deps_provider_symbol("__libc_start_main") == nil)
}

@Test func theGraphicsProvidersAnswerOnlyGraphicsNames() {
    guard fixture("libfixture_basic.so") != nil else { return }
    #expect(mead_deps_provider_symbol("glClear") != nil)
    #expect(mead_deps_provider_symbol("eglSwapBuffers") != nil)
    #expect(mead_deps_provider_symbol("vkCreateDevice") != nil)
    // Spelled like GL and Vulkan, and only reachable as glibc's.
    #expect(mead_deps_provider_symbol("glob") == nil)
    #expect(mead_deps_provider_symbol("vkprintf") == nil)
}

@Test func sixteenKilobyteLibrariesStayAligned() {
    guard let handle = fixture("libfixture_16k.so") else { return }
    let add = mead_find_symbol(handle, "fixture_add")
    var info = mead_dl_info()
    #expect(mead_dladdr(add, &info) == 1)
    #expect(UInt(bitPattern: info.dli_fbase) & 0x3fff == 0)
    let state = unsafeBitCast(mead_find_symbol(handle, "fixture_state"),
                              to: UnsafeMutablePointer<Int32>.self)
    #expect(state.pointee == 42)
}

@Test func aSkippedFunctionReturnsAtOnce() {
    guard let handle = fixture("libfixture_basic.so") else { return }
    let skipped = unsafeBitCast(mead_find_symbol(handle, "_ZN9Microsoft12Applications6Events19TelemetrySystemBase5startEv"),
                                to: (@convention(c) () -> Int).self)
    #expect(skipped() == 0)
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
