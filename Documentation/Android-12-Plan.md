# Moving Mead's ART to Android 12

Mead runs apps on ART and framework built from Android 10 (API 29), through
the `mead` branch of our art_standalone fork. This plan moves both to
Android 12L (API 32), so apps that require Android 11 or 12 run on the APIs
they were built for.

## Why

- Some games now set `minSdkVersion` 31. Rome: Total War – Alexander is the
  first: Mead parses it anyway (running it on API 29), but it calls
  `WindowManager.getCurrentWindowMetrics()` (API 30) without a version
  check, as its minimum says it may, and stops there. Its code also uses
  `WindowMetrics`, `OnBackInvokedDispatcher`, `LocaleManager`,
  `OutcomeReceiver`, `SdkExtensions` and Credential Manager.
- Of the games tried on ART so far, it's the only one. The number will
  grow as publishers raise their minimums.
- The alternative, adding Android 11/12 methods to the Android 10
  framework as games need them, is what upstream (Android Translation
  Layer's art_standalone) does for its own needs: it stays on Android 10
  and backports (runtime `LambdaMetafactory`, a `d8` branch replacing `dx`).
  That works for single methods, but drifts the framework from any real
  Android release and has to be repeated per game.

## Where Mead is

| Piece | Today |
| --- | --- |
| ART, libcore | Android 10, built standalone by the fork's makefiles (upstream has no Android 12 version) |
| Framework | `framework.jar` and `framework-classes.jar` from the Android 10 tree on the Optiplex (66 GB, 589 GB free) |
| Fork's own code | `frameworks/mead`: 52 files, about 15,900 lines (android_runtime, gui, hwui, egl, ui, media_jni, compat, hidl, processgroup) |
| Fork's patches to AOSP | about 60 files: ART (parsed_options, runtime, thread_pool), hwui (EglManager, RenderThread, Bitmap), binder (IPCThreadState, ProcessState), input, ui, libandroidfw, minikin, JNI (EGL14, NativeActivity, ApkAssets, HardwareBuffer, ThreadedRenderer) |
| Mead's Java services | `Java/mead-framework`: 32 files, about 3,700 lines, implementing 20 of Android's service interfaces |
| Mead's Swift natives | `Sources/MeadRuntime/ART*.swift`: about 3,700 lines; 40 natives on `AudioTrack`, 18 for display, plus identity, licensing and services |

## How much Android 12 changes for Mead

Measured from AOSP's AIDL sources (android10-release against
android12-release):

- The 20 interfaces Mead implements have 1,249 methods in Android 10; in
  Android 12, 325 methods are new and 226 are gone or renamed.
- Of the methods Mead actually implements, most of the breakage is in one
  place: `IActivityTaskManager`, where 24 of Mead's 26 move to the new
  per-activity `IActivityClientController` (activityIdle, activityPaused,
  activityResumed, activityStopped, activityDestroyed, finishActivity, …).
- Elsewhere it's a handful: `IActivityManager` (3, including
  broadcastIntent's signature), `IPackageManager` (2: checkPermission,
  queryIntentActivities), `IWindowSession` (2), `IWindowManager` (1),
  `IPowerManager` (0).
- Connectivity and alarms leave `frameworks/base` for mainline modules
  (`framework-connectivity.jar`, the job scheduler APEX), so their
  interfaces come from those jars.
- Natively, Android 12 replaces BufferQueue surfaces with BLAST
  (`BLASTBufferQueue`, SurfaceControl transactions), which is exactly
  where Mead's `gui` and hwui patches attach to Mead's windows. This is
  the largest native change.

## Phases

Each phase ends with something that runs, and Android 10 stays the
default until the last.

### 0. Spike: can ART 12 build standalone? (1–2 weeks)

- Check out AOSP at the latest android-12.1.0 security tag on the Optiplex.
- Port the fork's makefile build to ART 12's sources (art, libnativehelper,
  libbase, libziparchive, libdexfile, libartpalette, libnativebridge,
  libsigchain, dex2oat) for arm64 glibc.
