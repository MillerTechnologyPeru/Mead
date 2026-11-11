import CMeadWayland
import Glibc

/// ART's display bridge's Wayland client: the connection, its globals, the
/// outputs (the display), the seat (keyboard, pointer, touch) and each
/// window's surfaces. All of it is used on the display thread only, which
/// dispatches the connection's default queue; Mesa's EGL, on hwui's render
/// thread, uses queues of its own on the same connection.
///
/// A window is a root `wl_surface` with an `xdg_toplevel` (or `xdg_popup`),
/// holding a 1×1 black buffer scaled to the window by its viewport, and a
/// layer: a subsurface over it, desynchronized, where the window's libgui
/// surface is shown. CPU frames are the surface's gralloc buffers, attached
/// in place as `wl_shm` buffers and handed back to libgui when the
/// compositor releases them; GPU frames come from a `wl_egl_window` on the
/// layer, which EGL commits. Frame callbacks on a window's root surface are
/// the display's vsync.
final class Wayland {
    let display: OpaquePointer
    private(set) var compositor: OpaquePointer?
    private(set) var subcompositor: OpaquePointer?
    private(set) var shm: OpaquePointer?
    private(set) var wmBase: OpaquePointer?
    private(set) var wmBaseVersion: UInt32 = 0
    private(set) var viewporter: OpaquePointer?
    private(set) var decorations: OpaquePointer?
    private(set) var seat: OpaquePointer?
    private(set) var shmFormats = Set<UInt32>()
    private var registry: OpaquePointer?

    /// An output: a monitor or a device's screen.
    final class Output {
        let proxy: OpaquePointer
        var width: Int32 = 0
        var height: Int32 = 0
        var refresh: Int32 = 0  // mHz
        var millimetersWide: Int32 = 0
        var millimetersHigh: Int32 = 0
        var scale: Int32 = 1
        init(_ proxy: OpaquePointer) { self.proxy = proxy }
    }

    private(set) var outputs: [Output] = []

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

    /// The windows, by their root and layer surfaces.
    var windows: [OpaquePointer: ARTDisplay.Window] = [:]
    /// A 1×1 black buffer for windows' root surfaces, scaled by viewports.
    private var background: OpaquePointer?
    /// The window whose root surface's frame callbacks are vsync.
    var vsyncWindow: ARTDisplay.Window?
    /// Whether libgui wants a vsync, and the frame callback asked for it.
    private var vsyncWanted = false
    private var frameCallback: OpaquePointer?
    /// When the vsync was asked for: delivered without a frame callback
    /// once it's overdue, when no window is mapped or the compositor holds
    /// callbacks back (a hidden window), so Choreographer never stalls.
    private var vsyncAskedAt: Int64?

    unowned let bridge: ARTDisplay

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
            wmBaseVersion = min(version, 3)
            wmBase = bind(mead_xdg_wm_base_interface(), 3)
            _ = xdg_wm_base_add_listener(wmBase, Self.wmBaseListener, context)
        case "wp_viewporter": viewporter = bind(mead_wp_viewporter_interface(), 1)
        case "zxdg_decoration_manager_v1": decorations = bind(mead_zxdg_decoration_manager_v1_interface(), 1)
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
            geometry: { data, _, _, _, width, height, _, _, _, _ in
                guard let data else { return }
                let output = Unmanaged<Output>.fromOpaque(data).takeUnretainedValue()
                output.millimetersWide = width
                output.millimetersHigh = height
            },
            mode: { data, _, flags, width, height, refresh in
                guard let data, flags & UInt32(WL_OUTPUT_MODE_CURRENT.rawValue) != 0 else { return }
                let output = Unmanaged<Output>.fromOpaque(data).takeUnretainedValue()
                output.width = width
                output.height = height
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

    /// The 1×1 black buffer roots show, scaled to their windows.
    private func backgroundBuffer() -> OpaquePointer? {
        if let background { return background }
        let fd = mead_wayland_memfd("mead-background")
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, 4) == 0 else { return nil }
        var black: UInt32 = 0xFF00_0000
        _ = Glibc.write(fd, &black, 4)
        let pool = wl_shm_create_pool(shm, fd, 4)
        background = wl_shm_pool_create_buffer(pool, 0, 1, 1, 4, UInt32(WL_SHM_FORMAT_ARGB8888.rawValue))
        wl_shm_pool_destroy(pool)
        return background
    }

