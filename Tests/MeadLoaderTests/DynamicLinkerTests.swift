#if canImport(Glibc)
import Glibc
#endif
import MeadLoaderCore
import Testing

// dlopen and its family over the loaded fixtures, as Android code calls them.

private let basicPath = ".build/mead-fixtures/libfixture_basic.so"

@Test func dlopenAndDlsymFindAFixtureFunction() throws {
    let handle = try #require(mead_dlopen(basicPath, 0))
    let add = unsafeBitCast(mead_dlsym(handle, "fixture_add", nil),
                            to: (@convention(c) (Int32, Int32) -> Int32).self)
    #expect(add(2, 3) == 5)
    #expect(mead_dlclose(handle) == 0)
}

@Test func aBareNameLoadsFromBesideTheGamesLibraries() throws {
    _ = try #require(mead_dlopen(basicPath, 0))
    let handle = try #require(mead_dlopen("libfixture_extra.so", 0))
    #expect(mead_dlsym(handle, "fixture_extra", nil) != nil)
}

@Test func aFailureIsReportedOnceThenCleared() throws {
    _ = mead_dlerror()
    #expect(mead_dlopen("libfixture_does_not_exist.so", 0) == nil)
    let message = try #require(mead_dlerror())
    #expect(String(cString: message).contains("libfixture_does_not_exist.so"))
    #expect(mead_dlerror() == nil)
}

@Test func aMissingSymbolSetsTheError() throws {
    let handle = try #require(mead_dlopen(basicPath, 0))
    _ = mead_dlerror()
    #expect(mead_dlsym(handle, "fixture_no_such_symbol", nil) == nil)
    let message = try #require(mead_dlerror())
    #expect(String(cString: message).contains("fixture_no_such_symbol"))
}

@Test func theWholeProcessHandleSearchesEverything() throws {
    _ = try #require(mead_dlopen(basicPath, 0))
    let process = try #require(mead_dlopen(nil, 0))
    #expect(mead_dlsym(process, "fixture_extra", nil) != nil)
}

@Test func rtldNextLooksOnlyInLaterImages() throws {
    let root = try #require(mead_dlopen(".build/mead-fixtures/libfixture_order_root.so", 0))
    let inRoot = mead_dlsym(root, "fixture_order_root_saw_leaf", nil)
    let inLeaf = mead_dlsym(root, "fixture_order_leaf_ready", nil)
    let next = UnsafeMutableRawPointer(bitPattern: -1)
    #expect(mead_dlsym(next, "fixture_order_leaf_ready", inRoot) == inLeaf)
    #expect(mead_dlsym(next, "fixture_order_root_saw_leaf", inLeaf) == nil)
}

@Test func dladdrNamesTheLibraryAndSymbol() throws {
    let handle = try #require(mead_dlopen(basicPath, 0))
    let add = mead_dlsym(handle, "fixture_add", nil)
    var info = mead_dl_info()
    #expect(mead_dladdr(add, &info) == 1)
    #expect(String(cString: info.dli_fname).hasSuffix("libfixture_basic.so"))
    #expect(String(cString: info.dli_sname) == "fixture_add")
    #expect(info.dli_saddr == add)
}

@Test func dladdrFallsBackToTheHostForTheHostsAddresses() {
    var info = mead_dl_info()
    #expect(mead_dladdr(unsafeBitCast(strlen as @convention(c) (UnsafePointer<CChar>) -> Int,
                                      to: UnsafeRawPointer.self), &info) == 1)
    #expect(info.dli_fname != nil)
}

private struct IterationResult {
    var sawFixture = false
    var sawHostLibc = false
    var fixtureLoadSegments = 0
}

@Test func iteratingPhdrsCoversAndroidImagesAndTheHost() throws {
    _ = try #require(mead_dlopen(basicPath, 0))
    var result = IterationResult()
    let status = withUnsafeMutablePointer(to: &result) { pointer in
        mead_dl_iterate_phdr({ info, _, data in
            let result = data!.assumingMemoryBound(to: IterationResult.self)
            let name = info!.pointee.dlpi_name.map { String(cString: $0) } ?? ""
            if name.hasSuffix("libfixture_basic.so") {
                result.pointee.sawFixture = true
                let phdr = info!.pointee.dlpi_phdr!
                for index in 0..<Int(info!.pointee.dlpi_phnum) where phdr[index].p_type == PT_LOAD {
                    result.pointee.fixtureLoadSegments += 1
                }
            }
            if name.contains("libc.so.6") {
                result.pointee.sawHostLibc = true
            }
            return 0
        }, pointer)
    }
    #expect(status == 0)
    #expect(result.sawFixture)
    #expect(result.fixtureLoadSegments > 0)
    #expect(result.sawHostLibc)
}

@Test func iterationStopsAtTheFirstNonzeroReturn() {
    var calls = 0
    let status = withUnsafeMutablePointer(to: &calls) { pointer in
        mead_dl_iterate_phdr({ _, _, data in
            data!.assumingMemoryBound(to: Int.self).pointee += 1
            return 7
        }, pointer)
    }
    #expect(status == 7)
    #expect(calls == 1)
}
