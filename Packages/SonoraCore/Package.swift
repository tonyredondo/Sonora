// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonoraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SonoraCore", targets: ["SonoraCore"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "SonoraCore", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "SonoraCoreTests", dependencies: ["SonoraCore", "ZIPFoundation"])
    ]
)
