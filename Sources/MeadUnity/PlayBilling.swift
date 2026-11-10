import MeadJNI
import MeadJava

// Google Play Billing's client, as a device without the Play Store has it:
// the service is unavailable. Connecting reports BILLING_UNAVAILABLE, the
// client is never ready, and so there are no purchases to report. Games built
// with Unity IAP make one during start-up and carry on without a store once
// told there isn't one. Nothing here ever says something has been paid for.

private let billingUnavailable: Int32 = 3
private let unavailableMessage = "Google Play Billing is not available"

@JavaClass("com/android/billingclient/api/BillingResult")
public final class JavaBillingResult: JavaObject {
    public let responseCode: Int32
    public let debugMessage: String

    public init(responseCode: Int32, debugMessage: String) {
        self.responseCode = responseCode
        self.debugMessage = debugMessage
        super.init()
    }

    @JavaMethod("getResponseCode") public func getResponseCode() -> Int32 { responseCode }
    @JavaMethod("getDebugMessage") public func getDebugMessage() -> String? { debugMessage }
    @JavaMethod("toString") public func javaToString() -> String? { "Response Code: \(responseCode), Debug Message: \(debugMessage)" }
}

@JavaClass("com/android/billingclient/api/BillingClient")
public final class JavaBillingClient: JavaObject {
    private static let stateListener = "com/android/billingclient/api/BillingClientStateListener"
    private static let result = "Lcom/android/billingclient/api/BillingResult;"

    private static func unavailable() -> JavaBillingResult {
        JavaBillingResult(responseCode: billingUnavailable, debugMessage: unavailableMessage)
    }

    @JavaMethod("newBuilder", signature: "(Landroid/content/Context;)Lcom/android/billingclient/api/BillingClient$Builder;")
    public static func newBuilder(_ context: JavaObject?) -> JavaBillingClientBuilder? { JavaBillingClientBuilder() }

    /// Answers later, as the real client does, from the main thread.
    @JavaMethod("startConnection", signature: "(Lcom/android/billingclient/api/BillingClientStateListener;)V")
    public func startConnection(_ listener: JavaObject?) {
        guard let listener else { return }
        JavaLooper.main.post {
            let thread = JavaRuntime.shared.attachCurrentThread()
            var value = jvalue()
            value.l = thread.newLocal(Self.unavailable())
            thread.call(Self.stateListener, "onBillingSetupFinished", "(\(Self.result))V", on: listener, [value])
        }
    }

    @JavaMethod("endConnection") public func endConnection() {}
    @JavaMethod("isReady") public func isReady() -> Bool { false }
    @JavaMethod("getConnectionState") public func getConnectionState() -> Int32 { 0 }  // disconnected

    @JavaMethod("isFeatureSupported", signature: "(Ljava/lang/String;)Lcom/android/billingclient/api/BillingResult;")
    public func isFeatureSupported(_ feature: String?) -> JavaBillingResult? { Self.unavailable() }

    @JavaMethod("launchBillingFlow", signature: "(Landroid/app/Activity;Lcom/android/billingclient/api/BillingFlowParams;)Lcom/android/billingclient/api/BillingResult;")
    public func launchBillingFlow(_ activity: JavaObject?, _ parameters: JavaObject?) -> JavaBillingResult? { Self.unavailable() }
}

@JavaClass("com/android/billingclient/api/BillingClient$Builder")
public final class JavaBillingClientBuilder: JavaObject {
    @JavaMethod("setListener", signature: "(Lcom/android/billingclient/api/PurchasesUpdatedListener;)Lcom/android/billingclient/api/BillingClient$Builder;")
    public func setListener(_ listener: JavaObject?) -> JavaBillingClientBuilder? { self }

    @JavaMethod("enablePendingPurchases", signature: "()Lcom/android/billingclient/api/BillingClient$Builder;")
    public func enablePendingPurchases() -> JavaBillingClientBuilder? { self }

    @JavaMethod("enablePendingPurchases", signature: "(Lcom/android/billingclient/api/PendingPurchasesParams;)Lcom/android/billingclient/api/BillingClient$Builder;")
    public func enablePendingPurchases(_ parameters: JavaObject?) -> JavaBillingClientBuilder? { self }

    @JavaMethod("build", signature: "()Lcom/android/billingclient/api/BillingClient;")
    public func build() -> JavaBillingClient? { JavaBillingClient() }
}

@JavaClass("com/android/billingclient/api/PendingPurchasesParams")
public final class JavaPendingPurchasesParams: JavaObject {
    @JavaMethod("newBuilder", signature: "()Lcom/android/billingclient/api/PendingPurchasesParams$Builder;")
    public static func newBuilder() -> JavaPendingPurchasesParamsBuilder? { JavaPendingPurchasesParamsBuilder() }
}

@JavaClass("com/android/billingclient/api/PendingPurchasesParams$Builder")
public final class JavaPendingPurchasesParamsBuilder: JavaObject {
    @JavaMethod("enableOneTimeProducts", signature: "()Lcom/android/billingclient/api/PendingPurchasesParams$Builder;")
    public func enableOneTimeProducts() -> JavaPendingPurchasesParamsBuilder? { self }

    @JavaMethod("enablePrepaidPlans", signature: "()Lcom/android/billingclient/api/PendingPurchasesParams$Builder;")
    public func enablePrepaidPlans() -> JavaPendingPurchasesParamsBuilder? { self }

    @JavaMethod("build", signature: "()Lcom/android/billingclient/api/PendingPurchasesParams;")
    public func build() -> JavaPendingPurchasesParams? { JavaPendingPurchasesParams() }
}