    /// The window's surfaces: its root, as a toplevel or a popup of its
    /// parent's, and the layer over it; mapped once the compositor configures
    /// it. False when the compositor refused.
    func makeSurfaces(for window: ARTDisplay.Window, title: String) -> Bool {
        guard let root = wl_compositor_create_surface(compositor),
              let xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, root) else { return false }
        window.root = root
        window.xdgSurface = xdgSurface
        let windowContext = Unmanaged.passUnretained(window).toOpaque()
        _ = xdg_surface_add_listener(xdgSurface, Self.xdgSurfaceListener, windowContext)
        switch (window.kind, window.parent) {
        case (.popup, let parent?) where parent.xdgSurface != nil:
            let positioner = xdg_wm_base_create_positioner(wmBase)
            xdg_positioner_set_size(positioner, max(window.width, 1), max(window.height, 1))
            xdg_positioner_set_anchor_rect(positioner, window.x, window.y, 1, 1)
            xdg_positioner_set_anchor(positioner, UInt32(XDG_POSITIONER_ANCHOR_TOP_LEFT.rawValue))
            xdg_positioner_set_gravity(positioner, UInt32(XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT.rawValue))
            xdg_positioner_set_constraint_adjustment(positioner,
                UInt32(XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X.rawValue | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y.rawValue))
            window.popup = xdg_surface_get_popup(xdgSurface, parent.xdgSurface, positioner)
            xdg_positioner_destroy(positioner)
            _ = xdg_popup_add_listener(window.popup, Self.popupListener, windowContext)
        default:
            let toplevel = xdg_surface_get_toplevel(xdgSurface)
            window.toplevel = toplevel
            _ = xdg_toplevel_add_listener(toplevel, Self.toplevelListener, windowContext)
            xdg_toplevel_set_title(toplevel, title)
            xdg_toplevel_set_app_id(toplevel, "mead")
            if window.kind == .dialog, let parent = window.parent?.toplevel {
                xdg_toplevel_set_parent(toplevel, parent)
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
        window.eglWindow = wl_egl_window_create(layer, max(window.width, 1), max(window.height, 1))
        windows[root] = window
        windows[layer] = window
        map(window)
        return true
    }

    /// Maps a window: its first commit, without a buffer, then waits for the
    /// compositor's configure, which attaches its background.
    func map(_ window: ARTDisplay.Window) {
        guard let root = window.root, !window.mapped else { return }
        window.configured = false
        wl_surface_commit(root)
        var waited = 0
        while !window.configured, waited < 50, wl_display_roundtrip(display) >= 0 {
            waited += 1
        }
        window.mapped = true
        if vsyncWindow == nil || vsyncWindow?.mapped == false {
            vsyncWindow = window
            if vsyncWanted { requestFrame() }
        }
    }

    /// Unmaps a window: its root without a buffer, which hides the layer too.
    func unmap(_ window: ARTDisplay.Window) {
        guard let root = window.root, window.mapped else { return }
        wl_surface_attach(root, nil, 0, 0)
        wl_surface_commit(root)
        window.mapped = false
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
        if let size = window.pendingSize, size.width > 0, size.height > 0,
           size.width != window.width || size.height != window.height {
            bridge.resize(window, width: size.width, height: size.height)
        }
        window.pendingSize = nil
        guard let root = window.root else { return }
        wl_surface_attach(root, backgroundBuffer(), 0, 0)
        wp_viewport_set_destination(window.rootViewport, max(window.width, 1), max(window.height, 1))
        wl_surface_damage_buffer(root, 0, 0, 1, 1)
        wl_surface_commit(root)
        window.configured = true
    }

    /// The window's surfaces at a new size.
    func resizeSurfaces(_ window: ARTDisplay.Window) {
        let width = max(window.width, 1), height = max(window.height, 1)
        wp_viewport_set_destination(window.rootViewport, width, height)
        wp_viewport_set_destination(window.layerViewport, width, height)
        if let eglWindow = window.eglWindow {
            wl_egl_window_resize(eglWindow, width, height, 0, 0)
        }
        if let root = window.root, window.mapped {
            wl_surface_commit(root)
        }
        if let layer = window.layer {
            wl_surface_commit(layer)
        }
    }

    /// A popup moved within its parent.
    func reposition(_ window: ARTDisplay.Window) {
        guard let popup = window.popup, wmBaseVersion >= 3 else { return }
        let positioner = xdg_wm_base_create_positioner(wmBase)
        xdg_positioner_set_size(positioner, max(window.width, 1), max(window.height, 1))
        xdg_positioner_set_anchor_rect(positioner, window.x, window.y, 1, 1)
        xdg_positioner_set_anchor(positioner, UInt32(XDG_POSITIONER_ANCHOR_TOP_LEFT.rawValue))
        xdg_positioner_set_gravity(positioner, UInt32(XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT.rawValue))
        xdg_popup_reposition(popup, positioner, 0)
        xdg_positioner_destroy(positioner)
    }

    func destroySurfaces(_ window: ARTDisplay.Window) {
        if vsyncWindow === window {
            dropFrameCallback()
            vsyncWindow = nil
        }
        if keyboardWindow === window { keyboardWindow = nil }
        if pointerWindow === window { pointerWindow = nil }
        touchWindows = touchWindows.filter { $0.value !== window }
        for buffer in window.buffers.values { wl_buffer_destroy(buffer.buffer) }
        window.buffers.removeAll()
        if let eglWindow = window.eglWindow { wl_egl_window_destroy(eglWindow) }
        if let viewport = window.layerViewport { wp_viewport_destroy(viewport) }
        if let subsurface = window.subsurface { wl_subsurface_destroy(subsurface) }
        if let layer = window.layer {
            windows[layer] = nil
            wl_surface_destroy(layer)
        }
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
            configure: { data, _, width, height, _ in
                guard let data else { return }
                Unmanaged<ARTDisplay.Window>.fromOpaque(data).takeUnretainedValue().pendingSize = (width, height)
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
        guard let layer = window.layer else {
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
        wp_viewport_set_destination(window.layerViewport, max(window.width, 1), max(window.height, 1))
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
        guard frameCallback == nil, let window = vsyncWindow, window.mapped, let root = window.root else { return }
        let callback = wl_surface_frame(root)
        frameCallback = callback
        _ = wl_callback_add_listener(callback, Self.frameListener, context)
        // Damaged, so the compositor repaints it and answers.
        wl_surface_damage_buffer(root, 0, 0, 1, 1)
        wl_surface_commit(root)
    }

    private func dropFrameCallback() {
        if let frameCallback { wl_callback_destroy(frameCallback) }
        frameCallback = nil
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
                if let window = wayland.keyboardWindow { wayland.bridge.focusedWindowID = window.id }
            },
            leave: { data, _, _, _ in wayland(data)?.keyboardWindow = nil },
            key: { data, _, _, _, key, state in
                guard let wayland = wayland(data), let window = wayland.keyboardWindow else { return }
                wayland.bridge.waylandKey(window, code: key, down: state == UInt32(WL_KEYBOARD_KEY_STATE_PRESSED.rawValue),
                                          modifiers: wayland.modifiers, locked: wayland.lockedModifiers)
            },
            modifiers: { data, _, _, depressed, latched, locked, _ in
                guard let wayland = wayland(data) else { return }
                wayland.modifiers = depressed | latched
                wayland.lockedModifiers = locked
            },
            repeat_info: { _, _, _, _ in }))
        return listener
    }()

