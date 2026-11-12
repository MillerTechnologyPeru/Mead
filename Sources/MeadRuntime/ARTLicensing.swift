internal import CSwiftJavaJNI
import Glibc
internal import MeadGooglePlay
internal import SwiftJavaJNICore

/// mead.server.LicensingService's natives: Google Play's license checks,
/// asked of Google for the account mead-google-login signed in, through
/// MeadGooglePlay. Each answer goes back to the app as Google sent it; the
/// app verifies it, and Mead says only what Google answered, never that a
/// license passed.
extension ART {
    func registerLicensing(env: JNIEnvironment) throws {
        typealias CheckV1 = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?, jstring?, jint, jlong) -> jobjectArray?
        typealias CheckV2 = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?, jstring?, jint) -> jobjectArray?
        let checkV1: CheckV1 = { env, _, packageName, versionCode, nonce in
            guard let env, let name = ART.string(env, packageName) else { return nil }
            let answer = LicenseRelay().checkV1(account: GoogleAccount.load(), packageName: name,
                                                versionCode: Int(versionCode), nonce: Int64(nonce))
            ART.logLicense(name, "first", answer.reason)
            return ART.strings(env, [String(answer.code), answer.signedData, answer.signature])
        }
        let checkV2: CheckV2 = { env, _, packageName, versionCode in
            guard let env, let name = ART.string(env, packageName) else { return nil }
            let answer = LicenseRelay().checkV2(account: GoogleAccount.load(), packageName: name, versionCode: Int(versionCode))
            ART.logLicense(name, "second", answer.reason)
            return ART.strings(env, [String(answer.code), answer.jwt])
        }
        try register(env: env, className: "mead/server/LicensingService", natives: [
            ("nativeCheckLicense", "(Ljava/lang/String;IJ)[Ljava/lang/String;", unsafeBitCast(checkV1, to: UnsafeMutableRawPointer.self)),
            ("nativeCheckLicenseV2", "(Ljava/lang/String;I)[Ljava/lang/String;", unsafeBitCast(checkV2, to: UnsafeMutableRawPointer.self)),
        ])
    }

    private static func logLicense(_ packageName: String, _ protocolName: String, _ reason: String) {
        let line = "mead: licensing: \(packageName), \(protocolName) protocol: \(reason); passed to the app unverified by Mead\n"
        _ = line.withCString { write(2, $0, strlen($0)) }
    }

    private static func string(_ env: UnsafeMutablePointer<JNIEnv?>, _ value: jstring?) -> String? {
        guard let jni = env.pointee?.pointee, let value, let characters = jni.GetStringUTFChars(env, value, nil) else { return nil }
        defer { jni.ReleaseStringUTFChars(env, value, characters) }
        return String(cString: characters)
    }

    /// A String[], nil elements as null.
    private static func strings(_ env: UnsafeMutablePointer<JNIEnv?>, _ values: [String?]) -> jobjectArray? {
        guard let jni = env.pointee?.pointee, let type = jni.FindClass(env, "java/lang/String") else { return nil }
        defer { jni.DeleteLocalRef(env, type) }
        guard let array = jni.NewObjectArray(env, jsize(values.count), type, nil) else { return nil }
        for (index, value) in values.enumerated() {
            guard let value, let string = jni.NewStringUTF(env, value) else { continue }
            jni.SetObjectArrayElement(env, array, jsize(index), string)
            jni.DeleteLocalRef(env, string)
        }
        return array
    }
}
