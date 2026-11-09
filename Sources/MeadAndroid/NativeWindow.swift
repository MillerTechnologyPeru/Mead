import Glibc
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

    var width: Int32 { bufferWidth > 0 ? bufferWidth : windowSize.width }
    var height: Int32 { bufferHeight > 0 ? bufferHeight : windowSize.height }

    var pointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
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
