// swift-tools-version: 5.9
import PackageDescription

// Native sources are shared with the corresponding CocoaPods podspec. This
// Swift package is used by the iOS-SPM-enabled multi-video app on macOS.
let package = Package(
    name: "flutter_realtime_media_livekit",
    platforms: [.macOS(.v12)],
    products: [.library(name: "flutter-realtime-media-livekit", targets: ["flutter_realtime_media_livekit"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_realtime_media_livekit",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/flutter_realtime_media_livekit",
            publicHeadersPath: "include"
        )
    ],
    cxxLanguageStandard: .cxx17
)
