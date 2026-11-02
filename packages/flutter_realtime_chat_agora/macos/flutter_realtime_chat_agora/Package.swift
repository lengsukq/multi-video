// swift-tools-version: 5.9
import PackageDescription

// Native sources are shared with the corresponding CocoaPods podspec. This
// Swift package is used by the iOS-SPM-enabled multi-video app on macOS.
let package = Package(
    name: "flutter_realtime_chat_agora",
    platforms: [.macOS(.v12)],
    products: [.library(name: "flutter-realtime-chat-agora", targets: ["flutter_realtime_chat_agora"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_realtime_chat_agora",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/flutter_realtime_chat_agora",
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("WebKit")]
        )
    ],
    cxxLanguageStandard: .cxx17
)
