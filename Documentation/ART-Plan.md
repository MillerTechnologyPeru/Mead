# Mead on ART: replacing MeadJNI

Mead today runs an app's native libraries on its own Java world, MeadJNI: a
JVM written in Swift, with Android's and Java's classes reimplemented in Swift
(MeadJava) and each game's own Java rewritten in Swift (MeadMinecraft,
MeadUnity). This plan replaces that with Android's real runtime:

- **ART** runs every app's dex, compiled ahead of time by **dex2oat**.
- **Core Java** is Android's own core library (libcore), unchanged.
- **The Android framework** is AOSP's, mostly unchanged.
- **Swift** provides only native-method implementations, through
  **swift-java**, where Android meets Linux: the SDL bridge (window, surface,
  display, input, vsync), audio, the in-process system services and the
  runtime's hosting. There is no fake JNI runtime: every JNI call goes to ART.
- **C and C++** that already exist (AOSP's native libraries, Mead's loader,
  bionic shims and providers) carry the rest, and are replaced with Swift
  only where it pays.

What stays from Mead: the ELF loader, the bionic shims, and the providers
(`libandroid`, EGL, Vulkan, OpenSL ES, `liblog`), because apps' NDK libraries
are still bionic code. What goes: MeadJNI, CMeadJNI, MeadMacros, MeadJava,
MeadMinecraft, MeadUnity and the three activity runners, because the APK's
own Java (Minecraft's, Unity's, GameActivity's) now runs as it is.

## Targets

- **ROCKNIX first**: the Retroid Pocket 5 and similar handhelds. ROCKNIX's
  root filesystem is read-only and has no package manager, so Mead ships
  everything it needs (ART, its libraries, the boot image) in its own
  directory under `/storage`, as it does the Swift runtime today.
- **Debian 13 with GNOME** second: devices with 4–8 GB of RAM, such as the
  Duet 3.
- Both are arm64 with glibc. Building on the oldest glibc of the targets
  (Debian's) gives binaries that run on both.

Memory matters on these devices: the boot image, ART's heap limits and
dex2oat's memory use are set for 4 GB devices, with one app at a time.

## Goals and non-goals

Goals:

- Run any APK's Java as Android does, so a new app needs no Swift rewrite of
  its Java.
- Keep games that work today working: Minecraft, Defense Zone 2 HD,
  Subnautica: Below Zero.
- Run ordinary (non-game) apps that don't need Google Play Services.
- Stay a single process per app with no second operating system.

Non-goals:

- Google Play Services. Apps that need them stay out of scope unless microG
  is chosen later, which is the user's call.
- Binder across processes, at first. Services are in-process (see phase 5).
- A zygote, for now. One app runs at a time on the target devices; see
  "Later".
- Rewriting ART, libcore or the framework's Java in Swift.

Rules carried over unchanged: never report a license, entitlement or
integrity check as passing unless the real signed answer verifies; don't
route around pairip-encrypted code or data without asking; never handle the
user's Google credentials.

## Target architecture

```
 app process (one per app, forked from Mead's zygote)
 ┌──────────────────────────────────────────────────────────────────┐
 │ App dex ─ dex2oat ─▶ native code   (AndroidX, Compose, game Java) │
 │ AOSP framework.jar  (Activity, View, widgets, resources, …)       │
 │ libcore             (java.*, javax.*, dalvik.*)                    │
 │──────────────────────────── ART (glibc) ──────────────────────────│
 │ JNI natives:                                                       │
 │   AOSP C++  libandroid_runtime, libandroidfw, libhwui + Skia,      │
 │             libbinder (in-process), libutils, libbase              │
 │   Swift     (swift-java)  Wayland surfaces, display, input, vsync, │
 │             audio, system services, runtime hosting                │
 │──────────────────── Mead loader + bionic shims ───────────────────│
 │ App NDK .so ─▶ providers: libandroid, EGL, Vulkan, OpenSL ES, log  │
 │───── glibc, Wayland, SDL3 (gamepads, audio), Mesa ────────────────│
 └──────────────────────────────────────────────────────────────────┘
```

How Swift and C++ share the framework's natives: AOSP's
`libandroid_runtime` registers natives for most framework classes. Mead
loads it, then registers its own Swift natives with `RegisterNatives` for the
classes it takes over (`android.view.Surface`, `InputEventReceiver`,
`DisplayEventReceiver`, `AudioTrack`, and so on). A later registration
replaces an earlier one, so C++ can be swapped for Swift one class at a time.

## What changes in Mead

| Target | Today | After |
|---|---|---|
| MeadLoader, MeadLoaderCore | ELF loader for bionic `.so` | Kept. Also the backend for ART's native library loading |
| CMeadBionic, MeadBionic | bionic over glibc | Kept. Signal handling chains through ART's `libsigchain` |
| MeadEGL, MeadVulkan, MeadOpenSLES | Providers | Kept |
| MeadWindow, CMeadWindow | SDL bindings | Kept, for gamepads and audio, and for MeadAndroid until phase 7; ART's windows go to Wayland (see "The display bridge on Wayland") |
| MeadInterface | Loader/provider interface | Kept |
| MeadAndroid | Runners plus `libandroid` provider | Runners removed. `libandroid` kept, with `ANativeWindow_fromSurface`, `AAssetManager_fromJava` and `AInputQueue` reading the framework's real objects |
| MeadJNI, CMeadJNI, MeadMacros | Fake JNI runtime | **Removed** |
| MeadJava | Java and Android classes in Swift | **Removed** |
| MeadMinecraft, MeadUnity | Games' Java in Swift | **Removed**: the APK's Java runs |
| MeadGooglePlay, MeadGoogleLogin, MeadCrypto | License verification, login | Reviewed in phase 7 |
| **MeadRuntime** (new, Swift) | | Starts ART, boot classpath, native library loading, zygote |
| **MeadFramework** (new, Swift) | | swift-java natives: SDL bridge, audio, system services |
| **mead-framework.jar** (new, Java) | | Small Java classes for Mead's services and natives, e.g. `MeadActivityManager extends IActivityManager.Stub` with `native` methods |
| **Build tooling** (new) | | ART, AOSP natives, Skia, boot image, built in `mead-dev` |

## Dependencies

Each dependency Mead changes is forked into its own repository under
MillerTechnologyPeru, and Mead's build fetches it from there:

- **art_standalone** (fork of android_translation_layer/art_standalone):
  ART, libcore, `libnativehelper`, `libandroidfw`, `libbase`, `liblog` and
  their AOSP dependencies, built with AOSP's makefiles and GCC. Its ART is
  roughly Android 10–11 (OAT version `17x`, dex up to 039); the rest comes
  from Android 6.0.1, so it mixes releases (see phase 3).
- **wolfSSL** for its Conscrypt replacement, built from an upstream release
  with `--enable-jni`. Forked only if it needs changes. Its licence (GPL-2.0)
  is a reason to move to BoringSSL with the framework.
- Later, the AOSP framework repositories, as each is needed.

`bionic_translation` (ATL's loader for bionic libraries) is not needed: ART
calls only `bionic_dlopen`, `bionic_dlsym`, `bionic_dlerror` and
`bionic_dlclose` from it, through `libdl_bio`, and Mead's bionic layer
(`CMeadBionic/bionic_dl.c`) already exports those four with the same
signatures, backed by Mead's loader. The fork makes `libdl_bio` optional
(upstream lists that as a TODO), with a plain glibc fallback for running ART
outside Mead.

art_standalone only supports building on the machine it targets, so ART is
built natively on an arm64 Debian device, not in Docker.

## Decisions to make in phase 0

1. **Where ART comes from.**
   - *art_standalone* (ATL's): builds on arm64 Linux today, but mixes
     releases (ART and libcore newer, the rest from Android 6.0.1), brings its
     own linker for bionic libraries (`bionic_translation`, which overlaps
     Mead's loader) and uses wolfSSL instead of BoringSSL.
   - *One AOSP release built for glibc*: ART, libcore and the framework from
     the same tag, so the framework's dependencies on ART internals match. AOSP
     builds ART for glibc hosts only on x86_64; arm64 glibc needs porting.
   - Decided: art_standalone's ART (Android 10) for phases 1–2, then
     Android 10 for everything in phase 3.
2. **Where the framework's Java and natives come from.** Build `framework.jar`
   and its natives from the chosen release's source, or take a matching AOSP
   build's prebuilts (`framework.jar` is dex; its natives are bionic and could
   run through Mead's loader). Recommendation: prebuilt `framework.jar` from
   the release, natives built for glibc, starting with what art_standalone
   already builds (`libandroidfw`).
3. **TLS library.** BoringSSL as AOSP has it, or wolfSSL as art_standalone
   has it. Recommendation: BoringSSL, to match Conscrypt.
4. **Which swift-java pieces.** Use the SwiftJava runtime and macros
   (`@JavaClass` wrappers to call Java, `@JavaImplementation` for natives) and
   `wrap-java` for Swift wrappers of framework classes. jextract's JNI mode
   isn't used for framework classes: it writes final classes with no
   superclass, and apps must subclass the framework.

## Phases

Each phase ends with something that runs on the Retroid Pocket 5 (ROCKNIX,
sway) and the Duet (Debian, GNOME Wayland), and with the Docker gate passing.

### Phase 1: ART runs

- Fork art_standalone; make `libdl_bio` optional.
- Build wolfSSL and art_standalone natively on the Duet (Debian), into a
  prefix Mead can ship; run a hello-world dex with `dalvikvm64` there and on
  the Retroid (ROCKNIX), with everything from that prefix.
- Generate a boot image with dex2oat for arm64 and check apps' dex compiles
  against it.

Exit: a dex `main` prints on both devices, from AOT-compiled code.

### Phase 2: Mead hosts ART

- **MeadRuntime** (Swift): loads `libart`, calls `JNI_CreateJavaVM` with the
  boot classpath and image, attaches threads, sets up `ANDROID_DATA` and the
  dex2oat cache under `~/.mead`.
- **Native library loading**: ART's `bionic_dlopen` resolves to Mead's
  bionic layer instead of `libdl_bio`, so `System.loadLibrary` of a bionic
  `.so` goes through Mead's loader and `JNI_OnLoad` gets ART's `JavaVM`. The
  bionic shims and providers apply unchanged.
- **Signals**: ART catches `SIGSEGV` for null checks and stack overflow
  through `libsigchain`. Mead's bionic `sigaction` and its crash report chain
  through it instead of replacing its handler.
- **swift-java in**: SwiftJava runtime and macros added; a first Swift native
  (a `Log` class) registered and called from Java.

Exit: a dex that loads a bionic `.so` (an NDK sample) runs, with the `.so`
calling back into Java through ART's JNI.

### Phase 3: one Android release, and the framework's Java

The release is **Android 10** (API 29), tag `android-security-10.0.0_r75`:
art_standalone's ART was rebased on it, its concurrent-copying collector
needs nothing special from the kernel, and the target apps need API 24 or
later. The fork's libcore was Android 8.1 (`android-8.1.0_r81`), so
everything else moves to Android 10 to match.

- **Java (dex) from AOSP's own build.** The boot class path (`core-oj`,
  `core-libart` with ICU4J inside it, `conscrypt`, `okhttp`, `bouncycastle`,
  `apache-xml`, then `framework`, `ext`, `telephony-common`, `voip-common`,
  `ims-common`, `updatable-media` and `android.test.base`) is built by AOSP's
  build system from an Android 10 tree on an x86_64 host (the Optiplex;
  `Scripts/aosp`). Dex is independent of the architecture, so these are
  what Android 10 itself ships. ICU4J's data (`icudt63l.dat`) and the time
  zones come from the same tree and install to `share/art/etc`, which
  `ANDROID_RUNTIME_ROOT` and `ANDROID_TZDATA_ROOT` name.
- **Native code built for arm64 glibc** from the same tag, on an arm64
  device: libcore's (`libjavacore`, `libopenjdk`, `libandroidio`, with
  libnativehelper; done: linked with the distribution's ICU4C, OpenSSL 3
  for `NativeBN`, Expat and zlib, and checked by `Tests/ART/CoreCheck.java`
  on the Retroid and the Duet), Conscrypt's
  (`libjavacrypto`, with BoringSSL in place of wolfSSL; done: BoringSSL is
  linked in statically with its symbols hidden, so it never meets the
  distribution's OpenSSL, and Android's CA certificates install to
  `share/art/etc/security/cacerts`, which `ANDROID_ROOT` names; checked by
  `Tests/ART/CryptoCheck.java`, TLS 1.3 included), and the
  framework's base libraries: `libandroid_runtime`, `libandroidfw`,
  `libbinder` (used in-process, for `Parcel` and local binders),
  `libutils`, `libcutils`, `libbase`, `libziparchive`, ICU. Done so far:
  Android 10's `libandroidfw`, `libbinder` and a first `libandroid_runtime`
  (Log, SystemClock, SystemProperties, Trace, Binder, Parcel, AssetManager,
  ApkAssets, StringBlock, XmlBlock), on the fork's newer `libutils`,
  `libbase` and `libziparchive`. `libandroid_runtime` registers its JNI from
  `JNI_OnLoad`, which Mead's `ART` calls right after the VM starts, as
  `app_process` would, and loads `$ANDROID_ROOT/build.prop` as init does.
  `ANDROID_ROOT` is Android's `/system` (`share/art`), with
  `framework/framework-res.apk`; `BOOTCLASSPATH` is in the environment as on
  Android. The rest of the framework's JNI comes with the phases that need
  it (graphics, views and input in phase 4).
- Stub what reaches the system: `ServiceManager` returns Mead's in-process
  services (phase 5); anything else fails cleanly.

Exit: a dex creates `Context`-free framework objects (`Bundle`, `Intent`,
`Parcel` round trips, `Resources` from an APK's `resources.arsc`). Met:
`Tests/ART/FrameworkCheck.java` passes on the Retroid and the Duet,
reading `framework-res.apk`'s resources. The `ServiceManager` stub waits for
phase 5's services.

### Phase 4: the SDL bridge (Swift)

Swift natives through swift-java, registered over the AOSP C++ ones:

- **Surface and windows**: a `Surface` backed by an SDL window; its native
  pointer is Mead's `ANativeWindow`, so EGL, Vulkan and `hwui` draw to it
  through Mead's existing EGL shim (`wl_egl_window` on Wayland). Replaces
  `libgui`, BufferQueue and SurfaceFlinger.
- **Display**: size, density, refresh rate, rotation from SDL.
- **Vsync**: `DisplayEventReceiver` and `Choreographer` frames from the
  window's frame timing.
- **Input**: SDL events become `MotionEvent` and `KeyEvent` delivered through
  `InputEventReceiver`, replacing input channels. Gamepads are listed through
  `InputManager`. Text input through SDL's text input and `InputConnection`.
- **Audio**: `AudioTrack` and `AudioRecord` natives over SDL audio or
  PipeWire; AAudio for NDK code alongside the existing OpenSL ES provider.

Exit: a minimal `Activity` with a `View` that draws with `Canvas` and takes
touches, keys and a gamepad, on both devices.

How the graphics stack is built, as of the work so far:

- **Skia** is Android 10's (`external/skia`), built from its Android
  target with a Mead configuration (Android's, without RAW, HEIF and PDF),
  the GL and Vulkan backends, and AOSP's libjpeg-turbo inside it (Debian's
  and ROCKNIX's libjpeg differ in soname). FreeType, libpng, libwebp,
  HarfBuzz, Expat and ICU are the distribution's; ROCKNIX has them all with
  Debian 13's sonames. Done. Built with GCC, Skia's software raster
  pipeline is scalar (its NEON code is clang-only); building Skia with clang
  is a later speedup.
- **minikin** is Android 10's, over the distribution's HarfBuzz and ICU.
  Done.
- **libui** stays AOSP's, built without BufferHub (Android's vendor
  configuration), with its HIDL-generated graphics types carried as
  generated headers and libhidl's base for them. Only its gralloc is Mead's:
  buffers in memfd shared memory, so a handle can go to another process as
  it is. libnativewindow, libsync and libgrallocusage are AOSP's. Done.
- **libgui** is Mead's: hwui uses it at exactly the bridge points (`Surface`
  as the `ANativeWindow` it renders to, `SurfaceComposerClient`'s display
  info, `DisplayEventReceiver` for vsync). Mead provides those classes under
  AOSP's names, in C++, over a C interface (`mead/gui.h`) that the Swift SDL
  bridge fills in: `mead_gui_set_display`, `mead_gui_vsync`, and
  `mead_surface_create`, whose surface presents each queued frame to a
  callback. Until the bridge delivers vsync, a timer at the display's
  refresh rate does. `SyncFeatures` is AOSP's. Done, untried with a window.
- **hwui** is Android 10's, with the GL and Vulkan pipelines, linked with
  Mesa's EGL and Vulkan; EGL's and GLES's extension functions, which
  Android's libraries export, are looked up with `eglGetProcAddress`. Built
  without TextureView's `SurfaceTexture`, which needs libgui's `BufferQueue`.
  Done.
- **The graphics JNI** (Bitmap, BitmapFactory, Canvas, Paint, Path, Matrix,
  Region, Shader, Typeface, fonts, text, VectorDrawable, ImageDecoder,
  HardwareBuffer) is in `libandroid_runtime`, without Movie (GIF),
  SurfaceTexture and PDF. `Tests/ART/GraphicsCheck.java` draws with
  `Canvas` into a `Bitmap` and round-trips PNG and JPEG: it passes on both
  devices.

- **The window** (`Sources/MeadRuntime/ARTDisplay.swift`): the bridge makes
  an SDL window, describes the display and the windowing connection to
  libgui, and hands Java an `android.view.Surface` for it (Mead's own
  Surface JNI, in libandroid_runtime). Software frames
  (`Surface.lockCanvas`) go through the surface's buffers to the bridge,
  which copies them to the window. hwui's EGL display is made on the
  bridge's Wayland or X11 connection, and its window surfaces on the
  `wl_egl_window` or X11 window behind Mead's surface, since Mesa's EGL
  can't take an `ANativeWindow`. Until the window manager hands out
  surfaces, Java asks for one through `mead.view.MeadWindow`, whose natives
  Mead registers when a program has the class. `Tests/ART/WindowCheck.java`
  draws both ways and reads the frames back through `MEAD_FRAME_DUMP`; it
  passes on the Duet's GNOME (Wayland) session.
- **Text**: Android 10's 249 system fonts (74 MB, CJK and emoji included)
  and `fonts.xml` are installed in `ANDROID_ROOT/fonts` and
  `ANDROID_ROOT/etc`. The framework reads them as `/system/fonts` and
  `/system/etc/fonts.xml`, written into its Java: the core library's file
  natives (libcore's `Linux` and OpenJDK's `File`) take `/system` paths as
  paths in `ANDROID_ROOT`, which covers every other `/system` path the
  framework reads too. Mead's ART startup initializes `Typeface`, as the
  zygote's preloading does, since hwui's default typeface comes from its
  initializer. `Tests/ART/TextCheck.java` (typefaces, measuring, drawing,
  CJK and emoji fallback, `StaticLayout`) passes on the Duet, and the window
  check draws text through hwui's GL pipeline.

- **Input and vsync**: SDL is all on the bridge's own display thread, which
  makes the windows and pumps their events, so Java's threads run their
  loopers; software frames are handed to it. Each window can have an input
  channel (libinput, AOSP's, with Mead's `mead/input.h` publishing on the
  server end), whose client end Java reads with an `InputEventReceiver`, as
  an app's window gets from the window manager. Keys become `KeyEvent`s;
  the mouse, touches (with multi-touch pointer IDs) and gamepad axes become
  `MotionEvent`s with Android's sources, actions and axes; gamepad buttons
  become gamepad `KeyEvent`s. SDL's key mapping now lives in MeadWindow,
  shared with MeadAndroid. `Choreographer` runs on libgui's vsync through
  Android's `DisplayEventReceiver` JNI; it asks the display service for the
  refresh rate, which started phase 5's services early (below). libbinder
  runs without a binder driver, in-process. `Tests/ART/InputCheck.java`
  injects keys and touches into SDL's event queue and gets them on a
  Looper, and counts 30 Choreographer frames at the display's rate (16 ms
  on the Duet): it passes on the Duet.

- **The exit check, on the Duet**: `Tests/ART/mead/check/ActivityCheck.java`
  is an `Activity`, run as Android runs one: `mead --dex activity-check.jar
  mead.server.MeadApp mead.check mead.check.ActivityCheck 640 480` calls
  `ActivityThread.main`, which attaches to Mead's activity manager, which
  binds the app and launches the activity through a client transaction.
  Its window goes through Mead's window manager, whose `SurfaceControl` is a
  display bridge window (libgui's window callbacks) with an input channel;
  `ViewRootImpl` draws with hwui and takes input as on Android. Its `View`
  draws with `Canvas` and gets a touch, a key and a gamepad button. It
  passes, with the first frame read back. The Retroid is untried.

- **Audio**: `AudioTrack`'s natives are Swift (`Sources/MeadRuntime/ARTAudio.swift`),
  each track an SDL audio stream on the default playback device (PipeWire
  or PulseAudio on GNOME, ALSA on ROCKNIX), in the track's own format,
  which SDL converts to the device's. Streaming tracks queue up to their
  buffer's size, blocking writes waiting for the device; static tracks keep
  their data and queue it, with its loops, when played; the playback head
  is what's been written less what SDL still holds. Rate changes go to
  SDL's resampling; marker and period notifications aren't sent yet. The
  audio service tracks players and has every stream at full volume.
  `Tests/ART/AudioCheck.java` passes on the Duet: a second's tone takes
  about a second to write, and the head follows.

Still to come in phase 4:

- **TextureView**: libgui's `BufferQueue`, in-process.
- `AudioRecord`, AAudio for NDK code under ART, and `AudioTrack`'s
  marker and period notifications.
- The display bridge on Wayland, below.

### The display bridge on Wayland

Decided 2026-11-10: ART's windows and surfaces go to Wayland directly, not
through SDL's video. SDL stays for gamepads (its gamepad subsystem and
mapping database, with no SDL video) and audio; MeadAndroid, the current
runtime, keeps SDL's windows until phase 7 removes it.

Why: Android's display is a compositor with layers, buffer queues and
transactions, which is Wayland's model; SDL gives one window with one
surface. On SDL, an `ANativeWindow`'s buffer geometry, scaling and
transform can't be honoured, CPU frames are copied twice, `SurfaceView`'s
child surfaces have nowhere to go, vsync is a timer, and a game's EGL can
meet SDL's own drawing on the same `wl_surface`. Both targets are Wayland:
Mutter on Debian 13 GNOME, sway on ROCKNIX.

How Android maps onto Wayland:

| Android | Wayland |
|---|---|
| SurfaceFlinger layer, `SurfaceControl` | `wl_surface`, `wl_subsurface` |
| `SurfaceControl` transactions, applied atomically | subsurface position and stacking, applied together by synchronized commits |
| `BufferQueue`, buffers coming back when released | `wl_buffer` attach and commit, release events |
| memfd gralloc buffers (Mead's today) | `wl_shm`, without a copy |
| GPU gralloc buffers, `AHardwareBuffer` | `zwp_linux_dmabuf_v1`, with GBM-backed gralloc |
| fences | explicit synchronization, DRM sync objects |
| Choreographer's vsync | `wl_surface.frame`, `wp_presentation` timestamps |
| buffer geometry, scaling mode, transform | `wp_viewporter`, `set_buffer_transform` |
| density | `wp_fractional_scale` |
| activity windows | `xdg_toplevel` |
| popups, menus, dropdowns | `xdg_popup` |
| `SurfaceView` | a subsurface of its window |
| display info | `wl_output` |
| `FLAG_KEEP_SCREEN_ON` | `zwp_idle_inhibit` |
| fullscreen, immersive mode | `xdg_toplevel.set_fullscreen` |
| input method | `zwp_text_input_v3` |
| clipboard | `wl_data_device` |
| mouse look | relative pointer, pointer constraints |

Keys take Android's own path: Wayland's keyboard events carry Linux evdev
codes, which Android's `Generic.kl` maps to key codes through libinput's
`KeyLayoutMap`, as Android's EventHub does, in place of Mead's SDL scancode
table. Touch is multi-touch natively; the pointer brings buttons and axes.

Who does what:

- **Swift**: the Wayland client, as the display bridge in place of
  `ARTDisplay`'s SDL video: the registry, `xdg-shell` toplevels with their
  configures and resizes, a subsurface per libgui surface with its viewport
  (buffer size and scaling) and transform, CPU frames as `wl_shm` buffers
  from gralloc's memfds, frame callbacks into `mead_gui_vsync`, outputs
  into `mead_gui_set_display`, and the seat (xkbcommon, pointer, touch)
  into input channels. Swift calls the protocols' generated request
  functions (inline C wrappers it imports) and registers listeners as
  `@convention(c)` closures. Window resizes, minimizing and restoring go to
  the window manager service, which tells `ViewRootImpl` (and a
  `NativeActivity`'s `onNativeWindowResized` and `onNativeWindowDestroyed`).
- **C**: only `wayland-scanner`'s glue for the protocols, in a small target
  (`CMeadWayland`). `Scripts/generate-wayland-protocols.sh` generates it from
  wayland-protocols' XML and it's committed, with the versions in
  `GENERATED_FROM`, so SwiftPM builds need no scanner. The build image has
  libwayland-dev and wayland-protocols; at run time, libwayland-client and
  libwayland-egl, which both targets have.
- **The fork's C++**: libgui's interface describes layers (parent,
  position, stacking, buffer size, scaling mode, transform) as well as
  windows; `Surface::perform` handles `NATIVE_WINDOW_LOCK` and
  `UNLOCK_AND_POST`, which `ANativeWindow_lock` and `unlockAndPost` send.
  Later, gralloc allocates GPU buffers through GBM.
- **The providers' C**: MeadEGL and MeadVulkan take a libgui surface's
  `wl_egl_window` and `wl_surface` (`MEAD_SURFACE_GET_NATIVE_WINDOW`) on the
  bridge's `wl_display`, as hwui does.

GPU rendering stays on a `wl_egl_window` per surface: Debian's and ROCKNIX's
Mesa have no Android EGL platform, so a game's `eglCreateWindowSurface`
can't render into gralloc buffers as on Android. Rendering into dmabuf
gralloc buffers is for hwui, `TextureView` and video, later.

Costs: decorations on GNOME come from libdecor, as SDL's do (Mutter draws
none; sway does). X11 is dropped for ART apps: X11 and Wayland were the
choice for SDL's windows, and both targets run Wayland; SDL's video could
stay as an X11 fallback at the cost of two bridges. The Wayland client is
some two to three thousand lines. Wayland's events and SDL's gamepad events
run on two threads, or one thread polls both.

Order:

1. The Wayland bridge: toplevels, a subsurface per surface, CPU frames,
   `wl_egl_window`s for EGL and Vulkan, outputs, frame callbacks. Done
   2026-11-10 on the Duet: a toplevel per window with a desync layer
   subsurface; CPU frames as `wl_shm` buffers over gralloc's memfds, with
   no copy, each slot held until `wl_buffer.release`; hwui on the layer's
   `wl_egl_window`; outputs give the display's size, density and refresh.
   Vsync is on request: libgui asks the bridge
   (`mead_gui_set_vsync_request`) when a receiver wants one, and the bridge
   asks for a frame callback on the window's root. When the compositor
   holds callbacks back, with no window mapped or the screen off, the
   vsync comes anyway after 100 ms, so Choreographer slows but never
   stalls. The window, input, activity, graphics, text and audio checks
   pass; with the screen on, the input check's 30 frames come at the
   display's 16 ms (with it off, at the 100 ms fallback).
   Missing: decorations on GNOME (no libdecor yet, so Mutter shows none).
   On the Duet, libdecor's GTK plugin doesn't load for SDL either, so
   decorations need a plugin there or Mead's own.
2. The seat: keys through `Generic.kl`, the pointer, touch. Done with step
   1: evdev keys go through `Generic.kl` (`mead_input_map_key`) and xkb's
   modifiers become meta state; the pointer and touch become
   `MotionEvent`s. Held keys repeat at the compositor's `repeat_info`, on
   the display thread, with Android's repeat count and the long press on
   the first; modifiers don't. The pointer shows the cursor theme's arrow
   (libwayland-cursor, XCURSOR_THEME and XCURSOR_SIZE, at the outputs'
   scale). Both are built and the checks pass, but they haven't been tried
   with a real keyboard and mouse. Android's pointer icons follow the app
   (`IInputManager.setPointerIconType`, as CSS cursor names with X11 names
   as fallbacks: the text beam over text, the hand over links), and a
   captioned window's shadow shows the resize arrows (2026-11-11; built and
   checked, not yet seen on screen). Remaining: animated cursors, custom
   pointer icons (bitmaps), scroll's high resolution.
   Windows draw at the output's scale (2026-11-11): Android's pixels are
   device pixels, the density is Wayland's scale (`MEAD_DISPLAY_SCALE`
   overrides it), the size given on the command line is in the desktop's
   logical pixels, and sizes, popup places and input convert. Windows with
   surface insets (popups' and dialogs' shadows) get surfaces that big,
   with input offset back into the frame; popups anchor inside their
   parents. Keys go to the window Android focused when Wayland's keyboard
   is on its toplevel. Fractional scales (`wp_fractional_scale_v1`) remain:
   GNOME's 1.25 or 1.5 draws at 2 and is scaled down. Open: Loop's toolbar
   icons don't show until a tap redraws the toolbar, with or without
   Choreographer's vsync, buffer age or today's changes.
   Windows' roots hold a clear buffer, so translucent windows (popups'
   shadows, dialogs' scrims) show what's under them; popups get their role
   only while shown and are taken down from the top, as xdg-shell requires.
   Seen right on the Duet's screen in Loop (2026-11-11). Dialogs with
   FLAG_DIM_BEHIND dim the window under them: a subsurface over its content,
   black at the dialog's dimAmount, with no input region (DialogCheck; seen
   on the Duet). The ← up arrow works: activities get their manifest
   meta-data, and up-navigation matches an alias's target.
   Decorations where the compositor draws none (GNOME): activities run in
   Android's freeform windowing mode, so their DecorView draws Android's
   caption (maximize, close) and a shadow in surface insets. The caption's
   drag is xdg_toplevel.move, maximize is set_maximized, close finishes the
   activity; a press in the shadow resizes from that edge. The window
   geometry is the frame, without the shadow. Compositor resizes reach
   Android through a window-events thread (IWindow.resized, then relayout
   at the compositor's size). MEAD_CAPTIONS=0 or 1 overrides. Seen working
   on the Duet (2026-11-11). Remaining: the caption's colors following the
   app's theme.
3. `SurfaceView`'s child surfaces, buffer geometry through viewports,
   transforms; `ANativeWindow_lock`. Child surfaces done 2026-11-11: a
   `SurfaceControl` made with a parent is a layer in its window
   (`mead_gui_create_layer`), a desynchronized subsurface of the window's
   root with no input region, with its own surface, viewport and
   `wl_egl_window`. Transactions set layers' places, sizes, order and
   visibility (`mead_gui_update_layer`): under the window's content when
   the order is negative, as a `SurfaceView`'s is, through the hole the
   view hierarchy leaves, and over it otherwise (`setZOrderOnTop`). Color
   and container layers keep their state and show nothing; crops,
   alpha and colors aren't shown yet. A layer's matrix scales its buffer
   to its size on screen through its viewport, as `SurfaceView` sets it
   for `setFixedSize` (`setBufferSize`, then `setMatrix` to the view's
   size); only the matrix's scale is kept, not rotation or skew.
   `ViewRootImpl`'s bounds layer is a buffer layer nothing draws to, so
   it's an empty subsurface. `SurfaceViewCheck` draws frames with
   `lockCanvas` into two `SurfaceView`s under labels, one at the view's
   size and one at half of it by `setFixedSize`, shown at the view's size
   (passes on the Duet; its log shows the layer following the layout as
   the window resizes). `Surface::lock` and `unlockAndPost` were already there
   (`NATIVE_WINDOW_LOCK`). The NDK's `ANativeWindow` on ART's surfaces
   done 2026-11-11: under ART `ANativeWindow_fromSurface` gives the app
   the Surface's libgui window, and MeadAndroid's `ANativeWindow_*` hand
   libgui's windows (told apart by their `'_wnd'` magic) to the runtime's
   libnativewindow, `lock` and `unlockAndPost` included. Mead's EGL and
   Vulkan draw to the `wl_egl_window` behind such a window
   (`mead_surface_get_native_window`), and `eglGetDisplay`'s default
   display is libgui's own connection, which hwui's EGL uses and which made
   the windows. `NativeSurfaceCheck` fills one `SurfaceView` through
   `ANativeWindow_lock` and draws another with EGL and GLES from a bionic
   library (`libfixture_surface.so`; passes on the Duet). At swap interval
   1, `eglSwapBuffers` waits for the compositor's frame callback, so a
   game stops while the screen is blanked, as it would with its display
   off; the check swaps at 0. Remaining: transforms, crops,
   `ANativeWindow_setBuffersGeometry`'s scaling (EGL draws at the window's
   size whatever the game asks), and Vulkan on these windows, unchecked.
