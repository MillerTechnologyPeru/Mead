// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Mead",
    products: [
        // Loader: runs arm64 Android ELF libraries on arm64 Linux.
        .executable(name: "mead", targets: ["MeadLoader"]),
        // Signs in to Google, for the license check below.
        .executable(name: "mead-google-login", targets: ["MeadGoogleLogin"]),
        // Google Play: sign-in and a real license check, with no JNI in it.
        .library(name: "MeadGooglePlay", targets: ["MeadGooglePlay"]),
        // Stands in for libc.so, libm.so, libdl.so, liblog.so and libz.so.
        .library(name: "MeadBionic", type: .dynamic, targets: ["MeadBionic"]),
        .library(name: "MeadDLBio", type: .dynamic, targets: ["CMeadDLBio"]),
        // Stands in for libandroid.so and libart.so: one library, as there
        // is to be one JVM however many things need it.
        .library(name: "MeadAndroid", type: .dynamic, targets: ["MeadAndroid"]),
        // Stand in for libEGL.so and the GLES libraries, and libvulkan.so.
        .library(name: "MeadEGL", type: .dynamic, targets: ["MeadEGL"]),
        .library(name: "MeadVulkan", type: .dynamic, targets: ["MeadVulkan"]),
        // Stands in for libOpenSLES.so and libaaudio.so.
        .library(name: "MeadOpenSLES", type: .dynamic, targets: ["MeadOpenSLES"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        // Interface between the loader and the provider libraries that
        // stand in for Android's.
        .target(name: "MeadInterface"),
        // The ELF loader itself.
        .target(
            name: "MeadLoaderCore",
            dependencies: ["MeadInterface"]
        ),
        .executableTarget(
            name: "MeadLoader",
            dependencies: ["MeadLoaderCore"]
        ),
        // What bionic's ABI needs that only C can say: variadics, struct
        // translation, and the table of what Android code may call.
        .target(
            name: "CMeadBionic",
            dependencies: ["MeadInterface"]
        ),
        .target(
            name: "MeadBionic",
            dependencies: ["CMeadBionic", "MeadInterface"]
        ),
        // The JNI function tables and variadics.
        .target(
            name: "CMeadJNI"
        ),
        // `@JavaClass` and its members, as compiler plugin.
        .macro(
            name: "MeadMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        // The runtime: handles, the class registry, threads and tracing. JNI
        // says who may touch what when, rather than Swift's concurrency.
        .target(
            name: "MeadJNI",
            dependencies: ["CMeadJNI", "MeadInterface", "MeadMacros"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SDL3, found at run time.
        .target(name: "CMeadWindow"),
        .target(name: "MeadWindow", dependencies: ["CMeadWindow"]),
        // Checking signatures: RSA, SHA-1, SHA-256.
        .target(name: "MeadCrypto"),
        // Google Play's sign-in and license servers, over FoundationNetworking.
        .target(
            name: "MeadGooglePlay",
            dependencies: ["MeadCrypto"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MeadGoogleLogin",
            dependencies: ["MeadGooglePlay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Android framework's classes, on the fake JVM.
        .target(
            name: "MeadJava",
            dependencies: ["MeadCrypto", "MeadJNI", "MeadInterface"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unity's Java player, for games built with Unity 6.
        .target(
            name: "MeadUnity",
            dependencies: ["MeadJNI", "MeadJava"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Minecraft's own Java classes: its activity, and its store's license check.
        .target(
            name: "MeadMinecraft",
            dependencies: ["MeadGooglePlay", "MeadJNI", "MeadJava"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The host's graphics libraries, through what little needs changing.
        .target(name: "MeadEGL", dependencies: ["MeadInterface"]),
        .target(name: "MeadVulkan", dependencies: ["MeadInterface"]),
        // Android's two audio APIs, on SDL3's audio.
        .target(
            name: "MeadOpenSLES",
            dependencies: ["MeadInterface", "CMeadWindow"],
            linkerSettings: [.linkedLibrary("m")]
        ),
        .target(name: "CMeadAndroid", dependencies: ["CMeadJNI", "MeadInterface"]),
        .target(
            name: "MeadAndroid",
            dependencies: ["CMeadAndroid", "MeadGooglePlay", "MeadJNI", "MeadJava", "MeadMinecraft", "MeadUnity", "MeadWindow", "MeadInterface"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeadGooglePlayTests",
            dependencies: ["MeadGooglePlay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeadAndroidTests",
            dependencies: ["MeadAndroid", "MeadCrypto", "MeadMinecraft", "MeadUnity", "CMeadWindow"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeadJNITests",
            dependencies: ["MeadJNI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "CMeadDLBio"),
        .testTarget(
            name: "MeadDLBioTests",
            dependencies: ["CMeadDLBio"]
        ),
        .testTarget(
            name: "MeadLoaderTests",
            dependencies: ["MeadLoaderCore"]
        ),
    ]
)
