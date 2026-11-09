import Glibc
import MeadJNI
import MeadJava

// Unity's Java player, as Unity 6 (6000.x) has it: the classes the engine
// registers its natives on and calls back into. On Android, Unity's own Java
// drives the engine; here a runner plays that part and these classes answer
// the engine's questions. What the engine asks that isn't here falls through
// to the stand-ins' zeros and nulls, as with any other game.

/// The game's activity, `com.unity3d.player.UnityPlayerActivity`.
@JavaClass("com/unity3d/player/UnityPlayerActivity")
open class JavaUnityPlayerActivity: JavaActivity {
    @JavaMethod("getRequestedOrientation") public func getRequestedOrientation() -> Int32 { -1 }  // unspecified

    @JavaMethod("getSystemService", signature: "(Ljava/lang/String;)Ljava/lang/Object;")
    public override func getSystemService(_ name: String?) -> JavaObject? {
        standardService(name) ?? super.getSystemService(name)
    }
}

/// The player both ways of running Unity share. Natives are registered on it
/// by libunity.so's JNI_OnLoad.
@JavaClass("com/unity3d/player/UnityPlayer")
open class JavaUnityPlayer: JavaObject {
    public let activity: JavaUnityPlayerActivity

    public init(activity: JavaUnityPlayerActivity) {
        self.activity = activity
        super.init()
    }

    /// Work the engine hands to its main thread: Unity's Java keeps a queue,
    /// which the runner drains before each frame.
    private let jobs = LockedValue([() -> Void]())

    public func post(_ job: @escaping () -> Void) {
        jobs.withLock { $0.append(job) }
    }

    @JavaMethod("executeMainThreadJobs") public func executeMainThreadJobs() {
        let taken = jobs.withLock { queue -> [() -> Void] in
            defer { queue.removeAll() }
            return queue
        }
        for job in taken { job() }
    }

    @JavaMethod("getContext") public func getContext() -> JavaContext? { activity }
    @JavaMethod("getActivity") public func getActivity() -> JavaActivity? { activity }
    @JavaMethod("getSplashEnabled") public func getSplashEnabled() -> Bool { false }
    @JavaMethod("getSplashMode") public func getSplashMode() -> Int32 { 0 }
    @JavaMethod("isFinishing") public func isFinishing() -> Bool { false }
    @JavaMethod("finish") public func finish() { activity.finish() }
}

/// The player for an activity, which is what UnityPlayerActivity makes.
@JavaClass("com/unity3d/player/UnityPlayerForActivityOrService")
public final class JavaUnityPlayerForActivityOrService: JavaUnityPlayer {
    @JavaMethod("getHaveAndroidWindowSupport") public func getHaveAndroidWindowSupport() -> Bool { true }
}

/// libmain.so registers `load` here, which loads libunity.so and the rest.
@JavaClass("com/unity3d/player/NativeLoader")
public final class JavaUnityNativeLoader: JavaObject {}
