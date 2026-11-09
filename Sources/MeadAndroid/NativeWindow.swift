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

@_cdecl("mead_android_window_native")
public func meadAndroidWindowNative(_ pointer: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<mead_native_window>) -> Bool {
    let target = pointer.map { Unmanaged<NativeWindow>.fromOpaque($0).takeUnretainedValue() } ?? NativeWindow.current
    guard let target else { return false }
    return target.describe(out)
}

private func window(_ pointer: UnsafeMutableRawPointer) -> NativeWindow {
    Unmanaged<NativeWindow>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("ANativeWindow_acquire")
public func ANativeWindow_acquire(_ pointer: UnsafeMutableRawPointer) {
    _ = Unmanaged<NativeWindow>.fromOpaque(pointer).retain()
}

@_cdecl("ANativeWindow_release")
public func ANativeWindow_release(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<NativeWindow>.fromOpaque(pointer).release()
}

@_cdecl("ANativeWindow_getWidth")
public func ANativeWindow_getWidth(_ pointer: UnsafeMutableRawPointer) -> Int32 { window(pointer).width }

@_cdecl("ANativeWindow_getHeight")
public func ANativeWindow_getHeight(_ pointer: UnsafeMutableRawPointer) -> Int32 { window(pointer).height }

@_cdecl("ANativeWindow_getFormat")
public func ANativeWindow_getFormat(_ pointer: UnsafeMutableRawPointer) -> Int32 { window(pointer).format }

@_cdecl("ANativeWindow_setBuffersGeometry")
public func ANativeWindow_setBuffersGeometry(_ pointer: UnsafeMutableRawPointer, _ width: Int32, _ height: Int32, _ format: Int32) -> Int32 {
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
    guard let held = (JavaThread.from(env).resolve(surface) as? JavaSurface)?.nativeWindow else { return nil }
    ANativeWindow_acquire(held)
    return held
}

@_cdecl("ANativeWindow_toSurface")
public func ANativeWindow_toSurface(_ env: UnsafeMutableRawPointer, _ pointer: UnsafeMutableRawPointer) -> OpaquePointer? {
    ANativeWindow_acquire(pointer)
    return JavaThread.from(env).newLocal(JavaSurface(nativeWindow: pointer))
}

/// The SDL_Window behind an ANativeWindow, for the EGL and Vulkan providers.
@_cdecl("mead_android_window_handle")
public func meadAndroidWindowHandle(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    window(pointer).handle
}