- Exit: `dalvikvm` runs a hello-world dex against an ART 12 boot image on
  the Duet.
- If this doesn't converge, stop here: the fallback is per-game
  backports on Android 10, and nothing else in this plan is spent.

### 1. Runtime and core libraries (1–2 weeks)

- libcore 12 (core-oj, core-libart, core-icu4j), okhttp, bouncycastle,
  conscrypt (its BoringSSL), apache-xml; `d8` in place of `dx` (upstream's
  `d8` branch is a start).
- Re-apply the fork's ART patches (parsed_options, runtime, thread_pool)
  and Mead's bionic needs.
- Exit: Mead's core, crypto and text checks pass on ART 12, beside ART 10
  (`MEAD_ART_HOME` chooses).

### 2. Framework (1–2 weeks)

- Build `framework.jar`, `framework-res.apk` and the compile-time classes
  jar from AOSP 12, plus the mainline jars apps reach (connectivity,
  wifi, media, permission, sdkextensions).
- Rebuild `mead-framework.jar` against them: `generate-service-bases.py`
  regenerates the bases; services are ported, `IActivityTaskManager`
  first (with a new `IActivityClientController`).
- Exit: the framework and activity checks pass (an activity starts,
  draws, finishes).

### 3. Native runtime (2–3 weeks)

- libandroid_runtime 12's JNI, with the fork's `frameworks/mead` and its
  JNI patches (EGL14/EGL10/GL10, NativeActivity, SurfaceTexture,
  media_jni on FFmpeg, NDK binder, libandroid NDK names).
- libgui with BLAST: Mead's surfaces become BLASTBufferQueue consumers
  that present to Mead's windows; hwui's EglManager and RenderThread
  patches move to 12's versions.
- libandroidfw, minikin, input, ui patches re-applied.
- Mead's Swift natives (AudioTrack, display, identity) checked against
  12's native method signatures.
- Exit: all 14 Duet checks pass on ART 12.

### 4. Games (1–2 weeks)

- Below Zero, BFBB (Vulkan, NativeActivity, video), Defense Zone 2 HD,
  Minecraft, then Rome: Total War – Alexander.
- Exit: each runs as well as on ART 10, and Rome reaches its menu.

### 5. Cutover

- ART 12 becomes the default; ART 10 stays installable for a release.
- Ports entries and `Documentation/ART-Plan.md` updated.

Roughly 7–11 weeks of focused work, most of the risk in phase 0 and in
BLAST (phase 3). These are estimates, not measurements.

## Risks

- **No upstream to follow.** Android Translation Layer stays on Android
  10, so the ART 12 standalone build is ours alone to keep up.
- **BLAST.** Android 12's surface model is new ground for Mead's window
  plumbing.
- **Bytecode and Java level.** Android 12's libcore and framework need
  `d8`; Mead's own Java builds with `dx` today.
- **Hidden APIs.** Android 12 enforces them more strictly for apps; Mead's
  own framework code is on the boot class path and exempt, but games that
  reflect into hidden APIs may behave differently than on ART 10.
- **Two runtimes for a while.** Fixes made on ART 10 during the move have
  to be carried across.

## What carries over

Everything Mead does outside the runtime: its loader, bionic layer,
Vulkan and EGL providers, Wayland windows, input, audio, Google Play
licensing and local asset packs (Play Core's local testing is the same
in 12). The recent Android 10 work (connectivity, media session, thermal,
signatures, RELRO, NDK binder, EGL10) is mostly in Mead's own code and
moves with the services and patches above.

## Open decisions

- Android 12L (API 32) or straight to 13/14: each later release adds more
  mainline modules and more interface churn, but lasts longer.
- Whether to finish ART-Plan's Phase 7 (removing MeadJNI) on Android 10
  first, so the move only has one runtime path to carry.
- Whether to propose the ART 12 build upstream, to share its upkeep.
