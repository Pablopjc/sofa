// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sofa",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "Sofa",
            path: "Sources/Sofa"
        )
    ]
)