4. `xdg_popup`, idle inhibition, fullscreen, the input method, the
   clipboard. Idle inhibition done 2026-11-11: a visible window with
   `FLAG_KEEP_SCREEN_ON` (`View.setKeepScreenOn`, a game's or a video
   player's) holds a `zwp_idle_inhibitor_v1` on its root, which the
   compositor honors while it shows the window; `SurfaceViewCheck` keeps
   the screen on (GNOME takes the inhibitor).
5. dmabuf gralloc through GBM.

### Phase 5: in-process system services (Swift)

AOSP's `ActivityThread` drives an app through the system services. Mead
implements the ones apps need in-process, as `IXxx.Stub` subclasses in
mead-framework.jar whose methods are Swift natives:

- **Activity and task**: `IActivityManager`, `IActivityTaskManager`. Starts
  the launcher activity from the manifest, runs the lifecycle through
  `ActivityThread`'s client transactions, handles `startActivity` within the
  app, back navigation and finishing.
- **Window**: `IWindowManager` and `IWindowSession`, one SDL window per
  top-level window; dialogs and popups as child windows.
- **Package**: `IPackageManager` from the APK's manifest via `libandroidfw`.
- **Input method, display, power, audio, clipboard, alarm, vibrator,
  notification** (logged), **connectivity**.
- Content providers within the app; `SharedPreferences`, SQLite and files
  work as on Android, under `~/.mead/apps/<package>`.

Started early, for `Choreographer` and phase 4's exit check: `mead-framework.jar` (`Java/mead-framework`,
built by `Scripts/build-mead-framework.sh` against Android 10's framework)
sits beside Mead's providers and is on ART's boot class path after Android's
jars. `mead.server.MeadServices.start()`, which Mead calls at startup, puts
the services in `ServiceManager`'s cache, where `getService` finds them
without a service manager. `ServiceManager` is given Mead's own service
manager (`ServiceManagerService`), since there's no binder driver; binder
calls without one fail as to a dead process, which `ServiceManager` takes
as no service. The services so far: display (the one display the bridge
describes), activity (binds the one app, launches its activity, hands out
the settings provider), activity task, window (window sessions whose
windows are the bridge's), input method (nothing to bind), package (the one
app, every permission granted, a touchscreen, keys and gamepads), app ops
(everything allowed) and input (the bridge's devices, with Android's
`Generic.kcm` and `Virtual.kcm`). Their bases are generated from the
framework's AIDL interfaces (`Scripts/generate-service-bases.py`): every
method answers as a service that doesn't do it would, and says so once in
the log. `mead.server.MeadApp` runs an app's activity, as above.

Exit: a small open-source app (from F-Droid) runs, with layouts inflated from
its resources, AppCompat themes, `RecyclerView` and navigation between
activities.

**Met on the Duet, 2026-11-10**, with Loop Habit Tracker 2.3.2 (F-Droid,
`org.isoron.uhabits`, no native code): `mead --dex <apk> mead.server.MeadApp
800 600`. Its main screen draws from its own resources and AppCompat theme;
**+** opens its habit-type dialog, "Yes or No" starts `EditHabitActivity`,
a typed name is saved to its SQLite database and shows in the habit list
(`RecyclerView`); tapping the habit starts `ShowHabitActivity`, with its
charts; Back returns to the list, and Back again finishes the app. The
earlier checks (Core, Crypto, Framework, Native, Text, Graphics, Window,
Input, Audio, Activity) still pass. What it took:

- `MeadApp` reads an APK's manifest (`PackageParser`): its activities,
  intent filters and permissions, and its launcher activity.
- The activity task manager keeps a stack of activity records and drives
  them as Android does: starting pauses the top one, launches the new one,
  and stops the one below when the new one is idle; finishing pauses, resumes
  the one below with its results, then destroys; Back on the task's root
  finishes it, and the process ends with its last activity. Intents resolve
  by component or by the manifest's filters.
- The window session gives each window its own SDL window and input
  channel: an activity's window is a window of its own; a dialog over one,
  even filling it, is that window's modal child; a sub-window (popup menu,
  spinner) is an SDL popup placed by its gravity. Focus goes to the newest
  visible focusable window. These go to Wayland directly with the display
  bridge's move below.
