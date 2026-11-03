# Generated SDK declarations

Generated from optional driver registrations and adapter declarations. This is implementation evidence, not build or real-call acceptance.

| Provider | Engine | Driver | Platforms | Declared roles |
| --- | --- | --- | --- | --- |
| agora | agora | native | android, ios, macos, windows | participant, host, viewer |
| agora | agora | web | web | participant, host, viewer |
| agora-chat | agora-chat | native | android, ios, macos | participant, host, viewer (credential-dependent) |
| agora-chat | agora-chat | web | web | participant, host, viewer (credential-dependent) |
| artc | artc | native | android, ios, macos | participant, host, viewer |
| artc | artc | web | web | participant, host, viewer |
| aws | chime | native | android, ios, macos | participant |
| aws | ivs | native | android, ios, macos | participant, host, viewer |
| aws | chime | web | web | participant |
| aws | ivs | web | web | participant, host, viewer |
| ivs-chat | ivs-chat | native | android, ios, macos | participant, host, viewer (credential-dependent) |
| ivs-chat | ivs-chat | web | web | participant, host, viewer (credential-dependent) |
| livekit | livekit | native | android, ios, macos, windows | participant, host, viewer |
| livekit | livekit | web | web | participant, host, viewer |
| tencent-chat | tencent-chat | native | android, ios, macos, windows | participant, host, viewer (credential-dependent) |
| tencent-chat | tencent-chat | web | web | participant, host, viewer (credential-dependent) |
| trtc | trtc | native | android, ios, macos, windows | participant, host, viewer |
| trtc | trtc | web | web | participant, host, viewer |

## Background and media feature declarations

Expressions below are copied from source. Runtime probes, role conditions and platform restrictions remain part of the declaration; an implemented sink does not prove a successful remote call.

### livekit

Processed-video sink in adapter source: **yes**.

- `canBlurBackground`: `!isViewer && (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canReplaceBackgroundImage`: `!isViewer && (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canScreenShare`: `!isViewer && (!kIsWeb || !lk.lkPlatformIsWebMobile())`
- `canReportNetworkStats`: `true`

### agora

Processed-video sink in adapter source: **yes**.

- `canBlurBackground`: `!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canReplaceBackgroundImage`: `!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canScreenShare`: `!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canReportNetworkStats`: `true`

### trtc

Processed-video sink in adapter source: **yes**.

- `canBlurBackground`: `!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canReplaceBackgroundImage`: `!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canScreenShare`: `!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)`
- `canReportNetworkStats`: `true`

### artc

Processed-video sink in adapter source: **yes**.

- `canBlurBackground`: `_capabilities.canPublishVideo && _publishing._effectsPlatform`
- `canReplaceBackgroundImage`: `_capabilities.canPublishVideo && _publishing._effectsPlatform`
- `canScreenShare`: `true`
- `canReportNetworkStats`: `(not explicitly declared here; inspect factory/profile defaults)`

### chime

Processed-video sink in adapter source: **yes**.

- `canBlurBackground`: `_chimeCapabilities.canPublishVideo && _controls._effectsPlatform`
- `canReplaceBackgroundImage`: `_chimeCapabilities.canPublishVideo && _controls._effectsPlatform`
- `canScreenShare`: `(not explicitly declared here; inspect factory/profile defaults)`
- `canReportNetworkStats`: `(not explicitly declared here; inspect factory/profile defaults)`

### ivs

Processed-video sink in adapter source: **yes**.

- `canBlurBackground`: `publisher && _publishing._effectsPlatform`
- `canReplaceBackgroundImage`: `publisher && _publishing._effectsPlatform`
- `canScreenShare`: `(not explicitly declared here; inspect factory/profile defaults)`
- `canReportNetworkStats`: `true`

## Source fingerprints

These fingerprints make CI reject stale declarations, including changes to the explicit provider registrations, SDK dependency boundary and conditional Web features.

