// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "callrec",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "callrec",
            path: "Sources/callrec",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
