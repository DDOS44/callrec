// swift-tools-version:5.9
import PackageDescription
import Foundation

let frameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingLibPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "callrec",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "callrec",
            path: "Sources/callrec",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
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
        .testTarget(
            name: "callrecTests",
            dependencies: ["callrec"],
            path: "Tests/callrecTests",
            // This Mac has Command Line Tools but no Xcode, so XCTest is absent
            // and swift-testing's framework is not on the default search path.
            swiftSettings: [.unsafeFlags(["-F", frameworksPath])],
            linkerSettings: [.unsafeFlags(["-F", frameworksPath, "-Xlinker", "-rpath", "-Xlinker", frameworksPath, "-Xlinker", "-rpath", "-Xlinker", testingLibPath])]
        )
    ]
)
