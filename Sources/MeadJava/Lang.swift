import Glibc
import MeadInterface
import MeadJNI

@JavaClass("java/lang/Number")
open class JavaNumber: JavaObject {}

@JavaClass("java/lang/Integer", implements: ["java/lang/Comparable"])
public final class JavaInteger: JavaNumber {
    public let value: Int32

    @JavaMethod public init(value: Int32) {
        self.value = value
        super.init()
    }

    @JavaMethod("valueOf") public static func valueOf(_ value: Int32) -> JavaInteger? { JavaInteger(value: value) }
    @JavaMethod("intValue") public func intValue() -> Int32 { value }
    @JavaMethod("longValue") public func longValue() -> Int64 { Int64(value) }
    @JavaMethod("floatValue") public func floatValue() -> Float { Float(value) }
    @JavaMethod("doubleValue") public func doubleValue() -> Double { Double(value) }
    @JavaMethod("toString") public func javaToString() -> String? { String(value) }

    @JavaMethod("parseInt") public static func parseInt(_ text: String?) throws -> Int32 {
        guard let text, let parsed = Int32(text) else {
            throw JavaException("java/lang/NumberFormatException", text)
        }
        return parsed
    }
}

@JavaClass("java/lang/Long", implements: ["java/lang/Comparable"])
public final class JavaLong: JavaNumber {
    public let value: Int64

    @JavaMethod public init(value: Int64) {
        self.value = value
        super.init()
    }

    @JavaMethod("valueOf") public static func valueOf(_ value: Int64) -> JavaLong? { JavaLong(value: value) }
    @JavaMethod("intValue") public func intValue() -> Int32 { Int32(truncatingIfNeeded: value) }
    @JavaMethod("longValue") public func longValue() -> Int64 { value }
    @JavaMethod("toString") public func javaToString() -> String? { String(value) }
}

@JavaClass("java/lang/Float", implements: ["java/lang/Comparable"])
public final class JavaFloat: JavaNumber {
    public let value: Float

    @JavaMethod public init(value: Float) {
        self.value = value
        super.init()
    }

    @JavaMethod("valueOf") public static func valueOf(_ value: Float) -> JavaFloat? { JavaFloat(value: value) }
    @JavaMethod("floatValue") public func floatValue() -> Float { value }
    @JavaMethod("doubleValue") public func doubleValue() -> Double { Double(value) }
}

@JavaClass("java/lang/Double", implements: ["java/lang/Comparable"])
public final class JavaDouble: JavaNumber {
    public let value: Double

    @JavaMethod public init(value: Double) {
        self.value = value
        super.init()
    }

    @JavaMethod("valueOf") public static func valueOf(_ value: Double) -> JavaDouble? { JavaDouble(value: value) }
    @JavaMethod("floatValue") public func floatValue() -> Float { Float(value) }
    @JavaMethod("doubleValue") public func doubleValue() -> Double { value }
}

@JavaClass("java/lang/Boolean", implements: ["java/lang/Comparable"])
public final class JavaBoolean: JavaObject {
    public let value: Bool

    @JavaMethod public init(value: Bool) {
        self.value = value
        super.init()
    }

    @JavaMethod("valueOf") public static func valueOf(_ value: Bool) -> JavaBoolean? { JavaBoolean(value: value) }
    @JavaMethod("booleanValue") public func booleanValue() -> Bool { value }
}

@JavaClass("java/lang/System")
public final class JavaSystem: JavaObject {
    @JavaMethod("currentTimeMillis") public static func currentTimeMillis() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
    }

    @JavaMethod("nanoTime") public static func nanoTime() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    @JavaMethod("getProperty") public static func getProperty(_ name: String?) -> String? {
        switch name {
        case "os.name": return "Linux"
        case "os.arch": return "aarch64"
        case "file.separator": return "/"
        case "line.separator": return "\n"
        case "path.separator": return ":"
        case "java.vm.name": return "Mead"
        default: return nil
        }
    }

    @JavaMethod("identityHashCode", signature: "(Ljava/lang/Object;)I")
    public static func identityHashCode(_ object: JavaObject?) -> Int32 {
        object.map { Int32(truncatingIfNeeded: ObjectIdentifier($0).hashValue) } ?? 0
    }

    @JavaMethod("gc") public static func collectGarbage() {}

    @JavaMethod("exit") public static func exitProcess(_ status: Int32) {
        exit(status)
    }

    @JavaMethod("loadLibrary") public static func loadLibrary(_ name: String?) throws {
        guard let name else {
            throw JavaException("java/lang/NullPointerException", "loadLibrary(null)")
        }
        try load("lib\(name).so")
    }

    @JavaMethod("load") public static func load(_ path: String?) throws {
        guard let path else {
            throw JavaException("java/lang/NullPointerException", "load(null)")
        }
        try load(library: path)
    }

    /// As the app's Java would: `lib<name>.so`, and its JNI_OnLoad.
    public static func loadNamed(_ name: String) throws {
        try load("lib\(name).so")
    }

    private static func load(_ file: String) throws {
        try load(library: file)
    }

    nonisolated(unsafe) private static var onLoadRan = Set<UnsafeMutableRawPointer>()
    private static let lock = pthreadLock()

    private static func load(library: String) throws {
        guard let loader = AndroidEnvironment.loader,
              let handle = library.withCString({ loader.pointee.dl_open($0, 2) }) else {
            throw JavaException("java/lang/UnsatisfiedLinkError", library)
        }
        // JNI_OnLoad runs the first time, as for System.loadLibrary on
        // Android; libraries pulled in as dependencies never get one.
        pthread_mutex_lock(lock)
        let first = onLoadRan.insert(handle).inserted
        pthread_mutex_unlock(lock)
        guard first, let symbol = loader.pointee.dl_sym(handle, "JNI_OnLoad", nil) else {
            _ = loader.pointee.dl_error()
            return
        }
        typealias OnLoad = @convention(c) (UnsafeMutablePointer<JavaVM?>, UnsafeMutableRawPointer?) -> jint
        _ = unsafeBitCast(symbol, to: OnLoad.self)(JavaRuntime.shared.vm, nil)
    }
}

private func pthreadLock() -> UnsafeMutablePointer<pthread_mutex_t> {
    let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    pthread_mutex_init(lock, nil)
    return lock
}

@JavaClass("java/lang/Thread", implements: ["java/lang/Runnable"])
public final class JavaLangThread: JavaObject {
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { value in
            if let value {
                Unmanaged<JavaLangThread>.fromOpaque(value).release()
            }
        }
        return key
    }()

    @JavaMethod("currentThread") public static func currentThread() -> JavaLangThread? {
        if let existing = pthread_getspecific(key) {
            return Unmanaged<JavaLangThread>.fromOpaque(existing).takeUnretainedValue()
        }
        let thread = JavaLangThread()
        pthread_mutex_lock(nameLock)
        thread.name = created == 0 ? "main" : "Thread-\(created)"
        created += 1
        pthread_mutex_unlock(nameLock)
        pthread_setspecific(key, Unmanaged.passRetained(thread).toOpaque())
        return thread
    }

    private var name = ""
    nonisolated(unsafe) private static var created = 0
    private static let nameLock = pthreadLock()

    @JavaMethod("getName") public func getName() -> String? { name }

    @JavaMethod("sleep") public static func sleep(_ milliseconds: Int64) {
        var time = timespec(tv_sec: Int(milliseconds / 1000), tv_nsec: Int(milliseconds % 1000) * 1_000_000)
        nanosleep(&time, nil)
    }

    @JavaMethod("yield") public static func yieldNow() {
        sched_yield()
    }
}
