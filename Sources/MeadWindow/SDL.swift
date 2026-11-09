@_exported import CMeadWindow
import Glibc

/// The SDL3 functions Mead calls, from the library found at run time, so
/// that a build needs no SDL and a game that opens no window loads none.
public enum SDL {
    public typealias Pointer = UnsafeMutableRawPointer
    public typealias EventPointer = UnsafeMutablePointer<mead_sdl_event>

    public nonisolated(unsafe) static var initialize: (@convention(c) (UInt32) -> Bool)!
    public nonisolated(unsafe) static var quit: (@convention(c) () -> Void)!
    public nonisolated(unsafe) static var getError: (@convention(c) () -> UnsafePointer<CChar>?)!
    public nonisolated(unsafe) static var createWindow: (@convention(c) (UnsafePointer<CChar>, Int32, Int32, UInt64) -> Pointer?)!
    public nonisolated(unsafe) static var destroyWindow: (@convention(c) (Pointer?) -> Void)!
    public nonisolated(unsafe) static var getWindowSizeInPixels: (@convention(c) (Pointer?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Bool)!
    public nonisolated(unsafe) static var waitEventTimeout: (@convention(c) (EventPointer?, Int32) -> Bool)!
    public nonisolated(unsafe) static var pushEvent: (@convention(c) (EventPointer?) -> Bool)!

    public static var lastError: String {
        getError?().map { String(cString: $0) } ?? "SDL is not loaded"
    }

    nonisolated(unsafe) private static var loaded: Bool?

    public static func loadOnce() -> Bool {
        if let loaded { return loaded }
        let result = load()
        loaded = result
        return result
    }

    private static func load() -> Bool {
        guard let library = dlopen("libSDL3.so.0", RTLD_NOW) else { return false }
        var complete = true
        func bind<T>(_ name: String) -> T? {
            guard let symbol = dlsym(library, name) else {
                complete = false
                return nil
            }
            return unsafeBitCast(symbol, to: T.self)
        }
        initialize = bind("SDL_Init")
        quit = bind("SDL_Quit")
        getError = bind("SDL_GetError")
        createWindow = bind("SDL_CreateWindow")
        destroyWindow = bind("SDL_DestroyWindow")
        getWindowSizeInPixels = bind("SDL_GetWindowSizeInPixels")
        waitEventTimeout = bind("SDL_WaitEventTimeout")
        pushEvent = bind("SDL_PushEvent")
        return complete
    }
}
