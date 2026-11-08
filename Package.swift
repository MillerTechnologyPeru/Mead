// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Mead",
    products: [
        // Loader: runs arm64 Android ELF libraries on arm64 Linux.
        .executable(name: "mead", targets: ["MeadLoader"]),
        // Stands in for libc.so, libm.so, libdl.so, liblog.so and libz.so.
        .library(name: "MeadBionic", type: .dynamic, targets: ["MeadBionic"]),
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
        .testTarget(
            name: "MeadLoaderTests",
            dependencies: ["MeadLoaderCore"]
        ),
    ]
)
