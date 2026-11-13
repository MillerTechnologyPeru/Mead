import Glibc
import MeadInterface
import MeadJNI
import MeadJava
import MeadWindow

/// An ANativeWindow over an SDL window.
public final class NativeWindow {
    /// The SDL_Window; nil only for a window made in a test.
    public let handle: SDL.Pointer?
    var bufferWidth: Int32 = 0
    var bufferHeight: Int32 = 0
    var format: Int32 = 1 // WINDOW_FORMAT_RGBA_8888
    private let fallbackWidth: Int32
    private let fallbackHeight: Int32

    public init(handle: SDL.Pointer?, width: Int32, height: Int32) {
        self.handle = handle
        fallbackWidth = width
        fallbackHeight = height
    }

    private var windowSize: (width: Int32, height: Int32) {
        var width = fallbackWidth, height = fallbackHeight
        if let handle {
            _ = SDL.getWindowSizeInPixels(handle, &width, &height)
        }
        return (width, height)
    }

    /// The window's own size in pixels, whatever buffer size the game asked for.
    var pixelWidth: Int32 { windowSize.width }
    var pixelHeight: Int32 { windowSize.height }

    /// Pixels per SDL point, which is what SDL's mouse positions are in.
    var pixelsPerPoint: Float {
        var points = (width: Int32(0), height: Int32(0))
        guard let handle, SDL.getWindowSize(handle, &points.width, &points.height), points.width > 0 else { return 1 }
        return Float(windowSize.width) / Float(points.width)
    }

    var width: Int32 { bufferWidth > 0 ? bufferWidth : windowSize.width }
    var height: Int32 { bufferHeight > 0 ? bufferHeight : windowSize.height }

    var pointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// MEAD_FULLSCREEN=1: the window covers the screen, as an Android app
    /// does, for a handheld whose compositor would otherwise tile it.
    static var fullscreenFlag: UInt64 {
        guard let value = getenv("MEAD_FULLSCREEN"), String(cString: value) != "0" else { return 0 }
        return MEAD_SDL_WINDOW_FULLSCREEN
    }

    /// The window the running app was given.
    nonisolated(unsafe) static var current: NativeWindow?

    // On Wayland EGL draws to a wl_egl_window, which SDL only makes for its
    // own OpenGL windows; Mead's window is left to whichever API the game
    // picks, so it makes its own.
    private var waylandEGLWindow: UnsafeMutableRawPointer?

    private static let waylandEGL = dlopen("libwayland-egl.so.1", RTLD_NOW)

    /// What the host calls this window.
    func describe(_ out: UnsafeMutablePointer<mead_native_window>) -> Bool {
        out.pointee = mead_native_window()
        guard let handle else { return false }
        let properties = SDL.getWindowProperties(handle)
        if let display = SDL.getPointerProperty(properties, MEAD_SDL_PROP_X11_DISPLAY, nil) {
            out.pointee.kind = UInt32(MEAD_NATIVE_WINDOW_X11)
            out.pointee.display = display
            out.pointee.window = UInt(SDL.getNumberProperty(properties, MEAD_SDL_PROP_X11_WINDOW, 0))
            return true
        }
        if let display = SDL.getPointerProperty(properties, MEAD_SDL_PROP_WAYLAND_DISPLAY, nil),
           let surface = SDL.getPointerProperty(properties, MEAD_SDL_PROP_WAYLAND_SURFACE, nil) {
            out.pointee.kind = UInt32(MEAD_NATIVE_WINDOW_WAYLAND)
            out.pointee.display = display
            out.pointee.window = UInt(bitPattern: surface)
            out.pointee.egl_window = SDL.getPointerProperty(properties, MEAD_SDL_PROP_WAYLAND_EGL_WINDOW, nil)
                ?? makeWaylandEGLWindow(surface)
            return true
        }
        return false
    }

    private func makeWaylandEGLWindow(_ surface: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
        if let waylandEGLWindow {
            return waylandEGLWindow
        }
        typealias Create = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> UnsafeMutableRawPointer?
        guard let library = NativeWindow.waylandEGL, let symbol = dlsym(library, "wl_egl_window_create") else { return nil }
        let size = windowPixels
        waylandEGLWindow = unsafeBitCast(symbol, to: Create.self)(surface, size.width, size.height)
        return waylandEGLWindow
    }

    private var windowPixels: (width: Int32, height: Int32) { windowSize }

    /// Tells a Wayland EGL window the window's new size; X11 needs no telling.
    func windowWasResized() {
        typealias Resize = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, Int32) -> Void
        guard let waylandEGLWindow, let library = NativeWindow.waylandEGL,
              let symbol = dlsym(library, "wl_egl_window_resize") else { return }
        let size = windowPixels
        unsafeBitCast(symbol, to: Resize.self)(waylandEGLWindow, size.width, size.height, 0, 0)
    }
}

