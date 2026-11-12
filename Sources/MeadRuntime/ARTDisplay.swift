internal import CSwiftJavaJNI
import CMeadWayland
import Glibc
import MeadWindow
internal import SwiftJavaJNICore

/// Mead's display bridge for ART: Wayland windows as the framework's
/// surfaces, and the seat's and SDL's gamepads' input as the framework's
/// input events.
///
/// Mead's libgui (art_standalone's `frameworks/mead/gui`, interface in
/// `mead/gui.h`) stands where SurfaceFlinger is on Android. This fills it in:
/// the display it describes (from Wayland's outputs), the windowing
/// connection hwui's EGL display is made on, and for each window a surface
/// whose CPU frames (`Surface.lockCanvas`, `ANativeWindow_lock`) are shown in
/// place as `wl_shm` buffers, and whose `wl_egl_window` hwui's GL pipeline
/// renders to. The Wayland client is `Wayland` (ARTWayland.swift). Each window
/// can have an input channel (`frameworks/mead/android_runtime/include/mead/input.h`),
/// whose client end an `InputEventReceiver` reads, as an app's window gets
/// from the window manager; the keyboard (mapped by Android's `Generic.kl`),
/// the pointer, touches and gamepads arrive on it as `KeyEvent`s and
/// `MotionEvent`s. Choreographer's vsync comes from frame callbacks.
///
/// Wayland is all on the bridge's display thread, which dispatches the
/// connection and does the work handed to it, so that Java's threads are free
/// to run their loopers. SDL has a thread of its own, for gamepads and for
/// the input checks inject, without its video.
///
/// Java asks for a window through the window manager service, or through
/// `mead.view.MeadWindow` for checks; this registers both's natives.
final class ARTDisplay {
    /// What a window is: a top-level window, a dialog over its parent, a
    /// popup (a menu, a dropdown) at a place in its parent, or a layer in
    /// its parent (a SurfaceView's surface).
    enum WindowKind: Int32 {
        case normal = 0
        case dialog = 1
        case popup = 2
        case layer = 3
    }

