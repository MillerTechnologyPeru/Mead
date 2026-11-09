import MeadJNI
import MeadJava

/// Brings Unity's Java player classes into being, beside Android's own. Safe
/// to call again.
public enum UnityFramework {
    public static func register() {
        JavaFramework.register()
        let classes: [JavaObject.Type] = [
            JavaUnityPlayerActivity.self, JavaUnityPlayer.self, JavaUnityPlayerForActivityOrService.self,
            JavaUnityNativeLoader.self, JavaJNIBridge.self,
        ]
        for type in classes {
            JavaRuntime.shared.defineClass(for: type)
        }
    }
}
