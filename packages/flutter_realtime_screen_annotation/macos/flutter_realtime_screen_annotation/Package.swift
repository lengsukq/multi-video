// swift-tools-version: 5.9
import PackageDescription

// Native sources are shared with the corresponding CocoaPods podspec. This
// Swift package is used by the iOS-SPM-enabled multi-video app on macOS.
let package = Package(
    name: "flutter_realtime_screen_annotation",
    platforms: [.macOS(.v12)],
    products: [.library(name: "flutter-realtime-screen-annotation", targets: ["flutter_realtime_screen_annotation"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_realtime_screen_annotation",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/flutter_realtime_screen_annotation",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit")]
        )
    ],
    cxxLanguageStandard: .cxx17
)