- `packages/flutter_realtime_chat_agora/lib/src/agora_chat_join_info.dart`: `b582e4b16a9f1033`
- `packages/flutter_realtime_chat_core/lib/src/model/chat_role.dart`: `9b92f5cea74f4d02`
- `packages/flutter_realtime_chat_ivs/lib/src/ivs_chat_join_info.dart`: `e6a17278c17c422e`
- `packages/flutter_realtime_chat_tencent/lib/src/tencent_chat_join_info.dart`: `3884ff1e25b5fa03`
- `packages/flutter_realtime_media_agora/lib/src/agora_capabilities.dart`: `b618738283104eab`
- `packages/flutter_realtime_media_agora/lib/src/agora_data_stream.dart`: `d6ea74592f257147`
- `packages/flutter_realtime_media_agora/lib/src/agora_event_adapter.dart`: `a84dc3833fb815ba`
- `packages/flutter_realtime_media_agora/lib/src/agora_failures.dart`: `03043f8ecd8cec0a`
- `packages/flutter_realtime_media_agora/lib/src/agora_host_session.dart`: `6c580ee08ff3cf20`
- `packages/flutter_realtime_media_agora/lib/src/agora_interactive_session.dart`: `a6becdffe4d1e4de`
- `packages/flutter_realtime_media_agora/lib/src/agora_media_session.dart`: `da520f33f5c0c53a`
- `packages/flutter_realtime_media_agora/lib/src/agora_publishing.dart`: `f77cecb63bbb13b8`
- `packages/flutter_realtime_media_agora/lib/src/agora_session_factory.dart`: `3aa6d565e8f46d7c`
- `packages/flutter_realtime_media_agora/lib/src/agora_snapshot_mapper.dart`: `fdb61a0c18b45a83`
- `packages/flutter_realtime_media_agora/lib/src/agora_viewer_session.dart`: `66a6084ceebe04ae`
- `packages/flutter_realtime_media_artc/lib/src/artc_broadcast_host_session.dart`: `cb87c97b4893d1f7`
- `packages/flutter_realtime_media_artc/lib/src/artc_broadcast_viewer_session.dart`: `e15645b56ceea688`
- `packages/flutter_realtime_media_artc/lib/src/artc_credential_refresh.dart`: `9cdc196c81564737`
- `packages/flutter_realtime_media_artc/lib/src/artc_data_messenger.dart`: `fc81f3876fa354aa`
- `packages/flutter_realtime_media_artc/lib/src/artc_media_session.dart`: `35f9bb5f1a4c0d79`
- `packages/flutter_realtime_media_artc/lib/src/artc_participant_session.dart`: `f8c90be8f374dc08`
- `packages/flutter_realtime_media_artc/lib/src/artc_publishing.dart`: `cd68f76ad601bdac`
- `packages/flutter_realtime_media_artc/lib/src/artc_session_factory.dart`: `518680ef5600f7b5`
- `packages/flutter_realtime_media_artc/lib/src/artc_snapshot_mapper.dart`: `b1817fc7cb34a16c`
- `packages/flutter_realtime_media_chime/lib/src/chime_media_controls.dart`: `93870615556d3fb5`
- `packages/flutter_realtime_media_chime/lib/src/chime_media_session.dart`: `2cb6094b62a384e6`
- `packages/flutter_realtime_media_chime/lib/src/chime_session_factory.dart`: `0ab5d595b8d7c8e8`
- `packages/flutter_realtime_media_chime/lib/src/chime_snapshot_mapper.dart`: `4ff43e296434fe9b`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_broadcast_host_session.dart`: `3cce1226054c0410`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_broadcast_viewer_session.dart`: `cf9f5aa536c39095`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_credential_refresh.dart`: `951fd54c0fe4fc47`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_media_session.dart`: `9b5cf8f6862124ef`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_participant_session.dart`: `acb0e546f8b38717`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_publishing.dart`: `721b02cd8cc285d5`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_session_factory.dart`: `0313e54a89b103ba`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_snapshot_mapper.dart`: `055c449e5e113946`
- `packages/flutter_realtime_media_ivs/lib/src/ivs_statistics.dart`: `f3d94cb05a2b89b9`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_capabilities.dart`: `8c2a6ce7df32ad0d`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_data_messenger.dart`: `3a47bbde56d14b68`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_event_adapter.dart`: `16b4b505430459e7`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_failures.dart`: `22e2362c19f025fd`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_host_session.dart`: `6b436595fb4d0d14`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_interactive_session.dart`: `a1301ba926951903`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_media_session.dart`: `0dfa561aa0c4c308`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_publishing.dart`: `b86973a4e5b903a0`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_screen_share.dart`: `47f5a9ab1d9cca0c`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_session_factory.dart`: `17bea6a36df94f9d`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_snapshot_mapper.dart`: `1382e25e2966db69`
- `packages/flutter_realtime_media_livekit/lib/src/livekit_viewer_session.dart`: `b700eca27eabe65f`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_capabilities.dart`: `d916894c9d5ff45a`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_credential_refresh.dart`: `e7676e67361ca60c`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_data_messenger.dart`: `cc26baf35741c7b5`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_host_session.dart`: `6da8673a8fc3700a`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_interactive_session.dart`: `c222094a67f4ba06`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_media_session.dart`: `79df4b2a144591c1`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_participant_session.dart`: `10bbea88de739a0f`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_publishing.dart`: `5eec22d70c5a0913`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_session_factory.dart`: `0725426dd935202e`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_snapshot_mapper.dart`: `6ab052c0233ea1a3`
- `packages/flutter_realtime_media_trtc/lib/src/trtc_viewer_session.dart`: `a3962250ad983979`
- `packages/flutter_realtime_media_web/lib/src/provider_web_profile.dart`: `767eba65b2f9f5ea`
- `packages/flutter_realtime_media_web/lib/src/provider_web_session_factory.dart`: `209ed9f6a0846624`
- `packages/flutter_realtime_provider_agora/lib/src/drivers_native.dart`: `2c208f9a627d1cad`
- `packages/flutter_realtime_provider_agora/lib/src/drivers_web.dart`: `bd81a8d666ea0441`
- `packages/flutter_realtime_provider_agora_chat/lib/src/drivers_native.dart`: `d08d482cbe94ac72`
- `packages/flutter_realtime_provider_agora_chat/lib/src/drivers_web.dart`: `ea37a522e2246302`
- `packages/flutter_realtime_provider_artc/lib/src/drivers_native.dart`: `8a7597c818ca21c5`
- `packages/flutter_realtime_provider_artc/lib/src/drivers_web.dart`: `7aa589413c8e9665`
- `packages/flutter_realtime_provider_aws/lib/src/drivers_native.dart`: `22bde5d25b6fc764`
- `packages/flutter_realtime_provider_aws/lib/src/drivers_web.dart`: `8ebcb8186e43b6ef`
- `packages/flutter_realtime_provider_ivs_chat/lib/src/drivers_native.dart`: `1fcf7e18de32be5d`
- `packages/flutter_realtime_provider_ivs_chat/lib/src/drivers_web.dart`: `ef1e144fa3e3f879`
- `packages/flutter_realtime_provider_livekit/lib/src/drivers_native.dart`: `cb07e880bf1de859`
- `packages/flutter_realtime_provider_livekit/lib/src/drivers_web.dart`: `caf4095823a79672`
- `packages/flutter_realtime_provider_tencent_chat/lib/src/drivers_native.dart`: `5862c1fea875fdfb`
- `packages/flutter_realtime_provider_tencent_chat/lib/src/drivers_web.dart`: `83276f7af33054a5`
- `packages/flutter_realtime_provider_trtc/lib/src/drivers_native.dart`: `578e9790ecde26a9`
- `packages/flutter_realtime_provider_trtc/lib/src/drivers_web.dart`: `fe51dd06f5757189`
- `packages/flutter_realtime_sdk/pubspec.yaml`: `e6ae8e6ae3779bcb`
- `packages/flutter_realtime_sdk_runtime/lib/src/provider_web_session_wrapper.dart`: `da906bcbf530dfe3`
- `packages/flutter_realtime_video_effects/pubspec.yaml`: `8c87ab635bc39e86`