/// Under ART an app's ANativeWindows are libgui's surfaces (android::Surface),
/// from `ANativeWindow_fromSurface`: the NDK's calls on them go to the
/// runtime's libnativewindow, and EGL and Vulkan draw to the windowing
/// system's window behind each, as hwui's EGL does.
struct ARTNativeWindow {
    typealias FromJava = @convention(c) (UnsafeMutableRawPointer, OpaquePointer?) -> UnsafeMutableRawPointer?
    typealias Retain = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Get = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias SetGeometry = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32) -> Int32
    typealias Lock = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias NativeWindow = @convention(c) (UnsafeMutableRawPointer) -> UInt
    typealias NativeDisplay = @convention(c) (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Void

    let fromJava: FromJava
    let acquire: Retain
    let release: Retain
    let getWidth: Get
    let getHeight: Get
    let getFormat: Get
    let setBuffersGeometry: SetGeometry
    let lock: Lock
    let unlockAndPost: Get
    let setBuffersTransform: Set
    let nativeWindow: NativeWindow
    let nativeDisplay: NativeDisplay

    /// The runtime's window API when ART has loaded it; an app's native code
    /// only runs after it has, so the answer is kept.
    static let shared: ARTNativeWindow? = {
        guard let runtime = dlopen("libandroid_runtime.so", RTLD_NOW | RTLD_NOLOAD),
              let windows = dlopen("libnativewindow.so", RTLD_NOW | RTLD_NOLOAD),
              let gui = dlopen("libgui.so", RTLD_NOW | RTLD_NOLOAD) else { return nil }
        func symbol<T>(_ library: UnsafeMutableRawPointer, _ name: String, _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let fromJava = symbol(runtime, "mead_surface_from_java", FromJava.self),
              let acquire = symbol(windows, "ANativeWindow_acquire", Retain.self),
              let release = symbol(windows, "ANativeWindow_release", Retain.self),
              let getWidth = symbol(windows, "ANativeWindow_getWidth", Get.self),
              let getHeight = symbol(windows, "ANativeWindow_getHeight", Get.self),
              let getFormat = symbol(windows, "ANativeWindow_getFormat", Get.self),
              let setBuffersGeometry = symbol(windows, "ANativeWindow_setBuffersGeometry", SetGeometry.self),
              let lock = symbol(windows, "ANativeWindow_lock", Lock.self),
              let unlockAndPost = symbol(windows, "ANativeWindow_unlockAndPost", Get.self),
              let setBuffersTransform = symbol(windows, "ANativeWindow_setBuffersTransform", Set.self),
              let nativeWindow = symbol(gui, "mead_surface_get_native_window", NativeWindow.self),
              let nativeDisplay = symbol(gui, "mead_gui_get_native_display", NativeDisplay.self) else { return nil }
        return ARTNativeWindow(fromJava: fromJava, acquire: acquire, release: release, getWidth: getWidth,
                               getHeight: getHeight, getFormat: getFormat, setBuffersGeometry: setBuffersGeometry,
                               lock: lock, unlockAndPost: unlockAndPost, setBuffersTransform: setBuffersTransform,
                               nativeWindow: nativeWindow, nativeDisplay: nativeDisplay)
    }()

    /// The runtime's API when `pointer` is one of its surfaces: an
    /// ANativeWindow starts with its magic, '_wnd', where a NativeWindow
    /// starts with its class.
    static func owning(_ pointer: UnsafeMutableRawPointer) -> ARTNativeWindow? {
        guard let shared, pointer.load(as: UInt32.self) == 0x5f77_6e64 else { return nil }
        return shared
    }

    /// What the host calls a surface's window: its wl_egl_window (and the
    /// wl_surface under it, for Vulkan) or X11 Window, on the display hwui's
    /// EGL uses, which made it. Without a surface, only that display, for
    /// eglGetDisplay(EGL_DEFAULT_DISPLAY): EGL on another connection could
    /// not draw to the windows.
    func describe(_ pointer: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<mead_native_window>) -> Bool {
        out.pointee = mead_native_window()
        var kind: UInt32 = 0
        var display: UnsafeMutableRawPointer?
        nativeDisplay(&kind, &display)
        guard let display, kind == 1 || kind == 2 else { return false }
        out.pointee.display = display
        guard let pointer else {
            out.pointee.kind = UInt32(kind == 1 ? MEAD_NATIVE_WINDOW_X11 : MEAD_NATIVE_WINDOW_WAYLAND)
            return true
        }
        let window = nativeWindow(pointer)
        guard window != 0 else { return false }
        switch kind {
        case 1: // MEAD_GUI_NATIVE_X11
            out.pointee.kind = UInt32(MEAD_NATIVE_WINDOW_X11)
            out.pointee.window = window
        case 2: // MEAD_GUI_NATIVE_WAYLAND
            guard let eglWindow = UnsafeMutableRawPointer(bitPattern: window) else { return false }
            out.pointee.kind = UInt32(MEAD_NATIVE_WINDOW_WAYLAND)
            out.pointee.egl_window = eglWindow
            // wayland-egl-backend.h's struct wl_egl_window, version 3 on:
            // version, six ints, driver_private, two callbacks, surface.
            if eglWindow.load(as: Int.self) >= 3 {
                out.pointee.window = eglWindow.load(fromByteOffset: 56, as: UInt.self)
            }
        default:
            return false
        }
        return true
    }
}

@_cdecl("mead_android_window_native")
public func meadAndroidWindowNative(_ pointer: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<mead_native_window>) -> Bool {
    if let pointer, let art = ARTNativeWindow.owning(pointer) { return art.describe(pointer, out) }
    if pointer == nil, NativeWindow.current == nil, let art = ARTNativeWindow.shared { return art.describe(nil, out) }
    let target = pointer.map { Unmanaged<NativeWindow>.fromOpaque($0).takeUnretainedValue() } ?? NativeWindow.current
    guard let target else { return false }
    return target.describe(out)
}

private func window(_ pointer: UnsafeMutableRawPointer) -> NativeWindow {
    Unmanaged<NativeWindow>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("ANativeWindow_acquire")
public func ANativeWindow_acquire(_ pointer: UnsafeMutableRawPointer) {
    if let art = ARTNativeWindow.owning(pointer) { return art.acquire(pointer) }
    _ = Unmanaged<NativeWindow>.fromOpaque(pointer).retain()
}

@_cdecl("ANativeWindow_release")
public func ANativeWindow_release(_ pointer: UnsafeMutableRawPointer) {
    if let art = ARTNativeWindow.owning(pointer) { return art.release(pointer) }
    Unmanaged<NativeWindow>.fromOpaque(pointer).release()
}

@_cdecl("ANativeWindow_getWidth")
public func ANativeWindow_getWidth(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    ARTNativeWindow.owning(pointer)?.getWidth(pointer) ?? window(pointer).width
}

@_cdecl("ANativeWindow_getHeight")
public func ANativeWindow_getHeight(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    ARTNativeWindow.owning(pointer)?.getHeight(pointer) ?? window(pointer).height
}

@_cdecl("ANativeWindow_getFormat")
public func ANativeWindow_getFormat(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    ARTNativeWindow.owning(pointer)?.getFormat(pointer) ?? window(pointer).format
}

@_cdecl("ANativeWindow_setBuffersGeometry")
public func ANativeWindow_setBuffersGeometry(_ pointer: UnsafeMutableRawPointer, _ width: Int32, _ height: Int32, _ format: Int32) -> Int32 {
    if let art = ARTNativeWindow.owning(pointer) { return art.setBuffersGeometry(pointer, width, height, format) }
    let target = window(pointer)
    JavaRuntime.shared.trace("ANativeWindow_setBuffersGeometry \(width)x\(height), the window being \(target.pixelWidth)x\(target.pixelHeight)")
    target.bufferWidth = width
    target.bufferHeight = height
    if format != 0 {
        target.format = format
    }
    return 0
}

@_cdecl("ANativeWindow_fromSurface")
public func ANativeWindow_fromSurface(_ env: UnsafeMutableRawPointer, _ surface: OpaquePointer?) -> UnsafeMutableRawPointer? {
    // Under ART env is ART's, and the surface's window is libgui's.
    if let art = ARTNativeWindow.shared {
        guard let window = art.fromJava(env, surface) else { return nil }
        art.acquire(window)
        return window
    }
    guard let held = (JavaThread.from(env).resolve(surface) as? JavaSurface)?.nativeWindow else { return nil }
    ANativeWindow_acquire(held)
    return held
}

@_cdecl("ANativeWindow_toSurface")
public func ANativeWindow_toSurface(_ env: UnsafeMutableRawPointer, _ pointer: UnsafeMutableRawPointer) -> OpaquePointer? {
    ANativeWindow_acquire(pointer)
    return JavaThread.from(env).newLocal(JavaSurface(nativeWindow: pointer))
}

/// Drawing on the CPU to a surface, under ART; a NativeWindow (SDL's) has
/// no buffers to lock.
@_cdecl("ANativeWindow_lock")
public func ANativeWindow_lock(_ pointer: UnsafeMutableRawPointer, _ buffer: UnsafeMutableRawPointer?,
                               _ dirty: UnsafeMutableRawPointer?) -> Int32 {
    ARTNativeWindow.owning(pointer)?.lock(pointer, buffer, dirty) ?? -EINVAL
}

@_cdecl("ANativeWindow_unlockAndPost")
public func ANativeWindow_unlockAndPost(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    ARTNativeWindow.owning(pointer)?.unlockAndPost(pointer) ?? -EINVAL
}

@_cdecl("ANativeWindow_setBuffersTransform")
public func ANativeWindow_setBuffersTransform(_ pointer: UnsafeMutableRawPointer, _ transform: Int32) -> Int32 {
    ARTNativeWindow.owning(pointer)?.setBuffersTransform(pointer, transform) ?? (transform == 0 ? 0 : -EINVAL)
}

/// The SDL_Window behind an ANativeWindow, for the EGL and Vulkan providers;
/// none for a surface of ART's.
@_cdecl("mead_android_window_handle")
public func meadAndroidWindowHandle(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    if ARTNativeWindow.owning(pointer) != nil { return nil }
    return window(pointer).handle
}


