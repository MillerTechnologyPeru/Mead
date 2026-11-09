import CMeadAndroid
import Glibc

public typealias LooperCallback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32

public let ALOOPER_POLL_WAKE: Int32 = -1
public let ALOOPER_POLL_CALLBACK: Int32 = -2
public let ALOOPER_POLL_TIMEOUT: Int32 = -3
public let ALOOPER_POLL_ERROR: Int32 = -4

/// A lock for state a few threads share.
final class Mutex {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    init() {
        pthread_mutex_init(mutex, nil)
    }

    func withLock<Result>(_ body: () -> Result) -> Result {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return body()
    }
}

/// ALooper: a thread's epoll loop, with the behaviour of Android's, in which
/// a file descriptor either has a callback or returns an identifier from
/// pollOnce.
public final class Looper {
    private struct Request {
        let ident: Int32
        let callback: LooperCallback?
        let data: UnsafeMutableRawPointer?
    }

    private struct Response {
        let ident: Int32
        let fd: Int32
        let events: Int32
        let callback: LooperCallback?
        let data: UnsafeMutableRawPointer?
    }

    private let pollFD = mead_poll_create()
    private let wakeFD = mead_event_create()
    private let lock = Mutex()
    private var requests: [Int32: Request] = [:]
    private var responses: [Response] = []
    private var nextResponse = 0

    public init() {
        _ = mead_poll_add(pollFD, wakeFD, Int32(MEAD_LOOPER_EVENT_INPUT))
    }

    deinit {
        close(pollFD)
        close(wakeFD)
    }

    public func wake() {
        mead_event_signal(wakeFD)
    }

    public func addFd(_ fd: Int32, ident: Int32, events: Int32, callback: LooperCallback?, data: UnsafeMutableRawPointer?) -> Int32 {
        if callback == nil, ident < 0 {
            return -1
        }
        let request = Request(ident: callback != nil ? ALOOPER_POLL_CALLBACK : ident, callback: callback, data: data)
        return lock.withLock {
            let result = requests[fd] == nil ? mead_poll_add(pollFD, fd, events) : mead_poll_modify(pollFD, fd, events)
            guard result == 0 else { return -1 }
            requests[fd] = request
            return 1
        }
    }

    public func removeFd(_ fd: Int32) -> Int32 {
        lock.withLock {
            guard requests.removeValue(forKey: fd) != nil else { return 0 }
            _ = mead_poll_remove(pollFD, fd)
            return 1
        }
    }

    public func pollOnce(timeout: Int32, outFd: UnsafeMutablePointer<Int32>?, outEvents: UnsafeMutablePointer<Int32>?, outData: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
        var result: Int32 = 0
        while true {
            while nextResponse < responses.count {
                let response = responses[nextResponse]
                nextResponse += 1
                if response.ident >= 0 {
                    outFd?.pointee = response.fd
                    outEvents?.pointee = response.events
                    outData?.pointee = response.data
                    return response.ident
                }
            }
            if result != 0 {
                outFd?.pointee = 0
                outEvents?.pointee = 0
                outData?.pointee = nil
                return result
            }
            result = pollInner(timeout: timeout)
        }
    }

    private func pollInner(timeout: Int32) -> Int32 {
        var items = [mead_poll_item](repeating: mead_poll_item(), count: 16)
        let count = mead_poll_wait(pollFD, &items, Int32(items.count), timeout)
        responses.removeAll(keepingCapacity: true)
        nextResponse = 0
        if count < 0 {
            return errno == EINTR ? ALOOPER_POLL_WAKE : ALOOPER_POLL_ERROR
        }
        if count == 0 {
            return ALOOPER_POLL_TIMEOUT
        }

        var result = ALOOPER_POLL_WAKE
        lock.withLock {
            for item in items[0..<Int(count)] {
                if item.fd == wakeFD {
                    mead_event_drain(wakeFD)
                } else if let request = requests[item.fd] {
                    responses.append(Response(ident: request.ident, fd: item.fd, events: item.events, callback: request.callback, data: request.data))
                }
            }
        }
        for response in responses {
            guard response.ident == ALOOPER_POLL_CALLBACK, let callback = response.callback else { continue }
            if callback(response.fd, response.events, response.data) == 0 {
                _ = removeFd(response.fd)
            }
            result = ALOOPER_POLL_CALLBACK
        }
        return result
    }

