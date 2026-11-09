import Foundation
import MeadGooglePlay
import MeadJNI

// The game's store, on the fake JVM. Selling things isn't supported, so the
// store says it has started with nothing available. Whether the account has
// the game is asked of Google itself, by MeadGooglePlay, and the answer is
// whatever a signed response from Google says. Without one it is "not verified".

@JavaClass("com/mojang/minecraftpe/store/NativeStoreListener", implements: ["com/mojang/minecraftpe/store/StoreListener"])
public final class JavaNativeStoreListener: JavaObject {
    fileprivate let callback: Int64

    @JavaMethod(signature: "(J)V") public init(callback: Int64) {
        self.callback = callback
        super.init()
    }

    /// Calls one of the game's `(J)V` or `(JZ)V` listener natives.
    fileprivate func notify(_ name: String, available: Bool? = nil) {
        runOnNewThread {
            var pointer = jvalue()
            pointer.j = self.callback
            var arguments = [pointer]
            var signature = "(J)V"
            if let available {
                var flag = jvalue()
                flag.z = available ? 1 : 0
                arguments.append(flag)
                signature = "(JZ)V"
            }
            _ = JavaRuntime.shared.attachCurrentThread().call(
                "com/mojang/minecraftpe/store/NativeStoreListener", name, signature, on: self, arguments)
        }
    }
}

/// The times and retries Google's signed response came with; zeros without one.
@JavaClass("com/mojang/minecraftpe/store/ExtraLicenseResponseData")
public final class JavaExtraLicenseResponseData: JavaObject {
    private let validationTime: Int64
    private let retryUntilTime: Int64
    private let retryAttempts: Int64

    init(_ result: LicenseResult?) {
        validationTime = result?.validationTime ?? 0
        retryUntilTime = result?.retryUntilTime ?? 0
        retryAttempts = result?.retryAttempts ?? 0
        super.init()
    }

    @JavaMethod("getValidationTime") public func getValidationTime() -> Int64 { validationTime }
    @JavaMethod("getRetryUntilTime") public func getRetryUntilTime() -> Int64 { retryUntilTime }
    @JavaMethod("getRetryAttempts") public func getRetryAttempts() -> Int64 { retryAttempts }
}

@JavaClass("com/mojang/minecraftpe/store/Store")
public final class JavaStore: JavaObject {
    private let listener: JavaNativeStoreListener?
    private let lock = NSLock()
    private var license: LicenseResult?

    init(listener: JavaObject?, publicKey: String?) {
        self.listener = listener as? JavaNativeStoreListener
        super.init()
        self.listener?.notify("onStoreInitialized", available: false)
        runOnNewThread { self.checkLicense(publicKey: publicKey) }
    }

    private func checkLicense(publicKey: String?) {
        let result: LicenseResult
        if let directory = AndroidEnvironment.gameDirectory, let publicKey, let manifest = AndroidManifest(path: "\(directory)/AndroidManifest.xml") {
            result = GooglePlayLicense().check(account: GoogleAccount.load(), packageName: manifest.packageName,
                                               versionCode: manifest.versionCode, publicKey: publicKey,
                                               cache: .standard(for: manifest.packageName))
        } else {
            result = GooglePlayLicense().check(account: nil, packageName: "", versionCode: 0, publicKey: "")
        }
        FileHandle.standardError.write(Data("mead: license check: \(result.reason)\n".utf8))
        lock.lock()
        license = result
        lock.unlock()
    }

    private var currentLicense: LicenseResult? {
        lock.lock()
        defer { lock.unlock() }
        return license
    }

    @JavaMethod("getStoreId") public func getStoreId() -> String? { "" }
    @JavaMethod("getProductSkuPrefix") public func getProductSkuPrefix() -> String? { "" }
    @JavaMethod("getRealmsSkuPrefix") public func getRealmsSkuPrefix() -> String? { "" }
    @JavaMethod("receivedLicenseResponse") public func receivedLicenseResponse() -> Bool { currentLicense != nil }
    @JavaMethod("hasVerifiedLicense") public func hasVerifiedLicense() -> Bool { currentLicense?.verified ?? false }
    @JavaMethod("getExtraLicenseData") public func getExtraLicenseData() -> JavaExtraLicenseResponseData? { JavaExtraLicenseResponseData(currentLicense) }

    @JavaMethod("queryProducts", signature: "([Ljava/lang/String;)V")
    public func queryProducts(_ products: JavaObject?) { listener?.notify("onQueryProductsFail") }

    @JavaMethod("queryPurchases") public func queryPurchases() { listener?.notify("onQueryPurchasesFail") }
}

@JavaClass("com/mojang/minecraftpe/store/StoreFactory")
public final class JavaStoreFactory: JavaObject {
    @JavaMethod("createGooglePlayStore", signature: "(Ljava/lang/String;Lcom/mojang/minecraftpe/store/StoreListener;)Lcom/mojang/minecraftpe/store/Store;")
    public static func createGooglePlayStore(_ key: String?, _ listener: JavaObject?) -> JavaStore? { JavaStore(listener: listener, publicKey: key) }

    @JavaMethod("createAmazonAppStore", signature: "(Lcom/mojang/minecraftpe/store/StoreListener;)Lcom/mojang/minecraftpe/store/Store;")
    public static func createAmazonAppStore(_ listener: JavaObject?) -> JavaStore? { JavaStore(listener: listener, publicKey: nil) }
}
