import MeadJNI
import MeadJava

/// Brings Unity's Java player classes into being, beside Android's own. Safe
/// to call again.
public enum UnityFramework {
    public static func register() {
        JavaFramework.register()
        JavaRuntime.shared.defineInterface("com/android/billingclient/api/BillingClientStateListener", methods: [
            ("onBillingSetupFinished", "(Lcom/android/billingclient/api/BillingResult;)V"), ("onBillingServiceDisconnected", "()V"),
        ])
        JavaRuntime.shared.defineInterface("com/android/billingclient/api/PurchasesUpdatedListener", methods: [
            ("onPurchasesUpdated", "(Lcom/android/billingclient/api/BillingResult;Ljava/util/List;)V"),
        ])
        JavaRuntime.shared.defineInterface("com/google/android/gms/tasks/OnSuccessListener", methods: [("onSuccess", "(Ljava/lang/Object;)V")])
        JavaRuntime.shared.defineInterface("com/google/android/gms/tasks/OnFailureListener", methods: [("onFailure", "(Ljava/lang/Exception;)V")])
        JavaRuntime.shared.defineInterface("com/google/android/gms/tasks/OnCompleteListener", methods: [("onComplete", "(Lcom/google/android/gms/tasks/Task;)V")])
        let classes: [JavaObject.Type] = [
            JavaUnityPlayerActivity.self, JavaUnityPlayer.self, JavaUnityPlayerForActivityOrService.self,
            JavaUnityNativeLoader.self, JavaJNIBridge.self, JavaUnityReflectionHelper.self,
            JavaBillingResult.self, JavaBillingClient.self, JavaBillingClientBuilder.self,
            JavaPendingPurchasesParams.self, JavaPendingPurchasesParamsBuilder.self,
            JavaFinishedTask.self, JavaAuthenticationResult.self, JavaGamesSignInClient.self, JavaPlayGames.self, JavaPlayGamesSdk.self,
        ]
        for type in classes {
            JavaRuntime.shared.defineClass(for: type)
        }
    }
}
