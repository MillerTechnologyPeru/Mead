internal import CSwiftJavaJNI
internal import SwiftJavaJNICore

/// The uid the app sees: Android's first application uid, as an app holds
/// on a phone, whatever user runs Mead. ROCKNIX runs everything as root, and
/// Android's framework treats uid 0 as no app: StorageManager lists no
/// volumes for a package whose uid is 0, so getExternalFilesDir is null (and
/// a desktop's first user, 1000, is Android's system uid). Java asks the
/// uid of libcore's Os.getuid (Process.myUid does) and of
/// Binder.getCallingUid (binder calls stay in this process, so every caller
/// is the app); both answer this uid. The kernel still checks file access
/// against the user that runs Mead.
extension ART {
    static let appUid: jint = 10000

    func registerIdentity(env: JNIEnvironment) throws {
        // Linux.getuid is an instance native, Binder.getCallingUid a
        // @CriticalNative with no arguments; a function that reads none of
        // its arguments suits both calling conventions.
        typealias Uid = @convention(c) () -> jint
        let uid: Uid = { ART.appUid }
        let pointer = unsafeBitCast(uid, to: UnsafeMutableRawPointer.self)
        try register(env: env, className: "libcore/io/Linux", natives: [("getuid", "()I", pointer)])
        try register(env: env, className: "android/os/Binder", natives: [("getCallingUid", "()I", pointer)])
    }
}
