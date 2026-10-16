// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonoraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SonoraCore", targets: ["SonoraCore"])],
    targets: [
        .target(name: "SonoraCore"),
        .testTarget(name: "SonoraCoreTests", dependencies: ["SonoraCore"])
    ]
)
