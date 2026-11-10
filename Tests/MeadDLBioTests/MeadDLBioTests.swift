import CMeadDLBio
import Foundation
import Glibc
import Testing

// Mead's libdl_bio: glibc libraries to the system's linker, bionic ones to
// Mead's loader.

private let bionicLibrary = ".build/mead-fixtures/libfixture_basic.so"

/// The path of a library this process has mapped, by its file name.
private func mapped(_ name: String) -> String? {
    guard let file = fopen("/proc/self/maps", "r") else { return nil }
    defer { fclose(file) }
    var line = [CChar](repeating: 0, count: 4096)
    while fgets(&line, Int32(line.count), file) != nil {
        let text = String(cString: line).trimmingCharacters(in: .newlines)
        guard let slash = text.firstIndex(of: "/") else { continue }
        let path = String(text[slash...])
        if path.hasSuffix("/" + name) { return path }
    }
    return nil
}

@Test func aLibraryIsBionicWhenItNeedsBionicsLibc() {
    let glibc = mapped("libc.so.6"), swiftCore = mapped("libswiftCore.so")
    #expect(glibc != nil && swiftCore != nil)
    #expect(mead_dl_bio_is_bionic_library(glibc ?? "") == false)  // glibc itself
    #expect(mead_dl_bio_is_bionic_library(swiftCore ?? "") == false)
    #expect(mead_dl_bio_is_bionic_library("/no/such/library.so") == false)
    #expect(access(bionicLibrary, R_OK) == 0)
    #expect(mead_dl_bio_is_bionic_library(bionicLibrary))
}

@Test func aHostLibraryOpensThroughTheSystemsLinker() {
    let handle = bionic_dlopen(mapped("libswiftCore.so") ?? "", RTLD_NOW)
    #expect(handle != nil)
    #expect(bionic_dlsym(handle, "swift_retain") != nil)
    #expect(bionic_dlsym(handle, "mead_no_such_symbol") == nil)
    #expect(bionic_dlerror() != nil)
    #expect(bionic_dlclose(handle) == 0)
    // By name, as ART asks for its own libraries.
    let byName = bionic_dlopen("libc.so.6", RTLD_NOW)
    #expect(byName != nil && bionic_dlsym(byName, "strlen") != nil)
    bionic_dlclose(byName)
}

nonisolated(unsafe) private var opened: [String] = []

@Test func aBionicLibraryOpensThroughMeadsLoader() {
    // Before Mead's loader is installed, a bionic library has nowhere to go.
    #expect(bionic_dlopen(bionicLibrary, RTLD_NOW) == nil)
    #expect(bionic_dlerror() != nil)
    var loader = mead_dl_bio_loader(
        open: { name, _ in
            opened.append(String(cString: name!))
            return UnsafeMutableRawPointer(bitPattern: 0x1000)
        },
        sym: { _, name, _ in String(cString: name!) == "answer" ? UnsafeMutableRawPointer(bitPattern: 0x2000) : nil },
        close: { _ in 0 },
        error: { UnsafePointer(strdup("not in Mead's images")) })
    mead_dl_bio_install(&loader)
    let handle = bionic_dlopen(bionicLibrary, RTLD_NOW)
    #expect(handle != nil && opened == [bionicLibrary])
    #expect(bionic_dlsym(handle, "answer") == UnsafeMutableRawPointer(bitPattern: 0x2000))
    #expect(bionic_dlsym(handle, "question") == nil)
    #expect(bionic_dlerror().map { String(cString: $0) } == "not in Mead's images")
    #expect(bionic_dlclose(handle) == 0)
}

@Test func aLibraryAskedForByNameIsFoundInTheSearchDirectories() {
    guard let swiftCore = mapped("libswiftCore.so") else {
        Issue.record("no libswiftCore.so mapped")
        return
    }
    let directory = String(swiftCore[..<swiftCore.lastIndex(of: "/")!])
    mead_dl_bio_add_search_directory("/no/such/directory")
    mead_dl_bio_add_search_directory(directory)
    let handle = bionic_dlopen("libswiftCore.so", RTLD_NOW)
    #expect(handle != nil && bionic_dlsym(handle, "swift_retain") != nil)
    bionic_dlclose(handle)
}
