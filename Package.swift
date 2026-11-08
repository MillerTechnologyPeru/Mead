// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Mead",
    products: [
        // Loader: runs arm64 Android ELF libraries on arm64 Linux.
        .executable(name: "mead", targets: ["MeadLoader"]),
        // Stands in for libc.so, libm.so, libdl.so, liblog.so and libz.so.
        .library(name: "MeadBionic", type: .dynamic, targets: ["MeadBionic"]),
        // The fake JVM: stands in for libart.so.
        .library(name: "MeadJNI", type: .dynamic, targets: ["MeadJNI"]),
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
        .testTarget(
            name: "MeadJNITests",
            dependencies: ["MeadJNI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeadLoaderTests",
            dependencies: ["MeadLoaderCore"]
        ),
    ]
)
