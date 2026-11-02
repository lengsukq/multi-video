// swift-tools-version: 5.9
import PackageDescription

// Native sources are shared with the corresponding CocoaPods podspec. This
// Swift package is used by the iOS-SPM-enabled multi-video app on macOS.
let package = Package(
    name: "flutter_realtime_media_core",
    platforms: [.macOS(.v12)],
    products: [.library(name: "flutter-realtime-media-core", targets: ["flutter_realtime_media_core"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_realtime_media_core",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/flutter_realtime_media_core",
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("AppKit")]
        )
    ],
    cxxLanguageStandard: .cxx17
)
