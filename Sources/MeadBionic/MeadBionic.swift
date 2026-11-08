import CMeadBionic
import Glibc
import MeadInterface

// libMeadBionic.so's entry points, as mead_interface.h names them.

@_cdecl("mead_provider_startup")
public func meadProviderStartup(_ info: UnsafePointer<mead_startup_info>) {
    mead_bionic_startup(info)
}

@_cdecl("mead_provider_symbol")
public func meadProviderSymbol(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    mead_bionic_lookup(name)
}

// liblog.so ends up here: one line on standard error, each written whole so
// that threads' messages do not interleave.

private let priorityLetters: [Character] = ["?", "?", "V", "D", "I", "W", "E", "F"]

@_cdecl("mead_bionic_log_write")
public func meadBionicLogWrite(_ priority: Int32, _ tag: UnsafePointer<CChar>?, _ text: UnsafePointer<CChar>?) {
    let letter = priorityLetters.indices.contains(Int(priority)) ? priorityLetters[Int(priority)] : "?"
    let tagText = tag.map { String(cString: $0) } ?? "?"
    let message = text.map { String(cString: $0) } ?? ""
    var line = "\(letter)/\(tagText): \(message)\n"
    line.withUTF8 { bytes in
        _ = write(2, bytes.baseAddress, bytes.count)
    }
}
