internal import CSwiftJavaJNI
import Glibc
import MeadWindow
internal import SwiftJavaJNICore

/// Mead's display bridge for ART: SDL windows as the framework's surfaces.
///
/// Mead's libgui (art_standalone's `frameworks/mead/gui`, interface in
/// `mead/gui.h`) stands where SurfaceFlinger is on Android. This fills it in:
/// the display it describes, the windowing connection hwui's EGL display is
/// made on, and for each window a surface whose software frames
/// (`Surface.lockCanvas`) this copies to the window, and whose native window
/// hwui's GL pipeline renders to (`Surface.lockHardwareCanvas`,
/// `HardwareRenderer`).
///
/// Until the window manager (phase 5) hands out surfaces, Java asks for a
/// window through `mead.view.MeadWindow`, whose natives this registers when
/// the app has that class.
final class ARTDisplay {
    /// libgui's and libandroid_runtime's functions for the bridge.
    private struct Functions {
        typealias SetDisplay = @convention(c) (UnsafeRawPointer) -> Void
        typealias SetNativeDisplay = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Void
        typealias CreateSurface = @convention(c) (UInt32, UInt32, Int32, UnsafeRawPointer) -> UnsafeMutableRawPointer?
        typealias SetNativeWindow = @convention(c) (UnsafeMutableRawPointer, UInt) -> Void
        typealias ResizeSurface = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Void
        typealias SurfaceToJava = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, UnsafeMutableRawPointer) -> jobject?

        let setDisplay: SetDisplay
        let setNativeDisplay: SetNativeDisplay
        let createSurface: CreateSurface
        let setNativeWindow: SetNativeWindow
        let resizeSurface: ResizeSurface
        let surfaceToJava: SurfaceToJava

