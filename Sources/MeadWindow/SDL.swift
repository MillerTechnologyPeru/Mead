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
    public nonisolated(unsafe) static var startTextInput: (@convention(c) (Pointer?) -> Bool)!
    public nonisolated(unsafe) static var stopTextInput: (@convention(c) (Pointer?) -> Bool)!
    public nonisolated(unsafe) static var setWindowRelativeMouseMode: (@convention(c) (Pointer?, Bool) -> Bool)!
    public nonisolated(unsafe) static var getWindowSize: (@convention(c) (Pointer?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Bool)!
    public nonisolated(unsafe) static var getWindowSizeInPixels: (@convention(c) (Pointer?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Bool)!
    public nonisolated(unsafe) static var getWindowProperties: (@convention(c) (Pointer?) -> UInt32)!
    public nonisolated(unsafe) static var getPointerProperty: (@convention(c) (UInt32, UnsafePointer<CChar>, Pointer?) -> Pointer?)!
    public nonisolated(unsafe) static var getNumberProperty: (@convention(c) (UInt32, UnsafePointer<CChar>, Int64) -> Int64)!
    public nonisolated(unsafe) static var waitEventTimeout: (@convention(c) (EventPointer?, Int32) -> Bool)!
    public nonisolated(unsafe) static var openGamepad: (@convention(c) (UInt32) -> Pointer?)!
    public nonisolated(unsafe) static var closeGamepad: (@convention(c) (Pointer?) -> Void)!
    public nonisolated(unsafe) static var pushEvent: (@convention(c) (EventPointer?) -> Bool)!
    public nonisolated(unsafe) static var pumpEvents: (@convention(c) () -> Void)!
    public nonisolated(unsafe) static var getWindowSurface: (@convention(c) (Pointer?) -> UnsafeMutablePointer<mead_sdl_surface>?)!
    public nonisolated(unsafe) static var updateWindowSurface: (@convention(c) (Pointer?) -> Bool)!
    public nonisolated(unsafe) static var convertPixels: (@convention(c) (Int32, Int32, UInt32, UnsafeRawPointer?, Int32, UInt32, Pointer?, Int32) -> Bool)!
    public nonisolated(unsafe) static var getPrimaryDisplay: (@convention(c) () -> UInt32)!
    public nonisolated(unsafe) static var getCurrentDisplayMode: (@convention(c) (UInt32) -> UnsafePointer<mead_sdl_display_mode>?)!
    public nonisolated(unsafe) static var getDisplayContentScale: (@convention(c) (UInt32) -> Float)!

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
        getWindowSize = bind("SDL_GetWindowSize")
        setWindowRelativeMouseMode = bind("SDL_SetWindowRelativeMouseMode")
        startTextInput = bind("SDL_StartTextInput")
        stopTextInput = bind("SDL_StopTextInput")
        getWindowSizeInPixels = bind("SDL_GetWindowSizeInPixels")
        getWindowProperties = bind("SDL_GetWindowProperties")
        getPointerProperty = bind("SDL_GetPointerProperty")
        getNumberProperty = bind("SDL_GetNumberProperty")
        waitEventTimeout = bind("SDL_WaitEventTimeout")
        openGamepad = bind("SDL_OpenGamepad")
        closeGamepad = bind("SDL_CloseGamepad")
        pushEvent = bind("SDL_PushEvent")
        pumpEvents = bind("SDL_PumpEvents")
        getWindowSurface = bind("SDL_GetWindowSurface")
        updateWindowSurface = bind("SDL_UpdateWindowSurface")
        convertPixels = bind("SDL_ConvertPixels")
        getPrimaryDisplay = bind("SDL_GetPrimaryDisplay")
        getCurrentDisplayMode = bind("SDL_GetCurrentDisplayMode")
        getDisplayContentScale = bind("SDL_GetDisplayContentScale")
        return complete
    }
}
