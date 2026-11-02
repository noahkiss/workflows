// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Kit", targets: ["Kit"])],
    targets: [
        .target(name: "Kit"),
        .testTarget(name: "KitTests", dependencies: ["Kit"]),
    ]
)
