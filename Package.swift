// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VR180Camera",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VR180Protocol", targets: ["VR180Protocol"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "153.0.0")
    ],
    targets: [
        .target(name: "VR180Protocol"),
        .executableTarget(
            name: "VR180Camera",
            dependencies: [
                "VR180Protocol",
                .product(name: "WebRTC", package: "WebRTC")
            ],
            linkerSettings: [.linkedFramework("CoreWLAN")]
        )
    ],
    swiftLanguageModes: [.v5]
)
