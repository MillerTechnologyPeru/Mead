import Glibc
import MeadJNI

// The Java half of libHttpClient, which the game does its HTTP through. Mead
// has no network stack behind it yet, so every request reports that there is
// no network, as a phone in airplane mode would. A request nobody answers is
// one the game may wait on forever.

/// Runs `body` on a thread of its own: how an answer the real platform gives
/// asynchronously reaches the game after the call that asked has returned.
public func runOnNewThread(_ body: @escaping () -> Void) {
    final class Box {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
    }
    var thread = pthread_t()
    let box = Unmanaged.passRetained(Box(body)).toOpaque()
    guard pthread_create(&thread, nil, { argument in
        Unmanaged<Box>.fromOpaque(argument!).takeRetainedValue().body()
        return nil
    }, box) == 0 else {
        Unmanaged<Box>.fromOpaque(box).release()
        return
    }
    pthread_detach(thread)
}

@JavaClass("com/xbox/httpclient/HttpClientRequest")
public final class JavaHttpClientRequest: JavaObject {
    private var url = ""

    @JavaMethod(signature: "(Landroid/content/Context;)V") public init(context: JavaObject?) {
        super.init()
    }

    @JavaMethod("setHttpUrl") public func setHttpUrl(_ url: String?) { self.url = url ?? "" }
    @JavaMethod("setHttpHeader") public func setHttpHeader(_ name: String?, _ value: String?) {}
    @JavaMethod("setHttpMethodAndBody") public func setHttpMethodAndBody(_ method: String?, _ body: Int64, _ contentType: String?, _ length: Int64) {}

    /// Reports the failure from another thread, as the real one finishes:
    /// the game's call has returned before it hears back.
    @JavaMethod("doRequestAsync") public func doRequestAsync(_ call: Int64) {
        JavaRuntime.shared.trace("HTTP request to \(url): no network")
        runOnNewThread { self.reportNoNetwork(call) }
    }

    private func reportNoNetwork(_ call: Int64) {
        let thread = JavaRuntime.shared.attachCurrentThread()
        var callValue = jvalue(), message = jvalue(), stack = jvalue(), details = jvalue(), noNetwork = jvalue()
        callValue.j = call
        message.l = thread.newLocal(JavaString("no network"))
        stack.l = thread.newLocal(JavaString(""))
        details.l = thread.newLocal(JavaString(""))
        noNetwork.z = 1
        _ = thread.call("com/xbox/httpclient/HttpClientRequest", "OnRequestFailed",
                        "(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;Z)V", on: self,
                        [callValue, message, stack, details, noNetwork])
    }
}
