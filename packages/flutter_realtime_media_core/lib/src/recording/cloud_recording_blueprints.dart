import 'cloud_recording_descriptor.dart';
import 'recording_options.dart';

/// Registry and blueprint generators for provider-specific cloud recording APIs.
///
/// Educational vendor request examples, NOT the production recording execution
/// path. The authoritative capability check and storage/auth configuration
/// belong to demo-server; clients must not dispatch these example payloads.
class CloudRecordingBlueprints {
  CloudRecordingBlueprints._();

  static void _requireLayout(
    String providerId,
    RecordingOptions options,
    Set<RecordingLayout> allowed,
  ) {
    if (!allowed.contains(options.layout)) {
      throw UnsupportedError(
        '$providerId cloud recording does not support '
        '${options.layout.name}; query recording capabilities first.',
      );
    }
  }

  /// Builds a [CloudRecordingDescriptor] for the given [providerId] and room context.
  static CloudRecordingDescriptor buildDescriptor({
    required String providerId,
    required String roomCode,
    String? participantId,
    RecordingOptions options = const RecordingOptions(
      mode: RecordingMode.cloud,
    ),
    String action = 'start',
  }) {
    final normalizedProvider = providerId.toLowerCase().trim();

    if (normalizedProvider.contains('agora')) {
      return _buildAgoraDescriptor(roomCode, participantId, options, action);
    } else if (normalizedProvider.contains('chime') ||
        normalizedProvider.contains('aws')) {
      return _buildAwsChimeDescriptor(roomCode, participantId, options, action);
    } else if (normalizedProvider.contains('trtc') ||
        normalizedProvider.contains('tencent')) {
      return _buildTencentTrtcDescriptor(
        roomCode,
        participantId,
        options,
        action,
      );
    } else if (normalizedProvider.contains('artc') ||
        normalizedProvider.contains('aliyun') ||
        normalizedProvider.contains('alibaba')) {
      return _buildAlibabaArtcDescriptor(
        roomCode,
        participantId,
        options,
        action,
      );
    } else if (normalizedProvider.contains('livekit')) {
      return _buildLiveKitDescriptor(roomCode, participantId, options, action);
    }

    return _buildGenericDescriptor(
      providerId,
      roomCode,
      participantId,
      options,
      action,
    );
  }

  static CloudRecordingDescriptor _buildAgoraDescriptor(
    String roomCode,
    String? participantId,
    RecordingOptions options,
    String action,
  ) {
    _requireLayout('agora', options, {
      RecordingLayout.grid,
      RecordingLayout.featuredParticipant,
      RecordingLayout.speaker,
    });
    // The recording service must join with a fresh numeric UID. A normal
    // participant ID is not necessarily valid and must not be reused.
    const uid = '{recordingUid}';

    // Map RecordingLayout to Agora mixedVideoLayout:
    // 0: Floating, 1: Best-Fit (Grid), 2: Vertical
    final agoraLayout = switch (options.layout) {
      RecordingLayout.grid => 1,
      RecordingLayout.featuredParticipant => 0,
      RecordingLayout.activeSpeaker => 0,
      RecordingLayout.speaker => 0,
      RecordingLayout.screenShare => 2,
      RecordingLayout.custom => 3,
    };

    // Stream types: 0: audio, 1: video, 2: audio & video
    final streamTypes = switch (options.streamType) {
      RecordingStreamType.audioOnly => 0,
      RecordingStreamType.videoOnly => 1,
      RecordingStreamType.both => 2,
    };

    final startParams = <String, dynamic>{
      'token': '{serverGeneratedRecordingRtcToken}',
      'recordingConfig': {
        'channelType':
            1, // Agora Flutter adapter joins live broadcasting channels.
        'streamTypes': streamTypes,
        'transcodingConfig': {
          'mixedVideoLayout': agoraLayout,
          'width': 1280,
          'height': 720,
          'fps': 15,
          'bitrate': 1130,
        },
      },
      'recordingFileConfig': {
        'avFileType': ['hls', 'mp4'],
      },
      'storageConfig': {
        'vendor': 1, // AWS S3; actual values belong to the backend only.
        'region': 0,
        'bucket': 'your-recording-bucket',
        'accessKey': 'YOUR_STORAGE_ACCESS_KEY',
        'secretKey': 'YOUR_STORAGE_SECRET_KEY',
        'fileNamePrefix': ['recordings', 'uniqueRecordingId123'],
      },
    };

    _deepMerge(startParams, options.rawProviderParams);
    final basePayload = <String, dynamic>{
      'cname': roomCode,
      'uid': uid,
      'clientRequest': action == 'start' ? startParams : <String, dynamic>{},
    };
    final modePath =
        'https://api.sd-rtn.com/v1/apps/{appId}/cloud_recording/'
        'resourceid/{resourceId}/sid/{sid}/mode/mix/';

    return CloudRecordingDescriptor(
      providerId: 'agora',
      action: action,
      endpoint: action == 'start'
          ? 'https://api.sd-rtn.com/v1/apps/{appId}/cloud_recording/'
                'resourceid/{resourceId}/mode/mix/start'
          : '$modePath$action',
      httpMethod: action == 'query' ? 'GET' : 'POST',
      suggestedHeaders: const {
        'Content-Type': 'application/json;charset=utf-8',
        'Authorization': 'Basic <BASE64(CustomerID:CustomerSecret)>',
      },
      payload: basePayload,
      documentationUrl:
          'https://docs.agora.io/en/api-reference/api-ref/cloud-recording/start',
      description: 'Agora Cloud Recording REST API (Composite Recording Mode)',
    );
  }

