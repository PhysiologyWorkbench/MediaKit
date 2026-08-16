// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"])
    ],
    targets: [
        .target(name: "MediaKit"),
        .executableTarget(name: "tap-probe", dependencies: ["MediaKit"],
                          exclude: ["README.md"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"])
    ]
)
