@_exported import CMeadJNI
import Glibc

// The fake JVM's process-wide state: the class registry, the global and weak
// reference tables, and the three modes unknown calls can be met with.
//
// MEAD_STRICT=1 aborts at the first class, member or stale reference that
// isn't what the game expects. Without it they are logged once and met with
// a stand-in that returns zero or null. MEAD_TRACE=jni logs every call, and
// MEAD_JNI_STUBS=<path> writes Swift stubs for every stand-in made.

/// A recursive lock.
final class JavaLock {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    init() {
        var attributes = pthread_mutexattr_t()
        pthread_mutexattr_init(&attributes)
        pthread_mutexattr_settype(&attributes, Int32(PTHREAD_MUTEX_RECURSIVE))
        pthread_mutex_init(mutex, &attributes)
        pthread_mutexattr_destroy(&attributes)
    }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }

    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}

/// A reference to a class or member by name and signature.
struct MemberKey: Hashable {
    let name: String
    let signature: String
}

private func environmentFlag(_ name: String) -> Bool {
    guard let value = getenv(name) else { return false }
    return value[0] != 0 && String(cString: value) != "0"
}

private func traceRequested() -> Bool {
    guard let value = getenv("MEAD_TRACE") else { return false }
    return String(cString: value).split(separator: ",").contains { $0 == "jni" || $0 == "all" }
}

func writeStandardError(_ text: String) {
    var line = text
    line.withUTF8 { bytes in
        _ = write(2, bytes.baseAddress, bytes.count)
    }
}

public final class JavaRuntime {
    public static let shared = JavaRuntime()

    let lock = JavaLock()
    let strict = environmentFlag("MEAD_STRICT")
    let tracing = traceRequested()

    private var classesByName: [String: JavaClass] = [:]
    private var classesBySwiftType: [ObjectIdentifier: JavaClass] = [:]
    private var started = false
    private var reported = Set<String>()

    var globals = ReferenceTable()
    var weaks = WeakReferenceTable()

    private init() {}

    func trace(_ text: @autoclosure () -> String) {
        if tracing {
            writeStandardError("mead(jni): \(text())\n")
        }
    }

    /// Something a well-behaved program would not do: fatal under MEAD_STRICT.
    func problem(_ text: String) {
        writeStandardError("mead(jni): \(text)\n")
        if strict {
            abort()
        }
    }

    /// As `problem`, once per distinct message.
    func problemOnce(_ text: String) {
        let isNew = lock.withLock { reported.insert(text).inserted }
        if isNew {
            problem(text)
        }
    }

    /// Makes the standard classes exist. Safe to call again.
    public func start() {
        lock.withLock {
            guard !started else { return }
            started = true
            let object = defineClass(for: JavaObject.self)
            let classClass = defineClass(for: JavaClass.self)
            object.javaClass = classClass
            classClass.javaClass = classClass
            defineClass(for: JavaString.self)
            defineClass(for: JavaThrowable.self)
            defineClass(for: JavaDirectBuffer.self)
            defineClass(for: JavaReflectedMember.self)
            for (name, parent) in standardExceptions {
                defineStandardClass(name, parent: parent)
            }
        }
        installStubWriter()
    }

    private let standardExceptions: [(String, String)] = [
        ("java/lang/Exception", "java/lang/Throwable"),
        ("java/lang/Error", "java/lang/Throwable"),
        ("java/lang/RuntimeException", "java/lang/Exception"),
        ("java/lang/ArithmeticException", "java/lang/RuntimeException"),
        ("java/lang/ArrayIndexOutOfBoundsException", "java/lang/RuntimeException"),
        ("java/lang/ArrayStoreException", "java/lang/RuntimeException"),
        ("java/lang/ClassCastException", "java/lang/RuntimeException"),
        ("java/lang/IllegalArgumentException", "java/lang/RuntimeException"),
        ("java/lang/IllegalStateException", "java/lang/RuntimeException"),
        ("java/lang/IndexOutOfBoundsException", "java/lang/RuntimeException"),
        ("java/lang/NegativeArraySizeException", "java/lang/RuntimeException"),
        ("java/lang/NullPointerException", "java/lang/RuntimeException"),
        ("java/lang/StringIndexOutOfBoundsException", "java/lang/RuntimeException"),
        ("java/lang/UnsupportedOperationException", "java/lang/RuntimeException"),
        ("java/lang/ClassNotFoundException", "java/lang/Exception"),
        ("java/lang/NoSuchFieldException", "java/lang/Exception"),
        ("java/lang/NoSuchMethodException", "java/lang/Exception"),
        ("java/io/IOException", "java/lang/Exception"),
        ("java/lang/LinkageError", "java/lang/Error"),
        ("java/lang/NoClassDefFoundError", "java/lang/LinkageError"),
        ("java/lang/NoSuchFieldError", "java/lang/LinkageError"),
        ("java/lang/NoSuchMethodError", "java/lang/LinkageError"),
        ("java/lang/VirtualMachineError", "java/lang/Error"),
        ("java/lang/OutOfMemoryError", "java/lang/VirtualMachineError"),
    ]