  static CloudRecordingDescriptor _buildAwsChimeDescriptor(
    String roomCode,
    String? participantId,
    RecordingOptions options,
    String action,
  ) {
    if (options.layout != RecordingLayout.grid) {
      throw UnsupportedError(
        'Chime webcam-only cloud recording supports GridView only. '
        'Content-share overlays do not implement a full speaker layout.',
      );
    }

    final basePayload = <String, dynamic>{
      'SourceType': 'ChimeSdkMeeting',
      'SourceArn': 'arn:aws:chime:us-east-1:{awsAccountId}:meeting/$roomCode',
      'SinkType': 'S3Bucket',
      'SinkArn':
          'arn:aws:s3:::your-recording-bucket/chime-recordings/$roomCode',
      'ClientRequestToken':
          'chime-rec-${DateTime.now().millisecondsSinceEpoch}',
      'ChimeSdkMeetingConfiguration': {
        'ArtifactsConfiguration': {
          'Audio': {'MuxType': 'AudioWithCompositedVideo'},
          'Video': {'State': 'Disabled'},
          'Content': {'State': 'Disabled'},
          'CompositedVideo': {
            'Layout': 'GridView',
            'Resolution':
                options.qualityPreset == RecordingQualityPreset.fullHd1080p30
                ? 'FHD'
                : 'HD',
            'GridViewConfiguration': {'ContentShareLayout': 'PresenterOnly'},
          },
        },
      },
    };

    _deepMerge(basePayload, options.rawProviderParams);

    return CloudRecordingDescriptor(
      providerId: 'chime',
      action: action,
      endpoint:
          'https://media-pipelines-chime.{region}.amazonaws.com/sdk-meetings/media-capture-pipelines',
      httpMethod: 'POST',
      suggestedHeaders: const {
        'Content-Type': 'application/json',
        'Authorization':
            'AWS4-HMAC-SHA256 Credential=.../media-pipelines-chime/...',
        'x-amz-date': '<ISO8601-Date>',
      },
      payload: basePayload,
      documentationUrl:
          'https://docs.aws.amazon.com/chime-sdk/latest/APIReference/API_Operations_Amazon_Chime_SDK_Media_Pipelines.html',
      description: 'AWS Chime SDK Media Capture Pipeline (Auto-record to S3)',
    );
  }

  static CloudRecordingDescriptor _buildTencentTrtcDescriptor(
    String roomCode,
    String? participantId,
    RecordingOptions options,
    String action,
  ) {
    _requireLayout('trtc', options, {
      RecordingLayout.grid,
      RecordingLayout.featuredParticipant,
      RecordingLayout.speaker,
    });
    final trtcLayout = switch (options.layout) {
      RecordingLayout.grid => 3, // 3: 九宫格
      RecordingLayout.featuredParticipant => 1, // 1: 悬浮/画中画
      RecordingLayout.activeSpeaker => 1, // 示意用；实际需服务端能力检查
      RecordingLayout.speaker => 1,
      RecordingLayout.screenShare => 2, // 2: 屏幕分享为主
      RecordingLayout.custom => 4,
    };

    final basePayload = <String, dynamic>{
      'Action': action == 'start'
          ? 'CreateCloudRecording'
          : 'StopCloudRecording',
      'Version': '2019-07-22',
      'SdkAppId': 1400000000,
      'RoomId': roomCode,
      'UserId': participantId ?? 'recorder_bot',
      'RecordMode': 1, // 1: 合流录制, 2: 单流录制
      'MixLayoutParams': {
        'MixLayoutMode': trtcLayout,
        'MaxMediaStreamNumber': 9,
      },
      'StorageParams': {
        'CloudStorage': 0, // 0: 腾讯云 COS
        'CloudStoreInfo': {
          'Region': 'ap-guangzhou',
          'Bucket': 'your-recording-bucket',
          'AccessKey': 'YOUR_COS_SECRET_ID',
          'SecretKey': 'YOUR_COS_SECRET_KEY',
        },
      },
    };

    _deepMerge(basePayload, options.rawProviderParams);

    return CloudRecordingDescriptor(
      providerId: 'trtc',
      action: action,
      endpoint: 'https://trtc.tencentcloudapi.com',
      httpMethod: 'POST',
      suggestedHeaders: const {
        'Content-Type': 'application/json',
        'Authorization': 'TC3-HMAC-SHA256 Credential=...',
        'X-TC-Action': 'CreateCloudRecording',
        'X-TC-Version': '2019-07-22',
      },
      payload: basePayload,
      documentationUrl: 'https://cloud.tencent.com/document/api/647/44055',
      description: 'Tencent Cloud TRTC Server API (CreateCloudRecording)',
    );
  }

