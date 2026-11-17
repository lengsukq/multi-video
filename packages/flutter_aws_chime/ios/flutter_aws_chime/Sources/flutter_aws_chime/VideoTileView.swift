//
//  VideoTileView.swift
//  flutter_aws_chime
//
//  Created by Conan on 2023/9/9.
//


import AmazonChimeSDK
import Foundation
import Flutter
import os

class VideoTileView: NSObject, FlutterPlatformView {
    private static let logger = Logger(subsystem: "com.oneplusdream.aws.chime",
                                       category: "VideoTileView")
    private static var activeBindings: [Int: ObjectIdentifier] = [:]
    private var _view: UIView
    private let tileId: Int

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) {
        _view = DefaultVideoRenderView(frame: frame)
        let parsed = VideoTileView.parseArguments(args)
        tileId = parsed.tileId
        super.init()
        guard tileId >= 0 else { return }
        let videoRenderView = _view as! VideoRenderView
        let session = MeetingSession.shared.meetingSession
        NSLog("[flutter_aws_chime] Binding VideoRenderView tileId=%d fit=%@ hasSession=%d",
              self.tileId, parsed.fit, session != nil ? 1 : 0)
        Self.logger.info("Binding VideoRenderView tileId=\(self.tileId) fit=\(parsed.fit, privacy: .public) hasSession=\(session != nil)")

        VideoTileView.activeBindings[tileId] = ObjectIdentifier(self)
        // Bind view to VideoView
        session?.audioVideo.bindVideoView(videoView: videoRenderView, tileId: tileId)

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
        guard tileId >= 0 else { return }
        let targetTileId = tileId
        let selfId = ObjectIdentifier(self)
        let release = {
            if VideoTileView.activeBindings[targetTileId] == selfId {
                VideoTileView.activeBindings.removeValue(forKey: targetTileId)
                MeetingSession.shared.meetingSession?.audioVideo.unbindVideoView(tileId: targetTileId)
            }
        }
        if Thread.isMainThread {
            release()
        } else {
            DispatchQueue.main.async(execute: release)
        }
    }
}