- New services: user (one unlocked owner), notification (logged), alarm
  (logged, not fired yet), power, app widget (none), storage (one emulated
  volume, `~/.mead/storage`) and content (content observers); pending
  intents, broadcast receivers and broadcasts in the activity manager.
  statsd's natives (`StatsLog`, `StatsLogInternal`) do nothing
  (`mead.server.NativeStubs`).
- In the fork: Android 10's SQLite (`external/sqlite`, static, its symbols
  hidden) and the database JNI; a batch of view, text and utility JNI
  (`PathParser`, `PropertyValuesHolder`, `Hyphenator`, `VirtualRefBasePtr`
  and others); `ActivityThread`'s natives; `/data` mapped to
  `ANDROID_DATA`; no swap interval on hwui's surfaces, Choreographer pacing
  frames.
- `MEAD_DEBUG_TAPS="secs:x,y;secs:key=scancode;secs:text=words"` plays
  input into the focused window, for driving an app on a host nobody's at;
  `MEAD_FRAME_DUMP` writes each window's frames to their own file.

Not yet: an input method (text arrives as hardware keys; `showSoftInput`
is logged), alarms firing, `textservices`, services (`startService`), and
the Retroid.

### Phase 6: games move to ART

- `NativeActivity`, GameActivity (in the APK) and Unity's player (in the APK)
  run as Android runs them; Minecraft's Java runs as shipped.
