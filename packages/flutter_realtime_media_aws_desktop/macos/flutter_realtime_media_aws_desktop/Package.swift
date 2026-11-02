// swift-tools-version: 5.9
import PackageDescription

// Native sources are shared with the corresponding CocoaPods podspec. This
// Swift package is used by the iOS-SPM-enabled multi-video app on macOS.
let package = Package(
    name: "flutter_realtime_media_aws_desktop",
    platforms: [.macOS(.v12)],
    products: [.library(name: "flutter-realtime-media-aws-desktop", targets: ["flutter_realtime_media_aws_desktop"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_realtime_media_aws_desktop",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/flutter_realtime_media_aws_desktop",
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("AVFoundation"), .linkedFramework("AppKit")]
        )
    ],
    cxxLanguageStandard: .cxx17
)