    // Each thread's looper, in a key whose destructor drops the thread's hold.
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { value in
            if let value {
                Unmanaged<Looper>.fromOpaque(value).release()
            }
        }
        return key
    }()

    public static var forThread: Looper? {
        pthread_getspecific(key).map { Unmanaged<Looper>.fromOpaque($0).takeUnretainedValue() }
    }

    public static func prepare() -> Looper {
        if let existing = forThread {
            return existing
        }
        let looper = Looper()
        pthread_setspecific(key, Unmanaged.passRetained(looper).toOpaque())
        return looper
    }
}

private func looper(_ pointer: UnsafeMutableRawPointer) -> Looper {
    Unmanaged<Looper>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("ALooper_forThread")
public func ALooper_forThread() -> UnsafeMutableRawPointer? {
    Looper.forThread.map { Unmanaged.passUnretained($0).toOpaque() }
}

@_cdecl("ALooper_prepare")
public func ALooper_prepare(_ options: Int32) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(Looper.prepare()).toOpaque()
}

@_cdecl("ALooper_acquire")
public func ALooper_acquire(_ pointer: UnsafeMutableRawPointer) {
    _ = Unmanaged<Looper>.fromOpaque(pointer).retain()
}

@_cdecl("ALooper_release")
public func ALooper_release(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<Looper>.fromOpaque(pointer).release()
}

@_cdecl("ALooper_wake")
public func ALooper_wake(_ pointer: UnsafeMutableRawPointer) {
    looper(pointer).wake()
}

@_cdecl("ALooper_addFd")
public func ALooper_addFd(_ pointer: UnsafeMutableRawPointer, _ fd: Int32, _ ident: Int32, _ events: Int32, _ callback: LooperCallback?, _ data: UnsafeMutableRawPointer?) -> Int32 {
    looper(pointer).addFd(fd, ident: ident, events: events, callback: callback, data: data)
}

@_cdecl("ALooper_removeFd")
public func ALooper_removeFd(_ pointer: UnsafeMutableRawPointer, _ fd: Int32) -> Int32 {
    looper(pointer).removeFd(fd)
}

@_cdecl("ALooper_pollOnce")
public func ALooper_pollOnce(_ timeout: Int32, _ outFd: UnsafeMutablePointer<Int32>?, _ outEvents: UnsafeMutablePointer<Int32>?, _ outData: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let current = Looper.forThread else { return ALOOPER_POLL_ERROR }
    return current.pollOnce(timeout: timeout, outFd: outFd, outEvents: outEvents, outData: outData)
}

private func milliseconds() -> Int64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
}

@_cdecl("ALooper_pollAll")
public func ALooper_pollAll(_ timeout: Int32, _ outFd: UnsafeMutablePointer<Int32>?, _ outEvents: UnsafeMutablePointer<Int32>?, _ outData: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let current = Looper.forThread else { return ALOOPER_POLL_ERROR }
    if timeout <= 0 {
        var result: Int32
        repeat {
            result = current.pollOnce(timeout: timeout, outFd: outFd, outEvents: outEvents, outData: outData)
        } while result == ALOOPER_POLL_CALLBACK
        return result
    }
    let deadline = milliseconds() + Int64(timeout)
    var remaining = timeout
    while true {
        let result = current.pollOnce(timeout: remaining, outFd: outFd, outEvents: outEvents, outData: outData)
        guard result == ALOOPER_POLL_CALLBACK else { return result }
        remaining = Int32(deadline - milliseconds())
        if remaining <= 0 {
            return ALOOPER_POLL_TIMEOUT
        }
    }
}
