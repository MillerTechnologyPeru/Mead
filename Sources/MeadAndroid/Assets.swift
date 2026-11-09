import CMeadAndroid
import Glibc
import MeadJNI
import MeadJava

/// An AAssetManager over an extracted APK's assets/ directory.
public final class AssetManager {
    public nonisolated(unsafe) static let shared = AssetManager()

    /// The directory holding the assets; set when the provider starts.
    public var root = "."

    public init() {}

    /// The file an asset name refers to, refusing names that lead out of
    /// the assets. Android's names are always relative and never contain "..".
    public func path(for name: String) -> String? {
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return nil }
        return name.isEmpty ? root : "\(root)/\(name)"
    }

    var pointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

private func manager(_ pointer: UnsafeMutableRawPointer) -> AssetManager {
    Unmanaged<AssetManager>.fromOpaque(pointer).takeUnretainedValue()
}

/// An open AAsset.
public final class Asset {
    let descriptor: Int32
    let length: Int64
    private var mapping: UnsafeMutableRawPointer?

    init?(path: String) {
        descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        length = Int64(status.st_size)
    }

    deinit {
        if let mapping {
            munmap(mapping, Int(length))
        }
        close(descriptor)
    }

    /// The whole asset, mapped the first time it is asked for.
    var buffer: UnsafeMutableRawPointer? {
        if mapping == nil, length > 0 {
            let mapped = mmap(nil, Int(length), PROT_READ, MAP_PRIVATE, descriptor, 0)
            if mapped != MAP_FAILED {
                mapping = mapped
            }
        }
        return mapping
    }
}

private func asset(_ pointer: UnsafeMutableRawPointer) -> Asset {
    Unmanaged<Asset>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("AAssetManager_fromJava")
public func AAssetManager_fromJava(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> UnsafeMutableRawPointer? {
    JavaThread.from(env).resolve(object) is JavaAssetManager ? AssetManager.shared.pointer : nil
}

@_cdecl("AAssetManager_open")
public func AAssetManager_open(_ pointer: UnsafeMutableRawPointer, _ name: UnsafePointer<CChar>, _ mode: Int32) -> UnsafeMutableRawPointer? {
    guard let path = manager(pointer).path(for: String(cString: name)), let opened = Asset(path: path) else { return nil }
    return Unmanaged.passRetained(opened).toOpaque()
}

@_cdecl("AAsset_close")
public func AAsset_close(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<Asset>.fromOpaque(pointer).release()
}

@_cdecl("AAsset_read")
public func AAsset_read(_ pointer: UnsafeMutableRawPointer, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int32 {
    Int32(read(asset(pointer).descriptor, buffer, count))
}

@_cdecl("AAsset_seek")
public func AAsset_seek(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ whence: Int32) -> Int {
    lseek(asset(pointer).descriptor, offset, whence)
}

@_cdecl("AAsset_seek64")
public func AAsset_seek64(_ pointer: UnsafeMutableRawPointer, _ offset: Int64, _ whence: Int32) -> Int64 {
    Int64(lseek(asset(pointer).descriptor, Int(offset), whence))
}

@_cdecl("AAsset_getBuffer")
public func AAsset_getBuffer(_ pointer: UnsafeMutableRawPointer) -> UnsafeRawPointer? {
    asset(pointer).buffer.map { UnsafeRawPointer($0) }
}

@_cdecl("AAsset_getLength")
public func AAsset_getLength(_ pointer: UnsafeMutableRawPointer) -> Int { Int(asset(pointer).length) }

@_cdecl("AAsset_getLength64")
public func AAsset_getLength64(_ pointer: UnsafeMutableRawPointer) -> Int64 { asset(pointer).length }

@_cdecl("AAsset_getRemainingLength")
public func AAsset_getRemainingLength(_ pointer: UnsafeMutableRawPointer) -> Int {
    Int(AAsset_getRemainingLength64(pointer))
}

@_cdecl("AAsset_getRemainingLength64")
public func AAsset_getRemainingLength64(_ pointer: UnsafeMutableRawPointer) -> Int64 {
    let opened = asset(pointer)
    return opened.length - Int64(lseek(opened.descriptor, 0, SEEK_CUR))
}

@_cdecl("AAsset_isAllocated")
public func AAsset_isAllocated(_ pointer: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("AAsset_openFileDescriptor64")
public func AAsset_openFileDescriptor64(_ pointer: UnsafeMutableRawPointer, _ start: UnsafeMutablePointer<Int64>, _ length: UnsafeMutablePointer<Int64>) -> Int32 {
    let opened = asset(pointer)
    start.pointee = 0
    length.pointee = opened.length
    return dup(opened.descriptor)
}

@_cdecl("AAsset_openFileDescriptor")
public func AAsset_openFileDescriptor(_ pointer: UnsafeMutableRawPointer, _ start: UnsafeMutablePointer<Int>, _ length: UnsafeMutablePointer<Int>) -> Int32 {
    var longStart: Int64 = 0, longLength: Int64 = 0
    let descriptor = AAsset_openFileDescriptor64(pointer, &longStart, &longLength)
    start.pointee = Int(longStart)
    length.pointee = Int(longLength)
    return descriptor
}

/// An open AAssetDir.
final class AssetDirectory {
    let handle: OpaquePointer

    init?(path: String) {
        guard let opened = opendir(path) else { return nil }
        handle = opened
    }

    deinit {
        closedir(handle)
    }
}

private func directory(_ pointer: UnsafeMutableRawPointer) -> AssetDirectory {
    Unmanaged<AssetDirectory>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("AAssetManager_openDir")
public func AAssetManager_openDir(_ pointer: UnsafeMutableRawPointer, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    guard let path = manager(pointer).path(for: String(cString: name)), let opened = AssetDirectory(path: path) else { return nil }
    return Unmanaged.passRetained(opened).toOpaque()
}

// Android lists a directory's files, and not the directories in it.
@_cdecl("AAssetDir_getNextFileName")
public func AAssetDir_getNextFileName(_ pointer: UnsafeMutableRawPointer) -> UnsafePointer<CChar>? {
    mead_next_file_name(UnsafeMutableRawPointer(directory(pointer).handle))
}

@_cdecl("AAssetDir_rewind")
public func AAssetDir_rewind(_ pointer: UnsafeMutableRawPointer) {
    rewinddir(directory(pointer).handle)
}

@_cdecl("AAssetDir_close")
public func AAssetDir_close(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<AssetDirectory>.fromOpaque(pointer).release()
}
