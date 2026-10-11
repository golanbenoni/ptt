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
// Test only the library once. Building every executable into an iOS test host
// otherwise produces duplicate copies of LiveKit's binary frameworks.
let libraryTestsOnly = Context.environment["PTT_LIBRARY_TESTS_ONLY"] == "1"
let nativeLibraryDirectories = Context.environment["PTT_NATIVE_TARGET_DIR"].map { [$0] } ?? [
    "\(nativeTarget)/release", "\(nativeTarget)/aarch64-apple-ios/release",
    "\(nativeTarget)/aarch64-apple-ios-sim/release",
]

let package = Package(
    name: "PttTalk",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PttTalkLib", targets: ["PttTalkLib"]),
        .executable(name: "PttTalk", targets: ["PttTalk"]),
        .executable(name: "ProductionVoiceProbe", targets: ["ProductionVoiceProbe"]),
        .executable(name: "CallCiphertextObserverProbe", targets: ["CallCiphertextObserverProbe"]),
    ].filter { !libraryTestsOnly || $0.name == "PttTalkLib" },
    dependencies: [
        .package(path: "../PttWire"),
        .package(name: "LibSignalClient", path: libsignalSwift),
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.16.0"),
    ],
    targets: [
        .target(
            name: "PttTalkLib",
            dependencies: [
                "PttWire",
                .product(name: "LibSignalClient", package: "LibSignalClient"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            linkerSettings: [
                .unsafeFlags(nativeLibraryDirectories.map { "-L\($0)" }),
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
        .executableTarget(
            name: "CallCiphertextObserverProbe",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
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
    ].filter { !libraryTestsOnly || ["PttTalkLib", "PttTalkLibTests"].contains($0.name) }
)
