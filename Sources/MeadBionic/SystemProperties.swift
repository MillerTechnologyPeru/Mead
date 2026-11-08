import CMeadBionic
import Glibc

// What __system_property_get answers: the device Android code believes it is
// on. A game's manifest or compat profile will have the say over these once
// there are any; they describe a recent, ordinary 64-bit phone until then.

private let properties: [(name: String, value: String)] = [
    ("ro.board.platform", "mead"),
    ("ro.build.characteristics", "default"),
    ("ro.build.fingerprint", "mead/mead/mead:13/TQ3A.230901.001/1:user/release-keys"),
    ("ro.build.id", "TQ3A.230901.001"),
    ("ro.build.tags", "release-keys"),
    ("ro.build.type", "user"),
    ("ro.build.version.codename", "REL"),
    ("ro.build.version.incremental", "1"),
    ("ro.build.version.release", "13"),
    ("ro.build.version.sdk", "33"),
    ("ro.debuggable", "0"),
    ("ro.hardware", "mead"),
    ("ro.kernel.qemu", "0"),
    ("ro.opengles.version", "196610"),
    ("ro.product.board", "mead"),
    ("ro.product.brand", "mead"),
    ("ro.product.cpu.abi", "arm64-v8a"),
    ("ro.product.cpu.abilist", "arm64-v8a"),
    ("ro.product.cpu.abilist64", "arm64-v8a"),
    ("ro.product.device", "mead"),
    ("ro.product.manufacturer", "mead"),
    ("ro.product.model", "Mead"),
    ("ro.product.name", "mead"),
    ("ro.secure", "1"),
    ("ro.zygote", "zygote64"),
]

private let nameCapacity = 32
private let valueCapacity = 92

// Copies a string in, as far as Android's fixed-size buffers allow.
private func copy(_ string: String, to buffer: UnsafeMutablePointer<CChar>, capacity: Int) {
    let bytes = Array(string.utf8.prefix(capacity - 1))
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
}

// A property's handle is its place in the list, plus one so as never to be
// NULL; Android code only ever hands it back.
private func handle(_ index: Int) -> UnsafeRawPointer? {
    UnsafeRawPointer(bitPattern: index + 1)
}

@_cdecl("mead_bionic_property_get")
public func meadBionicPropertyGet(_ name: UnsafePointer<CChar>, _ value: UnsafeMutablePointer<CChar>) -> Int32 {
    let wanted = String(cString: name)
    guard let found = properties.first(where: { $0.name == wanted }) else {
        value[0] = 0
        return 0
    }
    copy(found.value, to: value, capacity: valueCapacity)
    return Int32(strlen(value))
}

@_cdecl("mead_bionic_property_find")
public func meadBionicPropertyFind(_ name: UnsafePointer<CChar>) -> UnsafeRawPointer? {
    let wanted = String(cString: name)
    return properties.firstIndex { $0.name == wanted }.flatMap(handle)
}

@_cdecl("mead_bionic_property_at")
public func meadBionicPropertyAt(_ index: UInt32) -> UnsafeRawPointer? {
    Int(index) < properties.count ? handle(Int(index)) : nil
}

@_cdecl("mead_bionic_property_copy")
public func meadBionicPropertyCopy(
    _ property: UnsafeRawPointer,
    _ name: UnsafeMutablePointer<CChar>,
    _ value: UnsafeMutablePointer<CChar>
) {
    let entry = properties[Int(bitPattern: property) - 1]
    copy(entry.name, to: name, capacity: nameCapacity)
    copy(entry.value, to: value, capacity: valueCapacity)
}
