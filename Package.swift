// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GarrisonHelper",
    platforms: [.macOS(.v14)],
    targets: [
        // Text recognition in a separate process the app can restart (see Sources/OCRWorker/main.swift).
        .executableTarget(
            name: "OCRWorker",
            path: "Sources/OCRWorker",
            linkerSettings: [.linkedFramework("Vision")]
        ),
        .executableTarget(
            name: "GarrisonHelper",
            path: "Sources/GarrisonHelper",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
            ]
        ),
    ]
)
