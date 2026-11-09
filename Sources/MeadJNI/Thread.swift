import Glibc

/// A thread attached to the VM: its local references and pending exception.
/// Only that thread ever touches one.
public final class JavaThread {
    private struct Frame {
        var base: Int
        var free: [Int] = []
    }

    let block: UnsafeMutablePointer<mead_jni_env_block>
    private var locals: [JavaObject?] = []
    private var generations: [UInt32] = []
    private var frames: [Frame] = [Frame(base: 0)]
    public internal(set) var pending: JavaThrowable?

    init() {
        block = .allocate(capacity: 1)
        block.pointee.functions = mead_jni_function_table()
        block.pointee.thread = Unmanaged.passUnretained(self).toOpaque()
    }

    deinit {
        block.deallocate()
    }

    public var env: UnsafeMutablePointer<JNIEnv?> {
        UnsafeMutableRawPointer(block).assumingMemoryBound(to: JNIEnv?.self)
    }

    public static func from(_ env: UnsafeMutableRawPointer) -> JavaThread {
        let block = env.assumingMemoryBound(to: mead_jni_env_block.self)
        return Unmanaged<JavaThread>.fromOpaque(block.pointee.thread).takeUnretainedValue()
    }

    // MARK: References

    /// A local reference to `object`, or null for nil.
    public func newLocal(_ object: JavaObject?) -> OpaquePointer? {
        guard let object else { return nil }
        let index: Int
        if let reused = frames[frames.count - 1].free.popLast() {
            index = reused
            locals[index] = object
        } else {
            let top = frames[frames.count - 1].base + frameUsed
            if top < locals.count {
                index = top
                locals[index] = object
            } else {
                locals.append(object)
                generations.append(1)
                index = locals.count - 1
            }
            frameUsed += 1
        }
        return Handle(kind: .local, index: index, generation: generations[index]).pointer
    }

    private var frameUsed = 0
    private var savedUsed: [Int] = []

    public func pushFrame() {
        savedUsed.append(frameUsed)
        frames.append(Frame(base: frames[frames.count - 1].base + frameUsed))
        frameUsed = 0
    }

    public func popFrame() {
        guard frames.count > 1 else {
            JavaRuntime.shared.problem("PopLocalFrame without a matching PushLocalFrame")
            return
        }
        let frame = frames.removeLast()
        for index in frame.base..<min(frame.base + frameUsed, locals.count) {
            locals[index] = nil
            generations[index] &+= 1
        }
        frameUsed = savedUsed.removeLast()
    }

    func deleteLocal(_ handle: Handle) {
        guard isLiveLocal(handle) else {
            JavaRuntime.shared.problem("DeleteLocalRef of a stale local reference")
            return
        }
        locals[handle.index] = nil
        generations[handle.index] &+= 1
        let current = frames.count - 1
        if handle.index >= frames[current].base {
            frames[current].free.append(handle.index)
        }
    }

    private func isLiveLocal(_ handle: Handle) -> Bool {
        handle.index < locals.count && generations[handle.index] == handle.generation && locals[handle.index] != nil
    }

    /// The object a handle stands for. A handle that was valid once and is
    /// not now is a bug in the caller, and is said so.
    public func resolve(_ pointer: OpaquePointer?) -> JavaObject? {
        guard let pointer else { return nil }
        guard let handle = Handle(pointer) else {
            JavaRuntime.shared.problem("\(pointer) is not a reference")
            return nil
        }
        let runtime = JavaRuntime.shared
        switch handle.kind {
        case .local:
            guard isLiveLocal(handle) else {
                runtime.problem("use of a stale local reference (slot \(handle.index))")
                return nil
            }
            return locals[handle.index]
        case .global:
            let found = runtime.lock.withLock { runtime.globals.object(at: handle.index, generation: handle.generation) }
            if found == nil {
                runtime.problem("use of a deleted global reference (slot \(handle.index))")
            }
            return found
        case .weak:
            return runtime.lock.withLock {
                guard runtime.weaks.isLive(index: handle.index, generation: handle.generation) else {
                    runtime.problem("use of a deleted weak reference (slot \(handle.index))")
                    return nil
                }
                return runtime.weaks.object(at: handle.index, generation: handle.generation)
            }
        }
    }

