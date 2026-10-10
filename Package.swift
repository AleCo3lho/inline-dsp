// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InlineDSP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "inline-dsp", targets: ["InlineDSP"]),
    ],
    targets: [
        .target(name: "ObjCExceptionCatcher"),
        .executableTarget(
            name: "InlineDSP",
            dependencies: ["ObjCExceptionCatcher"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("SwiftUI"),
                // Embed an Info.plist so TCC has an NSMicrophoneUsageDescription when the
                // binary runs headless (e.g. under launchd) rather than from a terminal.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/InlineDSP/Info.plist",
                ]),
            ]
        ),
    ]
)
