// swift-tools-version:5.9
import PackageDescription

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
        )
    ]
)
