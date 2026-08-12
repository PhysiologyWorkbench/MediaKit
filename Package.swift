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
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"])
    ]
)
