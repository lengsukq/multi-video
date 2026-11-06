# 供应商云端录制 · Flutter SDK + Demo

本项目是 **Flutter 前端 SDK**。录制、混流、转码（若厂商提供）由 RTC 供应商的云端服务执行；`demo-server` 只负责调用厂商 REST/OpenAPI、持有服务器凭证、查询任务以及流式转发云存储里的 MP4 文件。**不需要部署 Linux 录制程序、Java Recording SDK、FFmpeg 或我们自己的媒体录制服务。**

**云录制布局能力与跨厂商限制**请先阅读：[宫格、固定主画面、动态发言人布局说明](CLOUD_RECORDING.md)。Demo 已根据服务端真实能力过滤布局，不能把“演讲者”笼统视为所有供应商都能自动跟踪语音。

## 供应商能力现状

| 媒体供应商 | Demo 录制执行器 | 厂商托管录制 | 存储要求 | MP4 下载 | 实际验收状态 |
|---|---|---|---|---|---|
| Agora | `agora-cloud-recording.ts` | Agora Cloud Recording：Acquire/Start/Query/Stop（`mode/mix`） | S3（第一版下载适配；Agora 也支持其他厂商存储，但需对应下载适配） | 通过 S3 读取后由 Demo 下载 | ⏳ 模拟 API 契约已对齐；历史真实调用 `acquire` 返回 HTTP 401，修复后待重新验收 |
| LiveKit | `livekit-cloud-recording.ts` | LiveKit Egress API，配 LiveKit Cloud 服务 | S3 | 通过 S3 读取后由 Demo 下载 | ✅ **用户确认已可用（2026-10-12）** |
| Tencent TRTC | `trtc-cloud-recording.ts` | 腾讯云 Create/Describe/DeleteCloudRecording | 默认腾讯 VOD；可选直接写入 AWS S3 | VOD HTTPS 转发，或从 S3 私有读取后由 Demo 下载 | ⏳ 真实环境待验收 |
| Alibaba ARTC | `artc-vod-recording.ts`（默认）/ `artc-cloud-recording.ts`（旧 OSS） | 阿里云 Live RTC Start/Stop/DescribeRtcCloudRecordingFiles | 默认阿里云 VOD；旧 OSS 可显式启用；**不新增 AWS S3** | VOD GetPlayInfo MP4 HTTPS 转发；旧 OSS 流式下载 | ⏳ 真实环境待验收 |
| AWS Chime SDK | `chime-cloud-recording.ts` | AWS Media Capture Pipeline + Media Concatenation Pipeline | S3 | 完成云端合成后从 S3 读取 MP4 | ✅ **用户确认 Chime 云录制及文件下载可用（2026-10-13）**；音画质量及多布局仍待细项验收 |
| AWS IVS Real-Time | `ivs-cloud-recording.ts` | AWS IVS Composition（HLS）+ AWS MediaConvert（云端 MP4 转码） | S3 + IVS Encoder/Storage ARN + MediaConvert IAM Role | 等录制完成事件 → MediaConvert Job 完成 → S3 MP4 下载 | ✅ **用户确认 IVS 云录制与 MP4 下载成功（2026-10-13）**；音画质量及多布局仍待细项验收 |

接口已实现并通过模拟厂商 API 单测。**LiveKit Cloud 录制由项目使用者于 2026-10-12 确认可用；AWS Chime 会议云录制和下载由项目使用者于 2026-10-13 确认可用；AWS IVS 直播云录制及 MP4 下载也由项目使用者于 2026-10-13 确认成功。** IVS Demo 的 MP4 导出链路使用 AWS MediaConvert 转码后下载，因此本次用户反馈覆盖**实际取得 MP4 文件**；但未独立审阅 MediaConvert Job 日志或检查文件音画质量。上述状态属于用户实际使用反馈，本次文档更新未重新发起真实录制，也不代表已逐平台验证全部布局、音轨或长时间录制。其他尚未确认的供应商真实 E2E 仍待验收；Agora 当前受 REST API `acquire` HTTP 401 阻断（与 RTC 入会、S3 文件下载属于不同环节）。

## 填写方式：存储桶可以先留空

新建房间、正常入会、聊天与其他 SDK 能力与录制配置解耦。如果录制存储没有配置，Demo 录制前查询 `recording/status` 的 `recordingAvailable: false`，并展示 `recordingUnavailableReason`；点击开始时返回明确的配置错误，**不会创建假任务，也不会消耗录制配额**。

### Agora（官方 Cloud Recording REST）

```dotenv
# 现有 Agora 入会使用的 App ID 与 App Certificate，录制复用
AGORA_APP_ID=
AGORA_APP_CERTIFICATE=

# Agora RESTful API 的 Customer ID / Customer Secret（与 App ID 不同）
AGORA_CUSTOMER_ID=
AGORA_CUSTOMER_SECRET=

# 示例第一版选择 AWS S3（Agora vendor=1）
AGORA_RECORDING_S3_BUCKET=
AGORA_RECORDING_S3_REGION=              # 如 us-east-1
AGORA_RECORDING_S3_REGION_CODE=         # Agora 的数值地域编码；us-east-1 是 0
AGORA_RECORDING_S3_ACCESS_KEY=
AGORA_RECORDING_S3_SECRET_KEY=
```

Demo Server 使用 **Basic Customer ID/Secret** 调用官方 `https://api.sd-rtn.com/v1/apps/{appid}/cloud_recording`，由后端生成不与客户端重复的录制 UID 和录制专用 RTC Token，执行 `acquire → mode/mix/start → mode/mix/query → mode/mix/stop`。请求中携带服务端 `recordingConfig`、嵌套的 `transcodingConfig`、`recordingFileConfig: {avFileType: ['hls', 'mp4']}` 和 S3 `storageConfig`；Agora 官方 **不允许只配置 `['mp4']`**。录制专用 `fileNamePrefix` 由服务端生成，仅含字母数字。停止时请求 `async_stop: false`；若 Stop 响应没有提供 MP4 文件名，则仅在当前任务的独立 S3 前缀下查找 MP4。必须真实确认对象存在，才向 Demo 提供下载。**不需要 `AGORA_RECORDING_SDK_JAR` / `AGORA_RECORDING_NATIVE_LIB_DIR` 或 Linux。**

