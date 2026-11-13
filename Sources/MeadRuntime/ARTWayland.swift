import CMeadWayland
import Glibc

/// ART's display bridge's Wayland client: the connection, its globals, the
/// outputs (the display), the seat (keyboard, pointer, touch) and each
/// window's surfaces. All of it is used on the display thread only, which
/// dispatches the connection's default queue; Mesa's EGL, on hwui's render
/// thread, uses queues of its own on the same connection.
///
/// A window is a root `wl_surface` with an `xdg_toplevel` (or `xdg_popup`),
/// holding a 1×1 clear buffer scaled to the window by its viewport, and a
/// layer: a subsurface over it, desynchronized, where the window's libgui
/// surface is shown. CPU frames are the surface's gralloc buffers, attached
/// in place as `wl_shm` buffers and handed back to libgui when the
/// compositor releases them; GPU frames come from a `wl_egl_window` on the
/// layer, which EGL commits. Frame callbacks on a window's root surface are
/// the display's vsync.
///
/// A layer in a window (a SurfaceView's surface) is a subsurface of the
/// window's root, desynchronized, with no input: under the window's own
/// layer, where Android's view hierarchy leaves a hole for it, or over it.
final class Wayland {
    let display: OpaquePointer
    private(set) var compositor: OpaquePointer?
    private(set) var subcompositor: OpaquePointer?
    private(set) var shm: OpaquePointer?
    private(set) var wmBase: OpaquePointer?
    private(set) var wmBaseVersion: UInt32 = 0
    private(set) var viewporter: OpaquePointer?
    private(set) var decorations: OpaquePointer?
    /// zwp_idle_inhibit_manager_v1, for windows that keep the screen on.
    private var idleInhibitManager: OpaquePointer?
    private(set) var seat: OpaquePointer?
    private(set) var shmFormats = Set<UInt32>()
    private var registry: OpaquePointer?

    /// An output: a monitor or a device's screen.
    final class Output {
        let proxy: OpaquePointer
        /// The mode and physical size as the panel has them, before the
        /// compositor turns it: a handheld's portrait panel shown landscape
        /// (the Retroid's 1080×1920 DSI panel, which sway rotates).
        var panelWidth: Int32 = 0
        var panelHeight: Int32 = 0
        var panelMillimetersWide: Int32 = 0
        var panelMillimetersHigh: Int32 = 0
        /// wl_output's transform: odd values turn the panel a quarter turn.
        var transform: Int32 = 0
        var refresh: Int32 = 0  // mHz
        var scale: Int32 = 1
        init(_ proxy: OpaquePointer) { self.proxy = proxy }

        private var turned: Bool { transform & 1 != 0 }
        /// The output as it's shown: what apps lay themselves out on.
        var width: Int32 { turned ? panelHeight : panelWidth }
        var height: Int32 { turned ? panelWidth : panelHeight }
        var millimetersWide: Int32 { turned ? panelMillimetersHigh : panelMillimetersWide }
        var millimetersHigh: Int32 { turned ? panelMillimetersWide : panelMillimetersHigh }
    }

    private(set) var outputs: [Output] = []

    /// MEAD_FULLSCREEN=1: activities' windows cover the screen, as on a
    /// phone, for a handheld whose compositor would tile them (sway beside
    /// EmulationStation). Dialogs keep their own size.
    static let fullscreen: Bool = {
        guard let value = getenv("MEAD_FULLSCREEN") else { return false }
        let text = String(cString: value)
        return !text.isEmpty && text != "0"
    }()

    // The seat's devices, and which windows they're on.
    private var keyboard: OpaquePointer?
    private var pointer: OpaquePointer?
    private var touch: OpaquePointer?
    var keyboardWindow: ARTDisplay.Window?
    var pointerWindow: ARTDisplay.Window?
    var pointerX: Float = 0
    var pointerY: Float = 0
    /// xkb's modifier bits held (depressed and latched) and locked.
    var modifiers: UInt32 = 0
    var lockedModifiers: UInt32 = 0
    var touchWindows: [Int32: ARTDisplay.Window] = [:]

    /// Key repeat, as the compositor sets it: keys per second (0 is none)
    /// and the delay before the first, in milliseconds.
    private var repeatRate: Int32 = 25
    private var repeatDelay: Int32 = 600
    /// The held key that repeats, and when it next does.
    private struct Repeat {
        let window: ARTDisplay.Window
        let code: UInt32
        let keyCode: Int32
        var count: Int32
        var next: Int64
    }
    private var held: Repeat?

    /// The cursor's theme (XCURSOR_THEME, XCURSOR_SIZE), its image's surface
    /// and its hotspot, set on the pointer's enter.
    private var cursorTheme: OpaquePointer?
    private var cursorSurface: OpaquePointer?
    private var cursorHotspot: (Int32, Int32) = (0, 0)

    /// The windows, by their root and layer surfaces.
    var windows: [OpaquePointer: ARTDisplay.Window] = [:]
    /// A 1×1 clear buffer for windows' root surfaces, scaled by viewports.
    private var background: OpaquePointer?
    /// The window whose root surface's frame callbacks are vsync.
    var vsyncWindow: ARTDisplay.Window?
    /// Mapped popups, oldest first. xdg-shell takes popups down from the
    /// top, so one under others goes after them.
    private var popupStack: [ARTDisplay.Window] = []
    /// Whether libgui wants a vsync, and the frame callback asked for it.
    private var vsyncWanted = false
    private var frameCallback: OpaquePointer?
    /// When the vsync was asked for: delivered without a frame callback
    /// once it's overdue, when no window is mapped or the compositor holds
    /// callbacks back (a hidden window), so Choreographer never stalls.
    private var vsyncAskedAt: Int64?
    /// When the vsync window's frame callback was asked for, while it's
    /// unanswered. One held back for long means the compositor shows the
    /// window no more: GNOME holds them while the screen is blanked, which
    /// isn't xdg_toplevel's suspended state.
    private var frameAskedAt: Int64?
    /// How long a frame callback is held back before its window counts as
    /// hidden, in milliseconds.
    private static let heldBackLimit: Int64 = 2_000

    unowned let bridge: ARTDisplay

    /// MEAD_INPUT_TRACE: the seat's events and where they go, on stderr.
    static let tracing = getenv("MEAD_INPUT_TRACE") != nil
    static func trace(_ message: @autoclosure () -> String) {
        if tracing { ARTDisplay.report("input: \(message())") }
    }

    /// Device pixels per logical pixel of Wayland's (the first output's
    /// scale). Android's pixels are device pixels: its windows' buffers are
    /// at full resolution, and sizes, places and input convert.
    private(set) var scale: Int32 = 1

    /// Pixels in logical pixels, at least one.
    func logical(_ pixels: Int32) -> Int32 { max((pixels + scale - 1) / scale, 1) }
    /// A position in pixels in logical pixels.
    func logicalPosition(_ pixels: Int32) -> Int32 { Int32((Double(pixels) / Double(scale)).rounded(.down)) }

    /// Points the window's content viewport at its size on screen: its
    /// buffer's, or a layer's as its matrix scales it.
    private func setContentDestination(_ window: ARTDisplay.Window) {
        guard let viewport = window.layerViewport else { return }
        let size = window.shownSize ?? (max(window.width, 1), max(window.height, 1))
        wp_viewport_set_destination(viewport, logical(size.width), logical(size.height))
    }
    /// Wayland's logical coordinate in pixels.
    func pixels(_ value: wl_fixed_t) -> Float { Float(wl_fixed_to_double(value)) * Float(scale) }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Connects to the compositor (WAYLAND_DISPLAY), or nil.
    init?(bridge: ARTDisplay) {
        guard let display = wl_display_connect(nil) else { return nil }
        self.display = display
        self.bridge = bridge
        registry = wl_display_get_registry(display)
        _ = wl_registry_add_listener(registry, Self.registryListener, context)
        // The globals, then what they say about themselves (outputs' modes,
        // shm's formats, the seat's capabilities).
        _ = wl_display_roundtrip(display)
        _ = wl_display_roundtrip(display)
        // MEAD_DISPLAY_SCALE overrides the output's, as a whole number.
        let chosen = getenv("MEAD_DISPLAY_SCALE").flatMap { Int32(String(cString: $0)) }
        scale = max(chosen ?? outputs.first?.scale ?? 1, 1)
    }

