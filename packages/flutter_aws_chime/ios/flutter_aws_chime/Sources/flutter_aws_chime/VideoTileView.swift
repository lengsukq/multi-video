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
        tileId = args as? Int ?? -1
        super.init()
        guard tileId >= 0 else { return }
        let videoRenderView = _view as! VideoRenderView

        // Bind view to VideoView
        MeetingSession.shared.meetingSession?.audioVideo.bindVideoView(videoView: videoRenderView, tileId: tileId)

        // Fix aspect ratio and clip video rendering to the platform view bounds.
        _view.contentMode = .scaleAspectFit
        _view.clipsToBounds = true

        // Declare _view as UIView for Flutter interpretation
        _view = _view as UIView
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