    /// libgui's and libandroid_runtime's functions for the bridge.
    struct Functions {
        typealias SetDisplay = @convention(c) (UnsafeRawPointer) -> Void
        typealias SetNativeDisplay = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Void
        typealias CreateSurface = @convention(c) (UInt32, UInt32, Int32, UnsafeRawPointer) -> UnsafeMutableRawPointer?
        typealias SetNativeWindow = @convention(c) (UnsafeMutableRawPointer, UInt) -> Void
        typealias ResizeSurface = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Void
        typealias ReleaseBuffer = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        typealias Vsync = @convention(c) (Int64) -> Void
        typealias VsyncRequest = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias SetVsyncRequest = @convention(c) (VsyncRequest, UnsafeMutableRawPointer?) -> Void
        typealias SurfaceToJava = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, UnsafeMutableRawPointer) -> jobject?
        typealias SurfaceFromJava = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jobject?) -> UnsafeMutableRawPointer?
        typealias SetWindowCallbacks = @convention(c) (UnsafeRawPointer) -> Void
        typealias OpenInput = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, UnsafePointer<CChar>, UnsafeMutablePointer<OpaquePointer?>) -> jobject?
        typealias SendKey = @convention(c) (OpaquePointer, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int64, Int64) -> Int32
        typealias SendMotion = @convention(c) (OpaquePointer, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int64, Int64,
                                               UInt32, UnsafePointer<Int32>, UnsafePointer<Int32>, UInt64, UnsafePointer<Float>) -> Int32
        typealias MapKey = @convention(c) (Int32) -> Int32
        typealias InputFromChannel = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jobject?) -> OpaquePointer?
        typealias SurfaceControlCreate = @convention(c) (UnsafeMutableRawPointer) -> Int64
        typealias SetLayerCallbacks = @convention(c) (UnsafeRawPointer) -> Void

        let setDisplay: SetDisplay
        let setNativeDisplay: SetNativeDisplay
        let createSurface: CreateSurface
        let setNativeWindow: SetNativeWindow
        let resizeSurface: ResizeSurface
        let releaseBuffer: ReleaseBuffer
        let vsync: Vsync
        let setVsyncRequest: SetVsyncRequest
        let surfaceToJava: SurfaceToJava
        let surfaceFromJava: SurfaceFromJava
        let setWindowCallbacks: SetWindowCallbacks
        let openInput: OpenInput
        let sendKey: SendKey
        let sendMotion: SendMotion
        let mapKey: MapKey
        let inputFromChannel: InputFromChannel
        let surfaceControlCreate: SurfaceControlCreate
        let setLayerCallbacks: SetLayerCallbacks

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
            releaseBuffer = try symbol(gui, "mead_surface_release_buffer")
            vsync = try symbol(gui, "mead_gui_vsync")
            setVsyncRequest = try symbol(gui, "mead_gui_set_vsync_request")
            surfaceToJava = try symbol(runtime, "mead_surface_to_java")
            surfaceFromJava = try symbol(runtime, "mead_surface_from_java")
            setWindowCallbacks = try symbol(gui, "mead_gui_set_window_callbacks")
            openInput = try symbol(runtime, "mead_input_open")
            sendKey = try symbol(runtime, "mead_input_send_key")
            sendMotion = try symbol(runtime, "mead_input_send_motion")
            mapKey = try symbol(runtime, "mead_input_map_key")
            inputFromChannel = try symbol(runtime, "mead_input_from_channel")
            surfaceControlCreate = try symbol(runtime, "mead_surface_control_create")
            setLayerCallbacks = try symbol(gui, "mead_gui_set_layer_callbacks")
        }
    }

    /// A window, the surface drawing to it and the input channel reading it.
    final class Window {
        let id: UInt32
        let kind: WindowKind
        let parent: Window?
        /// Its place in its parent (a popup's) and its size, in pixels.
        var x: Int32
        var y: Int32
        var width: Int32
        var height: Int32
        var pixelWidth: Int32 { width }
        var pixelHeight: Int32 { height }

        // Its Wayland objects (see Wayland).
        var root: OpaquePointer?
        var xdgSurface: OpaquePointer?
        var toplevel: OpaquePointer?
        var popup: OpaquePointer?
        var decoration: OpaquePointer?
        var rootViewport: OpaquePointer?
        var layer: OpaquePointer?
        var subsurface: OpaquePointer?
        var layerViewport: OpaquePointer?
        /// A clear 1×1 subsurface over everything in the window, whose frame
        /// callbacks are the vsync: a compositor may answer only surfaces it
        /// can see, and a game's opaque layer hides the root.
        var tick: OpaquePointer?
        var tickSubsurface: OpaquePointer?
        var eglWindow: OpaquePointer?
        /// How much the window dims its parent while it's mapped (Android's
        /// FLAG_DIM_BEHIND), and the dim layer over this window when one of
        /// its children dims it.
        var dimAmount: Float = 0
        var dim: OpaquePointer?
        var dimSubsurface: OpaquePointer?
        var dimViewport: OpaquePointer?
        var dimShown: Float = 0
        /// A layer's order in its parent (under its content when negative)
        /// and whether it shows.
        var z: Int32 = -2
        var layerShown = false
        /// A layer's size on screen, in pixels, when its matrix scales its
        /// buffer (a SurfaceView's with a fixed size); nil at its buffer's.
        var shownSize: (width: Int32, height: Int32)?
        var configured = false
        var mapped = false
        /// The size a toplevel's last configure asked for.
        var pendingSize: (width: Int32, height: Int32)?

        /// A gralloc buffer as a wl_buffer, by its libgui slot.
        struct HeldBuffer {
            let fd: Int32
            let width: Int32
            let height: Int32
            let stride: Int32
            let format: UInt32
            let buffer: OpaquePointer
        }

        var buffers: [Int32: HeldBuffer] = [:]

        /// The surface, an ANativeWindow from `mead_surface_create`.
        var surface: UnsafeMutableRawPointer?
        /// The input channel's server end, from `mead_input_open`.
        var input: OpaquePointer?

        // The display thread's input state.
        var keyDownTimes: [Int32: Int64] = [:]
        var mouseButtons: Int32 = 0
        /// Where the window's frame starts in its surface (its surface
        /// insets), taken from input's coordinates.
        var inputOffset: (x: Float, y: Float) = (0, 0)
        /// Its frame in its surface, in pixels, once the window manager has
        /// said (its windows are the window manager's to size); nil for a
        /// window of its own (MeadWindow's).
        var frame: (x: Int32, y: Int32, width: Int32, height: Int32)?
        var maximized = false
        /// Whether the compositor has stopped showing it: xdg_toplevel's
        /// suspended state, or its frame callbacks held back; and what the
        /// window manager was last told.
        var suspended = false
        var heldBack = false
        /// Its idle inhibitor, while it keeps the screen on.
        var idleInhibitor: OpaquePointer?
        var reportedHidden = false
        var mouseDownTime: Int64 = 0
        var fingers: [(source: UInt64, id: Int32, x: Float, y: Float, pressure: Float)] = []
        var touchDownTime: Int64 = 0

        /// Frames presented, for MEAD_FRAME_DUMP.
        var frames = 0

        init(id: UInt32, kind: WindowKind, parent: Window?, x: Int32, y: Int32, width: Int32, height: Int32) {
            self.id = id
            self.kind = kind
            self.parent = parent
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// MEAD_FRAME_DUMP=path: the frame as a binary PPM, every 60 frames
        /// from the first, as Mead's EGL provider and hwui write theirs.
        func dump(_ pixels: UnsafeRawPointer, width: UInt32, height: UInt32, stride: UInt32) {
            defer { frames += 1 }
            guard frames % 60 == 0, let variable = getenv("MEAD_FRAME_DUMP"),
                  let file = fopen(String(cString: variable), "wb") else { return }
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

    let functions: Functions
    /// The Wayland connection, once the display thread has made it.
    private(set) var wayland: Wayland?
    /// The windows, which only the display thread changes.
    var windows: [Window] = []
    private var windowsLock = pthread_mutex_t()
    private var nextWindowID: UInt32 = 1
    var focusedWindowID: UInt32 = 0
    var gamepads: [UInt32: SDL.Pointer] = [:]
    var gamepadAxes: [UInt32: [Int32: Float]] = [:]

    // Window events for the window manager's thread (nextWindowEvent).
    private var eventLock = pthread_mutex_t()
    private var eventReady = pthread_cond_t()
    private var events: [[Int32]] = []

    /// Hands the window manager an event: kind 1, a toplevel the compositor
    /// resized to a frame of width×height pixels; kind 2, a toplevel it
    /// stopped showing (width 1) or shows again (width 0).
    func postWindowEvent(kind: Int32, window: Window, width: Int32, height: Int32) {
        pthread_mutex_lock(&eventLock)
        events.append([kind, Int32(bitPattern: window.id), width, height])
        pthread_cond_signal(&eventReady)
        pthread_mutex_unlock(&eventLock)
    }

    /// The next window event, waiting for one. On the window manager's thread.
    func nextWindowEvent() -> [Int32] {
        pthread_mutex_lock(&eventLock)
        while events.isEmpty { pthread_cond_wait(&eventReady, &eventLock) }
        let event = events.removeFirst()
        pthread_mutex_unlock(&eventLock)
        return event
    }

    // The display thread and the work handed to it.
    private var thread = pthread_t()
    private var started = false
    private var queueLock = pthread_mutex_t()
    private var queued: [() -> Void] = []
    /// A pipe whose writes wake the display thread for queued work.
    private var wake: [Int32] = [-1, -1]
    private var startFailure: String?
    /// MEAD_DEBUG_TAPS's steps, the next to play, and when the first window
    /// was made (CLOCK_MONOTONIC seconds).
    var script: [ScriptStep] = []
    var scriptNext = 0
    var scriptStart: Double?

    nonisolated(unsafe) static var shared: ARTDisplay?
    /// The window Android's window manager focused, which gets the keys of
    /// its toplevel. On the display thread.
    var androidFocus: Window?

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
        pthread_mutex_init(&windowsLock, nil)
        pthread_mutex_init(&queueLock, nil)
        installWindowCallbacks()
        installLayerCallbacks()
    }

    // MARK: The display thread

    /// Runs `work` on the display thread, starting it first, and waits for it.
    func onDisplayThread<T>(_ work: @escaping () -> T) -> T? {
        guard startThread() else { return nil }
        let completion = Completion<T>()
        enqueue { completion.finish(work()) }
        return completion.wait()
    }

    /// Hands `work` to the display thread without waiting.
    func enqueue(_ work: @escaping () -> Void) {
        pthread_mutex_lock(&queueLock)
        queued.append(work)
        pthread_mutex_unlock(&queueLock)
        var byte: UInt8 = 1
        _ = Glibc.write(wake[1], &byte, 1)
    }

    private func startThread() -> Bool {
        pthread_mutex_lock(&queueLock)
        defer { pthread_mutex_unlock(&queueLock) }
        if started { return startFailure == nil }
        started = true
        guard pipe(&wake) == 0 else {
            startFailure = "no pipe for the display thread"
            return false
        }
        _ = fcntl(wake[0], F_SETFL, O_NONBLOCK)
        let ready = Completion<String?>()
        let context = Unmanaged.passRetained(Box((self, ready))).toOpaque()
        let result = pthread_create(&thread, nil, { context in
            let box = Unmanaged<Box<(ARTDisplay, Completion<String?>)>>.fromOpaque(context!).takeRetainedValue()
            box.value.0.run(ready: box.value.1)
            return nil
        }, context)
        guard result == 0 else {
            startFailure = "no display thread: \(result)"
            Self.report(startFailure!)
            return false
        }
        pthread_mutex_unlock(&queueLock)
        startFailure = ready.wait() ?? nil
        if startFailure == nil {
            startInputThread()
        }
        pthread_mutex_lock(&queueLock)
        if let startFailure { Self.report(startFailure) }
        return startFailure == nil
    }

    private func run(ready: Completion<String?>) {
        guard let wayland = Wayland(bridge: self) else {
            ready.finish("no Wayland compositor (WAYLAND_DISPLAY)")
            return
        }
        if let missing = wayland.missing {
            ready.finish("the Wayland compositor has no \(missing)")
            return
        }
        self.wayland = wayland
        functions.setNativeDisplay(2, UnsafeMutableRawPointer(wayland.display))  // MEAD_GUI_NATIVE_WAYLAND
        describeDisplay()
        // Choreographer's vsync, on request, from frame callbacks.
        // The bridge itself is the context: libgui may ask before
        // ARTDisplay.shared is set, and the bridge lives as long as the process.
        functions.setVsyncRequest({ context in
            let display = Unmanaged<ARTDisplay>.fromOpaque(context!).takeUnretainedValue()
            display.enqueue { display.wayland?.wantVsync() }
        }, Unmanaged.passUnretained(self).toOpaque())
        script = Self.parseScript(getenv("MEAD_DEBUG_TAPS").map { String(cString: $0) } ?? "")
        ready.finish(nil)

        let display = wayland.display
        var fds = [pollfd(fd: wayland.fileDescriptor, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
        while true {
            pthread_mutex_lock(&queueLock)
            let work = queued
            queued.removeAll()
            pthread_mutex_unlock(&queueLock)
            work.forEach { $0() }
            if scriptNext < script.count, let start = scriptStart {
                playScript(elapsed: Double(Self.now()) / 1e9 - start)
            }

            // Wayland's reading, as threads sharing a connection do it.
            while wl_display_prepare_read(display) != 0 {
                _ = wl_display_dispatch_pending(display)
            }
            _ = wl_display_flush(display)
            fds[0].revents = 0
            fds[1].revents = 0
            var waiting: Int32 = scriptNext < script.count ? 20 : 1000
            if let vsync = wayland.vsyncTimeout() { waiting = min(waiting, vsync) }
            if let held = wayland.heldBackTimeout() { waiting = min(waiting, held) }
            if let repeating = wayland.repeatTimeout() { waiting = min(waiting, repeating) }
            if poll(&fds, 2, waiting) > 0, fds[0].revents & Int16(POLLIN) != 0 {
                if wl_display_read_events(display) < 0 {
                    Self.report("the Wayland connection is lost: \(String(cString: strerror(errno)))")
                    return
                }
            } else {
                wl_display_cancel_read(display)
            }
            _ = wl_display_dispatch_pending(display)
            if fds[1].revents & Int16(POLLIN) != 0 {
                var drained = [UInt8](repeating: 0, count: 64)
                while Glibc.read(wake[0], &drained, drained.count) > 0 {}
            }
        }
    }

    /// SDL's thread: gamepads, and the keys and touches checks inject, each
    /// handed to the display thread.
    private func startInputThread() {
        let ready = Completion<Bool>()
        var sdlThread = pthread_t()
        let context = Unmanaged.passRetained(Box((self, ready))).toOpaque()
        let result = pthread_create(&sdlThread, nil, { context in
            let box = Unmanaged<Box<(ARTDisplay, Completion<Bool>)>>.fromOpaque(context!).takeRetainedValue()
            box.value.0.runInput(ready: box.value.1)
            return nil
        }, context)
        if result == 0 { _ = ready.wait() }
    }

    private func runInput(ready: Completion<Bool>) {
        guard SDL.loadOnce(), SDL.initialize(UInt32(MEAD_SDL_INIT_EVENTS) | UInt32(MEAD_SDL_INIT_GAMEPAD)) else {
            Self.report("no gamepads: SDL: \(SDL.lastError)")
            ready.finish(false)
            return
        }
        ready.finish(true)
        var event = mead_sdl_event()
        while true {
            if SDL.waitEventTimeout(&event, 1000) {
                let received = event
                enqueue { [self] in handle(received) }
            }
        }
    }

    func window(id: UInt32) -> Window? {
        pthread_mutex_lock(&windowsLock)
        defer { pthread_mutex_unlock(&windowsLock) }
        return windows.first { $0.id == id }
    }

    /// The window input without one goes to: the focused one, or the newest.
    var inputWindow: Window? {
        if let focused = window(id: focusedWindowID) { return focused }
        pthread_mutex_lock(&windowsLock)
        defer { pthread_mutex_unlock(&windowsLock) }
        return windows.last { $0.kind != .layer }
    }

    /// The window an android.view.Surface draws to.
    func window(env: UnsafeMutablePointer<JNIEnv?>?, surface: jobject?) -> Window? {
        guard let native = functions.surfaceFromJava(env, surface) else { return nil }
        pthread_mutex_lock(&windowsLock)
        defer { pthread_mutex_unlock(&windowsLock) }
        return windows.first { $0.surface == native }
    }

    // MARK: Surfaces

    /// A new window titled `title`, of width×height pixels, as an
    /// `android.view.Surface`; nil, with the reason on standard error, when
    /// there's no window to be had.
    func createSurface(env: UnsafeMutablePointer<JNIEnv?>?, title: String, width: Int32, height: Int32) -> jobject? {
        guard let window = createWindow(title: title, width: width, height: height), let surface = window.surface else {
            return nil
        }
        // The Java Surface holds its own reference; the window keeps the one
        // mead_surface_create gave.
        return functions.surfaceToJava(env, surface)
    }

    /// A new window titled `title`, of width×height pixels, and its surface,
    /// which holds the reference `mead_surface_create` gave; nil, with the
    /// reason on standard error, when there's no window to be had.
    func createWindow(title: String, width: Int32, height: Int32, kind: WindowKind = .normal, parent: Window? = nil,
                      x: Int32 = 0, y: Int32 = 0) -> Window? {
        let made: Window?? = onDisplayThread { [self] in
            guard let wayland else { return nil }
            let window = Window(id: nextWindowID, kind: kind, parent: parent, x: x, y: y, width: width, height: height)
            nextWindowID += 1
            guard wayland.makeSurfaces(for: window, title: title) else {
                Self.report("the compositor made no window")
                wayland.destroySurfaces(window)
                return nil
            }
            if scriptStart == nil { scriptStart = Double(Self.now()) / 1e9 }
            return window
        }
        guard let made, let window = made else { return nil }

        // MeadSurfaceCallbacks: the context, present (unused), presentBuffer.
        typealias PresentBuffer = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, UInt32, UInt32, UInt32, Int32,
                                                  UnsafeRawPointer?) -> Void
        let presentBuffer: PresentBuffer = { context, slot, fd, width, height, stride, format, pixels in
            guard let context, let display = ARTDisplay.shared else { return }
            let window = Unmanaged<Window>.fromOpaque(context).takeUnretainedValue()
            if let pixels { window.dump(pixels, width: width, height: height, stride: stride) }
            display.enqueue {
                display.wayland?.attach(window, slot: slot, fd: fd, width: Int32(width), height: Int32(height),
                                        stride: Int32(stride), format: format)
            }
        }
        let callbacks: [UnsafeRawPointer?] = [UnsafeRawPointer(Unmanaged.passUnretained(window).toOpaque()), nil,
                                              unsafeBitCast(presentBuffer, to: UnsafeRawPointer.self)]
        // HAL_PIXEL_FORMAT_RGBA_8888.
        let surface = callbacks.withUnsafeBytes {
            functions.createSurface(UInt32(max(window.width, 1)), UInt32(max(window.height, 1)), 1, $0.baseAddress!)
        }
        guard let surface else {
            Self.report("no surface for the window")
            enqueue { [self] in wayland?.destroySurfaces(window) }
            return nil
        }
        window.surface = surface
        if let eglWindow = window.eglWindow {
            functions.setNativeWindow(surface, UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(eglWindow))))
        }
        pthread_mutex_lock(&windowsLock)
        windows.append(window)
        pthread_mutex_unlock(&windowsLock)
        return window
    }

    /// Hands back a buffer the compositor released. On the display thread.
    func release(_ window: Window, slot: Int32) {
        guard let surface = window.surface else { return }
        functions.releaseBuffer(surface, slot)
    }

    /// Closes the window whose surface `surface` is; its SurfaceControl is
    /// gone.
    func destroyWindow(surface: UnsafeMutableRawPointer) {
        pthread_mutex_lock(&windowsLock)
        let index = windows.firstIndex { $0.surface == surface }
        let window = index.map { windows.remove(at: $0) }
        pthread_mutex_unlock(&windowsLock)
        guard let window else { return }
        enqueue { [self] in
            if androidFocus === window { androidFocus = nil }
            window.surface = nil
            wayland?.destroySurfaces(window)
        }
    }

    /// The compositor asked to close a window (its title bar's button): as
    /// Android's back key, which finishes an activity.
    func closeRequested(_ window: Window) {
        guard let input = window.input else { return }
        let time = Self.now()
        let back: Int32 = 4  // KEYCODE_BACK
        _ = functions.sendKey(input, Android.keyboard, Android.sourceKeyboard, Android.keyDown, 0, back, 0, 0, 0, time, time)
        _ = functions.sendKey(input, Android.keyboard, Android.sourceKeyboard, Android.keyUp, 0, back, 0, 0, 0, time, time)
    }

    /// Makes the windows of the window manager's SurfaceControls, through
    /// libgui's window callbacks.
    private func installWindowCallbacks() {
        typealias Create = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt32, UInt32) -> UnsafeMutableRawPointer?
        typealias Destroy = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        let create: Create = { _, name, width, height in
            // The SurfaceControl takes the surface's reference.
            ARTDisplay.shared?.createWindow(title: name.map { String(cString: $0) } ?? "Mead",
                                            width: Int32(width), height: Int32(height))?.surface
        }
        let destroy: Destroy = { _, surface in
            guard let surface else { return }
            ARTDisplay.shared?.destroyWindow(surface: surface)
        }
        // MeadWindowCallbacks: the context, create and destroy.
        let callbacks: [UnsafeRawPointer?] = [nil, unsafeBitCast(create, to: UnsafeRawPointer.self),
                                              unsafeBitCast(destroy, to: UnsafeRawPointer.self)]
        callbacks.withUnsafeBytes { functions.setWindowCallbacks($0.baseAddress!) }
    }

    /// Makes the layers of SurfaceControls made with a parent (SurfaceViews'),
    /// through libgui's layer callbacks.
    private func installLayerCallbacks() {
        typealias Create = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt32,
                                           UInt32) -> UnsafeMutableRawPointer?
        typealias Update = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
        let create: Create = { _, parent, name, width, height in
            guard let display = ARTDisplay.shared, let parent, let window = display.window(surface: parent) else {
                ARTDisplay.report("a layer for a surface that isn't a window's")
                return nil
            }
            let title = name.map { String(cString: $0) } ?? "Mead layer"
            // The SurfaceControl takes the surface's reference.
            let layer = display.createWindow(title: title, width: Int32(width), height: Int32(height), kind: .layer,
                                             parent: window)
            if let layer { ARTDisplay.report("layer \(layer.id) in window \(window.id): \(title)") }
            return layer?.surface
        }
        let update: Update = { _, surface, state in
            guard let display = ARTDisplay.shared, let surface, let state,
                  let layer = display.window(surface: surface) else { return }
            // MeadLayerState: x, y, width, height, z, shown, then its scale.
            func value(_ index: Int) -> Int32 { state.load(fromByteOffset: index * 4, as: Int32.self) }
            let x = value(0), y = value(1), width = value(2), height = value(3), z = value(4), shown = value(5) != 0
            let scaleX = state.load(fromByteOffset: 24, as: Float.self)
            let scaleY = state.load(fromByteOffset: 28, as: Float.self)
            let shownWidth = Int32((Float(width) * scaleX).rounded()), shownHeight = Int32((Float(height) * scaleY).rounded())
            display.enqueue {
                display.wayland?.updateLayer(layer, x: x, y: y, width: width, height: height,
                                             shownWidth: shownWidth, shownHeight: shownHeight, z: z, shown: shown)
            }
        }
        // MeadLayerCallbacks: the context, create and update.
        let callbacks: [UnsafeRawPointer?] = [nil, unsafeBitCast(create, to: UnsafeRawPointer.self),
                                              unsafeBitCast(update, to: UnsafeRawPointer.self)]
        callbacks.withUnsafeBytes { functions.setLayerCallbacks($0.baseAddress!) }
    }

    /// The window or layer whose surface `surface` is.
    func window(surface: UnsafeMutableRawPointer) -> Window? {
        pthread_mutex_lock(&windowsLock)
        defer { pthread_mutex_unlock(&windowsLock) }
        return windows.first { $0.surface == surface }
    }

    /// An input channel for the window `surface` draws to: its client end, an
    /// android.view.InputChannel, which an InputEventReceiver reads.
    func openInput(env: UnsafeMutablePointer<JNIEnv?>?, surface: jobject?) -> jobject? {
        guard let window = window(env: env, surface: surface) else {
            Self.report("openInput: that Surface isn't a window's")
            return nil
        }
        var input: OpaquePointer?
        let client = "mead window \(window.id)".withCString { functions.openInput(env, $0, &input) }
        guard let client, let input else { return nil }
        _ = onDisplayThread { window.input = input }
        return client
    }

    /// The display libgui reports, from Wayland's first output. On the
    /// display thread.
    private func describeDisplay() {
        guard let output = wayland?.outputs.first, output.width > 0, output.height > 0 else { return }
        let scale = Float(wayland?.scale ?? 1)
        // Dots per inch from the output's physical size, when it has one.
        func dpi(_ pixels: Int32, _ millimeters: Int32) -> Float {
            millimeters > 0 ? Float(pixels) * 25.4 / Float(millimeters) : 160 * scale
        }
        // MeadDisplay: width and height in pixels, xdpi, ydpi, refresh rate,
        // and density (1 at 160 dpi).
        var described = [UInt32](repeating: 0, count: 6)
        described[0] = UInt32(output.width)
        described[1] = UInt32(output.height)
        described[2] = dpi(output.width, output.millimetersWide).bitPattern
        described[3] = dpi(output.height, output.millimetersHigh).bitPattern
        described[4] = (output.refresh > 0 ? Float(output.refresh) / 1000 : 60).bitPattern
        described[5] = scale.bitPattern
        described.withUnsafeBytes { functions.setDisplay($0.baseAddress!) }
        Self.report("\(output.width)×\(output.height) pixels, \(output.millimetersWide)×\(output.millimetersHigh) mm, scale \(output.scale), \(wayland?.outputs.count ?? 0) outputs")
    }

    /// A window's position (a popup's, in its parent) and size, in pixels.
    func setFrame(_ window: Window, x: Int32, y: Int32, width: Int32, height: Int32, popup: Bool) {
        _ = onDisplayThread { [self] in
            let moved = popup && (x != window.x || y != window.y)
            window.x = x
            window.y = y
            if width != window.width || height != window.height {
                resize(window, width: width, height: height)
            }
            if moved { wayland?.reposition(window) }
        }
    }

    /// Shows a window, or hides it.
    func setShown(_ window: Window, _ shown: Bool) {
        _ = onDisplayThread { [self] in
            if shown {
                wayland?.map(window)
            } else {
                wayland?.unmap(window)
            }
        }
    }

    /// Publishes a window's input to the server end of a channel the window
    /// manager opened.
    func attachInput(env: UnsafeMutablePointer<JNIEnv?>?, window: Window, serverChannel: jobject?) {
        guard let input = functions.inputFromChannel(env, serverChannel) else { return }
        _ = onDisplayThread { window.input = input }
    }

    /// A window's new size: its surfaces, and libgui's surface's buffers. On
    /// the display thread.
    func resize(_ window: Window, width: Int32, height: Int32) {
        window.width = width
        window.height = height
        wayland?.resizeSurfaces(window)
        if let surface = window.surface {
            functions.resizeSurface(surface, UInt32(max(width, 1)), UInt32(max(height, 1)))
        }
    }

    /// SDL's IDs for the gamepads open; none before the display thread starts.
    func openGamepads() -> [UInt32] {
        pthread_mutex_lock(&queueLock)
        let running = started && startFailure == nil
        pthread_mutex_unlock(&queueLock)
        guard running else { return [] }
        return onDisplayThread { [self] in gamepads.keys.sorted() } ?? []
    }

    static func report(_ message: String) {
        var line = "mead: display: \(message)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
    }
}

/// A value one thread hands another, which waits for it.
final class Completion<T> {
    private var lock = pthread_mutex_t()
    private var condition = pthread_cond_t()
    private var value: T?
    private var done = false

    init() {
        pthread_mutex_init(&lock, nil)
        pthread_cond_init(&condition, nil)
    }

    func finish(_ result: T) {
        pthread_mutex_lock(&lock)
        value = result
        done = true
        pthread_cond_broadcast(&condition)
        pthread_mutex_unlock(&lock)
    }

    func wait() -> T? {
        pthread_mutex_lock(&lock)
        while !done {
            pthread_cond_wait(&condition, &lock)
        }
        let result = value
        pthread_mutex_unlock(&lock)
        return result
    }
}

final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}
