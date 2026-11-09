import Glibc
import MeadJNI

// Android's message loop, as native code drives it through JNI: a Looper per
// thread with a queue of work in time order, Handlers that post to one,
// HandlerThreads that run one, and the Choreographer that calls back once a
// frame. Engines (Unity's) pace their frames through these.

private func monotonicNanos() -> UInt64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
}

/// android.os.Looper: a thread's queue of work, run in due-time order.
@JavaClass("android/os/Looper")
public final class JavaLooper: JavaObject {
    private struct Entry {
        let due: UInt64
        let order: UInt64
        let what: Int32?
        let handler: JavaHandler?
        let token: ObjectIdentifier?
        let job: () -> Void
    }

    private var entries: [Entry] = []
    private var order: UInt64 = 0
    private var quitting = false
    private let mutex: UnsafeMutablePointer<pthread_mutex_t> = {
        let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
        return mutex
    }()
    private let condition: UnsafeMutablePointer<pthread_cond_t> = {
        let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        var attributes = pthread_condattr_t()
        pthread_condattr_init(&attributes)
        pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC)
        pthread_cond_init(condition, &attributes)
        pthread_condattr_destroy(&attributes)
        return condition
    }()

    /// The main thread's: the runner drains it between frames.
    public static let main = JavaLooper()

    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { value in
            if let value { Unmanaged<JavaLooper>.fromOpaque(value).release() }
        }
        return key
    }()

    /// The calling thread's looper, if it has one.
    public static var current: JavaLooper? {
        pthread_getspecific(key).map { Unmanaged<JavaLooper>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Makes `looper` the calling thread's.
    public static func setCurrent(_ looper: JavaLooper) {
        if let old = pthread_getspecific(key) { Unmanaged<JavaLooper>.fromOpaque(old).release() }
        pthread_setspecific(key, Unmanaged.passRetained(looper).toOpaque())
    }

    /// Adds work, due `delay` nanoseconds from now.
    public func post(delay: UInt64 = 0, what: Int32? = nil, handler: JavaHandler? = nil, token: AnyObject? = nil,
                     _ job: @escaping () -> Void) {
        pthread_mutex_lock(mutex)
        order += 1
        let entry = Entry(due: monotonicNanos() + delay, order: order, what: what, handler: handler,
                          token: token.map(ObjectIdentifier.init), job: job)
        let index = entries.firstIndex { ($0.due, $0.order) > (entry.due, entry.order) } ?? entries.count
        entries.insert(entry, at: index)
        pthread_cond_signal(condition)
        pthread_mutex_unlock(mutex)
    }

    /// Takes back work not yet run: a handler's with `what`, or what was
    /// posted with `token`; with neither, all of the handler's.
    public func remove(handler: JavaHandler?, what: Int32? = nil, token: AnyObject? = nil) {
        pthread_mutex_lock(mutex)
        let tokenID = token.map(ObjectIdentifier.init)
        entries.removeAll { entry in
            if let handler, entry.handler !== handler { return false }
            if let what, entry.what != what { return false }
            if let tokenID, entry.token != tokenID { return false }
            return true
        }
        pthread_mutex_unlock(mutex)
    }

    public func has(handler: JavaHandler?, what: Int32) -> Bool {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return entries.contains { $0.handler === handler && $0.what == what }
    }

    /// The first job due by now, taken off the queue.
    private func takeDue(wait: Bool) -> (() -> Void)? {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        while true {
            if quitting { return nil }
            let now = monotonicNanos()
            if let first = entries.first, first.due <= now {
                entries.removeFirst()
                return first.job
            }
            guard wait else { return nil }
            if let first = entries.first {
                var deadline = timespec(tv_sec: Int(first.due / 1_000_000_000), tv_nsec: Int(first.due % 1_000_000_000))
                pthread_cond_timedwait(condition, mutex, &deadline)
            } else {
                pthread_cond_wait(condition, mutex)
            }
        }
    }

    /// Runs whatever is due now and returns: for a thread that has its own
    /// loop, as the runner's main thread does.
    public func runDue() {
        let thread = JavaRuntime.shared.attachCurrentThread()
        while let job = takeDue(wait: false) {
            thread.pushFrame()
            job()
            thread.popFrame()
        }
    }

    /// Runs work as it falls due until quit.
    public func loopForever() {
        let thread = JavaRuntime.shared.attachCurrentThread()
        while let job = takeDue(wait: true) {
            thread.pushFrame()
            job()
            thread.popFrame()
        }
    }

    @JavaMethod("quit") public func quit() {
        pthread_mutex_lock(mutex)
        quitting = true
        pthread_cond_broadcast(condition)
        pthread_mutex_unlock(mutex)
    }

    @JavaMethod("quitSafely") public func quitSafely() { quit() }

    @JavaMethod("getMainLooper") public static func getMainLooper() -> JavaLooper? { main }
    @JavaMethod("myLooper") public static func myLooper() -> JavaLooper? { current }

    @JavaMethod("prepare") public static func prepare() {
        if current == nil { setCurrent(JavaLooper()) }
    }

    @JavaMethod("loop") public static func loop() {
        current?.loopForever()
    }
}

/// android.os.Message: what a Handler is sent.
@JavaClass("android/os/Message")
public final class JavaMessage: JavaObject {
    @JavaField("what") public var what: Int32 = 0
    @JavaField("arg1") public var arg1: Int32 = 0
    @JavaField("arg2") public var arg2: Int32 = 0
    @JavaField("obj", signature: "Ljava/lang/Object;") public var obj: JavaObject? = nil
    public var target: JavaHandler?
    public var callback: JavaObject?

    @JavaMethod public override init() {
        super.init()
    }

    @JavaMethod("obtain", signature: "()Landroid/os/Message;") public static func obtain() -> JavaMessage? { JavaMessage() }

    @JavaMethod("getTarget") public func getTarget() -> JavaHandler? { target }
    @JavaMethod("sendToTarget") public func sendToTarget() { _ = target?.sendMessage(self) }
    @JavaMethod("recycle") public func recycle() {}
}

/// android.os.Handler: posts work and messages to a looper, and hands each
/// message to its callback (a Handler.Callback, often a proxy) or to its
/// own handleMessage.
@JavaClass("android/os/Handler")
open class JavaHandler: JavaObject {
    public let looper: JavaLooper
    public let callback: JavaObject?

    public init(queue: JavaLooper?, callback: JavaObject?) {
        self.looper = queue ?? JavaLooper.current ?? JavaLooper.main
        self.callback = callback
        super.init()
    }

    @JavaMethod public convenience override init() {
        self.init(queue: nil, callback: nil)
    }

    @JavaMethod(signature: "(Landroid/os/Looper;)V") public convenience init(looper: JavaObject?) {
        self.init(queue: looper as? JavaLooper, callback: nil)
    }

    @JavaMethod(signature: "(Landroid/os/Handler$Callback;)V") public convenience init(callback: JavaObject?) {
        self.init(queue: nil, callback: callback)
    }

    @JavaMethod(signature: "(Landroid/os/Looper;Landroid/os/Handler$Callback;)V")
    public convenience init(looper: JavaObject?, callback: JavaObject?) {
        self.init(queue: looper as? JavaLooper, callback: callback)
    }

    @JavaMethod("getLooper") public func getLooper() -> JavaLooper? { looper }

    private func message(what: Int32 = 0, arg1: Int32 = 0, arg2: Int32 = 0, obj: JavaObject? = nil) -> JavaMessage {
        let message = JavaMessage()
        message.what = what
        message.arg1 = arg1
        message.arg2 = arg2
        message.obj = obj
        message.target = self
        return message
    }

    @JavaMethod("obtainMessage", signature: "()Landroid/os/Message;")
    public func obtainMessage() -> JavaMessage? { message() }

    @JavaMethod("obtainMessage", signature: "(I)Landroid/os/Message;")
    public func obtainMessage(_ what: Int32) -> JavaMessage? { message(what: what) }

    @JavaMethod("obtainMessage", signature: "(ILjava/lang/Object;)Landroid/os/Message;")
    public func obtainMessage(_ what: Int32, _ obj: JavaObject?) -> JavaMessage? { message(what: what, obj: obj) }

    @JavaMethod("obtainMessage", signature: "(III)Landroid/os/Message;")
    public func obtainMessage(_ what: Int32, _ arg1: Int32, _ arg2: Int32) -> JavaMessage? {
        message(what: what, arg1: arg1, arg2: arg2)
    }

    @JavaMethod("obtainMessage", signature: "(IIILjava/lang/Object;)Landroid/os/Message;")
    public func obtainMessage(_ what: Int32, _ arg1: Int32, _ arg2: Int32, _ obj: JavaObject?) -> JavaMessage? {
        message(what: what, arg1: arg1, arg2: arg2, obj: obj)
    }

    /// What Android's dispatchMessage does: the message's own runnable, else
    /// the callback, else handleMessage.
    public func dispatch(_ message: JavaMessage) {
        let thread = JavaRuntime.shared.attachCurrentThread()
        var argument = jvalue()
        argument.l = thread.newLocal(message)
        if let runnable = message.callback {
            thread.call("java/lang/Runnable", "run", "()V", on: runnable)
            return
        }
        if let callback {
            let handled = thread.call("android/os/Handler$Callback", "handleMessage", "(Landroid/os/Message;)Z", on: callback, [argument])
            if handled.z != 0 { return }
        }
        thread.call("android/os/Handler", "handleMessage", "(Landroid/os/Message;)V", on: self, [argument])
    }

    @JavaMethod("handleMessage", signature: "(Landroid/os/Message;)V") open func handleMessage(_ message: JavaObject?) {}

    @JavaMethod("sendMessageDelayed", signature: "(Landroid/os/Message;J)Z")
    public func sendMessageDelayed(_ message: JavaObject?, _ milliseconds: Int64) -> Bool {
        guard let message = message as? JavaMessage else { return false }
        message.target = self
        looper.post(delay: UInt64(max(milliseconds, 0)) * 1_000_000, what: message.what, handler: self) { [self] in
            dispatch(message)
        }
        return true
    }

    @JavaMethod("sendMessage", signature: "(Landroid/os/Message;)Z")
    public func sendMessage(_ message: JavaObject?) -> Bool { sendMessageDelayed(message, 0) }

    @JavaMethod("sendMessageAtFrontOfQueue", signature: "(Landroid/os/Message;)Z")
    public func sendMessageAtFrontOfQueue(_ message: JavaObject?) -> Bool { sendMessageDelayed(message, 0) }

    @JavaMethod("sendEmptyMessage") public func sendEmptyMessage(_ what: Int32) -> Bool {
        sendMessageDelayed(message(what: what), 0)
    }

    @JavaMethod("sendEmptyMessageDelayed") public func sendEmptyMessageDelayed(_ what: Int32, _ milliseconds: Int64) -> Bool {
        sendMessageDelayed(message(what: what), milliseconds)
    }

    @JavaMethod("postDelayed", signature: "(Ljava/lang/Runnable;J)Z")
    public func postDelayed(_ runnable: JavaObject?, _ milliseconds: Int64) -> Bool {
        guard let runnable else { return false }
        looper.post(delay: UInt64(max(milliseconds, 0)) * 1_000_000, handler: self, token: runnable) {
            JavaRuntime.shared.attachCurrentThread().call("java/lang/Runnable", "run", "()V", on: runnable)
        }
        return true
    }

    @JavaMethod("post", signature: "(Ljava/lang/Runnable;)Z")
    public func post(_ runnable: JavaObject?) -> Bool { postDelayed(runnable, 0) }

    @JavaMethod("postAtFrontOfQueue", signature: "(Ljava/lang/Runnable;)Z")
    public func postAtFrontOfQueue(_ runnable: JavaObject?) -> Bool { postDelayed(runnable, 0) }

    @JavaMethod("removeMessages", signature: "(I)V") public func removeMessages(_ what: Int32) {
        looper.remove(handler: self, what: what)
    }

    @JavaMethod("removeCallbacks", signature: "(Ljava/lang/Runnable;)V") public func removeCallbacks(_ runnable: JavaObject?) {
        guard let runnable else { return }
        looper.remove(handler: self, token: runnable)
    }

    @JavaMethod("removeCallbacksAndMessages", signature: "(Ljava/lang/Object;)V")
    public func removeCallbacksAndMessages(_ token: JavaObject?) {
        looper.remove(handler: self, token: token)
    }

    @JavaMethod("hasMessages", signature: "(I)Z") public func hasMessages(_ what: Int32) -> Bool {
        looper.has(handler: self, what: what)
    }
}

/// android.os.HandlerThread: a thread that runs a looper of its own.
@JavaClass("android/os/HandlerThread")
public final class JavaHandlerThread: JavaObject {
    public let name: String
    private let ready = LockedValue<JavaLooper?>(nil)
    private var threadID: Int32 = -1

    @JavaMethod(signature: "(Ljava/lang/String;)V") public init(name: String?) {
        self.name = name ?? "HandlerThread"
        super.init()
    }

    @JavaMethod(signature: "(Ljava/lang/String;I)V") public convenience init(name: String?, priority: Int32) {
        self.init(name: name)
    }

    @JavaMethod("start") public func start() {
        let looper = JavaLooper()
        let name = String(decoding: Array(name.utf8.prefix(15)), as: UTF8.self)
        runOnNewThread { [self] in
            name.withCString { _ = setThreadName(pthread_self(), $0) }
            JavaLooper.setCurrent(looper)
            threadID = JavaProcess.myTid()
            ready.withLock { $0 = looper }
            looper.loopForever()
        }
    }

    /// Waits, as Android's does, until the thread's looper is running.
    @JavaMethod("getLooper") public func getLooper() -> JavaLooper? {
        for _ in 0..<2000 {
            if let looper = ready.withLock({ $0 }) { return looper }
            usleep(1000)
        }
        return nil
    }

    @JavaMethod("quit") public func quit() -> Bool {
        ready.withLock { $0 }?.quit()
        return true
    }

    @JavaMethod("quitSafely") public func quitSafely() -> Bool { quit() }
    @JavaMethod("getThreadId") public func getThreadId() -> Int32 { threadID }
    @JavaMethod("getName") public func getName() -> String? { name }
}

/// android.view.Choreographer: calls its frame callbacks once a frame, on
/// the thread whose looper it belongs to, with the frame's time.
@JavaClass("android/view/Choreographer")
public final class JavaChoreographer: JavaObject {
    public let looper: JavaLooper

    /// One frame of a 60 Hz display, unless MEAD_REFRESH_RATE says otherwise.
    public static let frameInterval: UInt64 = {
        let rate = getenv("MEAD_REFRESH_RATE").flatMap { Double(String(cString: $0)) } ?? 60
        return UInt64(1_000_000_000 / max(rate, 1))
    }()

    init(looper: JavaLooper) {
        self.looper = looper
        super.init()
    }

    private static let instances = LockedValue([ObjectIdentifier: JavaChoreographer]())

    @JavaMethod("getInstance") public static func getInstance() -> JavaChoreographer? {
        let looper = JavaLooper.current ?? JavaLooper.main
        return instances.withLock { table in
            if let existing = table[ObjectIdentifier(looper)] { return existing }
            let made = JavaChoreographer(looper: looper)
            table[ObjectIdentifier(looper)] = made
            return made
        }
    }

    /// The time from now to the next frame boundary, after `delay`.
    private static func untilNextFrame(after delay: UInt64) -> UInt64 {
        let now = monotonicNanos() + delay
        return delay + (frameInterval - now % frameInterval)
    }

    @JavaMethod("postFrameCallbackDelayed", signature: "(Landroid/view/Choreographer$FrameCallback;J)V")
    public func postFrameCallbackDelayed(_ callback: JavaObject?, _ milliseconds: Int64) {
        guard let callback else { return }
        let wait = Self.untilNextFrame(after: UInt64(max(milliseconds, 0)) * 1_000_000)
        looper.post(delay: wait, token: callback) {
            var now = jvalue()
            now.j = Int64(monotonicNanos())
            JavaRuntime.shared.attachCurrentThread().call("android/view/Choreographer$FrameCallback", "doFrame", "(J)V",
                                                          on: callback, [now])
        }
    }

    @JavaMethod("postFrameCallback", signature: "(Landroid/view/Choreographer$FrameCallback;)V")
    public func postFrameCallback(_ callback: JavaObject?) { postFrameCallbackDelayed(callback, 0) }

    @JavaMethod("removeFrameCallback", signature: "(Landroid/view/Choreographer$FrameCallback;)V")
    public func removeFrameCallback(_ callback: JavaObject?) {
        guard let callback else { return }
        looper.remove(handler: nil, token: callback)
    }
}

/// glibc's pthread_setname_np, which Swift's Glibc module doesn't show.
private let setThreadName: @convention(c) (pthread_t, UnsafePointer<CChar>) -> Int32 = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "pthread_setname_np") else { return { _, _ in 0 } }
    return unsafeBitCast(symbol, to: (@convention(c) (pthread_t, UnsafePointer<CChar>) -> Int32).self)
}()
