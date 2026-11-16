//
//  VideoTileView.swift
//  flutter_aws_chime
//
//  Created by Conan on 2023/9/9.
//


import AmazonChimeSDK
import Foundation
import Flutter

class VideoTileView: NSObject, FlutterPlatformView {
    private var _view: UIView
    private let tileId: Int

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) {
        _view = DefaultVideoRenderView()
        let parsed = VideoTileView.parseArguments(args)
        tileId = parsed.tileId
        super.init()
        guard tileId >= 0 else { return }
        let videoRenderView = _view as! VideoRenderView

        // Bind view to VideoView
        MeetingSession.shared.meetingSession?.audioVideo.bindVideoView(videoView: videoRenderView, tileId: tileId)

        // Apply requested scaling mode and clip overflow to platform view bounds.
        _view.contentMode = parsed.fit == "cover" ? .scaleAspectFill : .scaleAspectFit
        _view.clipsToBounds = true

        // Declare _view as UIView for Flutter interpretation
        _view = _view as UIView
    }

    private static func parseArguments(_ args: Any?) -> (tileId: Int, fit: String) {
        if let rawId = args as? Int {
            return (rawId, "contain")
        }
        if let number = args as? NSNumber {
            return (number.intValue, "contain")
        }
        if let values = args as? [String: Any] {
            let id = (values["tileId"] as? NSNumber)?.intValue ?? -1
            let fit = values["fit"] as? String ?? "contain"
            return (id, fit)
        }
        return (-1, "contain")
    }

    func view() -> UIView {
        return _view
    }

    deinit {
        if tileId >= 0 {
            MeetingSession.shared.meetingSession?.audioVideo.unbindVideoView(tileId: tileId)
        }
    }
}
