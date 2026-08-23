// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PttWire",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "PttWire", targets: ["PttWire"])],
    targets: [
        .target(name: "PttWire"),
        .testTarget(name: "PttWireTests", dependencies: ["PttWire"]),
    ]
)
