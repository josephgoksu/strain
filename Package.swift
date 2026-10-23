// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Strain",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HelperKit"),
        .executableTarget(name: "Strain", dependencies: ["HelperKit"]),
        .executableTarget(name: "StrainHelper", dependencies: ["HelperKit"]),
        .testTarget(name: "StrainTests", dependencies: ["Strain", "HelperKit"]),
    ]
)
