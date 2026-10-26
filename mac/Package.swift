// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RemoteMac",
            path: "Sources/RemoteMac",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
