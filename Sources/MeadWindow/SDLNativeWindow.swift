import CMeadWindow
import Glibc

/// The windowing system's window behind an SDL window, for drawing to it
/// with EGL: an X11 window, or a Wayland surface with its `wl_egl_window`.
public final class SDLNativeWindow {
    /// The windowing systems, numbered as Mead's libgui and its providers
    /// number them.
    public enum Kind: UInt32 {
        case x11 = 1
        case wayland = 2
    }

    public let kind: Kind
    /// X11's Display, or the wl_display.
    public let display: UnsafeMutableRawPointer
    /// What EGL draws to: the X11 Window, or the `wl_egl_window`.
    public let eglWindow: UInt
    /// The `wl_egl_window` this made, which it resizes; nil when SDL made it
    /// or on X11.
    private let ownWaylandEGLWindow: UnsafeMutableRawPointer?

    nonisolated(unsafe) private static let waylandEGL = dlopen("libwayland-egl.so.1", RTLD_NOW)

    /// The window behind `window`, or nil on a windowing system Mead doesn't
    /// know.
    public init?(_ window: SDL.Pointer) {
        let properties = SDL.getWindowProperties(window)
        if let display = SDL.getPointerProperty(properties, MEAD_SDL_PROP_X11_DISPLAY, nil) {
            kind = .x11
            self.display = display
            eglWindow = UInt(SDL.getNumberProperty(properties, MEAD_SDL_PROP_X11_WINDOW, 0))
            ownWaylandEGLWindow = nil
            return
        }
        guard let display = SDL.getPointerProperty(properties, MEAD_SDL_PROP_WAYLAND_DISPLAY, nil),
              let surface = SDL.getPointerProperty(properties, MEAD_SDL_PROP_WAYLAND_SURFACE, nil) else {
            return nil
        }
        kind = .wayland
        self.display = display
        // EGL draws to a wl_egl_window, which SDL makes only for its own
        // OpenGL windows.
        if let made = SDL.getPointerProperty(properties, MEAD_SDL_PROP_WAYLAND_EGL_WINDOW, nil) {
            eglWindow = UInt(bitPattern: made)
            ownWaylandEGLWindow = nil
            return
        }
        typealias Create = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> UnsafeMutableRawPointer?
        var width: Int32 = 0, height: Int32 = 0
        _ = SDL.getWindowSizeInPixels(window, &width, &height)
        guard let library = Self.waylandEGL, let create = dlsym(library, "wl_egl_window_create"),
              let made = unsafeBitCast(create, to: Create.self)(surface, width, height) else {
            return nil
        }
        eglWindow = UInt(bitPattern: made)
        ownWaylandEGLWindow = made
    }

    /// Tells the `wl_egl_window` the window's new size; X11 needs no telling.
    public func resize(width: Int32, height: Int32) {
        typealias Resize = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, Int32) -> Void
        guard let ownWaylandEGLWindow, let library = Self.waylandEGL,
              let resize = dlsym(library, "wl_egl_window_resize") else { return }
        unsafeBitCast(resize, to: Resize.self)(ownWaylandEGLWindow, width, height, 0, 0)
    }

    deinit {
        typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
        guard let ownWaylandEGLWindow, let library = Self.waylandEGL,
              let destroy = dlsym(library, "wl_egl_window_destroy") else { return }
        unsafeBitCast(destroy, to: Destroy.self)(ownWaylandEGLWindow)
    }
}