**本地模拟验收已通过，但未发起 Agora 实际录制请求。** 当前 Demo 下载接口只导出单个 MP4；Agora 混合模式若超过约 2 小时或 2GB 可能自动分段成多个 MP4，完整多段导出尚未实现。另外启用 HLS+MP4 会生成 M3U8/TS 等附加文件，当前 Demo 的下载清理仅删除已下载的 MP4，不会自动清理该任务的所有 HLS 文件；如需清理全部录制产物，应另行设计安全的存储生命周期策略。正式验收请检查 **多人音频是否真的被混入 MP4**，而不仅是文件存在。

新加入的 S3 前缀回退查找使用 `ListObjectsV2`，因此 Agora 使用的 S3 凭据除上传所需的 `s3:PutObject` 外，还需要给**指定存储桶**授予 `s3:ListBucket`、`s3:GetObject`；Demo 下载完成后删除文件还需要 `s3:DeleteObject`。为安全起见，请按录制专用桶和 `flutterrealtimedemo/` 前缀收紧权限，不要使用账户级全权限密钥。如果没有 `s3:ListBucket`，Stop 不返回 `fileList` 时将无法可靠发现 MP4。权限调整必须由用户在 AWS 侧执行，本次没有访问或修改云资源。

官方文档：[Acquire](https://docs.agora.io/en/api-reference/api-ref/cloud-recording/acquire)、[Start](https://docs.agora.io/en/api-reference/api-ref/cloud-recording/start)、[Query](https://docs.agora.io/en/api-reference/api-ref/cloud-recording/query)、[Stop](https://docs.agora.io/en/api-reference/api-ref/cloud-recording/stop)。

#### 结束直播时的录制防漏停策略

普通点击「停止云录制」使用房主鉴权的 `POST /rooms/:code/recording/stop`，Agora 执行 `mode/mix/stop`。房主在直播页点击「结束直播」时，Flutter Room UI **先停止仍在运行的云录制、再请求关闭房间**；录制操作正在启动/停止时会要求等待，避免请求竞态。

服务端有第二道保护：Agora 录制执行器在当前 Demo Server 进程内与路由、房间关闭逻辑共享同一任务表；**房主关闭房间、最后一名成员离开，以及服务器在约 90 秒无心跳后自动清理房间**时，均会先调用 Agora Stop，确认调用成功才删除房间。Stop 失败时保留房间及凭据，以便重试；开始/停止录制与关闭房间操作通过现有的房间队列串行化。手动停止或随后重复关闭不会重复调用 Agora Stop。

**边界**：以上保护覆盖正常请求和服务器仍在运行时的空闲回收，但尚无跨 Demo Server 进程重启的云录制任务持久化；服务器突然崩溃/重启、客户端断网或 Agora REST 持续不可用时，无法绝对保证立刻停止云端录制。Agora `maxIdleTime=30` 是没有订阅到媒体流时的自动结束兜底，而非固定 30 秒最大计费时间；如果房内仍有发布者，不能仅依赖该参数。**建议先点击「停止云录制」、等文件生成并下载，再点击「结束直播」**：直播间删除后原鉴权下载地址将不再可用。

Agora Cloud Recording 可以配置其他云存储厂商，但本次真正写好的 Agora MP4 **读取/下载**适配器是 S3；不要仅把 `storageConfig.vendor` 改成 COS/OSS 却继续使用 S3 下载器。

### LiveKit Cloud Egress

**验收记录（2026-10-12）：用户已确认 LiveKit 云录制可用。** 当前项目采用 LiveKit Cloud Egress → AWS S3 → Demo 下载 MP4 的执行路径，统一 Flutter SDK 录制 API 不变。后续如果调整 S3 Bucket、Egress 模式、视频布局或目标平台，应重新验证实际录制与下载；本条不等同于全部平台和音画质量的逐项验收。

```dotenv
LIVEKIT_URL=wss://your-project.livekit.cloud
LIVEKIT_API_KEY=
LIVEKIT_API_SECRET=

LIVEKIT_RECORDING_MODE=cloud
LIVEKIT_RECORDING_S3_BUCKET=
LIVEKIT_RECORDING_S3_REGION=
LIVEKIT_RECORDING_S3_ACCESS_KEY=
LIVEKIT_RECORDING_S3_SECRET_KEY=
```

默认在未填写本地 Egress 路径时使用**云端 S3**，无需 Egress Worker。服务端使用 `StartEgress → StopEgress → ListEgress`，存储字段由后端注入；上传完成后通过受控 S3 Key 验证文件再提供下载。为了不破坏之前的自部署示例，仍可通过 `LIVEKIT_RECORDING_MODE=local` + `LIVEKIT_EGRESS_OUTPUT_DIR`、`LIVEKIT_RECORDING_EXPORT_DIR` 使用旧的共享本地挂载目录模式。**推荐 Demo 使用 cloud。**

### Tencent TRTC 云录制 / VOD 或 AWS S3

```dotenv
TRTC_SDK_APP_ID=
TRTC_SDK_SECRET_KEY=
TENCENTCLOUD_SECRET_ID=
TENCENTCLOUD_SECRET_KEY=
TRTC_RECORDING_CALLBACK_KEY=
TRTC_RECORDING_VOD_HOSTS=
TRTC_RECORDING_REGION=ap-guangzhou
TRTC_RECORDING_STORAGE=vod

# 可选：将 TRTC_RECORDING_STORAGE 改为 s3，直接写入 AWS S3
# 此模式不需要 TRTC_RECORDING_VOD_HOSTS，但仍需要回调签名密钥
TRTC_RECORDING_S3_BUCKET=
TRTC_RECORDING_S3_REGION=              # 例如 ap-southeast-1
TRTC_RECORDING_S3_ACCESS_KEY=
TRTC_RECORDING_S3_SECRET_KEY=
```

默认 VOD 模式不需要 AWS S3 Bucket，但必须开通腾讯云 VOD。可切换 S3 模式：官方 `CreateCloudRecording` 的 `StorageParams.CloudStorage.Vendor=1` 直接写入 AWS S3（不是后端二次转存）。回调地址统一配置为 `https://<your-backend>/webhooks/recording/trtc`，且服务端可由公网访问；后端验签后仅接受当前房间 TaskId 的 **311（VOD）**或 **310（S3）** 完成事件。S3 模式必须验证受控前缀 `flutter_realtime_demo/trtc/<TaskId>/<filename>.mp4` 下的对象实际存在，才能开放下载。录制生成的多段 MP4 当前 V1 只导出首个回调文件，不提供自动合并。

配置 S3 Bucket 最小写入权限及后端私有读取权限，设置生命周期自动清理录像；S3 密钥只存储于服务端。注意录制本身与 S3 存储/请求/下行流量可能另外计费。

### Alibaba ARTC → VOD（默认，不依赖 AWS S3）

```dotenv
ARTC_APP_ID=
ALIBABA_CLOUD_ACCESS_KEY_ID=
ALIBABA_CLOUD_ACCESS_KEY_SECRET=

# 默认 ARTC_RECORDING_STORAGE=vod，使用阿里 Live 新版 RTC 云录制 API
ARTC_RECORDING_STORAGE=vod
ARTC_RECORDING_VOD_REGION=cn-shanghai   # 或 ap-southeast-1；us-east-1 暂不支持 VOD
ARTC_RECORDING_VOD_STORAGE_LOCATION=    # 阿里云 VOD 媒资管理 > 存储管理里的存储地址
ARTC_RECORDING_VOD_TRANSCODE_GROUP_ID=  # VOD 转码模板组（必须产生未加密的 MP4）
ARTC_RECORDING_VOD_HOSTS=               # 下载 HTTPS 域名白名单，逗号分隔，须精确匹配
```

新适配器调用官方 `@alicloud/live20161101` 的 `StartRtcCloudRecording → UpdateRtcCloudRecording（成员变化时）→ StopRtcCloudRecording → DescribeRtcCloudRecordingFiles`，取得混流录像的 `VodMediaList[].MediaIds/MergedIds` 后，通过 `@alicloud/vod20170321` 的 `GetPlayInfo` 获取未加密 MP4 播放地址，由 Demo Server 代理 HTTP 下载，**不需要 AWS S3**。VOD 本身需要开通并配置存储，可能产生录制/存储/转码/下载费用。

录制开始时订阅当前房间内在线发布者；Grid 使用宫格、固定主画面优先突出房主。服务器在已鉴权的录制状态轮询和停止之前调用 `UpdateRtcCloudRecording` 尽力同步新入会/离会的成员，并重新计算宫格；**暂未接入成员事件主动推送，不保证轮询间隔内立即更新，也不会按说话人自动切换画面**。默认导出一个已完成、未加密且位于配置域名白名单内的 MP4；如果厂商返回多个媒体分段，则报明确错误，不误把单片段当作完整录像。必须在 VOD 模板中生成 MP4。

### Alibaba ARTC 旧 OSS 模式（保留兼容，不新增 S3）

```dotenv
ARTC_RECORDING_STORAGE=oss
ARTC_RECORDING_TEMPLATE_ID=
ARTC_RECORDING_TEMPLATE_ID_GRID=       # 可选：显式指定宫格模板，覆盖上面的默认模板
ARTC_RECORDING_TEMPLATE_ID_SPEAKER=    # 可选：固定主画面模板，未配置不会开放此布局
ARTC_RECORDING_OSS_BUCKET=
ARTC_RECORDING_OSS_REGION=             # 例如 oss-cn-shanghai
ARTC_RECORDING_OSS_REGION_CODE=        # 阿里云 RTC 所需的数值地域编码
ARTC_RECORDING_OSS_ACCESS_KEY=
ARTC_RECORDING_OSS_SECRET_KEY=
```

旧模式继续使用 `@alicloud/rtc20180111` 的 `StartCloudRecord` 和 OSS；录制布局/编码由旧模板决定。默认 `ARTC_RECORDING_TEMPLATE_ID`（或显式的 `ARTC_RECORDING_TEMPLATE_ID_GRID`）应指向宫格模板；若需要固定主画面，另设 `ARTC_RECORDING_TEMPLATE_ID_SPEAKER`，未配置时 Demo 不显示该选项。该旧接口本身不支持 VOD，不能通过修改 `StorageConfig.Vendor` 实现 VOD。

### AWS Chime SDK 云录制 / MP4 云端合成

```dotenv
AWS_REGION=
CHIME_RECORDING_S3_REGION=
CHIME_RECORDING_S3_BUCKET=
# AWS 的服务端角色/环境变量凭证由标准 AWS SDK Provider Chain 提供
```

使用 `CreateMediaCapturePipeline` 开始捕获；停止时创建 `CreateMediaConcatenationPipeline` 并结束 Capture；再通过 `GetMediaPipeline` 等待合成完成。预期 S3 Key 仅使用服务端生成的前缀和该 Concatenation Pipeline ID，防止下载其他会议录像。音视频合成由 AWS 执行，不在 Demo Server 转码。需要为 Chime Media Pipelines 配置正确的 S3 Bucket Policy、IAM 权限和 `AWSServiceRoleForAmazonChimeSDKMediaPipelines` 服务关联角色。

2026-10-13 已在 Demo AWS 账号中配置并通过只读检查：Chime 录制复用 IVS 的 us-east-1 S3 Bucket；Bucket Policy 保留 IVS 原有授权，额外允许 `mediapipelines.chime.amazonaws.com` 的服务主体执行所需的 PutObject/PutObjectAcl/GetObject/ListBucket，并使用 SourceAccount/SourceArn 限制。录制调用身份 `chime-demo` 使用独立、受限的 IAM 托管策略，临时配置权限已经移除。

**IAM `s3:GetBucketPolicy`、Chime/IVS Bucket Policy、MediaConvert Role 以及验证命令，统一详见
[AWS S3 云录制权限配置](CLOUD_RECORDING.md)。**

- `H264_720P_30` → Chime `Resolution=HD`；`H264_1080P_30` → `Resolution=FHD`。Chime composited video 没有按帧率单独设置的 API，录制帧率由 AWS 服务决定。
- 目前 Chime 只在 Demo 开放 `grid` → Chime `GridView`。`ActiveSpeakerOnly` 只能在**屏幕共享发生时**影响内容布局；普通摄像头会议录制不具备固定主画面或全屏动态发言人布局。因此服务端直接拒绝这两种意图，不再提供无实际区别的第二个选项。
- **2026-10-13 使用验收：** 用户明确确认通过 **AWS Chime** 成功进行云端录制并下载录像到本地，记录为 **Chime 云录制与下载已可用（用户实测）**。尚未独立验证多种布局、不同画质、多人数/长时间录制及完整音画回放质量；不将这些细项标记为已验收。

### AWS IVS Cloud Composition + AWS MediaConvert（完全云端 MP4）

```dotenv
IVS_REALTIME_REGION=us-east-1
IVS_RECORDING_AWS_REGION=us-east-1
IVS_RECORDING_S3_BUCKET=
IVS_RECORDING_STORAGE_CONFIGURATION_ARN=
IVS_RECORDING_ENCODER_CONFIGURATION_ARN=
IVS_RECORDING_ENCODER_CONFIGURATION_ARN_1080P=   # 1080p 必须使用独立的 EncoderConfiguration
IVS_RECORDING_MEDIACONVERT_ROLE_ARN=
# IAM 权限由 AWS SDK 默认凭据链提供，密钥不放客户端
```

直播 Stage、录制所用 IVS Encoder/Storage Configuration 以及 S3 Bucket 必须位于同一区域。设置 `IVS_REALTIME_REGION=us-east-1` 时，也应将 `IVS_RECORDING_AWS_REGION` 设置为 `us-east-1` 并使用该区域的 S3 Bucket。修改区域只影响后续创建的 Stage，不会迁移已存在的直播房间。

IVS Real-Time Stage Composition 的**原生录像是 HLS**。为保持统一 MP4 下载，Demo 实现了两项 AWS 供应商托管服务的编排：`StartComposition → StopComposition`，再等待录制 S3 前缀里的 `events/recording-ended.json`，检查 `media/hls/multivariant.m3u8`，调用 **AWS MediaConvert CreateJob/GetJob** 转码为 MP4，最后验证云存储里的 MP4 并开放一次性下载。**所有媒体转码均在 AWS 云端执行；Demo Server 不跑 FFmpeg 或其他录制引擎**。

需要先在 IVS 控制台创建 EncoderConfiguration / StorageConfiguration，并为 MediaConvert 服务角色授予读取 IVS HLS 对象和写入 MP4 的 S3 权限。2026-10-13 已验证本项目 IVS StorageConfiguration 指向指定 S3，720p EncoderConfiguration 为 1280×720/30fps，并创建及配置了独立的 1920×1080/30fps EncoderConfiguration。

IVS 写入 S3 的 Bucket Policy、转码角色的 S3 权限和受限 `iam:PassRole` 见
[AWS S3 云录制权限配置](CLOUD_RECORDING.md)，不要把 IAM 用户权限与 S3 的服务主体权限混为一谈。

- `H264_720P_30` 选择标准 Encoder ARN，`H264_1080P_30` 选择 `_1080P` ARN；未配 1080p Encoder 时返回明确配置错误，不伪装成 1080p。
- `grid` 对应默认网格，`speaker` 对应 `featuredParticipantAttribute=isFeatured` 的突出显示网格；IVS 参与者 Token 由服务端根据 `role=host` 生成 `isFeatured=true`。**这是固定主持人/重点人物，不是实时语音激活切换。**
- 存储配置留空时会显示明确的 `recordingAvailable: false`。**2026-10-13 使用反馈：用户已确认 IVS 直播云录制成功，并成功下载 MP4 文件。** 按当前 Demo 实现，MP4 由 MediaConvert 云端转码生成；此次成功反馈说明整体录制、转码导出及下载路径可用，但未单独核对 AWS Job 详情。不同编码/布局、音画回放质量仍需独立 E2E 验收。IVS 产生的原始 HLS 文件不会在 MP4 下载后自动清理，建议设置 S3 生命周期过期规则。

## SDK 与 Demo 使用方式

```dart
final started = await room.startRecording(
  RecordingOptions.cloud(
    layout: RecordingLayout.grid,
    qualityPreset: RecordingQualityPreset.fullHd1080p30,
  ),
);
// 默认按厂商执行器发起录制；失败时为明确的供应商/配置错误。

await room.stopRecording(); // 可能暂时是 processing
final status = await room.queryCloudRecording();
if (status.metadata['canDownload'] == true) {
  final url = await room.cloudRecordingDownloadUrl();
  // Web、Android、iOS、macOS 和 Windows 的 Demo 都可使用 URL 下载 MP4。
}
```

`RealtimeRoom` API、权限认证和参数模型全部是 **provider-neutral**：App 不要传存储桶、Key、Secret、厂商录制任务 ID，也不允许从 Flutter 客户端覆盖服务器存储配置。

## Demo Server API、权限、导出及清理

| 方法与路径 | 说明 |
|---|---|
| `POST /rooms/:code/recording/start` | 仅房主，按供应商支持列表校验 `grid` / `featuredParticipant` / `activeSpeaker` + 720p/1080p；不可用布局返回 422，不会静默回退 |
| `POST /rooms/:code/recording/stop` | 仅房主，提交云端停止与文件封装 |
| `POST /rooms/:code/recording/status` | 仅房主，`state` + `recordingAvailable` + `recordingUnavailableReason` + `supportedLayouts` |
| `POST /rooms/:code/recording/download` | 仅房主，确认 MP4 可用后发放 **60 秒、一次有效、房间绑定**的票据 |
| `GET /rooms/:code/recording/export/:ticket` | 服务器从 S3/OSS/腾讯 VOD 流式转发真实 MP4，浏览器直接下载 |
| `POST /webhooks/recording/trtc` | TRTC 经过签名校验的 VOD 录制完成回调 |

Demo 云存储执行器在 MP4 传输**完整成功后**，尽力删除本次产生的 S3/OSS MP4 对象，避免长期占用示例 Bucket；删除失败会在服务器记录告警，不影响已经完成的下载。IVS 云端转码仍会留存原始 HLS，TRTC VOD 文件暂不由这个通用删除流程自动删除，建议配置供应商存储的自动过期规则。**正式项目需要决定更完整的留存策略和一段时间内允许重复下载的规则**。

**2026-10-13 S3 清理记录（用户已确认录像下载完毕）：** 使用 `AWS_PROFILE=chime-demo` 检查 us-east-1 的专用 Bucket `flutter-realtime-recordings-3930-20261012-b4f3`。首次 `ListObjectsV2` 仅发现一份对象 `flutter-realtime-demo/EG_PCFMf52q746f.json`（387 字节，`application/json`，录制相关元数据），**没有发现 MP4/HLS 视频文件**。已通过 `DeleteObject` 删除这份 JSON 元数据，再次 `ListObjectsV2` 返回无 `Contents`，**当前可见对象为 0**。此验证仅对应该 Bucket 中当前可列出的对象；`chime-demo` 无 `s3:GetBucketVersioning` 权限，不能据此断言不存在历史版本或删除标记，也不代表所有其他云存储桶均为空。

**单机 AWS 录制断点恢复（2026-10-13 新增）：** 可在 `demo-server/.env` 中配置：

```dotenv
DEMO_ROOM_STATE_PATH=.room-state.json
DEMO_RECORDING_STATE_DIR=.recording-state
```

这两个目录只供单机 Demo 使用（文件以 0600 权限写入，采用临时文件原子替换，并被 git 忽略）。RoomDirectory 仅保存 Chime/IVS 房间元数据与身份凭据的**哈希值**；对应录制执行器保存供应商任务 ID、处理状态和预期对象 Key。Demo 重启后可恢复未关闭的 AWS 房间，继续查询已有任务和下载结果，**不会保存 AWS Key、用户原始凭证或者已经发放的一次性下载票据**。下载票据重启后必须重新申请。请勿将此本地文件方案视为多实例/Vercel 无状态部署所需的持久化；生产环境必须使用共享数据库、任务队列并清理过期房间和任务。断点恢复对服务器意外掉电、请求中断和供应商超时仅是尽力恢复，不保证原子跨系统事务。

Bucket 或存储服务可先留空，实际测试录制之前必须开通、授予最低权限；供应商的 RTC、云录制、S3/OSS/VOD 费用另计。

## 验证

```sh
cd demo-server
npm run typecheck
npm test

cd ../packages/flutter_realtime_sdk_runtime
flutter test --no-pub test/http_cloud_recording_session_test.dart test/recording_controller_test.dart
```

单元测试使用可注入的云厂商响应和对象存储模拟，不涉及真实账号扣费。LiveKit、AWS Chime 与 AWS IVS 均已有上述用户可用性反馈；其中 **Chime 和 IVS 均已确认录制及下载可用，IVS 的 MP4 转码导出路径已由成功下载间接验证**。其他厂商以及已确认供应商的未覆盖场景，仍需分别验收 **真实用户入会 → 双人音视频 → 云端录制 → MP4 布局/声音回放 → 授权下载 → 清理**。

官方参考：[Agora Cloud Recording REST](https://docs.agora.io/en/cloud-recording/get-started/getstarted)、[LiveKit Egress](https://docs.livekit.io/home/egress/overview/)、[Amazon Chime Media Pipelines](https://docs.aws.amazon.com/chime-sdk/latest/dg/create-concat-pipe-steps.html)、[Amazon IVS Stage Composition](https://docs.aws.amazon.com/ivs/latest/RealTimeUserGuide/rt-composite-recording.html)、[阿里云 RTC Cloud Record](https://help.aliyun.com/zh/document_detail/2703647.html)。


---

## 跨厂商录制布局

### 统一语义

Flutter 应用只使用 `RecordingOptions.cloud(layout: ...)`，无需知道供应商的混流 API。

| `RecordingLayout` | 含义 | 注意 |
|---|---|---|
| `grid` | 等大的参与者画面组成宫格 | 全部六个执行器提供；人数、最大画面数依供应商限制。 |
| `featuredParticipant` | 固定突出一个参与者，其他视频可能缩小、悬浮或不显示 | **不随语音自动切换**。目前 Demo 由服务端/供应商决定主画面，未提供用户任意点名指定能力。 |
| `activeSpeaker` | 根据发言状态自动聚焦主画面 | 目前仅 LiveKit Cloud RoomComposite 的 `speaker` 模板被标记支持。其他供应商不可传此模式。 |
| `speaker` | 历史兼容值 | 服务端按当前供应商转为 `featuredParticipant` 或 `activeSpeaker`，不能保证跨厂商语义一致；新接入不要使用。 |
| `screenShare` / `custom` | 预留能力 | Demo Server V1 不接受；不能仅看 Dart 枚举就认定供应商支持。 |

### 供应商实际执行映射

| 供应商/执行器 | `grid` | `featuredParticipant` | `activeSpeaker` | 录制真实验收 |
|---|---|---|---|---|
| LiveKit RoomComposite Egress | `template.layout=grid` | — | `template.layout=speaker`（录制模板跟随主要发言视频） | ✅ 已确认云录制可用；需实测多人切换 |
| Agora Cloud Recording | `mixedVideoLayout=1` 自适应网格 | `mixedVideoLayout=0` 悬浮画面；主画面由 Agora 排列规则决定 | — | ❌ Agora `acquire` 401，未验收 |
| Tencent TRTC | `MixLayoutMode=3` 九宫格 | `MixLayoutMode=1` 悬浮画面，通常突出最先进入的发布者 | — | ⏳ 待真实验收 |
| Alibaba ARTC VOD | 静态参与者宫格 | 录制开始时优先选择房主为固定大画面 | — | ⏳ 待真实验收 |
| Alibaba ARTC OSS（旧模式） | 由 `ARTC_RECORDING_TEMPLATE_ID_GRID` 或旧的 `ARTC_RECORDING_TEMPLATE_ID` 预配置 | **仅**配置 `ARTC_RECORDING_TEMPLATE_ID_SPEAKER` 才开放，实际画面取决于模板 | — | ⏳ 待真实验收 |
| AWS Chime Media Pipelines | `GridView` | — | — | ✅ 已确认录制/下载可用；布局仍待实测 |
| AWS IVS Real-Time | `{grid:{}}` | `{grid:{featuredParticipantAttribute:'isFeatured'}}`，固定突出 Token 中标记的主持人 | — | ✅ 已确认录制/下载可用；布局仍待实测 |

**为什么 Chime 只有宫格？** AWS Chime `CompositedVideo` 当前只支持 `GridView` 作为摄像头布局。`ActiveSpeakerOnly` / `PresenterOnly` 是 **有屏幕共享时的内容共享覆盖层**，不能实现普通摄像头会议的全屏自动主讲人。Demo 拒绝伪装支持，不再将两种选择录成相同画面。未来若需要此能力，必须引入独立的云端合成方案并评估额外成本，而不是仅修改配置参数。

**为什么 IVS 不能自动切人？** IVS 的 `isFeatured` 是参与者令牌属性。可以借助 token exchange 更换此属性，但目前没有经过鉴权、节流与真实语音活动事件驱动的切人流程，故只提供固定主画面。

### 能力查询、权限与出错行为

通过现有仅房主可调用的接口查询支持模式：

`POST /rooms/:code/recording/status`，请求正文带当前房间管理凭据，返回示例：

```json
{
  "state": "idle",
  "provider": "chime",
  "recordingAvailable": true,
  "supportedLayouts": ["grid"],
  "canDownload": false
}
```

`recordingAvailable` 代表凭据、云存储等配置预检；即使为 `false` 也返回受支持的布局，供 UI 显示。它不承诺真实录制一定成功。Flutter `room.queryCloudRecording()` 在 `RecordingResult.metadata['supportedLayouts']` 获得名单。Demo 的两个入口统一调用 `demo_recording_layout_picker.dart`，按此名单生成选择器；旧服务端没返回名单时仅展示最保守的宫格。

`POST /rooms/:code/recording/start` 支持以下布局值：

```json
{"layout":"grid","containerFormat":"mp4","streamType":"both","rawProviderParams":{"preset":"H264_720P_30"}}
```

把 `layout` 换成 `featuredParticipant` / `activeSpeaker` 会先检查对应供应商是否支持，**不支持返回 HTTP 422 `unsupported-recording-layout`**，不会自动退化为宫格，不会触发云录制扣费。旧值 `speaker` 仅作兼容性映射。未认证房主返回 403，非法值返回 400。录制存储凭据和任务 ID 仍由服务器持有，前端不得传入密钥或任意存储配置。

```dart
final status = await room.queryCloudRecording();
final names = (status.metadata['supportedLayouts'] as List?)
        ?.whereType<String>().toSet() ?? {'grid'};
if (names.contains(RecordingLayout.featuredParticipant.name)) {
  await room.startRecording(RecordingOptions.cloud(
    layout: RecordingLayout.featuredParticipant,
  ));
} else {
  await room.startRecording(RecordingOptions.cloud(
    layout: RecordingLayout.grid,
  ));
}
```

### 质量、入会变化与已知限制

* 主流执行器接收 `H264_720P_30` / `H264_1080P_30` 两种预设；TRTC 与 ARTC VOD 的请求已按所选预设映射宽高、帧率和编码码率。实际帧率与图像质量仍取决于上行轨道、供应商限制与模板。ARTC 旧 OSS 模式由模板控制画质，并非动态响应本参数。
* **ARTC VOD** 录制开始时订阅在线发布者；服务端在房主发起的 `recording/status` 轮询或 `recording/stop` 前，会比较最新房间成员并调用厂商 `UpdateRtcCloudRecording` 重算订阅与画面。**这是轮询驱动的尽力同步**，不保证无人轮询时及时加入新成员；正式教学课堂仍建议由入会/离会事件主动触发，且验证录制服务端与 SDK 用户 ID 的一致性。固定主画面保持初始主讲人，离开后选择下一位在线发布者，不会自动跟随发言人。
* **ARTC OSS 旧模式** 的默认录制模板必须由部署者保证为宫格。若要固定主画面，请分别配置、验证两个模板 ID；传入额外 ID 不会使模板自动拥有对应效果。
* **Agora / TRTC** 固定主画面目前使用供应商默认的悬浮布局选择规则，不支持由 Demo 任意指定某个人，也不检测谁在发言。
* **AWS IVS** 的主画面在主持人发布视频且 `isFeatured` 标记可用时有效；主持人不在场时不会伪装存在主画面。
* **LiveKit** 的 `activeSpeaker` 属于录制视图模板提供的布局行为；应当用至少三名发布者交替发言、屏幕共享、静音、退出再加入进行真实 MP4 回放验收。
* 新布局模式属于**录制内容**，并不修改 Demo 会议实时视图。停止、MP4 转码、下载票据及云存储清理流程保持现有实现。


---

## AWS S3、IVS 和 MediaConvert 权限

### 2. 三种权限不要混淆

| 位置 / 身份 | 所需权限 | 作用 |
| --- | --- | --- |
| `chime-demo` 的 IAM 身份策略 | `s3:GetBucketPolicy`，Resource 为指定 **Bucket ARN**（无 `/*`） | Chime 创建管线前读取、检查 Bucket Policy；**这是之前出现 AccessDenied 的权限** |
| `chime-demo` 的 IAM 身份策略 | `chime:CreateMediaCapturePipeline`、`CreateMediaConcatenationPipeline`、`DeleteMediaCapturePipeline`、`GetMediaPipeline` | 启停和查询 Chime 录制管线 |
| S3 Bucket **资源策略** | 授予 `mediapipelines.chime.amazonaws.com` 写入、读取对象及列出 Bucket | **由 Chime 服务**向 Bucket 上传捕获文件、读取源片段并写入合成结果 |
| S3 Bucket **资源策略** | 授予 `ivs-composite.<region>.amazonaws.com` `PutObject` / `PutObjectAcl` | **由 IVS 服务**上传 HLS |
| `chime-demo` 的 IAM 身份策略 | `ivs:StartComposition`、`GetComposition`、`StopComposition`、`mediaconvert:CreateJob` / `GetJob`、指定角色的 `iam:PassRole` | 启停 IVS，调度云端 MP4 转码 |
| `FlutterRealtimeDemoMediaConvertRole` | S3 输入 `GetObject`、输出 `PutObject` / `AbortMultipartUpload`、`ListBucket` / `GetBucketLocation` | **由 MediaConvert 服务**读取 HLS 并上传 MP4 |
| `chime-demo` 的 IAM 身份策略 | S3 `GetObject`、`ListBucket`、限前缀 `DeleteObject` | 后端核对 MP4、流式下载并清理导出文件 |

**关键区别：** `s3:GetBucketPolicy` 是授予 API 调用者 `chime-demo` 的
**IAM 身份权限**；`s3:PutObject` 是通过 Bucket Policy 授予
Chime / IVS 服务主体的**资源权限**。仅设置其中一个不能替代另一个。
正常运行不需要给 `chime-demo` 开放 `s3:*`、`iam:*` 或
`AdministratorAccess`。

### 3. Chime 调用身份策略（包含 s3:GetBucketPolicy）

现有账号为 `chime-demo` 附加 IAM **托管策略**
`FlutterRealtimeDemoChimeRecordingRuntime`。关键语句示例：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ChimeCaptureAndConcatenate",
      "Effect": "Allow",
      "Action": [
        "chime:CreateMediaCapturePipeline",
        "chime:CreateMediaConcatenationPipeline",
        "chime:DeleteMediaCapturePipeline",
        "chime:GetMediaPipeline",
        "chime:ListMediaCapturePipelines"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadRecordingBucketPolicy",
      "Effect": "Allow",
      "Action": "s3:GetBucketPolicy",
      "Resource": "arn:aws:s3:::<BUCKET>"
    }
  ]
}
```

这是**关键权限示例**，不是现有托管策略的逐字导出；实际部署策略还有诊断查询权限与条件约束。
Chime 部分 `Create*` 操作需要在 IAM 适用的资源范围上授权，
其他权限应按服务支持情况进一步约束。管理策略时应**增量修改已有策略**，
不要用这段示例覆盖原策略，否则可能移除 IVS、读写或诊断权限。

若提示 Chime Service-Linked Role 不存在，由授权的 **IAM 管理员**执行一次：

```bash
aws iam create-service-linked-role \
  --aws-service-name mediapipelines.chime.amazonaws.com \
  --profile <IAM_ADMIN_PROFILE>
