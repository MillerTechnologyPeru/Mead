import Glibc
import MeadInterface
import MeadRuntime

/// The loader's interface, from this provider's startup.
nonisolated(unsafe) private var loaderInfo: UnsafePointer<mead_startup_info>?

@_cdecl("mead_provider_startup")
public func meadARTProviderStartup(_ info: UnsafePointer<mead_startup_info>) {
    loaderInfo = info
}

/// `mead --dex <file.dex> <class> [arguments...]`: runs a class's main on ART,
/// with Mead's loader for the bionic libraries it loads.
///
/// ART is installed at MEAD_ART_HOME, or in `art` beside the `mead`
/// executable.
@_cdecl("mead_art_run_dex")
public func meadARTRunDex(_ dex: UnsafePointer<CChar>, _ className: UnsafePointer<CChar>, _ argc: Int32,
                          _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    func fail(_ message: String) -> Int32 {
        var line = "mead: \(message)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
        return 1
    }
    guard let loader = loaderInfo?.pointee else {
        return fail("the loader hasn't started the providers")
    }
    let providers = executableDirectory()
    let home = getenv("MEAD_ART_HOME").map { String(cString: $0) } ?? "\(providers)/art"
    let arguments = (0..<Int(argc)).compactMap { argv?[$0].map { String(cString: $0) } }
    do {
        let art = try ART(
            home: home, providerDirectory: providers,
            loader: ART.Loader(open: loader.dl_open, symbol: loader.dl_sym, close: loader.dl_close, error: loader.dl_error),
            options: ART.options(classPath: [String(cString: dex)], libraryPath: []))
        try art.runMain(className: String(cString: className), arguments: arguments)
        art.shutDown()
        return 0
    } catch {
        return fail("\(error)")
    }
}

/// Where the `mead` executable is, which is where its providers are.
private func executableDirectory() -> String {
    var path = [CChar](repeating: 0, count: 4096)
    let length = readlink("/proc/self/exe", &path, path.count - 1)
    guard length > 0 else { return "." }
    let executable = String(decoding: path[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return executable.lastIndex(of: "/").map { String(executable[..<$0]) } ?? "."
}
