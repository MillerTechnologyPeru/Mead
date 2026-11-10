import MeadJNI
import MeadJava

// Google Play Games, as a device with no signed-in player has it: sign-in
// finishes and says the player isn't authenticated. Nothing here signs anyone
// in, or says anyone is signed in.

/// com.google.android.gms.tasks.Task, already finished with `result`.
/// Listeners hear about it later, on the main thread, as on Android.
@JavaClass("com/google/android/gms/tasks/Task")
public final class JavaFinishedTask: JavaObject {
    private let result: JavaObject?

    public init(result: JavaObject?) {
        self.result = result
        super.init()
    }

    private func notify(_ interface: String, _ method: String, _ signature: String, _ listener: JavaObject?, _ value: JavaObject?) -> JavaFinishedTask? {
        guard let listener else { return self }
        JavaLooper.main.post {
            let thread = JavaRuntime.shared.attachCurrentThread()
            var argument = jvalue()
            argument.l = thread.newLocal(value)
            thread.call(interface, method, signature, on: listener, [argument])
        }
        return self
    }

    private func success(_ listener: JavaObject?) -> JavaFinishedTask? {
        notify("com/google/android/gms/tasks/OnSuccessListener", "onSuccess", "(Ljava/lang/Object;)V", listener, result)
    }

    private func complete(_ listener: JavaObject?) -> JavaFinishedTask? {
        notify("com/google/android/gms/tasks/OnCompleteListener", "onComplete", "(Lcom/google/android/gms/tasks/Task;)V", listener, self)
    }

    @JavaMethod("addOnSuccessListener", signature: "(Lcom/google/android/gms/tasks/OnSuccessListener;)Lcom/google/android/gms/tasks/Task;")
    public func addOnSuccessListener(_ listener: JavaObject?) -> JavaFinishedTask? { success(listener) }

    @JavaMethod("addOnSuccessListener", signature: "(Landroid/app/Activity;Lcom/google/android/gms/tasks/OnSuccessListener;)Lcom/google/android/gms/tasks/Task;")
    public func addOnSuccessListener(activity: JavaObject?, _ listener: JavaObject?) -> JavaFinishedTask? { success(listener) }

    @JavaMethod("addOnCompleteListener", signature: "(Lcom/google/android/gms/tasks/OnCompleteListener;)Lcom/google/android/gms/tasks/Task;")
    public func addOnCompleteListener(_ listener: JavaObject?) -> JavaFinishedTask? { complete(listener) }

    @JavaMethod("addOnCompleteListener", signature: "(Landroid/app/Activity;Lcom/google/android/gms/tasks/OnCompleteListener;)Lcom/google/android/gms/tasks/Task;")
    public func addOnCompleteListener(activity: JavaObject?, _ listener: JavaObject?) -> JavaFinishedTask? { complete(listener) }

    // It didn't fail, so failure listeners never hear anything.
    @JavaMethod("addOnFailureListener", signature: "(Lcom/google/android/gms/tasks/OnFailureListener;)Lcom/google/android/gms/tasks/Task;")
    public func addOnFailureListener(_ listener: JavaObject?) -> JavaFinishedTask? { self }

    @JavaMethod("addOnFailureListener", signature: "(Landroid/app/Activity;Lcom/google/android/gms/tasks/OnFailureListener;)Lcom/google/android/gms/tasks/Task;")
    public func addOnFailureListener(activity: JavaObject?, _ listener: JavaObject?) -> JavaFinishedTask? { self }

    @JavaMethod("isComplete") public func isComplete() -> Bool { true }
    @JavaMethod("isSuccessful") public func isSuccessful() -> Bool { true }
    @JavaMethod("isCanceled") public func isCanceled() -> Bool { false }
    @JavaMethod("getResult", signature: "()Ljava/lang/Object;") public func getResult() -> JavaObject? { result }
    @JavaMethod("getException", signature: "()Ljava/lang/Exception;") public func getException() -> JavaObject? { nil }
}

@JavaClass("com/google/android/gms/games/AuthenticationResult")
public final class JavaAuthenticationResult: JavaObject {
    @JavaMethod("isAuthenticated") public func isAuthenticated() -> Bool { false }
}

@JavaClass("com/google/android/gms/games/GamesSignInClient")
public final class JavaGamesSignInClient: JavaObject {
    @JavaMethod("isAuthenticated", signature: "()Lcom/google/android/gms/tasks/Task;")
    public func isAuthenticated() -> JavaFinishedTask? { JavaFinishedTask(result: JavaAuthenticationResult()) }

    @JavaMethod("signIn", signature: "()Lcom/google/android/gms/tasks/Task;")
    public func signIn() -> JavaFinishedTask? { JavaFinishedTask(result: JavaAuthenticationResult()) }
}

@JavaClass("com/google/android/gms/games/PlayGames")
public final class JavaPlayGames: JavaObject {
    @JavaMethod("getGamesSignInClient", signature: "(Landroid/app/Activity;)Lcom/google/android/gms/games/GamesSignInClient;")
    public static func getGamesSignInClient(_ activity: JavaObject?) -> JavaGamesSignInClient? { JavaGamesSignInClient() }
}

@JavaClass("com/google/android/gms/games/PlayGamesSdk")
public final class JavaPlayGamesSdk: JavaObject {
    @JavaMethod("initialize", signature: "(Landroid/content/Context;)V") public static func initialize(_ context: JavaObject?) {}
}