```

已有角色无需重复创建，也不应通过向 `chime-demo` 授予 `iam:*` 绕过。

### 4. S3 Bucket Policy：同时保留 Chime 与 IVS

在 S3 → 目标 Bucket → **Permissions → Bucket policy** 编辑。
以下是与当前项目匹配的**结构示例**，在原策略上合并对应 Statement；
切勿直接覆盖已有声明（尤其是 IVS StorageConfiguration 自动创建的授权）。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowIVSCompositeWrite",
      "Effect": "Allow",
      "Principal": {
        "Service": "ivs-composite.us-east-1.amazonaws.com"
      },
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": "arn:aws:s3:::<BUCKET>/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control"
        },
        "Bool": {
          "aws:SecureTransport": "true"
        }
      }
    },
    {
      "Sid": "AllowChimeBucketListing",
      "Effect": "Allow",
      "Principal": {
        "Service": "mediapipelines.chime.amazonaws.com"
      },
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<BUCKET>",
      "Condition": {
        "StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"},
        "ArnLike": {
          "aws:SourceArn": "arn:aws:chime:us-east-1:<ACCOUNT_ID>:*"
        }
      }
    },
    {
      "Sid": "AllowChimeCaptureAndConcatObjects",
      "Effect": "Allow",
      "Principal": {
        "Service": "mediapipelines.chime.amazonaws.com"
      },
      "Action": ["s3:PutObject", "s3:PutObjectAcl", "s3:GetObject"],
      "Resource": "arn:aws:s3:::<BUCKET>/*",
      "Condition": {
        "StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"},
        "ArnLike": {
          "aws:SourceArn": "arn:aws:chime:us-east-1:<ACCOUNT_ID>:*"
        }
      }
    }
  ]
}
```