- Retest Minecraft (typing, input, images), Defense Zone 2 HD and Subnautica:
  Below Zero on both devices, including the Ports entry on the Retroid.
- What Mead added in Swift for these games is checked against what the real
  Java now does: billing and Play Games report unavailable the way the real
  clients do without Play Services, so no stand-in is needed.

Exit: the three games work at least as well as on MeadJNI.

Started 2026-11-11: the NDK's `ALooper` is the thread's `android::Looper`
under ART, the one Java's `MessageQueue` polls (libandroid_runtime's
`mead/looper.h`, as Android's libandroid has it); without ART it's Mead's
own. Defense Zone 2 HD on ART (the base APK, with its arm64 libraries in
the app's library directory): `UnityPlayerActivity` runs, its window opens,
libunity and il2cpp load, and Unity reports the device. Since the NDK's
`ANativeWindow` on ART's surfaces (Wayland plan step 3) and split APKs
(MeadApp gives the app the `split_*.apk` files beside its base APK that
name its package, as `splitSourceDirs`, which `LoadedApk` adds to its
assets; its install-time asset pack, `UnityDataAssetPack`, is one), its
scripts run and it draws: its graphics thread renders with EGL to its
`SurfaceView` (2400×1292) and swaps. Not yet seen on screen: the Duet's
screen was blanked.

Hidden windows stop their activities (2026-11-11), as Android stops them
with the display off. The bridge counts a toplevel hidden when the
compositor says so (xdg_toplevel's suspended state, xdg-shell 6:
minimized, another workspace) or holds its frame callbacks back for two
seconds (GNOME with the screen blanked, which isn't suspended). Window
event kind 2 tells the window manager, and the activity manager stops the
top activity (`StopActivityItem`, through onPause) and resumes it when the
window shows again; the window stays mapped meanwhile, so the compositor
can show it. `MEAD_STOP_HIDDEN=0` keeps activities resumed, for checks
run with the screen off. Mead's EGL no longer lets a swap wait on the
compositor: Mesa's swap at interval 1 waits for a frame callback, which
hung Unity's render thread with the screen blanked (its pause timed out),
so Wayland windows swap at interval 0 and Mead paces each swap to the
app's `eglSwapInterval`, at 60 Hz for now (the EGL shim doesn't know the
display's rate). With both, Defense Zone 2 HD pauses cleanly when the
screen blanks (its frame callbacks held back) and when it's locked (GNOME
suspends its window within seconds). With the screen awake it draws its
main menu (seen in `MEAD_FRAME_DUMP`'s frames) and nothing counts it
hidden. Resuming seen 2026-11-11: unlocked, GNOME shows the window
again within the second, the activity resumes and Unity draws on; played
by hand afterwards (towers built, waves on).

Playable 2026-11-11: taps (`MEAD_DEBUG_TAPS`, in the window's surface
pixels, insets included) reach Unity through its window; Begin game opens
its mission select and Play loads Mission 1, which runs (seen in frame
dumps: its map, money, health, waves and tower bar). Its audio is an
AAudio stream with a callback, at 24 kHz, the game's own rate, which
starts. Java's `AudioSystem` has Mead's natives (the fork's
`mead_audio_system.cpp`): one output, the speaker, at 48 kHz, no ports
or patches, and setters that change nothing; Android's ask AudioFlinger
over binder. It doesn't keep the screen on at its menu, as on Android.
Missing for it: the clipboard, connectivity, vibrator and sensor
services, and Play Core's asset pack service (it reports the packs it
can't sync; the pack is there anyway). Its sound plays (heard on the
Duet).

Subnautica: Below Zero on ART (2026-11-12, base APK and its three splits,
arm64 libraries in the app's library directory): Unity 6000.0 runs its
scripts, loads its main menu scene and renders with Vulkan to its
`SurfaceView`, which the compositor shows. Its main menu is seen
(2026-11-12) in `MEAD_VULKAN_FRAME_DUMP`'s frames: MeadVulkan, when that's
set, makes swapchains' images copyable and, every 60 presents, copies the
image being presented to a host buffer after the present's semaphores,
waits, and writes it as a PPM; its water moves from frame to frame. Its
swapchain is 2000×1200, which the layer scales to the view. Its pairip license client binds Play's
licensing service and asks the second protocol (`checkLicenseV2`). Mead
runs that service in-process (`mead.server.LicensingService`, written
against the AIDL by hand): each request is asked of Google for the account
mead-google-login signed in (MeadGooglePlay's `LicenseRelay`:
`fdfe/apps/checkLicense` for the first protocol, `checkLicenseServerFallback`
for the second, whose license is a JWT in payload field 173), and Google's
answer goes to the app's listener as Play hands it over, the token as
`LICENSE_DATA`. Mead verifies and alters neither; the app checks Google's
signature itself. Only the app's own package may be asked about. Firebase
finds its components through `getServiceInfo`'s meta-data on
`ComponentDiscoveryService`, which the package manager now answers, and
Play services' clients read the application's meta-data. Missing for it:
the connectivity, clipboard, shortcut and job scheduler services, Play
Core's asset pack service, and billing (its client finds no service and
carries on).

### Phase 7: remove MeadJNI

- Delete MeadJNI, CMeadJNI, MeadMacros, MeadJava, MeadMinecraft, MeadUnity
  and the runners.
- Review MeadGooglePlay, MeadGoogleLogin and MeadCrypto: under ART the app's
  own license and login code runs and talks to Play services that aren't
  there. Keep only what still has a caller, and keep license checks
  unverified.

Exit: the gate passes with MeadJNI gone; the three games and the phase 5 app
run.

### Phase 8: Swift where it pays

With everything running, replace C++ with Swift where Linux integration
gains from it, measured case by case:

- `Canvas` and `hwui`: keep AOSP's renderer and Skia unless its Android
  dependencies prove too heavy; a Swift renderer over Skia is the fallback.
- Fonts and text through fontconfig, file pickers and URLs through the
  desktop portal, notifications through the desktop's.
- Vulkan presentation through the SDL bridge.

`View` and the widgets stay AOSP's Java: they're logic, and dex2oat already
compiles them to native code.

## Later

- A zygote: one process starts ART, maps the boot image and preloads
  classes, resources and fonts, then forks per app, with SDL, Wayland, the
  GPU and audio started only after the fork. Worth it once several apps run
  at once.
- A small shared service process for apps that use more than one process
  (`android:process`).

## Risks

- **Version coherence.** ART, libcore and the framework must come from one
  release; mixing them breaks in subtle ways (hidden APIs, intrinsics).
- **ART on arm64 glibc.** AOSP's own host build is x86_64 only; art_standalone
  works but mixes releases.
- **hwui and libgui.** `hwui` assumes `libgui`'s buffer queue and gralloc;
  driving it from a plain `ANativeWindow` over Mead's EGL may need patches.
- **System services surface.** `ActivityThread` and the framework call many
  service methods; each missing one fails at run time. Phase 5 starts with
  what the target apps call, found by tracing.
- **Kernel features.** The newer garbage collector's `userfaultfd`, and page
  sizes on the devices' kernels.
- **Size and build time.** ART, Skia and the framework natives are large,
  and ART builds natively on an arm64 device, slowly.
- **Memory.** 4 GB devices leave little room for dex2oat on large apps and
  for ART's heap beside the GPU driver.
- **First launch.** dex2oat compiles each app once; large apps take a while
  the first time.

## Testing

- The Docker gate keeps running Mead's unit tests, plus Java-level tests run
  on ART (framework objects, resources, the services' answers).
- Each phase's exit check runs on the Duet and the Retroid.
- AOSP's CTS tests for the classes Mead replaces in Swift (`Surface`, input,
  `Choreographer`, `AudioTrack`) once phase 4 lands.