    @discardableResult
    private func defineStandardClass(_ name: String, parent: String) -> JavaClass {
        let definition = JavaClass(name: name, superclass: classesByName[parent], swiftType: nil, isSynthesized: false)
        definition.javaClass = classesByName["java/lang/Class"]
        classesByName[name] = definition
        return definition
    }

    /// The class a Swift type declares, making it and its superclasses exist.
    @discardableResult
    public func defineClass(for type: JavaObject.Type) -> JavaClass {
        start()
        return lock.withLock {
            if let existing = classesBySwiftType[ObjectIdentifier(type)] {
                return existing
            }
            let superclass = type.javaSuperclassType.map { defineClass(for: $0) }
            let definition = JavaClass(name: type.javaClassName, superclass: superclass, swiftType: type, isSynthesized: false)
            definition.javaClass = classesByName["java/lang/Class"]
            classesByName[type.javaClassName] = definition
            classesBySwiftType[ObjectIdentifier(type)] = definition
            for member in type.javaMembers() {
                definition.add(member)
            }
            return definition
        }
    }

    /// The class with `name`, if one exists.
    public func existingClass(named name: String) -> JavaClass? {
        lock.withLock { classesByName[name] }
    }

    /// The class FindClass answers with: real, an array's, or a stand-in.
    func findClass(named given: String) -> JavaClass? {
        let name = given.replacingDots()
        trace("FindClass \(name)")
        return lock.withLock {
            if let existing = classesByName[name] {
                return existing
            }
            let definition: JavaClass
            if name.hasPrefix("[") {
                definition = JavaClass(name: name, superclass: classesByName["java/lang/Object"], swiftType: nil, isSynthesized: false)
            } else {
                problemOnce("class \(name) is not implemented")
                definition = JavaClass(name: name, superclass: classesByName["java/lang/Object"], swiftType: nil, isSynthesized: true)
            }
            definition.javaClass = classesByName["java/lang/Class"]
            classesByName[name] = definition
            return definition
        }
    }

    func allClasses() -> [JavaClass] {
        lock.withLock { Array(classesByName.values) }
    }
}

extension String {
    func replacingDots() -> String {
        String(map { $0 == "." ? "/" : $0 })
    }
}

/// A single-word-per-slot table of references with reuse: each slot's
/// generation is bumped when it is emptied, so a stale handle is caught.
struct ReferenceTable {
    private(set) var objects: [JavaObject?] = []
    private(set) var generations: [UInt32] = []
    private var free: [Int] = []

    mutating func insert(_ object: JavaObject) -> (index: Int, generation: UInt32) {
        if let index = free.popLast() {
            objects[index] = object
            return (index, generations[index])
        }
        objects.append(object)
        generations.append(1)
        return (objects.count - 1, 1)
    }

    func object(at index: Int, generation: UInt32) -> JavaObject? {
        guard index < objects.count, generations[index] == generation else { return nil }
        return objects[index]
    }

    func isLive(index: Int, generation: UInt32) -> Bool {
        index < objects.count && generations[index] == generation && objects[index] != nil
    }

    mutating func remove(at index: Int, generation: UInt32) -> Bool {
        guard isLive(index: index, generation: generation) else { return false }
        objects[index] = nil
        generations[index] &+= 1
        free.append(index)
        return true
    }
}

struct WeakReferenceTable {
    private struct Slot {
        weak var object: JavaObject?
        var generation: UInt32 = 1
        var inUse = false
    }

    private var slots: [Slot] = []
    private var free: [Int] = []

    mutating func insert(_ object: JavaObject) -> (index: Int, generation: UInt32) {
        let index: Int
        if let reused = free.popLast() {
            index = reused
        } else {
            slots.append(Slot())
            index = slots.count - 1
        }
        slots[index].object = object
        slots[index].inUse = true
        return (index, slots[index].generation)
    }

    func isLive(index: Int, generation: UInt32) -> Bool {
        index < slots.count && slots[index].inUse && slots[index].generation == generation
    }

    func object(at index: Int, generation: UInt32) -> JavaObject? {
        isLive(index: index, generation: generation) ? slots[index].object : nil
    }

    mutating func remove(at index: Int, generation: UInt32) -> Bool {
        guard isLive(index: index, generation: generation) else { return false }
        slots[index] = Slot(object: nil, generation: slots[index].generation &+ 1, inUse: false)
        free.append(index)
        return true
    }
}

/// What a jobject is: never a pointer, but the kind of table it is in, its
/// place there, and the generation of that place.
enum ReferenceKind: UInt {
    case local = 1
    case global = 2
    case weak = 3
}

struct Handle {
    let kind: ReferenceKind
    let index: Int
    let generation: UInt32

    init(kind: ReferenceKind, index: Int, generation: UInt32) {
        self.kind = kind
        self.index = index
        self.generation = generation
    }

    init?(_ pointer: OpaquePointer?) {
        guard let pointer else { return nil }
        let bits = UInt(bitPattern: pointer)
        guard let kind = ReferenceKind(rawValue: bits & 3) else { return nil }
        self.kind = kind
        index = Int((bits >> 2) & 0xffff_ffff)
        generation = UInt32(bits >> 34)
    }

    var pointer: OpaquePointer? {
        let generationBits = UInt(generation) & 0x3fff_ffff
        return OpaquePointer(bitPattern: (generationBits << 34) | (UInt(index) << 2) | kind.rawValue)
    }
}