    /// What the compositor lacks of what the bridge needs, or nil.
    var missing: String? {
        let needed: [(String, OpaquePointer?)] = [
            ("wl_compositor", compositor), ("wl_subcompositor", subcompositor), ("wl_shm", shm),
            ("xdg_wm_base", wmBase), ("wp_viewporter", viewporter),
        ]
        let absent = needed.filter { $0.1 == nil }.map(\.0)
        return absent.isEmpty ? nil : absent.joined(separator: ", ")
    }

    var fileDescriptor: Int32 { wl_display_get_fd(display) }

    // MARK: Globals

    nonisolated(unsafe) private static let registryListener: UnsafeMutablePointer<wl_registry_listener> = {
        let listener = UnsafeMutablePointer<wl_registry_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_registry_listener(
            global: { data, registry, name, interface, version in
                guard let data, let interface else { return }
                Unmanaged<Wayland>.fromOpaque(data).takeUnretainedValue()
                    .global(registry: registry, name: name, interface: String(cString: interface), version: version)
            },
            global_remove: { _, _, _ in }))
        return listener
    }()

    private func global(registry: OpaquePointer?, name: UInt32, interface: String, version: UInt32) {
        func bind(_ wanted: UnsafePointer<wl_interface>, _ highest: UInt32) -> OpaquePointer? {
            OpaquePointer(wl_registry_bind(registry, name, wanted, min(version, highest)))
        }
        switch interface {
        case "wl_compositor": compositor = bind(mead_wl_compositor_interface(), 4)
        case "wl_subcompositor": subcompositor = bind(mead_wl_subcompositor_interface(), 1)
        case "wl_shm":
            shm = bind(mead_wl_shm_interface(), 1)
            _ = wl_shm_add_listener(shm, Self.shmListener, context)
        case "xdg_wm_base":
            // 6 for toplevels' suspended state.
            wmBaseVersion = min(version, 6)
            wmBase = bind(mead_xdg_wm_base_interface(), 6)
            _ = xdg_wm_base_add_listener(wmBase, Self.wmBaseListener, context)
        case "wp_viewporter": viewporter = bind(mead_wp_viewporter_interface(), 1)
        case "zxdg_decoration_manager_v1": decorations = bind(mead_zxdg_decoration_manager_v1_interface(), 1)
        case "zwp_idle_inhibit_manager_v1":
            idleInhibitManager = bind(mead_zwp_idle_inhibit_manager_v1_interface(), 1)
        case "wl_seat":
            guard seat == nil else { return }
            seat = bind(mead_wl_seat_interface(), 5)
            _ = wl_seat_add_listener(seat, Self.seatListener, context)
        case "wl_output":
            guard let proxy = bind(mead_wl_output_interface(), 2) else { return }
            let output = Output(proxy)
            outputs.append(output)
            _ = wl_output_add_listener(proxy, Self.outputListener, Unmanaged.passUnretained(output).toOpaque())
        default:
            break
        }
    }

    nonisolated(unsafe) private static let shmListener: UnsafeMutablePointer<wl_shm_listener> = {
        let listener = UnsafeMutablePointer<wl_shm_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_shm_listener(format: { data, _, format in
            guard let data else { return }
            Unmanaged<Wayland>.fromOpaque(data).takeUnretainedValue().shmFormats.insert(format)
        }))
        return listener
    }()

    nonisolated(unsafe) private static let wmBaseListener: UnsafeMutablePointer<xdg_wm_base_listener> = {
        let listener = UnsafeMutablePointer<xdg_wm_base_listener>.allocate(capacity: 1)
        listener.initialize(to: xdg_wm_base_listener(ping: { _, base, serial in xdg_wm_base_pong(base, serial) }))
        return listener
    }()

    nonisolated(unsafe) private static let outputListener: UnsafeMutablePointer<wl_output_listener> = {
        let listener = UnsafeMutablePointer<wl_output_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_output_listener(
            geometry: { data, _, _, _, width, height, _, _, _, transform in
                guard let data else { return }
                let output = Unmanaged<Output>.fromOpaque(data).takeUnretainedValue()
                output.panelMillimetersWide = width
                output.panelMillimetersHigh = height
                output.transform = transform
            },
            mode: { data, _, flags, width, height, refresh in
                guard let data, flags & UInt32(WL_OUTPUT_MODE_CURRENT.rawValue) != 0 else { return }
                let output = Unmanaged<Output>.fromOpaque(data).takeUnretainedValue()
                output.panelWidth = width
                output.panelHeight = height
                output.refresh = refresh
            },
            done: { _, _ in },
            scale: { data, _, factor in
                guard let data else { return }
                Unmanaged<Output>.fromOpaque(data).takeUnretainedValue().scale = factor
            },
            name: { _, _, _ in },
            description: { _, _, _ in }))
        return listener
    }()

    // MARK: Windows

    /// The 1×1 clear buffer roots show, scaled to their windows.
    private func backgroundBuffer() -> OpaquePointer? {
        if let background { return background }
        let fd = mead_wayland_memfd("mead-background")
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, 4) == 0 else { return nil }
        // Clear: a translucent window (a popup's shadow, a dialog's scrim)
        // shows what's under it where Android draws nothing.
        var clear: UInt32 = 0
        _ = Glibc.write(fd, &clear, 4)
        let pool = wl_shm_create_pool(shm, fd, 4)
        background = wl_shm_pool_create_buffer(pool, 0, 1, 1, 4, UInt32(WL_SHM_FORMAT_ARGB8888.rawValue))
        wl_shm_pool_destroy(pool)
        return background
    }

    /// The window's surfaces: its root, as a toplevel or a popup of its
    /// parent's, and the layer over it; mapped once the compositor configures
    /// it. False when the compositor refused.
    func makeSurfaces(for window: ARTDisplay.Window, title: String) -> Bool {
        if window.kind == .layer { return makeLayer(window) }
        guard let root = wl_compositor_create_surface(compositor) else { return false }
        window.root = root
        let windowContext = Unmanaged.passUnretained(window).toOpaque()
        switch (window.kind, window.parent) {
        case (.popup, _?):
            // A popup's role is made when it's shown, and dropped when it's
            // hidden (makePopupRole).
            break
        default:
            guard let xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, root) else { return false }
            window.xdgSurface = xdgSurface
            _ = xdg_surface_add_listener(xdgSurface, Self.xdgSurfaceListener, windowContext)
            let toplevel = xdg_surface_get_toplevel(xdgSurface)
            window.toplevel = toplevel
            _ = xdg_toplevel_add_listener(toplevel, Self.toplevelListener, windowContext)
            xdg_toplevel_set_title(toplevel, title)
            xdg_toplevel_set_app_id(toplevel, "mead")
            if window.kind == .dialog, let parent = window.parent?.toplevel {
                xdg_toplevel_set_parent(toplevel, parent)
            } else if Self.fullscreen {
                // Before the first commit, so the first configure is the
                // whole output; Android lays the window out at that size.
                xdg_toplevel_set_fullscreen(toplevel, nil)
            }
            // Server-side decorations where the compositor draws them (sway);
            // GNOME's needs libdecor, which isn't here yet.
            if let decorations {
                window.decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decorations, toplevel)
                zxdg_toplevel_decoration_v1_set_mode(window.decoration,
                                                    UInt32(ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE.rawValue))
            }
        }
        window.rootViewport = wp_viewporter_get_viewport(viewporter, root)

        guard let layer = wl_compositor_create_surface(compositor) else { return false }
        window.layer = layer
        window.subsurface = wl_subcompositor_get_subsurface(subcompositor, layer, root)
        wl_subsurface_set_position(window.subsurface, 0, 0)
        wl_subsurface_set_desync(window.subsurface)
        window.layerViewport = wp_viewporter_get_viewport(viewporter, layer)
        // The layer's buffers are in device pixels, shown at the window's
        // logical size: EGL's as well as the CPU frames attach gives.
        wp_viewport_set_destination(window.layerViewport, logical(window.width), logical(window.height))
        window.eglWindow = wl_egl_window_create(layer, max(window.width, 1), max(window.height, 1))
        makeTick(window, root: root, above: layer)
        windows[root] = window
        windows[layer] = window
        map(window)
        return true
    }

    /// The window's vsync surface: clear, 1×1, taking no input, kept over
    /// the content (layers placed above the content go under it). Frame
    /// callbacks are asked on it, not the root: wlroots (sway) answers only
    /// surfaces some of which shows, and a game's opaque SurfaceView covers
    /// the root, which left Below Zero on the Retroid at 5 frames a second
    /// on the held-back fallback.
    private func makeTick(_ window: ARTDisplay.Window, root: OpaquePointer, above content: OpaquePointer) {
        guard let tick = wl_compositor_create_surface(compositor) else { return }
        window.tick = tick
        window.tickSubsurface = wl_subcompositor_get_subsurface(subcompositor, tick, root)
        wl_subsurface_set_position(window.tickSubsurface, 0, 0)
        wl_subsurface_place_above(window.tickSubsurface, content)
        wl_subsurface_set_desync(window.tickSubsurface)
        let region = wl_compositor_create_region(compositor)
        wl_surface_set_input_region(tick, region)
        wl_region_destroy(region)
        wl_surface_attach(tick, backgroundBuffer(), 0, 0)
        wl_surface_damage_buffer(tick, 0, 0, 1, 1)
        wl_surface_commit(tick)
    }

    /// A layer's surface: a subsurface of its window's root, hidden until a
    /// transaction shows it, under the window's content. False when its
    /// window has no surfaces.
    private func makeLayer(_ window: ARTDisplay.Window) -> Bool {
        // A layer in a layer goes in that layer's window.
        var host = window.parent
        while let candidate = host, candidate.kind == .layer { host = candidate.parent }
        guard let host, let root = host.root, let content = host.layer,
              let layer = wl_compositor_create_surface(compositor) else { return false }
        window.layer = layer
        window.subsurface = wl_subcompositor_get_subsurface(subcompositor, layer, root)
        wl_subsurface_set_position(window.subsurface, logicalPosition(window.x), logicalPosition(window.y))
        wl_subsurface_place_below(window.subsurface, content)
        wl_subsurface_set_desync(window.subsurface)
        // No input: Android's window gets the touches, over it or not.
        let region = wl_compositor_create_region(compositor)
        wl_surface_set_input_region(layer, region)
        wl_region_destroy(region)
        window.layerViewport = wp_viewporter_get_viewport(viewporter, layer)
        setContentDestination(window)
        window.eglWindow = wl_egl_window_create(layer, max(window.width, 1), max(window.height, 1))
        wl_surface_commit(root)
        return true
    }

    /// A transaction's state for a layer: its place in its window, its
    /// buffer's size and its size on screen, its order against the window's
    /// content, and whether it shows.
    func updateLayer(_ window: ARTDisplay.Window, x: Int32, y: Int32, width: Int32, height: Int32, shownWidth: Int32,
                     shownHeight: Int32, z: Int32, shown: Bool) {
        var host = window.parent
        while let candidate = host, candidate.kind == .layer { host = candidate.parent }
        guard let host, let root = host.root, let content = host.layer, let layer = window.layer,
              let subsurface = window.subsurface else { return }
        let scaled = shownWidth != width || shownHeight != height ? " shown at \(shownWidth)×\(shownHeight)" : ""
        ARTDisplay.report("layer \(window.id) in window \(host.id): \(x),\(y) \(width)×\(height)\(scaled), z \(z), \(shown ? "shown" : "hidden")")
        window.x = x
        window.y = y
        wl_subsurface_set_position(subsurface, logicalPosition(x), logicalPosition(y))
        if z != window.z {
            window.z = z
            if z < 0 {
                wl_subsurface_place_below(subsurface, content)
            } else {
                wl_subsurface_place_above(subsurface, content)
            }
        }
        let shownSize = shownWidth > 0 && shownHeight > 0 && (shownWidth != width || shownHeight != height)
            ? (width: shownWidth, height: shownHeight) : nil
        let resized = width > 0 && height > 0 && (width != window.width || height != window.height)
        let rescaled = shownSize?.width != window.shownSize?.width || shownSize?.height != window.shownSize?.height
        window.shownSize = shownSize
        if resized {
            bridge.resize(window, width: width, height: height)
        } else if rescaled {
            setContentDestination(window)
            wl_surface_commit(layer)
        }
        if shown != window.layerShown {
            window.layerShown = shown
            if !shown {
                wl_surface_attach(layer, nil, 0, 0)
                wl_surface_commit(layer)
            }
        }
        // A subsurface's place and order apply with its parent's commit.
        wl_surface_commit(root)
        _ = wl_display_flush(display)
    }

    /// Maps a window: its first commit, without a buffer, then waits for the
    /// compositor's configure, which attaches its background.
    func map(_ window: ARTDisplay.Window) {
        guard let root = window.root, !window.mapped else { return }
        if window.kind == .popup, window.popup == nil {
            guard makePopupRole(window) else { return }
            popupStack.append(window)
        }
        window.configured = false
        wl_surface_commit(root)
        var waited = 0
        while !window.configured, waited < 50, wl_display_roundtrip(display) >= 0 {
            waited += 1
        }
        window.mapped = true
        if let parent = window.parent { updateDim(parent) }
        if vsyncWindow == nil || vsyncWindow?.mapped == false {
            vsyncWindow = window
            if vsyncWanted { requestFrame() }
        }
    }

    /// Unmaps a window: its root without a buffer, which hides the layer
    /// too; a popup gives up its role, and the popups over it theirs first.
    func unmap(_ window: ARTDisplay.Window) {
        guard let root = window.root, window.mapped else { return }
        if window.popup != nil {
            takeDownPopup(window)
        } else {
            wl_surface_attach(root, nil, 0, 0)
            wl_surface_commit(root)
            window.mapped = false
        }
        // A hidden window's popups go with it.
        for popup in popupStack.reversed() where isDescendant(popup, of: window) {
            takeDownPopup(popup)
        }
        windowHidden(window)
    }

    private func windowHidden(_ window: ARTDisplay.Window) {
        if let parent = window.parent { updateDim(parent) }
        if vsyncWindow === window {
            dropFrameCallback()
            vsyncWindow = bridge.windows.first { $0.mapped }
            if vsyncWanted { requestFrame() }
        }
    }

    /// A configure: acknowledged, and the root's background at the window's
    /// size (the compositor's, when it gives one).
    fileprivate func configured(_ window: ARTDisplay.Window, serial: UInt32) {
        xdg_surface_ack_configure(window.xdgSurface, serial)
        if let size = window.pendingSize, size.width > 0, size.height > 0 {
            let width = size.width * scale, height = size.height * scale
            if let frame = window.frame {
                // The window manager's window: Android lays it out at the
                // new frame and resizes its surface (shadow and all).
                if width != frame.width || height != frame.height {
                    bridge.postWindowEvent(kind: 1, window: window, width: width, height: height)
                }
            } else {
                window.unsentCompositorSize = (width, height)
                if width != window.width || height != window.height {
                    bridge.resize(window, width: width, height: height)
                }
            }
        }
        window.pendingSize = nil
        guard let root = window.root else { return }
        wl_surface_attach(root, backgroundBuffer(), 0, 0)
        wp_viewport_set_destination(window.rootViewport, logical(window.width), logical(window.height))
        wl_surface_damage_buffer(root, 0, 0, 1, 1)
        wl_surface_commit(root)
        window.configured = true
    }

    /// The window's surfaces at a new size.
    func resizeSurfaces(_ window: ARTDisplay.Window) {
        let width = max(window.width, 1), height = max(window.height, 1)
        // A layer has no root: it is a subsurface of its window's.
        if let rootViewport = window.rootViewport {
            wp_viewport_set_destination(rootViewport, logical(width), logical(height))
        }
        setContentDestination(window)
        if let eglWindow = window.eglWindow {
            wl_egl_window_resize(eglWindow, width, height, 0, 0)
        }
        if let dim = window.dim {
            wp_viewport_set_destination(window.dimViewport, logical(width), logical(height))
            wl_surface_commit(dim)
        }
        if let root = window.root, window.mapped {
            wl_surface_commit(root)
        }
        if let layer = window.layer {
            wl_surface_commit(layer)
        }
    }

    /// A toplevel's window, to the compositor, is its frame: its surface
    /// insets (a freeform window's shadow) are outside it.
    func setWindowGeometry(_ window: ARTDisplay.Window) {
        guard window.toplevel != nil, let xdgSurface = window.xdgSurface, let frame = window.frame else { return }
        xdg_surface_set_window_geometry(xdgSurface, logicalPosition(frame.x), logicalPosition(frame.y),
                                        logical(frame.width), logical(frame.height))
        if let root = window.root, window.mapped { wl_surface_commit(root) }
    }

    /// The latest serial of a press or touch, which moving and resizing
    /// with the compositor take.
    private var pressSerial: UInt32 = 0

    /// The toplevel a window is in: its own, or its parent's.
    private func toplevel(of window: ARTDisplay.Window) -> ARTDisplay.Window? {
        var current: ARTDisplay.Window? = window
        while let candidate = current {
            if candidate.toplevel != nil { return candidate }
            current = candidate.parent
        }
        return nil
    }

    /// The caption dragged: the compositor moves the window.
    func startMove(_ window: ARTDisplay.Window) {
        guard let seat, let toplevel = toplevel(of: window)?.toplevel else { return }
        xdg_toplevel_move(toplevel, seat, pressSerial)
    }

    /// The caption's maximize button.
    func toggleMaximized(_ window: ARTDisplay.Window) {
        guard let window = toplevel(of: window), let toplevel = window.toplevel else { return }
        if window.maximized {
            xdg_toplevel_unset_maximized(toplevel)
        } else {
            xdg_toplevel_set_maximized(toplevel)
        }
    }

    /// A press outside a captioned window's frame, in its shadow: the
    /// compositor resizes it from that edge or corner. False if the press
    /// is the app's.
    private func resizeFromEdge(_ window: ARTDisplay.Window, x: Float, y: Float) -> Bool {
        guard let seat, let toplevel = window.toplevel, let edges = resizeEdges(window, x: x, y: y) else { return false }
        xdg_toplevel_resize(toplevel, seat, pressSerial, edges)
        return true
    }

    /// The edges a point in a captioned window's shadow resizes; nil inside
    /// its frame, or for a window that doesn't resize so.
    private func resizeEdges(_ window: ARTDisplay.Window, x: Float, y: Float) -> UInt32? {
        guard window.kind == .normal, window.toplevel != nil, let frame = window.frame, !window.maximized,
              frame.x > 0 || frame.y > 0 else { return nil }
        var edges: UInt32 = 0
        if x < Float(frame.x) { edges |= UInt32(XDG_TOPLEVEL_RESIZE_EDGE_LEFT.rawValue) }
        if x >= Float(frame.x + frame.width) { edges |= UInt32(XDG_TOPLEVEL_RESIZE_EDGE_RIGHT.rawValue) }
        if y < Float(frame.y) { edges |= UInt32(XDG_TOPLEVEL_RESIZE_EDGE_TOP.rawValue) }
        if y >= Float(frame.y + frame.height) { edges |= UInt32(XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM.rawValue) }
        return edges != 0 ? edges : nil
    }

    /// Dims a window while a child of its that dims (a dialog) is mapped, as
    /// Android's window manager does: a layer over its content, black at
    /// the strongest child's dimAmount.
    func updateDim(_ window: ARTDisplay.Window) {
        let amount = bridge.windows.filter { $0.parent === window && $0.mapped }.map(\.dimAmount).max() ?? 0
        guard amount != window.dimShown, let root = window.root, let layer = window.layer else { return }
        window.dimShown = amount
        if window.dim == nil, amount > 0 {
            guard let dim = wl_compositor_create_surface(compositor) else { return }
            window.dim = dim
            window.dimSubsurface = wl_subcompositor_get_subsurface(subcompositor, dim, root)
            wl_subsurface_place_above(window.dimSubsurface, layer)
            wl_subsurface_set_desync(window.dimSubsurface)
            window.dimViewport = wp_viewporter_get_viewport(viewporter, dim)
            // No input: touches go through to the window, which the dialog's
            // modality already keeps from them.
            let region = wl_compositor_create_region(compositor)
            wl_surface_set_input_region(dim, region)
            wl_region_destroy(region)
        }
        guard let dim = window.dim else { return }
        if amount > 0 {
            wl_surface_attach(dim, dimBuffer(alpha: amount), 0, 0)
            wp_viewport_set_destination(window.dimViewport, logical(window.width), logical(window.height))
            wl_surface_damage_buffer(dim, 0, 0, 1, 1)
        } else {
            wl_surface_attach(dim, nil, 0, 0)
        }
        wl_surface_commit(dim)
        // The subsurface's place applies with its parent's commit.
        wl_surface_commit(root)
    }

    /// 1×1 black buffers at each opacity the dim layer has used.
    private var dimBuffers: [UInt8: OpaquePointer] = [:]

    private func dimBuffer(alpha: Float) -> OpaquePointer? {
        let byte = UInt8((alpha * 255).rounded())
        if let buffer = dimBuffers[byte] { return buffer }
        let fd = mead_wayland_memfd("mead-dim")
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, 4) == 0 else { return nil }
        // Premultiplied ARGB: black at the opacity.
        var pixel = UInt32(byte) << 24
        _ = Glibc.write(fd, &pixel, 4)
        let pool = wl_shm_create_pool(shm, fd, 4)
        let buffer = wl_shm_pool_create_buffer(pool, 0, 1, 1, 4, UInt32(WL_SHM_FORMAT_ARGB8888.rawValue))
        wl_shm_pool_destroy(pool)
        dimBuffers[byte] = buffer
        return buffer
    }

    /// A popup moved within its parent.
    func reposition(_ window: ARTDisplay.Window) {
        guard let popup = window.popup, let parent = window.parent, wmBaseVersion >= 3 else { return }
        let positioner = makePositioner(window, in: parent)
        xdg_popup_reposition(popup, positioner, 0)
        xdg_positioner_destroy(positioner)
    }

    /// A popup's place at x, y in its parent: the anchor is a point inside
    /// the parent, as xdg-shell requires, and the rest an offset, since a
    /// popup's surface insets can put its corner above or left of it.
    private func makePositioner(_ window: ARTDisplay.Window, in parent: ARTDisplay.Window) -> OpaquePointer? {
        let positioner = xdg_wm_base_create_positioner(wmBase)
        let x = logicalPosition(window.x), y = logicalPosition(window.y)
        let anchorX = min(max(x, 0), max(logical(parent.width) - 1, 0))
        let anchorY = min(max(y, 0), max(logical(parent.height) - 1, 0))
        xdg_positioner_set_size(positioner, logical(window.width), logical(window.height))
        xdg_positioner_set_anchor_rect(positioner, anchorX, anchorY, 1, 1)
        xdg_positioner_set_anchor(positioner, UInt32(XDG_POSITIONER_ANCHOR_TOP_LEFT.rawValue))
        xdg_positioner_set_gravity(positioner, UInt32(XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT.rawValue))
        xdg_positioner_set_offset(positioner, x - anchorX, y - anchorY)
        return positioner
    }

    /// A popup's role: its xdg_surface and xdg_popup in its parent's, which
    /// must have its own.
    private func makePopupRole(_ window: ARTDisplay.Window) -> Bool {
        guard let root = window.root, let parent = window.parent, let parentSurface = parent.xdgSurface,
              let xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, root) else { return false }
        let windowContext = Unmanaged.passUnretained(window).toOpaque()
        window.xdgSurface = xdgSurface
        _ = xdg_surface_add_listener(xdgSurface, Self.xdgSurfaceListener, windowContext)
        let positioner = makePositioner(window, in: parent)
        xdg_positioner_set_constraint_adjustment(positioner,
            UInt32(XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X.rawValue | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y.rawValue))
        window.popup = xdg_surface_get_popup(xdgSurface, parentSurface, positioner)
        xdg_positioner_destroy(positioner)
        _ = xdg_popup_add_listener(window.popup, Self.popupListener, windowContext)
        return true
    }

    /// Drops a popup's role, unmapping it, after the popups over it: those
    /// that aren't its own come back once it's gone.
    private func takeDownPopup(_ window: ARTDisplay.Window) {
        guard let index = popupStack.firstIndex(where: { $0 === window }) else {
            dropPopupRole(window)
            return
        }
        let above = Array(popupStack[(index + 1)...])
        for popup in above.reversed() { dropPopupRole(popup) }
        dropPopupRole(window)
        for popup in above where !isDescendant(popup, of: window) {
            map(popup)
        }
    }

    private func dropPopupRole(_ window: ARTDisplay.Window) {
        popupStack.removeAll { $0 === window }
        guard let popup = window.popup else { return }
        // Without a buffer, so the role can be made again.
        if let root = window.root {
            wl_surface_attach(root, nil, 0, 0)
            wl_surface_commit(root)
        }
        xdg_popup_destroy(popup)
        window.popup = nil
        if let xdgSurface = window.xdgSurface { xdg_surface_destroy(xdgSurface) }
        window.xdgSurface = nil
        window.configured = false
        window.mapped = false
        windowHidden(window)
    }

    private func isDescendant(_ window: ARTDisplay.Window, of ancestor: ARTDisplay.Window) -> Bool {
        var parent = window.parent
        while let current = parent {
            if current === ancestor { return true }
            parent = current.parent
        }
        return false
    }

    /// Keeps the screen on while the window shows, as Android's
    /// FLAG_KEEP_SCREEN_ON does (a game's or a video's), or no more: an idle
    /// inhibitor on its root, which holds only while the compositor shows it.
    func setKeepScreenOn(_ window: ARTDisplay.Window, _ on: Bool) {
        if on, window.idleInhibitor == nil, let manager = idleInhibitManager, let root = window.root {
            window.idleInhibitor = zwp_idle_inhibit_manager_v1_create_inhibitor(manager, root)
            ARTDisplay.report("window \(window.id) keeps the screen on")
        } else if !on, let inhibitor = window.idleInhibitor {
            zwp_idle_inhibitor_v1_destroy(inhibitor)
            window.idleInhibitor = nil
            ARTDisplay.report("window \(window.id) lets the screen sleep")
        } else if on, idleInhibitManager == nil {
            ARTDisplay.report("window \(window.id) wants the screen on; the compositor can't keep it on")
        }
        _ = wl_display_flush(display)
    }

    func destroySurfaces(_ window: ARTDisplay.Window) {
        if let inhibitor = window.idleInhibitor {
            zwp_idle_inhibitor_v1_destroy(inhibitor)
            window.idleInhibitor = nil
        }
        // Popups over it, and its own, go first.
        for popup in popupStack.reversed() where isDescendant(popup, of: window) {
            takeDownPopup(popup)
        }
        if window.popup != nil { takeDownPopup(window) }
        window.mapped = false
        if let parent = window.parent { updateDim(parent) }
        if vsyncWindow === window {
            dropFrameCallback()
            vsyncWindow = nil
        }
        if keyboardWindow === window { keyboardWindow = nil }
        if pointerWindow === window { pointerWindow = nil }
        touchWindows = touchWindows.filter { $0.value !== window }
        for buffer in window.buffers.values { wl_buffer_destroy(buffer.buffer) }
        window.buffers.removeAll()
        if let dimViewport = window.dimViewport { wp_viewport_destroy(dimViewport) }
        if let dimSubsurface = window.dimSubsurface { wl_subsurface_destroy(dimSubsurface) }
        if let dim = window.dim { wl_surface_destroy(dim) }
        window.dim = nil
        window.dimSubsurface = nil
        window.dimViewport = nil
        if let eglWindow = window.eglWindow { wl_egl_window_destroy(eglWindow) }
        if let viewport = window.layerViewport { wp_viewport_destroy(viewport) }
        if let subsurface = window.subsurface { wl_subsurface_destroy(subsurface) }
        if let layer = window.layer {
            windows[layer] = nil
            wl_surface_destroy(layer)
        }
        if let tickSubsurface = window.tickSubsurface { wl_subsurface_destroy(tickSubsurface) }
        if let tick = window.tick { wl_surface_destroy(tick) }
        window.tick = nil
        window.tickSubsurface = nil
        if let decoration = window.decoration { zxdg_toplevel_decoration_v1_destroy(decoration) }
        if let popup = window.popup { xdg_popup_destroy(popup) }
        if let toplevel = window.toplevel { xdg_toplevel_destroy(toplevel) }
        if let xdgSurface = window.xdgSurface { xdg_surface_destroy(xdgSurface) }
        if let viewport = window.rootViewport { wp_viewport_destroy(viewport) }
        if let root = window.root {
            windows[root] = nil
            wl_surface_destroy(root)
        }
        window.eglWindow = nil
        window.layer = nil
        window.root = nil
        _ = wl_display_flush(display)
    }

    nonisolated(unsafe) private static let xdgSurfaceListener: UnsafeMutablePointer<xdg_surface_listener> = {
        let listener = UnsafeMutablePointer<xdg_surface_listener>.allocate(capacity: 1)
        listener.initialize(to: xdg_surface_listener(configure: { data, _, serial in
            guard let data, let wayland = ARTDisplay.shared?.wayland else { return }
            wayland.configured(Unmanaged<ARTDisplay.Window>.fromOpaque(data).takeUnretainedValue(), serial: serial)
        }))
        return listener
    }()

    nonisolated(unsafe) private static let toplevelListener: UnsafeMutablePointer<xdg_toplevel_listener> = {
        let listener = UnsafeMutablePointer<xdg_toplevel_listener>.allocate(capacity: 1)
        listener.initialize(to: xdg_toplevel_listener(
            configure: { data, _, width, height, states in
                guard let data else { return }
                let window = Unmanaged<ARTDisplay.Window>.fromOpaque(data).takeUnretainedValue()
                window.pendingSize = (width, height)
                var maximized = false, suspended = false
                if let states, let words = states.pointee.data {
                    let count = states.pointee.size / MemoryLayout<UInt32>.size
                    let values = words.bindMemory(to: UInt32.self, capacity: count)
                    for index in 0..<count {
                        if values[index] == UInt32(XDG_TOPLEVEL_STATE_MAXIMIZED.rawValue) { maximized = true }
                        if values[index] == UInt32(XDG_TOPLEVEL_STATE_SUSPENDED.rawValue) { suspended = true }
                    }
                }
                window.maximized = maximized
                // The compositor shows the window no more (minimized, on
                // another workspace), or again.
                window.suspended = suspended
                ARTDisplay.shared?.wayland?.updateHidden(window)
            },
            close: { data, _ in
                guard let data else { return }
                ARTDisplay.shared?.closeRequested(Unmanaged<ARTDisplay.Window>.fromOpaque(data).takeUnretainedValue())
            },
            configure_bounds: { _, _, _, _ in },
            wm_capabilities: { _, _, _ in }))
        return listener
    }()

    nonisolated(unsafe) private static let popupListener: UnsafeMutablePointer<xdg_popup_listener> = {
        let listener = UnsafeMutablePointer<xdg_popup_listener>.allocate(capacity: 1)
        listener.initialize(to: xdg_popup_listener(
            configure: { _, _, _, _, _, _ in },
            popup_done: { _, _ in },
            repositioned: { _, _, _ in }))
        return listener
    }()

    // MARK: Frames

    /// A CPU frame: the gralloc buffer in slot, attached in place.
    func attach(_ window: ARTDisplay.Window, slot: Int32, fd: Int32, width: Int32, height: Int32, stride: Int32,
                format: Int32) {
        // A hidden layer shows nothing.
        guard let layer = window.layer, window.kind != .layer || window.layerShown else {
            bridge.release(window, slot: slot)
            return
        }
        // HAL_PIXEL_FORMAT_RGBA_8888 and RGBX_8888, bytes R, G, B, A: DRM's
        // ABGR8888 and XBGR8888.
        let shmFormat = format == 2 ? UInt32(WL_SHM_FORMAT_XBGR8888.rawValue) : UInt32(WL_SHM_FORMAT_ABGR8888.rawValue)
        guard format == 1 || format == 2, shmFormats.contains(shmFormat) else {
            Self.reportOnce("the compositor has no shm format for Android's format \(format)")
            bridge.release(window, slot: slot)
            return
        }
        var held = window.buffers[slot]
        if let existing = held, existing.fd != fd || existing.width != width || existing.height != height
            || existing.stride != stride || existing.format != shmFormat {
            wl_buffer_destroy(existing.buffer)
            held = nil
        }
        if held == nil {
            let size = stride * height * 4
            let pool = wl_shm_create_pool(shm, fd, size)
            guard let buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride * 4, shmFormat) else {
                wl_shm_pool_destroy(pool)
                bridge.release(window, slot: slot)
                return
            }
            wl_shm_pool_destroy(pool)
            let release = BufferRelease(window: window, slot: slot)
            _ = wl_buffer_add_listener(buffer, Self.bufferListener, Unmanaged.passRetained(release).toOpaque())
            held = ARTDisplay.Window.HeldBuffer(fd: fd, width: width, height: height, stride: stride, format: shmFormat,
                                                buffer: buffer)
            window.buffers[slot] = held
        }
        wl_surface_attach(layer, held!.buffer, 0, 0)
        wl_surface_damage_buffer(layer, 0, 0, width, height)
        setContentDestination(window)
        wl_surface_commit(layer)
    }

    /// Which buffer a wl_buffer's release hands back.
    final class BufferRelease {
        weak var window: ARTDisplay.Window?
        let slot: Int32
        init(window: ARTDisplay.Window, slot: Int32) {
            self.window = window
            self.slot = slot
        }
    }

    nonisolated(unsafe) private static let bufferListener: UnsafeMutablePointer<wl_buffer_listener> = {
        let listener = UnsafeMutablePointer<wl_buffer_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_buffer_listener(release: { data, _ in
            guard let data else { return }
            let release = Unmanaged<BufferRelease>.fromOpaque(data).takeUnretainedValue()
            if let window = release.window { ARTDisplay.shared?.release(window, slot: release.slot) }
        }))
        return listener
    }()

    /// libgui wants a vsync: the next frame callback on the vsync window's
    /// root, whose done is the vsync. On the display thread.
    func wantVsync() {
        vsyncWanted = true
        if vsyncAskedAt == nil { vsyncAskedAt = ARTDisplay.now() }
        requestFrame()
    }

    private func requestFrame() {
        guard frameCallback == nil, let window = vsyncWindow, window.mapped,
              let surface = window.tick ?? window.root else { return }
        let callback = wl_surface_frame(surface)
        frameCallback = callback
        frameAskedAt = ARTDisplay.now()
        _ = wl_callback_add_listener(callback, Self.frameListener, context)
        // Damaged, so the compositor repaints it and answers.
        wl_surface_damage_buffer(surface, 0, 0, 1, 1)
        wl_surface_commit(surface)
    }

    private func dropFrameCallback() {
        if let frameCallback { wl_callback_destroy(frameCallback) }
        frameCallback = nil
        frameAskedAt = nil
        // Its callbacks say nothing of the window from now on.
        if let window = vsyncWindow, window.heldBack {
            window.heldBack = false
            updateHidden(window)
        }
    }

    /// Tells the window manager when the compositor stops or starts showing a
    /// toplevel, by either sign (its suspended state, or its frame callbacks
    /// held back): Android's window manager stops its activity, as with the
    /// display off, and resumes it.
    func updateHidden(_ window: ARTDisplay.Window) {
        let hidden = window.suspended || window.heldBack
        guard hidden != window.reportedHidden, window.toplevel != nil else { return }
        window.reportedHidden = hidden
        ARTDisplay.report("window \(window.id) \(hidden ? "hidden" : "shown") by the compositor"
            + (window.suspended ? " (suspended)" : window.heldBack ? " (frames held back)" : ""))
        bridge.postWindowEvent(kind: 2, window: window, width: hidden ? 1 : 0, height: 0)
    }

    /// How long the display thread may wait before the vsync window's frame
    /// callback counts as held back, in milliseconds, marking it hidden if
    /// it's held back now. Its callback stays asked for, so that its done
    /// says when the compositor shows it again.
    func heldBackTimeout() -> Int32? {
        guard let asked = frameAskedAt, let window = vsyncWindow, !window.heldBack else { return nil }
        let waited = (ARTDisplay.now() - asked) / 1_000_000
        if waited >= Self.heldBackLimit {
            window.heldBack = true
            updateHidden(window)
            return nil
        }
        return Int32(Self.heldBackLimit - waited)
    }

    /// The display has refreshed, or the vsync is overdue.
    private func deliverVsync() {
        vsyncAskedAt = nil
        guard vsyncWanted else { return }
        vsyncWanted = false
        // libgui asks again, through wantVsync, if receivers still want it.
        bridge.functions.vsync(ARTDisplay.now())
    }

    /// How long the display thread may wait before an overdue vsync, in
    /// milliseconds, delivering it if it's due now.
    func vsyncTimeout() -> Int32? {
        guard let asked = vsyncAskedAt else { return nil }
        let waited = (ARTDisplay.now() - asked) / 1_000_000
        // A frame period with no window; a few when callbacks are held.
        let limit: Int64 = vsyncWindow?.mapped == true ? 100 : 16
        if waited >= limit {
            deliverVsync()
            return vsyncAskedAt == nil ? nil : 0
        }
        return Int32(limit - waited)
    }

    nonisolated(unsafe) private static let frameListener: UnsafeMutablePointer<wl_callback_listener> = {
        let listener = UnsafeMutablePointer<wl_callback_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_callback_listener(done: { data, callback, _ in
            let wayland = Unmanaged<Wayland>.fromOpaque(data!).takeUnretainedValue()
            guard callback == wayland.frameCallback else { return }
            wl_callback_destroy(callback)
            wayland.frameCallback = nil
            wayland.frameAskedAt = nil
            if let window = wayland.vsyncWindow, window.heldBack {
                window.heldBack = false
                wayland.updateHidden(window)
            }
            wayland.deliverVsync()
        }))
        return listener
    }()

    // MARK: The seat

    nonisolated(unsafe) private static let seatListener: UnsafeMutablePointer<wl_seat_listener> = {
        let listener = UnsafeMutablePointer<wl_seat_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_seat_listener(
            capabilities: { data, seat, capabilities in
                guard let data else { return }
                Unmanaged<Wayland>.fromOpaque(data).takeUnretainedValue().capabilities(seat, capabilities)
            },
            name: { _, _, _ in }))
        return listener
    }()

    private func capabilities(_ seat: OpaquePointer?, _ capabilities: UInt32) {
        if capabilities & UInt32(WL_SEAT_CAPABILITY_KEYBOARD.rawValue) != 0, keyboard == nil {
            keyboard = wl_seat_get_keyboard(seat)
            _ = wl_keyboard_add_listener(keyboard, Self.keyboardListener, context)
        }
        if capabilities & UInt32(WL_SEAT_CAPABILITY_POINTER.rawValue) != 0, pointer == nil {
            pointer = wl_seat_get_pointer(seat)
            _ = wl_pointer_add_listener(pointer, Self.pointerListener, context)
        }
        if capabilities & UInt32(WL_SEAT_CAPABILITY_TOUCH.rawValue) != 0, touch == nil {
            touch = wl_seat_get_touch(seat)
            _ = wl_touch_add_listener(touch, Self.touchListener, context)
        }
    }

    private static func wayland(_ data: UnsafeMutableRawPointer?) -> Wayland? {
        data.map { Unmanaged<Wayland>.fromOpaque($0).takeUnretainedValue() }
    }

    nonisolated(unsafe) private static let keyboardListener: UnsafeMutablePointer<wl_keyboard_listener> = {
        let listener = UnsafeMutablePointer<wl_keyboard_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_keyboard_listener(
            // Keys are mapped by Android's key layout, not the keymap.
            keymap: { _, _, _, fd, _ in close(fd) },
            enter: { data, _, _, surface, _ in
                guard let wayland = wayland(data), let surface else { return }
                wayland.keyboardWindow = wayland.windows[surface]
                trace("keyboard on window \(wayland.keyboardWindow?.id ?? 0)")
                if let window = wayland.keyboardWindow { wayland.bridge.focusedWindowID = window.id }
            },
            leave: { data, _, _, _ in
                guard let wayland = wayland(data) else { return }
                wayland.keyboardWindow = nil
                wayland.held = nil
            },
            key: { data, _, _, _, key, state in
                guard let wayland = wayland(data), let window = wayland.keyboardWindow else { return }
                wayland.key(window, code: key, down: state == UInt32(WL_KEYBOARD_KEY_STATE_PRESSED.rawValue))
            },
            modifiers: { data, _, _, depressed, latched, locked, _ in
                guard let wayland = wayland(data) else { return }
                wayland.modifiers = depressed | latched
                wayland.lockedModifiers = locked
            },
            repeat_info: { data, _, rate, delay in
                guard let wayland = wayland(data) else { return }
                wayland.repeatRate = max(rate, 0)
                wayland.repeatDelay = max(delay, 0)
                if rate <= 0 { wayland.held = nil }
            }))
        return listener
    }()

    /// A key pressed or released; a pressed key, not a modifier, repeats
    /// while it's held, as Android's dispatcher repeats them.
    private func key(_ keyboardWindow: ARTDisplay.Window, code: UInt32, down: Bool) {
        let window = focusTarget(keyboardWindow)
        Self.trace("key \(code) \(down ? "down" : "up") on window \(keyboardWindow.id) to \(window.id) (Android's focus \(bridge.androidFocus?.id ?? 0), input \(window.input != nil))")
        let keyCode = bridge.waylandKey(window, code: code, down: down, modifiers: modifiers, locked: lockedModifiers)
        if down {
            if repeatRate > 0, keyCode != 0, !ARTDisplay.isModifier(keyCode) {
                held = Repeat(window: window, code: code, keyCode: keyCode, count: 0,
                              next: ARTDisplay.now() + Int64(repeatDelay) * 1_000_000)
            }
        } else if held?.code == code {
            held = nil
        }
    }

    /// Android's focused window if it's the keyboard's window or one of its
    /// dialogs or popups (which Wayland doesn't give the keyboard), else the
    /// keyboard's window.
    private func focusTarget(_ keyboardWindow: ARTDisplay.Window) -> ARTDisplay.Window {
        guard let focused = bridge.androidFocus, focused.input != nil else { return keyboardWindow }
        var ancestor: ARTDisplay.Window? = focused
        while let current = ancestor {
            if current === keyboardWindow { return focused }
            ancestor = current.parent
        }
        return keyboardWindow
    }

    /// Repeats the held key if it's due, and how long the display thread may
    /// wait for the next, in milliseconds.
    func repeatTimeout() -> Int32? {
        guard var repeating = held else { return nil }
        guard let keyboardWindow, repeating.window === focusTarget(keyboardWindow), repeating.window.input != nil else {
            held = nil
            return nil
        }
        let now = ARTDisplay.now()
        if now >= repeating.next {
            repeating.count += 1
            // From now, so a stalled thread doesn't send a burst.
            repeating.next = now + 1_000_000_000 / Int64(max(repeatRate, 1))
            held = repeating
            bridge.waylandKey(repeating.window, code: repeating.code, down: true, modifiers: modifiers,
                              locked: lockedModifiers, repeatCount: repeating.count)
        }
        return Int32(max((repeating.next - now) / 1_000_000, 0))
    }

    // MARK: The cursor

    /// A cursor's image from the theme: its buffer, size and hotspot.
    private struct CursorImage {
        let buffer: OpaquePointer
        let width: Int32
        let height: Int32
        let hotspot: (x: Int32, y: Int32)
    }

    private var cursorImages: [String: CursorImage] = [:]
    /// The cursor shown, and the serial of the pointer's last enter, which
    /// setting it takes.
    private var shownCursor: String?
    private var enterSerial: UInt32 = 0
    /// The cursor Android asked for over its views (setPointerIconType).
    var appCursor = "default"

    /// The cursor theme (XCURSOR_THEME, XCURSOR_SIZE) at the outputs' largest
    /// scale, and the surface cursors show on.
    private func loadCursorTheme() -> Bool {
        if cursorTheme != nil { return true }
        guard let shm, let compositor else { return false }
        let scale = max(outputs.map(\.scale).max() ?? 1, 1)
        let size = getenv("XCURSOR_SIZE").flatMap { Int32(String(cString: $0)) } ?? 24
        guard let theme = wl_cursor_theme_load(getenv("XCURSOR_THEME"), size * scale, shm) else {
            Self.reportOnce("no cursor theme")
            return false
        }
        cursorTheme = theme
        cursorSurface = wl_compositor_create_surface(compositor)
        wl_surface_set_buffer_scale(cursorSurface, scale)
        return true
    }

    /// A cursor by its CSS name, else the older X11 names themes also use.
    private func cursorImage(_ name: String) -> CursorImage? {
        if let image = cursorImages[name] { return image }
        guard loadCursorTheme(), let theme = cursorTheme else { return nil }
        let names = [name] + (Self.cursorFallbacks[name] ?? []) + ["default", "left_ptr"]
        for candidate in names {
            guard let cursor = wl_cursor_theme_get_cursor(theme, candidate), cursor.pointee.image_count > 0,
                  let image = cursor.pointee.images[0], let buffer = wl_cursor_image_get_buffer(image) else { continue }
            let found = CursorImage(buffer: buffer, width: Int32(image.pointee.width), height: Int32(image.pointee.height),
                                    hotspot: (Int32(image.pointee.hotspot_x), Int32(image.pointee.hotspot_y)))
            cursorImages[name] = found
            return found
        }
        Self.reportOnce("no \(name) cursor in the cursor theme")
        return nil
    }

    private static let cursorFallbacks: [String: [String]] = [
        "pointer": ["hand2", "hand1"], "text": ["xterm"], "wait": ["watch"], "progress": ["left_ptr_watch"],
        "help": ["question_arrow"], "crosshair": ["cross"], "not-allowed": ["crossed_circle"],
        "no-drop": ["crossed_circle"], "grab": ["openhand", "hand1"], "grabbing": ["closedhand", "fleur"],
        "all-scroll": ["fleur"], "move": ["fleur"], "copy": ["dnd-copy"], "alias": ["dnd-link"],
        "context-menu": ["left_ptr"], "cell": ["plus"], "vertical-text": ["xterm"],
        "ew-resize": ["sb_h_double_arrow"], "ns-resize": ["sb_v_double_arrow"],
        "nesw-resize": ["fd_double_arrow"], "nwse-resize": ["bd_double_arrow"],
        "n-resize": ["top_side"], "s-resize": ["bottom_side"], "w-resize": ["left_side"], "e-resize": ["right_side"],
        "nw-resize": ["top_left_corner"], "ne-resize": ["top_right_corner"],
        "sw-resize": ["bottom_left_corner"], "se-resize": ["bottom_right_corner"],
        "zoom-in": [], "zoom-out": [],
    ]

    /// The cursor for where the pointer is: a resize arrow over a captioned
    /// window's shadow, else Android's.
    private func cursorName() -> String {
        if let window = pointerWindow, let edges = resizeEdges(window, x: pointerX, y: pointerY) {
            let top = edges & UInt32(XDG_TOPLEVEL_RESIZE_EDGE_TOP.rawValue) != 0
            let bottom = edges & UInt32(XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM.rawValue) != 0
            let left = edges & UInt32(XDG_TOPLEVEL_RESIZE_EDGE_LEFT.rawValue) != 0
            let right = edges & UInt32(XDG_TOPLEVEL_RESIZE_EDGE_RIGHT.rawValue) != 0
            return (top ? "n" : bottom ? "s" : "") + (left ? "w" : right ? "e" : "") + "-resize"
        }
        return appCursor
    }

    /// Shows the cursor for where the pointer is, if it changed.
    func updateCursor() {
        guard let pointer, pointerWindow != nil else { return }
        let name = cursorName()
        guard name != shownCursor else { return }
        if name == "none" {
            wl_pointer_set_cursor(pointer, enterSerial, nil, 0, 0)
            shownCursor = name
            return
        }
        guard let image = cursorImage(name), let surface = cursorSurface else { return }
        let scale = max(outputs.map(\.scale).max() ?? 1, 1)
        wl_surface_attach(surface, image.buffer, 0, 0)
        wl_surface_damage_buffer(surface, 0, 0, image.width, image.height)
        wl_surface_commit(surface)
        wl_pointer_set_cursor(pointer, enterSerial, surface, image.hotspot.x / scale, image.hotspot.y / scale)
        shownCursor = name
    }

    nonisolated(unsafe) private static let pointerListener: UnsafeMutablePointer<wl_pointer_listener> = {
        let listener = UnsafeMutablePointer<wl_pointer_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_pointer_listener(
            enter: { data, _, serial, surface, x, y in
                guard let wayland = wayland(data), let surface else { return }
                wayland.pointerWindow = wayland.windows[surface]
                trace("pointer on window \(wayland.pointerWindow?.id ?? 0)")
                wayland.pointerX = wayland.pixels(x)
                wayland.pointerY = wayland.pixels(y)
                // A new enter: the compositor's cursor until it's set again.
                wayland.enterSerial = serial
                wayland.shownCursor = nil
                wayland.updateCursor()
            },
            leave: { data, _, _, _ in wayland(data)?.pointerWindow = nil },
            motion: { data, _, _, x, y in
                guard let wayland = wayland(data), let window = wayland.pointerWindow else { return }
                wayland.pointerX = wayland.pixels(x)
                wayland.pointerY = wayland.pixels(y)
                wayland.updateCursor()
                wayland.bridge.pointerMoved(window, x: wayland.pointerX, y: wayland.pointerY)
            },
            button: { data, _, serial, _, button, state in
                guard let wayland = wayland(data), let window = wayland.pointerWindow else { return }
                if state == UInt32(WL_POINTER_BUTTON_STATE_PRESSED.rawValue) {
                    wayland.pressSerial = serial
                    if button == 0x110, wayland.resizeFromEdge(window, x: wayland.pointerX, y: wayland.pointerY) { return }
                }
                // Linux's BTN_LEFT, BTN_RIGHT and BTN_MIDDLE.
                let android: Int32
                switch button {
                case 0x110: android = ARTDisplay.Android.buttonPrimary
                case 0x111: android = ARTDisplay.Android.buttonSecondary
                case 0x112: android = ARTDisplay.Android.buttonTertiary
                default: return
                }
                wayland.bridge.pointerButton(window, button: android,
                                             down: state == UInt32(WL_POINTER_BUTTON_STATE_PRESSED.rawValue),
                                             x: wayland.pointerX, y: wayland.pointerY)
            },
            axis: { data, _, _, axis, value in
                guard let wayland = wayland(data), let window = wayland.pointerWindow else { return }
                // About 10 per wheel notch, down and right positive; Android's
                // scroll is in notches, up and right positive.
                let notches = Float(wl_fixed_to_double(value)) / 10
                let vertical = axis == UInt32(WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue)
                wayland.bridge.pointerScrolled(window, x: wayland.pointerX, y: wayland.pointerY,
                                               vertical: vertical ? -notches : 0, horizontal: vertical ? 0 : notches)
            },
            frame: { _, _ in },
            axis_source: { _, _, _ in },
            axis_stop: { _, _, _, _ in },
            axis_discrete: { _, _, _, _ in },
            axis_value120: { _, _, _, _ in },
            axis_relative_direction: { _, _, _, _ in }))
        return listener
    }()

    nonisolated(unsafe) private static let touchListener: UnsafeMutablePointer<wl_touch_listener> = {
        let listener = UnsafeMutablePointer<wl_touch_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_touch_listener(
            down: { data, _, serial, _, surface, id, x, y in
                guard let wayland = wayland(data), let surface, let window = wayland.windows[surface] else { return }
                wayland.pressSerial = serial
                if wayland.touchWindows.isEmpty, wayland.resizeFromEdge(window, x: wayland.pixels(x), y: wayland.pixels(y)) {
                    return
                }
                wayland.touchWindows[id] = window
                trace("touch \(id) down on window \(window.id) at \(wayland.pixels(x)),\(wayland.pixels(y)) offset \(window.inputOffset) input \(window.input != nil)")
                wayland.bridge.touched(window, action: .down, id: UInt64(bitPattern: Int64(id)),
                                       x: wayland.pixels(x), y: wayland.pixels(y), pressure: 1)
            },
            up: { data, _, _, _, id in
                guard let wayland = wayland(data), let window = wayland.touchWindows.removeValue(forKey: id) else { return }
                wayland.bridge.touched(window, action: .up, id: UInt64(bitPattern: Int64(id)), x: nil, y: nil, pressure: 0)
            },
            motion: { data, _, _, id, x, y in
                guard let wayland = wayland(data), let window = wayland.touchWindows[id] else { return }
                wayland.bridge.touched(window, action: .move, id: UInt64(bitPattern: Int64(id)),
                                       x: wayland.pixels(x), y: wayland.pixels(y), pressure: 1)
            },
            frame: { _, _ in },
            cancel: { data, _ in
                guard let wayland = wayland(data) else { return }
                for (id, window) in wayland.touchWindows {
                    wayland.bridge.touched(window, action: .up, id: UInt64(bitPattern: Int64(id)), x: nil, y: nil, pressure: 0)
                }
                wayland.touchWindows.removeAll()
            },
            shape: { _, _, _, _, _ in },
            orientation: { _, _, _, _ in }))
        return listener
    }()

    // MARK: Reporting

    nonisolated(unsafe) private static var reported = Set<String>()

    static func reportOnce(_ message: String) {
        guard reported.insert(message).inserted else { return }
        ARTDisplay.report(message)
    }
}