  static CloudRecordingDescriptor _buildAlibabaArtcDescriptor(
    String roomCode,
    String? participantId,
    RecordingOptions options,
    String action,
  ) {
    _requireLayout('artc', options, {
      RecordingLayout.grid,
      RecordingLayout.featuredParticipant,
      RecordingLayout.speaker,
    });
    final basePayload = <String, dynamic>{
      'Action': 'StartMPUTask',
      'AppId': 'your-aliyun-artc-appid',
      'ChannelId': roomCode,
      'TaskId': 'task_${roomCode}_${DateTime.now().millisecondsSinceEpoch}',
      'TaskProfile': '1080P',
      'LayoutIds': [
        const {
              RecordingLayout.speaker,
              RecordingLayout.featuredParticipant,
              RecordingLayout.activeSpeaker,
            }.contains(options.layout)
            ? 'speaker_pip'
            : 'grid_auto',
      ],
      'StorageConfig': {
        'OssBucket': 'your-oss-bucket',
        'OssEndpoint': 'oss-cn-shanghai.aliyuncs.com',
      },
    };

    _deepMerge(basePayload, options.rawProviderParams);

    return CloudRecordingDescriptor(
      providerId: 'artc',
      action: action,
      endpoint: 'https://live.aliyuncs.com',
      httpMethod: 'POST',
      suggestedHeaders: const {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': 'ACS3-HMAC-SHA256 Credential=...',
      },
      payload: basePayload,
      documentationUrl: 'https://help.aliyun.com/document_detail/450410.html',
      description: 'Alibaba Cloud ARTC MPU Task (StartMPUTask)',
    );
  }

  static CloudRecordingDescriptor _buildLiveKitDescriptor(
    String roomCode,
    String? participantId,
    RecordingOptions options,
    String action,
  ) {
    _requireLayout('livekit', options, {
      RecordingLayout.grid,
      RecordingLayout.activeSpeaker,
      RecordingLayout.speaker,
    });
    final livekitLayout = switch (options.layout) {
      RecordingLayout.grid => 'grid',
      RecordingLayout.featuredParticipant => 'speaker',
      RecordingLayout.activeSpeaker => 'speaker',
      RecordingLayout.speaker => 'speaker',
      RecordingLayout.screenShare => 'speaker-dark',
      RecordingLayout.custom => 'custom',
    };

    final basePayload = <String, dynamic>{
      'room_name': roomCode,
      'template': {'layout': livekitLayout},
      'preset': 'H264_720P_30',
      'outputs': [
        {
          'file': {
            'file_type': 'MP4',
            // Resolved by the recording backend, never by the SDK client.
            'filepath': '<SERVER_MANAGED_LOCAL_EGRESS_OUTPUT_PATH>',
          },
        },
      ],
    };

    _deepMerge(basePayload, options.rawProviderParams);

    return CloudRecordingDescriptor(
      providerId: 'livekit',
      action: action,
      endpoint:
          'https://{livekit-host}/twirp/livekit.Egress/${switch (action) {
            'stop' => 'StopEgress',
            'query' => 'ListEgress',
            _ => 'StartEgress',
          }}',
      httpMethod: 'POST',
      suggestedHeaders: const {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer <LiveKit_Token_With_RoomRecord_Permission>',
      },
      payload: basePayload,
      documentationUrl: 'https://docs.livekit.io/server/egress/',
      description:
          'Self-hosted LiveKit Egress local file output (server-managed shared directory; no S3)',
    );
  }

  static CloudRecordingDescriptor _buildGenericDescriptor(
    String providerId,
    String roomCode,
    String? participantId,
    RecordingOptions options,
    String action,
  ) {
    final basePayload = <String, dynamic>{
      'roomCode': roomCode,
      if (participantId != null) 'participantId': participantId,
      'layout': options.layout.name,
      'streamType': options.streamType.name,
      'containerFormat': options.containerFormat.name,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _deepMerge(basePayload, options.rawProviderParams);

    return CloudRecordingDescriptor(
      providerId: providerId,
      action: action,
      endpoint:
          'https://api.your-backend.com/v1/rooms/$roomCode/recording/$action',
      httpMethod: 'POST',
      suggestedHeaders: const {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer <User_Or_Service_Token>',
      },
      payload: basePayload,
      documentationUrl: 'https://github.com/lengsukq/multi-video',
      description: 'Generic Realtime Cloud Recording Proxy Descriptor',
    );
  }

  /// Deeply merges [source] into [target].
  static void _deepMerge(
    Map<String, dynamic> target,
    Map<String, dynamic> source,
  ) {
    for (final entry in source.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is Map<String, dynamic> &&
          target[key] is Map<String, dynamic>) {
        _deepMerge(target[key] as Map<String, dynamic>, value);
      } else {
        target[key] = value;
      }
    }
  }
}
