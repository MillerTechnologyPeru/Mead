import Glibc
import MeadJNI

// Android's alert dialog, as native code builds one: mostly to tell the
// player something has gone wrong. There's no dialog to show here, so its
// title and message go to the log, where they're of use.

@JavaClass("android/app/AlertDialog$Builder")
public final class JavaAlertDialogBuilder: JavaObject {
    public private(set) var title = ""
    public private(set) var message = ""

    @JavaMethod(signature: "(Landroid/content/Context;)V") public init(context: JavaObject?) {
        super.init()
    }

    static func text(_ sequence: JavaObject?) -> String {
        switch sequence {
        case let string as JavaString: return string.swiftValue
        case let builder as JavaStringBuilder: return builder.javaToString() ?? ""
        default: return ""
        }
    }

    @JavaMethod("setTitle", signature: "(Ljava/lang/CharSequence;)Landroid/app/AlertDialog$Builder;")
    public func setTitle(_ text: JavaObject?) -> JavaAlertDialogBuilder? {
        title = Self.text(text)
        JavaRuntime.shared.trace("AlertDialog title: \(title)")
        return self
    }

    @JavaMethod("setMessage", signature: "(Ljava/lang/CharSequence;)Landroid/app/AlertDialog$Builder;")
    public func setMessage(_ text: JavaObject?) -> JavaAlertDialogBuilder? {
        message = Self.text(text)
        JavaRuntime.shared.trace("AlertDialog message: \(message)")
        return self
    }

    @JavaMethod("setCancelable", signature: "(Z)Landroid/app/AlertDialog$Builder;")
    public func setCancelable(_ cancelable: Bool) -> JavaAlertDialogBuilder? { self }

    @JavaMethod("create", signature: "()Landroid/app/AlertDialog;")
    public func create() -> JavaAlertDialog? { JavaAlertDialog(title: title, message: message) }

    @JavaMethod("show", signature: "()Landroid/app/AlertDialog;")
    public func show() -> JavaAlertDialog? {
        let dialog = JavaAlertDialog(title: title, message: message)
        dialog.show()
        return dialog
    }
}

@JavaClass("android/app/AlertDialog")
public final class JavaAlertDialog: JavaObject {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
        super.init()
    }

    @JavaMethod("show") public func show() {
        var line = "mead: the game shows a dialog: \(title)\(title.isEmpty || message.isEmpty ? "" : ": ")\(message)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
    }

    @JavaMethod("dismiss") public func dismiss() {}
    @JavaMethod("isShowing") public func isShowing() -> Bool { false }
}
