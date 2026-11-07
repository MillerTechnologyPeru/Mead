// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Mead",
    products: [
        // Loader: runs arm64 Android ELF libraries on arm64 Linux.
        .executable(name: "mead", targets: ["MeadLoader"]),
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
        .testTarget(
            name: "MeadLoaderTests",
            dependencies: ["MeadLoaderCore"]
        ),
    ]
)
