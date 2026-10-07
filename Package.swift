// swift-tools-version:5.9
import Foundation
import PackageDescription

// This Mac has Command Line Tools but no Xcode, so XCTest is missing and
// swift-testing's framework is not on the default search path.
let frameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingLibPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

// Only add the CLT paths when the active developer dir IS the Command Line Tools.
// With Xcode selected (CI), the toolchain finds Testing itself and a second copy
// from the CLT would be wrong.
let selected = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
let cltOnly = selected.isEmpty || selected.contains("CommandLineTools")
let testSwiftFlags: [SwiftSetting] = cltOnly ? [.unsafeFlags(["-F", frameworksPath])] : []
let testLinkFlags: [LinkerSetting] = cltOnly ? [.unsafeFlags([
    "-F", frameworksPath,
    "-Xlinker", "-rpath", "-Xlinker", frameworksPath,
    "-Xlinker", "-rpath", "-Xlinker", testingLibPath])] : []

let package = Package(
    name: "callrec",
    platforms: [.macOS(.v14)],
    dependencies: [
        // CoreML Whisper runner. Pinned: the model folder layout and decoding
        // options are API we depend on.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0")
    ],
    targets: [
        .target(
            name: "CallrecCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/CallrecCore",
            // Complete checking on the core, with every warning fixed (18 at the time of enabling).
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .executableTarget(
            name: "callrec",
            dependencies: ["CallrecCore"],
            path: "Sources/callrec",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so macOS sees the usage
                // descriptions and shows the TCC prompts for a bare CLI.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/callrec/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "CallrecApp",
            dependencies: ["CallrecCore"],
            path: "Sources/CallrecApp"
        ),
        .testTarget(
            name: "callrecTests",
            dependencies: ["CallrecCore"],
            path: "Tests/callrecTests",
            swiftSettings: testSwiftFlags,
            linkerSettings: testLinkFlags
        )
    ]
)
