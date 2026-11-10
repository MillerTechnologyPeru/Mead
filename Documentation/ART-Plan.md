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
 │   Swift     (swift-java)  SDL surface, display, input, vsync,      │
 │             audio, system services, runtime hosting                │
 │──────────────────── Mead loader + bionic shims ───────────────────│
 │ App NDK .so ─▶ providers: libandroid, EGL, Vulkan, OpenSL ES, log  │
 │──────────────────────── glibc, SDL3, Mesa ────────────────────────│
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
| MeadWindow, CMeadWindow | SDL bindings | Kept. The SDL bridge builds on them |
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
  (`libjavacrypto`, with BoringSSL in place of wolfSSL), and the
  framework's base libraries: `libandroid_runtime`, `libandroidfw`,
  `libbinder` (used in-process, for `Parcel` and local binders),
  `libutils`, `libcutils`, `libbase`, `libziparchive`, ICU.
- Stub what reaches the system: `ServiceManager` returns Mead's in-process
  services (phase 5); anything else fails cleanly.

Exit: a dex creates `Context`-free framework objects (`Bundle`, `Intent`,
`Parcel` round trips, `Resources` from an APK's `resources.arsc`).

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

Exit: a small open-source app (from F-Droid) runs, with layouts inflated from
its resources, AppCompat themes, `RecyclerView` and navigation between
activities.

### Phase 6: games move to ART

- `NativeActivity`, GameActivity (in the APK) and Unity's player (in the APK)
  run as Android runs them; Minecraft's Java runs as shipped.
- Retest Minecraft (typing, input, images), Defense Zone 2 HD and Subnautica:
  Below Zero on both devices, including the Ports entry on the Retroid.
- What Mead added in Swift for these games is checked against what the real
  Java now does: billing and Play Games report unavailable the way the real
  clients do without Play Services, so no stand-in is needed.

Exit: the three games work at least as well as on MeadJNI.

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
