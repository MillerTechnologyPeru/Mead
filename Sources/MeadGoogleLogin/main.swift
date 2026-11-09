import Foundation
import MeadGooglePlay

// Signs in to Google for Mead's license check. Google's sign-in page runs in
// the browser you already use, and this program only ever sees the short-lived
// token the page leaves behind. Your password never comes near it.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mead-google-login: \(message)\n".utf8))
    exit(1)
}

/// A line from the terminal, not echoed: it is a credential.
func readSecret() -> String? {
    var saved = termios()
    let isTerminal = tcgetattr(STDIN_FILENO, &saved) == 0
    if isTerminal {
        var hidden = saved
        hidden.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
    }
    defer {
        if isTerminal {
            tcsetattr(STDIN_FILENO, TCSANOW, &saved)
            print("")
        }
    }
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Only with a screen to open it on: over SSH, xdg-open can fall back to a
/// text browser and take over the terminal this program is reading from.
func openInBrowser(_ url: String) {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SSH_CONNECTION"] == nil, environment["DISPLAY"] != nil || environment["WAYLAND_DISPLAY"] != nil else { return }
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xdg-open") else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
    process.arguments = [url]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--status" {
    if let account = GoogleAccount.load() {
        print("signed in as \(account.email)")
    } else {
        print("not signed in")
    }
    exit(0)
}
if arguments.first == "--sign-out" {
    try? FileManager.default.removeItem(atPath: GoogleAccount.defaultPath)
    print("signed out")
    exit(0)
}
var androidID = "1"
if arguments.first == "--android-id", arguments.count == 2 {
    androidID = arguments[1]
} else if !arguments.isEmpty {
    fail("usage: mead-google-login [--android-id HEX | --status | --sign-out]")
}

print("""
1. Sign in at this page, in a browser on any computer:

     \(GoogleAuth.signInURL)

2. When it finishes, open the browser's developer tools and find the cookies
   for accounts.google.com (Application > Cookies in Chrome, Storage > Cookies
   in Firefox). Copy the value of the one called oauth_token.

3. Paste it here. It won't be shown as you paste.

""")
openInBrowser(GoogleAuth.signInURL)
print("oauth_token: ", terminator: "")
fflush(stdout)
guard let token = readSecret(), !token.isEmpty else { fail("nothing was pasted") }
do {
    let account = try GoogleAuth().signIn(oauthToken: token, androidID: androidID)
    try account.save()
    print("Signed in as \(account.email). Saved to \(GoogleAccount.defaultPath), readable only by you.")
} catch {
    fail("\(error)")
}