    nonisolated(unsafe) private static let pointerListener: UnsafeMutablePointer<wl_pointer_listener> = {
        let listener = UnsafeMutablePointer<wl_pointer_listener>.allocate(capacity: 1)
        listener.initialize(to: wl_pointer_listener(
            enter: { data, _, _, surface, x, y in
                guard let wayland = wayland(data), let surface else { return }
                wayland.pointerWindow = wayland.windows[surface]
                wayland.pointerX = Float(wl_fixed_to_double(x))
                wayland.pointerY = Float(wl_fixed_to_double(y))
            },
            leave: { data, _, _, _ in wayland(data)?.pointerWindow = nil },
            motion: { data, _, _, x, y in
                guard let wayland = wayland(data), let window = wayland.pointerWindow else { return }
                wayland.pointerX = Float(wl_fixed_to_double(x))
                wayland.pointerY = Float(wl_fixed_to_double(y))
                wayland.bridge.pointerMoved(window, x: wayland.pointerX, y: wayland.pointerY)
            },
            button: { data, _, _, _, button, state in
                guard let wayland = wayland(data), let window = wayland.pointerWindow else { return }
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
            down: { data, _, _, _, surface, id, x, y in
                guard let wayland = wayland(data), let surface, let window = wayland.windows[surface] else { return }
                wayland.touchWindows[id] = window
                wayland.bridge.touched(window, action: .down, id: UInt64(bitPattern: Int64(id)),
                                       x: Float(wl_fixed_to_double(x)), y: Float(wl_fixed_to_double(y)), pressure: 1)
            },
            up: { data, _, _, _, id in
                guard let wayland = wayland(data), let window = wayland.touchWindows.removeValue(forKey: id) else { return }
                wayland.bridge.touched(window, action: .up, id: UInt64(bitPattern: Int64(id)), x: nil, y: nil, pressure: 0)
            },
            motion: { data, _, _, id, x, y in
                guard let wayland = wayland(data), let window = wayland.touchWindows[id] else { return }
                wayland.bridge.touched(window, action: .move, id: UInt64(bitPattern: Int64(id)),
                                       x: Float(wl_fixed_to_double(x)), y: Float(wl_fixed_to_double(y)), pressure: 1)
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
