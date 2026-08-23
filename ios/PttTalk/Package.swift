// swift-tools-version: 6.0
import PackageDescription

let libsignalSwift =
    Context.environment["LIBSIGNAL_SWIFT"] ?? "/Users/golanbenoni/src/libsignal/swift"
let libsignalFfi =
    Context.environment["LIBSIGNAL_FFI"] ?? "/Users/golanbenoni/src/libsignal/target/debug"

let package = Package(
    name: "PttTalk",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PttTalkLib", targets: ["PttTalkLib"]),
        .executable(name: "PttTalk", targets: ["PttTalk"]),
    ],
    dependencies: [
        .package(path: "../PttWire"),
        .package(name: "LibSignalClient", path: libsignalSwift),
    ],
    targets: [
        .target(
            name: "PttTalkLib",
            dependencies: [
                "PttWire",
                .product(name: "LibSignalClient", package: "LibSignalClient"),
            ]
        ),
        .executableTarget(
            name: "PttTalk",
            dependencies: ["PttTalkLib"],
            linkerSettings: [
                .unsafeFlags(["-L\(libsignalFfi)"]),
                .linkedLibrary("signal_ffi"),
                .linkedLibrary("resolv"),
                .linkedLibrary("c++"),
                .linkedLibrary("compression"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "PttTalkLibTests",
            dependencies: ["PttTalkLib"],
            linkerSettings: [
                .unsafeFlags(["-L\(libsignalFfi)"]),
                .linkedLibrary("signal_ffi"),
                .linkedLibrary("resolv"),
                .linkedLibrary("c++"),
                .linkedLibrary("compression"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
