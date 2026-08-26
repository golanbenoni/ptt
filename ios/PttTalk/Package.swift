// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let defaultRoots = ["libsignal-source", "libsignal"].map {
    packageDirectory.appendingPathComponent("../../../src/\($0)").standardizedFileURL.path
}
let defaultRoot = defaultRoots.first {
    FileManager.default.fileExists(atPath: "\($0)/swift/Package.swift")
        && FileManager.default.fileExists(atPath: "\($0)/target/debug/libsignal_ffi.a")
} ?? defaultRoots[0]
let libsignalSwift = Context.environment["LIBSIGNAL_SWIFT"] ?? "\(defaultRoot)/swift"
let libsignalFfi = Context.environment["LIBSIGNAL_FFI"] ?? "\(defaultRoot)/target/debug"
let nativeTarget = packageDirectory.appendingPathComponent("../../native/target").standardizedFileURL.path

let package = Package(
    name: "PttTalk",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PttTalkLib", targets: ["PttTalkLib"]),
        .executable(name: "PttTalk", targets: ["PttTalk"]),
        .executable(name: "ProductionVoiceProbe", targets: ["ProductionVoiceProbe"]),
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(nativeTarget)/release",
                    "-L\(nativeTarget)/aarch64-apple-ios/release",
                    "-L\(nativeTarget)/aarch64-apple-ios-sim/release",
                ]),
                .linkedLibrary("ptt_apple_ffi"),
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
        .executableTarget(
            name: "ProductionVoiceProbe",
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