**ARN 差异：** `s3:ListBucket` 使用 `arn:aws:s3:::<BUCKET>`，
`GetObject` / `PutObject` / `PutObjectAcl` 使用
`arn:aws:s3:::<BUCKET>/*`。Chime 合成读取捕获文件，因此不能只保留
`PutObject`；IVS 的 `s3:x-amz-acl=bucket-owner-full-control` 条件也不能随意删除。
仅在 AWS 官方支持的区域和服务主体上使用对应前缀。

**注意：** Bucket Policy 更新必须由拥有 `s3:PutBucketPolicy` 的授权管理员执行，
不要给日常 Demo 账户长期保留该权限。此项目完成配置后已撤销临时授权。
若使用 SSE-KMS（客户管理的 KMS Key），还需要分别为相关服务授予
`kms:GenerateDataKey`，合成读取可能还需 `kms:Decrypt`；不能只修改 S3。

### 5. IVS 与 MediaConvert IAM 权限

现有 `FlutterRealtimeDemoIvsRecordingPolicy` 包含这些动作：

- `ivs:StartComposition`、`ivs:GetComposition`、`ivs:StopComposition`
  （限制实际使用区域）
- `mediaconvert:CreateJob`、`mediaconvert:GetJob`
- `iam:PassRole` **只针对**
  `arn:aws:iam::<ACCOUNT_ID>:role/FlutterRealtimeDemoMediaConvertRole`，
  并限制 `iam:PassedToService=mediaconvert.amazonaws.com`