    func referenceType(_ pointer: OpaquePointer?) -> jobjectRefType {
        guard let handle = Handle(pointer) else { return JNIInvalidRefType }
        let runtime = JavaRuntime.shared
        switch handle.kind {
        case .local:
            return isLiveLocal(handle) ? JNILocalRefType : JNIInvalidRefType
        case .global:
            return runtime.lock.withLock {
                runtime.globals.isLive(index: handle.index, generation: handle.generation) ? JNIGlobalRefType : JNIInvalidRefType
            }
        case .weak:
            return runtime.lock.withLock {
                runtime.weaks.isLive(index: handle.index, generation: handle.generation) ? JNIWeakGlobalRefType : JNIInvalidRefType
            }
        }
    }

    // MARK: Exceptions

    func raise(_ className: String, _ message: String?) {
        pending = JavaException(className, message).throwable
    }

    func raise(_ error: Error) {
        if let exception = error as? JavaException {
            pending = exception.throwable
        } else {
            raise("java/lang/RuntimeException", "\(error)")
        }
    }

    // MARK: Calls

    /// Calls a method by name from Swift, for what plays the part of the
    /// Java code a game expects to be called by. Handles in `arguments` are
    /// the caller's.
    @discardableResult
    public func call(_ className: String, _ name: String, _ signature: String, isStatic: Bool = false,
                     on receiver: JavaObject?, _ arguments: [jvalue] = []) -> jvalue {
        var result = jvalue()
        guard let type = JavaRuntime.shared.findClass(named: className),
              let method = type.method(named: name, signature: signature, isStatic: isStatic) else { return result }
        arguments.withUnsafeBufferPointer {
            run(method, receiver: receiver, arguments: $0.baseAddress, result: &result)
        }
        return result
    }

    /// Runs a method, whichever way it is implemented. Reference results are
    /// local references of the frame the caller is in.
    func run(_ method: JavaMethod, receiver: JavaObject?, arguments: UnsafePointer<jvalue>?, result: UnsafeMutablePointer<jvalue>) {
        let runtime = JavaRuntime.shared
        runtime.trace("\(method.owner.name).\(method.name)\(method.signature)")
        memset(result, 0, MemoryLayout<jvalue>.size)
        if let native = method.native {
            pushFrame()
            let target = newLocal(method.isStatic ? method.owner : receiver)
            mead_jni_call_native(native, env, target, method.shorty, arguments, result)
            if method.returnsReference {
                let returned = resolve(result.pointee.l)
                popFrame()
                result.pointee.l = newLocal(returned)
            } else {
                popFrame()
            }
            return
        }
        if let body = method.body {
            do {
                result.pointee = try body(self, receiver, arguments)
            } catch {
                raise(error)
            }
            return
        }
        // A library loaded since the method was looked up may implement it.
        if let native = runtime.boundNative(owner: method.owner.name, name: method.name, signature: method.signature) {
            method.native = native
            method.everRegistered = true
            run(method, receiver: receiver, arguments: arguments, result: result)
            return
        }
        runtime.problemOnce("call of \(method.owner.name).\(method.name)\(method.signature), which is not implemented")
    }
}

// Attachment. A thread's JavaThread lives in a key, whose destructor is what
// detaches a thread that exits still attached.

private let threadKey: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key) { value in
        if let value {
            Unmanaged<JavaThread>.fromOpaque(value).release()
        }
    }
    return key
}()

extension JavaRuntime {
    /// The calling thread's JavaThread, if it is attached.
    public var currentThread: JavaThread? {
        pthread_getspecific(threadKey).map { Unmanaged<JavaThread>.fromOpaque($0).takeUnretainedValue() }
    }

    /// The calling thread's JavaThread, attaching it if need be.
    @discardableResult
    public func attachCurrentThread() -> JavaThread {
        start()
        if let existing = currentThread {
            return existing
        }
        let thread = JavaThread()
        pthread_setspecific(threadKey, Unmanaged.passRetained(thread).toOpaque())
        trace("thread attached")
        return thread
    }

    func detachCurrentThread() {
        guard let value = pthread_getspecific(threadKey) else { return }
        pthread_setspecific(threadKey, nil)
        Unmanaged<JavaThread>.fromOpaque(value).release()
        trace("thread detached")
    }
}

/// The process's one JavaVM.
let javaVM: UnsafeMutablePointer<JavaVM?> = {
    let vm = UnsafeMutablePointer<JavaVM?>.allocate(capacity: 1)
    vm.initialize(to: mead_jni_invoke_table())
    return vm
}()
