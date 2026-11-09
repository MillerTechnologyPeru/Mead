import MeadJNI
import MeadJava

/// Brings Minecraft's Java classes into being, beside Android's own. Safe to
/// call again.
public enum MinecraftFramework {
    public static func register() {
        JavaFramework.register()
        let runtime = JavaRuntime.shared
        runtime.defineInterface("com/mojang/minecraftpe/store/StoreListener")
        let classes: [JavaObject.Type] = [
            JavaMinecraftActivity.self, JavaCrashManager.self, JavaAppExitInfoHelper.self, JavaHardwareInformation.self,
            JavaBatteryMonitor.self, JavaThermalMonitor.self, JavaDateTimeHelper.self, JavaNetworkMonitor.self,
            JavaNativeStoreListener.self, JavaExtraLicenseResponseData.self, JavaStore.self, JavaStoreFactory.self,
        ]
        for type in classes {
            runtime.defineClass(for: type)
        }
    }
}