- 对录制 Bucket 的 `s3:GetObject`、`s3:GetBucketLocation`、
  `s3:ListBucket`，以及对 `flutter-realtime-demo/*` 导出前缀的
  `s3:DeleteObject`（录制完成下载后清理）

MediaConvert 服务角色的信任策略必须允许：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "mediaconvert.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
```

其 S3 权限应分开授予：录制 Bucket 内 HLS 文件
`s3:GetObject`，`flutter-realtime-demo/*` MP4 目标前缀
`s3:PutObject`、`s3:AbortMultipartUpload`，以及 Bucket 元信息
`s3:ListBucket`、`s3:GetBucketLocation`。IVS 上传与转码上传的服务主体不同，
不要直接让 `chime-demo` 的客户端凭证代替 MediaConvert 服务角色。

### 6. 只读验证命令（不会创建录制任务）

以下命令从本仓库运行，用 **`chime-demo`** 验证已配置资源。
输出 ARN/策略内容可能包含账号与资源名称，请勿把完整输出贴到公开讨论区。

```bash
export AWS_PROFILE=chime-demo
export AWS_REGION=us-east-1
export RECORDING_BUCKET="<BUCKET>"
export IVS_STORAGE_ARN="<STORAGE_CONFIGURATION_ARN>"
export IVS_ENCODER_720P_ARN="<720P_ENCODER_ARN>"
export IVS_ENCODER_1080P_ARN="<1080P_ENCODER_ARN>"

# IAM 用户凭证是否有效，Bucket 是否存在
aws sts get-caller-identity
aws s3api head-bucket --bucket "$RECORDING_BUCKET" --region "$AWS_REGION"

# 检查 chime-demo 是否有 s3:GetBucketPolicy；这里不涉及写入权限
aws s3api get-bucket-policy \
  --bucket "$RECORDING_BUCKET" --region "$AWS_REGION" \
  --query Policy --output text

# Chime 管线只读列表（新账号为空数组也表示接口权限正常）
aws chime-sdk-media-pipelines list-media-capture-pipelines --region "$AWS_REGION"

# IVS 的现有 Storage / Encoder 对象是否可读取
aws ivs-realtime get-storage-configuration \
  --arn "$IVS_STORAGE_ARN" --region "$AWS_REGION"
aws ivs-realtime get-encoder-configuration \
  --arn "$IVS_ENCODER_720P_ARN" --region "$AWS_REGION"
aws ivs-realtime get-encoder-configuration \
  --arn "$IVS_ENCODER_1080P_ARN" --region "$AWS_REGION"

# MediaConvert API 只读查询
aws mediaconvert list-jobs --region "$AWS_REGION"
```

进一步检查 IAM 策略是否已**附加到用户**，应使用有权限的 IAM
管理员身份查看 `chime-demo` 的 Attached/Inline Policies；
`chime-demo` 本身没有 `iam:List*` / `iam:Get*` 权限，这是预期的最小授权。

### 7. 常见报错与排查

| 现象 | 排查位置 |
| --- | --- |
| `s3:GetBucketPolicy AccessDenied` | `chime-demo` 的 **IAM 身份策略**，Action 为 `s3:GetBucketPolicy`，Resource 是 Bucket ARN；再检查 Permission Boundary、SCP、显式 Deny |
| Chime `CreateMediaCapturePipeline AccessDenied` | Chime Media Pipelines API 权限、对应 Region、Service-Linked Role |
| Chime 录制已开始但 S3 没有文件 | Bucket Policy 的 Chime 服务主体、`PutObject` / `PutObjectAcl`、区域与 SourceAccount/SourceArn、加密配置 |
| Chime 合成失败 / MP4 不生成 | Bucket Policy 的 `GetObject` + `ListBucket`、Concat Pipeline 状态、捕获对象是否存在 |
| IVS `StartComposition` 失败 / 无 HLS | IVS StorageConfiguration 是否指向本 Bucket，以及 IVS 服务主体 `PutObject` / `PutObjectAcl` 条件 |
| MediaConvert `AccessDenied` / `PassRole` 失败 | 调用用户的 `mediaconvert:CreateJob` 与 `iam:PassRole`；MediaConvert 角色的信任策略与 S3 输入/输出权限 |
| 已生成 MP4，但 Demo 下载失败 | `chime-demo` 对对象 `s3:GetObject` / `HeadObject` 的权限、MP4 Key、处理完成状态与 60 秒单次下载票据 |

**2026-10-13 存储清理验证：** 用户确认已下载录制文件后，使用 `chime-demo` 查询专用 Bucket `flutter-realtime-recordings-3930-20261012-b4f3`：仅有 `flutter-realtime-demo/EG_PCFMf52q746f.json`（387 字节的元数据），未列出 MP4/HLS。已删除此对象；随后 `ListObjectsV2` 无 `Contents`，当前可见对象数量为 0。Bucket 已配置短期对象过期规则，但不依赖生命周期任务来验证本次清理。由于缺少 `s3:GetBucketVersioning` 权限，**不声称历史版本也已经清理**。

**验收边界：** Chime 和 IVS 均已获用户确认录制与下载可用；按 Demo 实现，IVS 下载 MP4 前需要经过 MediaConvert，因此其录制/导出/下载主路径已得到用户实测反馈。两者的多人数、不同布局/画质及完整音画回放质量仍待进一步验收；如需更严格确认，可另外检查 IVS
`MediaConvert Job 完成状态 → MP4 文件内容 → S3 临时文件清理`。
真实录制与转码会产生费用。

AWS 官方文档：
[Chime 创建媒体管线的前置条件](https://docs.aws.amazon.com/chime-sdk/latest/dg/create-pipeline.html)、
[Chime Capture S3 Policy](https://docs.aws.amazon.com/chime-sdk/latest/dg/create-s3-bucket.html)、
[Chime Concatenation S3 Policy](https://docs.aws.amazon.com/chime-sdk/latest/dg/create-concat-pipe-steps.html)、
[IVS Composite Recording Bucket Policy](https://docs.aws.amazon.com/ivs/latest/RealTimeUserGuide/rt-composite-recording.html)、
[MediaConvert IAM Service Role](https://docs.aws.amazon.com/mediaconvert/latest/ug/iam-role.html)。
