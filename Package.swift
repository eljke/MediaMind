// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MediaMind",
    platforms: [.iOS(.v17)],
    products: [.library(name: "MediaMindCore", targets: ["MediaMindCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Modules/CSQLite"),
        .target(name: "MediaMindCore", dependencies: ["CSQLite"], path: "Sources/Core"),
        .testTarget(name: "MediaMindTests", dependencies: ["MediaMindCore"], path: "Tests")
    ]
)