        init(gui: UnsafeMutableRawPointer, runtime: UnsafeMutableRawPointer) throws {
            func symbol<T>(_ library: UnsafeMutableRawPointer, _ name: String) throws -> T {
                guard let found = dlsym(library, name) else { throw ART.Failure("no \(name) for Mead's display bridge") }
                return unsafeBitCast(found, to: T.self)
            }
            setDisplay = try symbol(gui, "mead_gui_set_display")
            setNativeDisplay = try symbol(gui, "mead_gui_set_native_display")
            createSurface = try symbol(gui, "mead_surface_create")
            setNativeWindow = try symbol(gui, "mead_surface_set_native_window")
            resizeSurface = try symbol(gui, "mead_surface_resize")
            surfaceToJava = try symbol(runtime, "mead_surface_to_java")
        }
    }

    /// A window and the surface drawing to it.
    final class Window {
        let handle: SDL.Pointer
        let native: SDLNativeWindow?
        /// The surface, an ANativeWindow from `mead_surface_create`.
        var surface: UnsafeMutableRawPointer?
        private var frames = 0

        init(handle: SDL.Pointer) {
            self.handle = handle
            native = SDLNativeWindow(handle)
        }

        /// A software frame, in Android's RGBA 8888 or RGBX 8888, copied to
        /// the window.
        func present(_ pixels: UnsafeRawPointer, width: UInt32, height: UInt32, stride: UInt32, format: Int32) {
            defer { frames += 1 }
            // HAL_PIXEL_FORMAT_RGBA_8888 and RGBX_8888: R, G, B, A in memory.
            guard format == 1 || format == 2 else { return }
            if frames % 60 == 0, let path = getenv("MEAD_FRAME_DUMP") {
                Self.dump(pixels, width: width, height: height, stride: stride, to: String(cString: path))
            }
            guard let target = SDL.getWindowSurface(handle) else { return }
            let width = min(Int32(width), target.pointee.w)
            let height = min(Int32(height), target.pointee.h)
            _ = SDL.convertPixels(width, height, MEAD_SDL_PIXELFORMAT_ABGR8888, pixels, Int32(stride) * 4,
                                  target.pointee.format, target.pointee.pixels, target.pointee.pitch)
            _ = SDL.updateWindowSurface(handle)
            SDL.pumpEvents()
        }

        /// MEAD_FRAME_DUMP=path: the frame as a binary PPM, every 60 frames
        /// from the first, as Mead's EGL provider and hwui write theirs.
        private static func dump(_ pixels: UnsafeRawPointer, width: UInt32, height: UInt32, stride: UInt32, to path: String) {
            guard let file = fopen(path, "wb") else { return }
            defer { fclose(file) }
            fputs("P6\n\(width) \(height)\n255\n", file)
            var row = [UInt8](repeating: 0, count: Int(width) * 3)
            for y in 0..<Int(height) {
                let source = pixels.advanced(by: y * Int(stride) * 4).assumingMemoryBound(to: UInt8.self)
                for x in 0..<Int(width) {
                    row[x * 3] = source[x * 4]
                    row[x * 3 + 1] = source[x * 4 + 1]
                    row[x * 3 + 2] = source[x * 4 + 2]
                }
                _ = row.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
            }
        }
    }

    private let functions: Functions
    private var windows: [Window] = []
    private var displayDescribed = false

    nonisolated(unsafe) static var shared: ARTDisplay?

    /// The bridge for the libgui and libandroid_runtime installed at `home`,
    /// which ART has loaded.
    init(home: String) throws {
        let flags = RTLD_NOW | RTLD_NOLOAD
        guard let gui = dlopen("\(home)/lib/art/libgui.so", flags) else {
            throw ART.Failure("libgui isn't loaded: \(String(cString: dlerror()))")
        }
        guard let runtime = dlopen("\(home)/lib/java/dex/art/natives/libandroid_runtime.so", flags) else {
            throw ART.Failure("libandroid_runtime isn't loaded: \(String(cString: dlerror()))")
        }
        functions = try Functions(gui: gui, runtime: runtime)
    }

    /// A new window titled `title`, of width×height pixels, as an
    /// `android.view.Surface`; nil, with the reason on standard error, when
    /// there's no window to be had.
    func createSurface(env: UnsafeMutablePointer<JNIEnv?>?, title: String, width: Int32, height: Int32) -> jobject? {
        guard SDL.loadOnce(), SDL.initialize(UInt32(MEAD_SDL_INIT_VIDEO) | UInt32(MEAD_SDL_INIT_EVENTS)) else {
            Self.report("SDL: \(SDL.lastError)")
            return nil
        }
        guard let handle = SDL.createWindow(title, width, height, 0) else {
            Self.report("no window: \(SDL.lastError)")
            return nil
        }
        let window = Window(handle: handle)
        describeDisplay(for: window)

        var pixelWidth = width, pixelHeight = height
        _ = SDL.getWindowSizeInPixels(handle, &pixelWidth, &pixelHeight)
        // MeadSurfaceCallbacks: the context, then present.
        typealias Present = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, UInt32, UInt32, Int32) -> Void
        let present: Present = { context, pixels, width, height, stride, format in
            guard let context, let pixels else { return }
            Unmanaged<Window>.fromOpaque(context).takeUnretainedValue()
                .present(pixels, width: width, height: height, stride: stride, format: format)
        }
        let callbacks = UnsafeMutableRawPointer.allocate(byteCount: 2 * MemoryLayout<UnsafeRawPointer>.size,
                                                         alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { callbacks.deallocate() }
        callbacks.storeBytes(of: Unmanaged.passUnretained(window).toOpaque(), as: UnsafeMutableRawPointer.self)
        callbacks.storeBytes(of: unsafeBitCast(present, to: UnsafeRawPointer.self),
                             toByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafeRawPointer.self)
        // HAL_PIXEL_FORMAT_RGBA_8888.
        guard let surface = functions.createSurface(UInt32(pixelWidth), UInt32(pixelHeight), 1, callbacks) else {
            Self.report("no surface for the window")
            SDL.destroyWindow(handle)
            return nil
        }
        window.surface = surface
        if let native = window.native {
            functions.setNativeWindow(surface, native.eglWindow)
        }
        windows.append(window)
        // The Java Surface holds its own reference; the window keeps the one
        // mead_surface_create gave.
        return functions.surfaceToJava(env, surface)
    }

    /// The display and windowing connection libgui reports, from the first
    /// window's.
    private func describeDisplay(for window: Window) {
        guard !displayDescribed else { return }
        displayDescribed = true
        if let native = window.native {
            functions.setNativeDisplay(native.kind.rawValue, native.display)
        }
        let display = SDL.getPrimaryDisplay()
        guard display != 0, let mode = SDL.getCurrentDisplayMode(display) else { return }
        let scale = max(SDL.getDisplayContentScale(display), 1)
        // MeadDisplay: width and height in pixels, xdpi, ydpi, refresh rate,
        // and density (1 at 160 dpi).
        var described = [UInt32](repeating: 0, count: 6)
        described[0] = UInt32(mode.pointee.w)
        described[1] = UInt32(mode.pointee.h)
        described[2] = (160 * scale).bitPattern
        described[3] = (160 * scale).bitPattern
        described[4] = (mode.pointee.refresh_rate > 0 ? mode.pointee.refresh_rate : 60).bitPattern
        described[5] = scale.bitPattern
        described.withUnsafeBytes { functions.setDisplay($0.baseAddress!) }
    }

    /// Registers `mead.view.MeadWindow`'s natives, when the app has the class.
    func registerNatives(env: JNIEnvironment) {
        guard let jni = env.pointee?.pointee else { return }
        guard let type = jni.FindClass(env, "mead/view/MeadWindow") else {
            jni.ExceptionClear(env)
            return
        }
        typealias Create = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?, jstring?, jint, jint) -> jobject?
        let create: Create = { env, _, title, width, height in
            guard let env, let jni = env.pointee?.pointee, let display = ARTDisplay.shared else { return nil }
            var name = "Mead"
            if let title, let characters = jni.GetStringUTFChars(env, title, nil) {
                name = String(cString: characters)
                jni.ReleaseStringUTFChars(env, title, characters)
            }
            return display.createSurface(env: env, title: name, width: width, height: height)
        }
        "create".withCString { name in
            "(Ljava/lang/String;II)Landroid/view/Surface;".withCString { signature in
                var method = JNINativeMethod(name: name, signature: signature,
                                             fnPtr: unsafeBitCast(create, to: UnsafeMutableRawPointer.self))
                if jni.RegisterNatives(env, type, &method, 1) != JNI_OK {
                    jni.ExceptionClear(env)
                    Self.report("mead.view.MeadWindow's natives didn't register")
                }
            }
        }
        jni.DeleteLocalRef(env, type)
    }

    private static func report(_ message: String) {
        var line = "mead: display: \(message)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
    }
}
