//
//  VideoTileObserver.swift
//  flutter_aws_chime
//
//  Created by Conan on 2023/9/9.
//


import AmazonChimeSDK
import AmazonChimeSDKMedia
import Foundation
import os

class MyVideoTileObserver: VideoTileObserver {
    private static let logger = Logger(subsystem: "com.oneplusdream.aws.chime",
                                       category: "VideoTileObserver")

    var methodChannel: MethodChannelCoordinator

    init(withMethodChannel methodChannel: MethodChannelCoordinator) {
        self.methodChannel = methodChannel
    }

    func videoTileDidAdd(tileState: VideoTileState) {
        NSLog("[flutter_aws_chime] videoTileDidAdd tileId=%d attendeeId=%@ local=%d content=%d size=%dx%d",
              tileState.tileId, tileState.attendeeId, tileState.isLocalTile ? 1 : 0,
              tileState.isContent ? 1 : 0, tileState.videoStreamContentWidth, tileState.videoStreamContentHeight)
        Self.logger.info("videoTileDidAdd tileId=\(tileState.tileId) attendeeId=\(tileState.attendeeId, privacy: .public) local=\(tileState.isLocalTile) content=\(tileState.isContent) size=\(tileState.videoStreamContentWidth)x\(tileState.videoStreamContentHeight)")
        methodChannel.callFlutterMethod(method: .videoTileAdd, args: videoTileStateToDict(state: tileState))
    }

    func videoTileDidRemove(tileState: VideoTileState) {
        NSLog("[flutter_aws_chime] videoTileDidRemove tileId=%d attendeeId=%@ local=%d content=%d",
              tileState.tileId, tileState.attendeeId, tileState.isLocalTile ? 1 : 0, tileState.isContent ? 1 : 0)
        Self.logger.info("videoTileDidRemove tileId=\(tileState.tileId) attendeeId=\(tileState.attendeeId, privacy: .public) local=\(tileState.isLocalTile) content=\(tileState.isContent)")
        MeetingSession.shared.meetingSession?.audioVideo.unbindVideoView(tileId: tileState.tileId)
        methodChannel.callFlutterMethod(method: .videoTileRemove, args: videoTileStateToDict(state: tileState))
    }

    func videoTileDidPause(tileState: VideoTileState) {
        callVideoTileEvent("videoTilePaused", tileState: tileState)
    }

    func videoTileDidResume(tileState: VideoTileState) {
        callVideoTileEvent("videoTileResumed", tileState: tileState)
    }

    func videoTileSizeDidChange(tileState: VideoTileState) {
        Self.logger.info("videoTileSizeDidChange tileId=\(tileState.tileId) size=\(tileState.videoStreamContentWidth)x\(tileState.videoStreamContentHeight)")
        callVideoTileEvent("videoTileSizeChanged", tileState: tileState)
    }

    private func callVideoTileEvent(_ type: String, tileState: VideoTileState) {
        methodChannel.callFlutterEvent(
            type,
            args: ["videoTile": videoTileStateToDict(state: tileState)]
        )
    }

    private func videoTileStateToDict(state: VideoTileState) -> [String: Any?] {
        return [
            "tileId": state.tileId,
            "attendeeId": state.attendeeId,
            "videoStreamContentWidth": state.videoStreamContentWidth,
            "videoStreamContentHeight": state.videoStreamContentHeight,
            "isLocalTile": state.isLocalTile,
            "isContent": state.isContent
        ]
    }
}
