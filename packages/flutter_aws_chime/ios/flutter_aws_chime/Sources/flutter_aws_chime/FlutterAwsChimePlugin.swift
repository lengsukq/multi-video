import Flutter
import UIKit

public class FlutterAwsChimePlugin: NSObject, FlutterPlugin {

    #if !FRSDK_DISABLE_CHIME
    static var methodChannel: MethodChannelCoordinator?
    #endif

    public static func register(with registrar: FlutterPluginRegistrar) {
        let binaryMessenger = registrar.messenger()
        #if FRSDK_DISABLE_CHIME
        let channel = FlutterMethodChannel(
            name: "com.oneplusdream.aws.chime.methodChannel",
            binaryMessenger: binaryMessenger
        )
        channel.setMethodCallHandler { _, result in
            result([
                "success": false,
                "code": "unsupported_platform",
                "message": "AWS Chime native iOS SDK was excluded at build time via FRSDK_IOS_DISABLE_CHIME=1 to isolate WebRTC binary symbols.",
                "data": NSNull(),
                "details": NSNull(),
            ])
        }
        #else
        let viewFactory = FlutterVideoTileFactory(messenger: binaryMessenger)
        registrar.register(viewFactory, withId: "videoTile")
        methodChannel = MethodChannelCoordinator(binaryMessenger: binaryMessenger)
        methodChannel?.setUpMethodCallHandler()
        #endif
    }

}
