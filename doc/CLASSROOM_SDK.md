# Classroom SDK V1 (Meeting)

## SDK-first boundary

The independent packages are:

- flutter_realtime_classroom_core: teacher/student roles, question state,
  raised hands, speaking grants, stats, notifications, state repository and
  optional revision transport.
- flutter_realtime_classroom_ui: teacher/student panels and an optional
  floating classroom entry point.
- flutter_realtime_classroom_preset: explicit, opt-in `ClassroomPreset` backed
  by the existing `ClassroomSession` and reference HTTP repository. It owns
  the previously SDK-owned whiteboard, shared-content and annotation adapters.
- flutter_realtime_sdk_runtime: **does not import Classroom Core**. Its generic
  Feature Registry attaches only the business plugins selected by the host.

The Demo explicitly registers `ClassroomPreset` and displays the standard SDK
meeting page. It contains no duplicate classroom
business logic; hosts may omit the preset and use a plain meeting.

## Built-in classroom workspace sidebar

`RealtimeMeetingPage` uses `RealtimeClassroomSidePanel` with stable
`RealtimeWorkspaceTab` identities (Chat, People, Classroom, Recording and
optional Notes). The Classroom tab shows a real-time overview backed by
`ClassroomState`, plus teacher-only hand requests, Q&A and provider-backed
poll/quiz activities. Student-facing controls honor the classroom capabilities.
The existing standalone `RealtimeClassroomPanel` remains available for
applications that assemble their own UI.

`RealtimeClassroomNotesPanel` is shown automatically **only for an authenticated
teacher** whose backend sends the `notes` collection in `ClassroomState`.
It supports adding, editing and deleting teacher notes and placing manual
chapter markers on the **room-creation time axis**. All changes go through
`ClassroomSession.addNote/updateNote/deleteNote` and authenticated HTTP
classroom actions; SDK consumers never need Demo-specific room methods.
`RealtimeMeetingPage(classroomNotesPanel: myNotesWidget)` can override this
view with a host-owned implementation, which must enforce its own access rules.
Older backends lacking the `notes` field do not show a broken tab.

The **Copy lesson minutes** action builds a Markdown document from the real
teacher notes, actual classroom questions/answers, and published poll/quiz
activity counts, and copies it to the clipboard. It is a manually exported
record, not an AI-generated summary or a cloud history service. Chapter
markers are not mapped onto recording playback yet: provider capture can
start after the room.

The recording sidebar now supports **Add lesson chapter** when the teacher's
classroom snapshot exposes the notes capability. Saving the chapter calls the
same authenticated `ClassroomSession.addNote(chapter: true)` API as the Notes
tab; a subscription to `classroom.states` refreshes the chapter list live,
independently of the cloud recorder's status stream. Markers are room-relative
and **are not seek links to a recording**.

Teachers can also create real classroom polls and quizzes from the Classroom
Activities tab. The form validates 2–8 distinct options (and one correct quiz
answer) and submits via `RealtimeRoomUiController.publishClassroomActivity`
to `ClassroomSession.publishActivity`. Students cannot access this control.
Student submissions, close actions, and totals remain backed by the existing
classroom-tool commands. The backend currently keeps interactive classroom
tools in room session state; exporting lesson minutes is not a permanent
archive.

The reference backend optionally persists notes with `CLASSROOM_STATE_DIR`
using a single-node file store and restricted file permissions. Without that
configuration, notes live only in the server process. Even with it configured,
**closing a room deletes classroom state**. Always export the minutes before
closing. This is not a production multi-instance or permanent archive; long-term
post-class retrieval requires a separate persistent database / archive API.
Teacher notes are never included in student snapshots.

Transcripts, automatic subtitles, AI summaries, recording seek links and cloud
quota are not generated or simulated by the SDK. The Recording tab uses the
real `RealtimeRecordingPanel` only when the recorder is configured and the
current user has the recording-management role.

The desktop sidebar is 340pt wide and mobile/tablet presentations use a right
drawer. The side panel does not own duplicate classroom state or provider RTC
logic; actions route through `RealtimeRoomUiController`.

Typed headless example:

~~~dart
final classroom = room.classroom;
// Check classroom.state?.notes != null and isTeacher before editing.
await classroom?.addNote('Review factoring before the next lesson');
await classroom?.addNote('Completing the square', chapter: true);
// Room-relative elapsed seconds are supplied by the backend.
~~~

## Raise-hand flow in the Demo

The meeting dock provides a dedicated `RealtimeDockRaiseHandButton` for
students. It reflects authoritative classroom state, toggles
`ClassroomSession.raiseHand/lowerHand`, blocks duplicate requests while
pending and displays failed requests. The reactions sheet can still offer
the same action, but is not the only way to raise a hand.

For teachers, `RealtimeDockHandQueueButton` displays the current number of
raised hands. Its host callback opens `RealtimeClassroomPanel(initialTab: 1)`
on the hand queue, where the teacher can allow or revoke speaking. Both
widgets are independent: an application may put either one in another toolbar
or use only its own headless UI.

The reference backend authenticates student requests and teacher grants.
Teachers receive classroom change notifications and a visible queue counter.
On approval, the server asks the RTC provider to update microphone publishing
permission where supported, then publishes the new classroom revision. The
student receives a speaking-granted notification and **must turn on their
microphone manually**; approving a request does not silently unmute anyone.
The same flow supports both LiveKit and other providers through the classroom
API; permission enforcement remains provider-dependent.

Manual two-client check: join the same Meeting as teacher and student; raise,
cancel, raise again, grant, enable the student microphone, and revoke. Verify
the queue badge, participant notification, microphone gating and error
feedback, including on a narrow mobile layout. Component tests cover the
direct controls; a real RTC end-to-end permission check still needs devices.

## Usage

Create or join a Meeting using `Realtime` with an explicitly selected
`ClassroomPreset`; import its optional package to access the extension getter.
Then use the SDK's ClassroomSession:

~~~dart
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';

final realtime = Realtime(
  providers: myProviders,
  backendUrl: backendUrl,
  featurePlugins: const [ClassroomPreset()],
);
final connection = await realtime.open(request);
final room = connection.mediaRoom!;
final classroom = room.classroom;
if (classroom != null) {
  await classroom.start();
  final subscription = classroom.states.listen((state) {
    print(state.stats.handsRaised);
    print(state.capabilities.canGrantSpeak);
  });
  final eventSubscription = classroom.events.listen((event) {
    // Typed hand, question, speaking-permission and presence transitions.
    print(event.kind);
  });
  // Students:
  await classroom.raiseHand();
  await classroom.askQuestion('Can you explain this?');
  if (classroom.state!.capabilities.canSendFeedback) {
    await classroom.sendFeedback(ClassroomFeedbackKind.question);
  }
  // Teachers (verified by backend room owner credential):
  // await classroom.grantSpeak(studentId);
  // await classroom.answerQuestion(questionId, 'Sure.');
  // await classroom.resolveQuestion(questionId);
  // Cancel both subscriptions on UI disposal.
}
~~~

Developers may supply their own ClassroomRepository and ClassroomRevisionTransport
to ClassroomSession if their backend does not use the reference HTTP contract.
For direct provider rooms, set `ClassroomPreset(enableForDirectRooms: true,
repositoryFactory: (context) => myRepository)`; no Demo-specific code or
mandatory example backend is required.

## Reference control-plane protocol

For a backend Meeting room with a participant credential, SDK attaches:

- POST /rooms/:code/classroom/snapshot
- POST /rooms/:code/classroom/action

Every request includes requesterParticipantId + participantCredential. Teacher
privileges require a valid roomOwnerCredential. Action identifiers:
hand.raise, hand.lower, speak.grant, speak.revoke, question.ask,
question.answer, question.resolve, feedback.send. User or question ids and text are supplied
as appropriate. The response is the full ClassroomState, with increasing
revision, selfUserId, students (including offline users and logical roles),
questions, and stats. Unknown actions and
unauthorized mutations are rejected, rather than applied optimistically.
Mutating requests use per-action eventId keys. The reference backend limits
question bursts (three submissions per student per 30 seconds), rejects
reused eventIds with conflicting payloads, and bounds room question history.
Raise-hand queue ordering uses a persistent monotonically increasing sequence
instead of wall-clock milliseconds. Stats distinguish active hands and pending
questions from cumulative raises, all submitted questions and speaking grants.
The chatMessages field remains local to the connected ChatSession (not a
server-wide, historic class chat count).

Quick feedback uses `kind` (`understood`, `great`, `idea`, `question`, `clap`).
The server supplies sender identity, display name, ID and timestamp from the
authenticated participant. Teachers can read all recent feedback; student
snapshots contain only their own responses. The room retains its latest 200
responses and limits each student to five submissions per ten seconds.
Feedback is available by default without a UI toggle or setup action.
Missing `feedbackSupported` preserves that default, including older snapshot
shapes. Repositories can explicitly return `feedbackSupported: false` when
they cannot implement feedback; the UI then reports unsupported service rather
than implying that someone needs to enable a setting. An older server still
needs the `feedback.send` action implementation before it can accept responses.
The optional classroom UI confirms sending only after backend acceptance,
shows teachers a short-lived bubble and unread badge, and retains a Feedback
tab with sender, type, time and counts for the retained window. Notifications
are derived from trusted snapshots and do not replay history on initial join.
Existing revision hints refresh the receiver promptly; polling remains the
fallback when hints are unavailable. Update the reference backend alongside
the client to enable this contract. Optional classroom persistence also stores
feedback and its rate-limit state.

By default the reference backend keeps its classroom state in memory.
Set CLASSROOM_STATE_DIR to enable an optional single-host FileClassroomStore:
it writes atomic JSON snapshots under restrictive file permissions and
restores revisions, raised hands, Q&A, participant-bound grants, rate-limit state and event IDs
when the same room identity (provider + roomCode + createdAt) is reconstructed.
A grant is restored only when its saved participant binding matches the current
media participant. Legacy snapshots without that binding lose their grants.
The file is deleted when the room is cleanly closed. Room registry and provider
sessions are still ephemeral: this does **not** restore a closed/media room,
implement cross-process locks or make a multi-instance deployment production
ready. For HA deployments, implement ClassroomStore with a shared,
transactionally updated database/Redis design along with durable room identity
restoration; the Demo itself remains a reference server only.

## Realtime update strategy

Both product Chat and RTC Data carry **only versioned, room-scoped
revision notifications** (v, type, roomCode, revision, eventId, timestampMs).
Product IM sessions in Agora Chat, Tencent Chat and Amazon IVS Chat use an
optional ChatSystemMessaging contract. The adapters filter reserved system
frames from user-facing ChatSession.messages, messageSnapshots and events.
Normal user messages beginning with a reserved system/text prefix are escaped
and restored as user text. Only structurally valid versioned revision envelopes
are routed to system hints; malformed reserved text remains visible in Chat.
Automatic reads from hints and polling share one in-flight snapshot and a
one-second minimum interval. Bursts queue at most one trailing read; explicit
refreshes bypass the cooldown and action responses apply immediately.
The reserved frames are plain-text messages at the vendor transport level;
non-SDK clients should not render them as normal chat. If the selected
ChatSession cannot send system frames, RTC Data is selected instead.
Messages with the wrong room/version or expired timestamps are dropped.
They are untrusted invalidation hints, never teacher commands or state payloads.
On a higher revision, ClassroomSession reads the authoritative state from its
repository. A polling fallback (default 2 seconds) works when the current
provider cannot send IM/RTC Data or when notifications are missed. Product Chat
remains a separate ChatSession: SDK-facing user chat messages never contain
the classroom control envelope.

## V1 scope and limitations

- Raising/lowering a hand, teacher approving/revoking a speaking request,
  Q&A replies/resolution, roster, reminders and live statistics work via the
  SDK. All teacher mutations are authorized at the control plane.
- Speaking grant enforcement depends on the media provider. **LiveKit Meeting**
  issues unapproved students a token without the microphone publish source,
  then uses authenticated RoomService UpdateParticipant to add/remove the
  microphone source while preserving camera and screen-share permissions.
  On remote update errors, the trusted classroom state is left unchanged.
  Other providers currently expose **advisory** grants (SDK UI gate only).
  Read state.capabilities.enforcesMicrophone rather than checking the provider
  name. Real LiveKit service interoperability and reconnection/token-rotation
  behavior still require authenticated two-device acceptance tests.
- A new participant ID (a fresh backend join) resets the student's speaking
  grant and raised hand. The previous LiveKit participant's microphone permission
  is revoked before replacement, including identities remembered after reference
  heartbeat pruning; failures reject the join and leave the old
  credential usable for retry. An already absent provider participant counts as
  revoked. A successful revocation remains reflected in classroom state even if
  the subsequent new join fails. Same-participant media network reconnections
  keep their grant. Q&A and attendance history are retained.
- The reference server serializes permissions, classroom snapshots and membership
  lifecycle changes per room, revalidating credentials and targets inside the
  queue. Provider failures release the queue; unrelated rooms proceed independently.
  LiveKit control requests abort after ten seconds. This in-process queue does not
  provide cross-instance locking; production hosts must bind join identities to
  authenticated users and use shared transactional coordination where applicable.
- Student microphone and camera flags are shown only if a media participant
  snapshot reports them. Otherwise the UI says unknown.
- Chat uses the existing ChatSession and its normal unread UI. The classroom
  stats chatMessages field is a local session count, not a server-wide total.
- SDK panels follow the host MaterialApp locale (English or zh); teacher views
  support student search and Q&A search/status filters. The backend retains
  offline roster entries in the room lifecycle. Question pagination, cloud
  persistence, robust server-wide
  message analytics, and real multi-device provider acceptance tests remain
  follow-up work.
- The class only appears for backend-provisioned Meeting rooms. Live rooms and
  direct-credential integrations are unaffected.

## Test commands

~~~sh
cd demo-server && npm test && npm run typecheck
cd ../packages/flutter_realtime_classroom_core && flutter test
cd ../flutter_realtime_classroom_ui && flutter test
cd ../flutter_realtime_sdk_runtime && flutter analyze
cd ../../example && flutter analyze && flutter build web
~~~

## Classroom tools extension

The existing `ClassroomRepository.action(String, data: Map<String,String>)`
contract is unchanged. Extended actions use `tool.*` names and a JSON string
`payload`. A snapshot with no `tools` field remains V1-compatible: its tools
capability is false and the SDK hides the teaching-tools tab.

`ClassroomState.tools` provides immutable notices, homework, materials, timer,
activities and annotation canvas; `ClassroomState.attendance` holds session
presence records. These methods belong to `ClassroomSession`:

```dart
await classroom.publishAnnouncement('Today: fractions');
await classroom.remindFocus('Please focus on the shared screen');
await classroom.publishHomework(title: 'Practice', instructions: 'Solve 1–5');
await classroom.shareMaterial(title: 'Slides', url: 'https://your-app/slides.pdf');
await classroom.startTimer(title: 'Practice', duration: Duration(minutes: 5));
await classroom.publishActivity(
  kind: ClassroomActivityKind.quiz,
  title: '2 + 2 = ?', options: ['3', '4'], correctOption: 1,
);
// Students: await classroom.answerActivity(activityId, 1);
// Teachers: await classroom.closeActivity(activityId);
```

Teachers publish announcements, focus reminders, homework, materials, timers,
Quiz/Poll and annotations. Student activity submissions use the authenticated
logical user identity. Options are single choice (2–8 distinct options); a
student's new answer replaces their previous answer until the teacher closes
the activity. Active Quiz snapshots sent to students omit the correct option,
result counts and individual answers. After close they expose aggregate counts
and the correct option; only teachers receive individual answer mappings.
Poll has no correct-answer field. The Quiz form derives its answer selector
from the entered nonempty options. Removing the selected answer requires a new
selection; invalid options and backend errors retain the form and its input.
Homework is publication/viewing only.

Timers use a server-issued absolute deadline and clamp at zero. Notices appear
in the tools panel and student announcement/focus notifications also appear as
a snackbar. Presence is derived from the reference room directory, leave and
heartbeat expiry; it is not biometric verification or a formal absence record.
Attendance reports first join, last join/leave and accumulated online duration.
Students see only their own attendance; teachers see student records. Stats
separate online participants, online students and students seen this session.
`chatMessages` is explicitly labelled as this device's cached messages.

### Composable meeting notifications and shared countdown

The optional `flutter_realtime_sdk_ui` package exposes
`RealtimeClassroomEventOverlay`. Place it anywhere inside the host's meeting
stage `Stack`, independently of the tools/participants/chat panels:

```dart
Stack(
  children: [
    const RealtimeVideoGrid(),
    if (room.classroom != null)
      Positioned(
        top: 8,
        left: 12,
        right: 12,
        child: RealtimeClassroomEventOverlay(classroom: room.classroom!),
      ),
  ],
)
```

The overlay subscribes to the existing authoritative `ClassroomSession.events`
and `.notifications` streams and renders short-lived named-action bubbles for
hands, speaking grants, questions and classroom tool publications. It never
replays old notifications on initial join, but renders any currently active
timer immediately from the initial snapshot. Multiple bubbles stack briefly
without blocking touches behind the overlay. It does not depend on the legacy
`ClassroomControlButton` and can be used with independently placed panels.

Teachers can open the existing `RealtimeClassroomToolsButton` (which displays
`ClassroomToolsPanel`) for announcements, homework, and start/stop timer. The
composable Meeting Demo uses both components. No new transport or cloud service
is required: trusted HTTP classroom state and revision hints synchronize remote
participants, with the existing polling fallback. The countdown is computed
locally from the server-provided absolute deadline: client clock skew and hint
delivery delay may affect second-level alignment, so this is not a guaranteed
high-precision synchronized clock. Homework remains publication/viewing only.

The SDK overlay shows recent transient events; historical notices and homework
are available in `ClassroomToolsPanel`. A durable, searchable audit trail of
every speaking/hand action is not part of the current backend contract.

Materials accept HTTP(S) links and open via the host platform's URL launcher.
There is no file picker, storage service, upload endpoint or document preview
engine in the Demo. Hosts can implement `ClassroomMaterialUploader` and call
`uploadMaterial` to upload through their own infrastructure before sharing its
returned link. Opening a material link is a user action, not a background fetch.

The reference bounds notices/homework/materials to 100 retained entries each
and activities to 100 per room. This extension remains in memory even when the
legacy optional `CLASSROOM_STATE_DIR` store is enabled. No new persistence,
payment or recording service is introduced.

## Infinite whiteboard viewport

The whiteboard uses one shared **1600 × 900 logical scene**, rather than fitting
a small 16:9 rectangle inside a phone. The viewport fills the available stage.
Single-touch drawing and two-finger pinch/drag coexist; the mobile hand tool
enables one-finger panning, and **Reset whiteboard view** recenters the scene.
Each user's pan and zoom matrix is local, while stroke points are stored in
shared scene coordinates and can extend outside the original `[0,1]` page.
The demo control plane bounds finite whiteboard coordinates to ±1000 for
request safety, independently of the viewport. Screen annotations still use
the original 0–1 normalized content rectangle and are **not** unbounded.

## Screen annotations

`classroom.annotations` is an `AnnotationSession` facade with `canvases`,
`setSource`, `begin`, `append`, `undo` and `clear`. `AnnotationCanvas` identifies
the source participant and a server-created canvas epoch. `AnnotationShape`
supports pen, highlight, circle, arrow and text with normalized points.

`RealtimeRoomView` now delegates content transitions and source changes to
`SharedContentController`; legacy backends retain the former shared-track path.
Its default annotation widget is placed inside the **contained video content
rectangle**, excluding letterboxes. Hosts can instead use the lower-level
`RealtimeSharedContentStage`, `ClassroomAnnotationOverlay` and
`AnnotationPainter` in a custom layout. `showAnnotations: false` hides the default overlay.
The toolbar is only editable for teachers sharing their own screen; students
are view-only. The first implementation operates in the SDK preview, not as a
system-wide drawing layer over other desktop applications.

Freehand points are sent in batches every 100 ms, at most 100 points per
request. Reference bounds are 200 shapes and 2,048 points per stroke. Teacher
permissions, tool types and normalized coordinates are checked at the control
plane. Every operation includes the current canvas ID; stale-source operations
are rejected. Undo removes the last shape, clear removes all current shapes,
and changing/stopping the share starts a fresh canvas. New/reconnected clients
load the full current canvas. Real-time hint delivery remains best-effort;
without it the default two-second polling fallback determines remote latency.

LiveKit is the first shared-screen path. Other adapters reuse the overlay when
there is a renderable screen track. Receiver support does not imply that the
same platform can start sharing: existing provider capabilities still decide
which sharing controls are enabled. Browser/native video overlay composition,
orientation changes and reconnect behavior need real remote-pixel validation.
Classroom recording remains deferred.

Platform coverage is distinct from the shared annotation API. LiveKit currently
exposes Android/macOS and desktop-browser capture; iOS uses
`useiOSBroadcastExtension: false` for in-app capture, not a configured cross-app
Broadcast Extension. TRTC exposes Android/iOS capture calls; its full iOS flow
still needs real-device acceptance, and its macOS adapter does not expose
publishing. Native Agora/ARTC/Chime adapters currently do not expose screen
publishing. A receiving client may render a share even when it cannot publish.

See the complete [feature/platform and screen-share matrices](SDK_CAPABILITY_MATRIX.zh-CN.md#teaching-tools-and-live-interactions)
([Chinese](SDK_CAPABILITY_MATRIX.zh-CN.md#教学工具与直播互动)) and
[outstanding work/acceptance record](ACCEPTANCE.md).

## Independent whiteboard and unified content

See [Whiteboard SDK](CLASSROOM_SDK.md) for the independent Core/UI packages, multi-page whiteboard, unified content menu, screen annotations, synchronization and failure semantics. The teaching Meeting Demo uses the common SDK stage by default.


---

## 独立白板传输和远端失败契约

### Package boundaries

`flutter_realtime_whiteboard_core` is pure Dart. It depends on neither media,
Chat nor Classroom. `flutter_realtime_whiteboard_ui` adds Flutter widgets only.
The full SDK and `Realtime` export the public models and widgets.

```dart
final board = WhiteboardSession.local();
await board.start();
// Place WhiteboardView(session: board) in a bounded area.
await board.addPage(title: 'Exercise');
await board.begin(AnnotationShape(
  id: 'example', tool: AnnotationTool.arrow,
  points: [AnnotationPoint(.1, .2), AnnotationPoint(.7, .6)],
), canvasId: board.canvas.canvasId);
// Dispose the session when the host is done with it.
await board.dispose();
```

A custom `WhiteboardRepository` supplies snapshots, a state stream, actions and
close. `MemoryWhiteboardRepository` operates offline. Repositories must validate
identity and edits independently; `canEdit` only controls client affordances.
`WhiteboardSession` serializes actions and provides states/errors and annotation
methods. Each action carries `eventId`, `expectedRevision` and, for drawing,
`pageId`/`canvasId`. A repository must deduplicate matching event IDs and reject
conflicting payloads, stale revisions or inactive/deleted targets.

Initial state has one page; the default maximum is 20. At least one page remains.
Deleting the active page selects its predecessor, otherwise the first page.
Every page retains its marks. Page activation rotates the canvas identity while
preserving shapes, so delayed operations from an earlier activation are rejected.
Snapshots carry the page directory and current canvas only.

### Capture and failure semantics

Existing vendor adapters still capture and publish the screen. This SDK unifies
management and preview annotations; it does not capture the OS itself, burn marks
into video frames or provide a system-wide desktop overlay. A receiving platform
may display annotations even when its adapter cannot initiate capture. A local
capture without a renderable preview shows a waiting state instead of an editable
empty video canvas.

Screen → whiteboard/members stops capture before committing content state.
A stop failure preserves screen mode. A successful stop followed by a failed
commit reports the stopped capture and offers a repeatable menu action; capture
is not automatically restarted.

Whiteboard → screen starts system selection/capture first. Cancellation/failure
preserves whiteboard mode. A failed content commit attempts to stop the new share.
Rollback failure explicitly reports that capture remains active; Members/stop
sharing can be retried. Busy state prevents concurrent transitions. There is no
optimistic authoritative mode change. Provider snapshot flags must reflect actual
capture completion for adapter acceptance.

A changed local track/source resets only the screen canvas. Whiteboard pages
survive all mode switches. OS stop events reconcile screen mode to Members.
Source changes that a vendor does not expose in its snapshots cannot be inferred;
that adapter's real-device acceptance must confirm its source identity behavior.

### Acceptance boundaries

See [interaction acceptance](ACCEPTANCE.md) for this run's tests and
builds. Web/Android/iOS/macOS use the same state and drawing implementation.
Native capture remains subject to the [provider/platform matrix](SDK_CAPABILITY_MATRIX.zh-CN.md#教学工具与直播互动).
Actual vendor screen transport, distant pixels, physical orientation changes and
multi-device reconnect still require separate acceptance. No persistence, file
upload/storage, recording, courseware import or video composition is added.


---

## 系统屏幕标注

### 平台与适用范围

| 平台 | 实现 | 限制与验证状态 |
| --- | --- | --- |
| Android | WindowManager 悬浮 FlutterView（次级 FlutterEngine）/ 备用卡片、透明画布、文字输入窗口 | 需要用户允许“显示在其他应用上层”；debug 整包构建通过，跨应用/远端实机待验收 |
| macOS | AppKit 浮动透明 NSPanel（次级 FlutterEngine 嵌入 FlutterViewController）/ 备用 HUD 面板、绘图 NSView、跨 Spaces 窗口 | 新插件原生构建通过；完整 Demo 仍遇到现有供应商模块/重复打包冲突，跨应用/远端待验收 |
| Windows | Win32 置顶分层窗口、GDI+ 画布、原生文字输入 | 已实现适配源码；缺少 Windows 构建与运行环境，尚未验证 |
| Linux X11 | GTK/Cairo 透明画布、置顶工具窗、点击穿透 | 要求合成器和 RGBA visual；已实现源码，缺少 Linux 构建/运行验证；置顶效果仍受窗口管理器控制 |
| Linux Wayland | SDK 返回不支持跨应用悬浮 | 保留课堂内标注 |
| iOS / Web | SDK 返回不支持跨应用悬浮 | 保留课堂内标注，不显示成已具备系统悬浮能力 |

共享供应商还必须在当前系统支持屏幕共享。SDK 不把“存在标注插件”当作媒体
供应商已经实现屏幕共享：课堂入口同时检查教师权限、共享状态和平台能力。
因此可用于 LiveKit、TRTC 等已接通屏幕共享的组合；供应商未接通的组合仍不可用。

默认目标是**主显示器整屏**。工具条可拖动，使用“操作 / Move”可继续操作下方应用。
SDK 不自动定位被共享的窗口，不覆盖系统安全界面，不保证所有应用允许悬浮窗。
显示器几何、缩放或安卓方向改变时关闭工具，并清除旧坐标的笔迹；用户在当前共享
画面上重新打开。此版本不自动跟随移动的被共享窗口，也不支持选择第二显示器。

### 独立使用

```dart
import 'package:flutter_realtime_screen_annotation/flutter_realtime_screen_annotation.dart';

final tools = SystemScreenAnnotationController(annotations: myAnnotationController);
final availability = await SystemScreenAnnotationController.capabilities();
if (availability.supported) {
  await tools.start(languageCode: 'zh');
}
// tools.active、tools.error、tools.changes 可驱动自定义 UI。
await tools.dispose();
```

宿主负责真实屏幕捕获、编辑授权、后端同步和播放端呈现。一个 Dart isolate 中同时
只有一间房间可持有系统工具；SDK 在异步能力查询后再次检查所有权。

高级宿主可传入 `SystemAnnotationViewport`，指定主屏幕内的固定归一化矩形。
共享单窗口且捕获不包含系统画布时，宿主必须跟踪窗口位置并指定正确矩形，且调用：

```dart
await content.startSystemAnnotations(
  viewport: const SystemAnnotationViewport(x: .1, y: .1, width: .7, height: .7),
  embeddedInVideo: false,
);
```

此矩形例子不是自动窗口追踪。宿主变更共享目标必须停止并重新绑定画布。

### 视频与笔迹的呈现

整屏共享会捕获本地系统画布。参考后端新增教师动作
`tool.annotation.presentation`，载荷为 `canvasId` 和 `embeddedInVideo`。
后端验证教师权限、活动共享源、当前画布及布尔值，并在权威快照中返回标记。

开启工具前 SDK 提交 `embeddedInVideo: true` 并确认后端已接受，接收端据此隐藏
重复的矢量绘制层。关闭工具后恢复为 `false`，恢复课堂内标注显示。
共享窗口不包含悬浮画布时可显式使用 `false`，由播放端绘制同步矢量笔迹。
接收端也需更新 SDK；旧客户端不会识别新呈现标记。

这需要部署更新后的参考后端，或在自有后端实现对应协议。未实现的后端会报错，
SDK 不会假装悬浮标注已成功。恢复呈现状态失败时通过内容状态错误保留诊断。
权限获取成功后若仍提示后端不支持，请更新正在运行的参考后端；不能靠客户端热重载
添加 Android 原生插件和清单权限，需要完整重建并安装应用。

自由笔迹约每 100 ms 发送进度，Dart 合并同一笔迹的待处理版本，单批不超过 100
点、单笔不超过 2048 点。后端完成后才确认本地草稿。撤销/清除与笔迹使用同一
顺序队列。同步失败后停止接受新绘制并显示错误，关闭后重开可依据权威快照恢复。


---

## 直播点赞、礼物与互动

### SDK boundary

`flutter_realtime_live_core` contains immutable gift/catalog/state types,
`LiveInteractionRepository`, `LiveRevisionTransport`, and `LiveInteractionSession`.
`flutter_realtime_live_preset` is an **optional**, UI-free business adapter
registering the existing Live session with `RealtimeFeatureRegistry`.
`flutter_realtime_live_ui` provides `LiveGiftPanel` and `LiveGiftOverlay`.
Neither package imports a media or Chat vendor SDK.

The host must explicitly register `LivePreset()` in `featurePlugins`, and
the provisioned room must advertise `liveInteractions: true`. The reference server advertises this for
Broadcast rooms. `RealtimeRoomView` renders the gift entry and incoming-event
animation on both hosts and viewers. The Live page's gift button uses `RealtimeLiveGiftButton` to open the shared
gift panel. `showLiveInteractions: false` suppresses this optional UI.
Session lifecycle and errors remain accessible to custom UI.
Applications can inject `LivePreset(repositoryFactory: ...)` for their own
trusted store; direct credentials do not silently create a reference backend.
For custom direct rooms without backend metadata, opt in via
`enableForDirectRooms: true` together with `repositoryFactory`.

```dart
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';

final realtime = Realtime(
  providers: myProviders,
  backendUrl: backendUrl,
  featurePlugins: const [LivePreset()],
);
final connection = await realtime.open(request);
final room = connection.mediaRoom!;
final gifts = room.liveInteractions;
if (gifts != null) {
  await gifts.start();
  final catalog = gifts.state!.catalog;
  final eventId = gifts.newEventId();
  await gifts.sendGift(catalog.first.id, quantity: 5, eventId: eventId);
  // If the request times out, retry with the SAME gift/quantity/eventId.
  // Listen to gifts.states, gifts.events and gifts.errors; cancel on disposal.
}
```

These are demonstration gifts. There is no currency, wallet, payment provider,
recharge, debit, withdrawal, or settlement API. The reference catalog uses local
Flutter icons for applause, flowers and stars. A custom repository can supply
its own catalog.

### Reference protocol

- `POST /rooms/:code/live/snapshot`
- `POST /rooms/:code/live/gift`

Both carry `requesterParticipantId` and `participantCredential`. Gift submission
additionally carries `giftId`, integer `quantity` (1–99), and `eventId`.
The joined identity is resolved by the server; sender/recipient identities
cannot be chosen in the submitted event. The recipient is the current host.
A missing host, wrong room mode, invalid credential or partially closed room
rejects the action. The reference limit is five gifts per sender per ten seconds.

Snapshots contain room/self/recipient identity, monotonic revision, catalog,
last 100 gift events and cumulative per-gift totals. Matching replay IDs are
idempotent while retained (last 1,000 submissions per room); conflicting payloads
return `idempotency-conflict`. Clients should retry promptly, not rely on
unbounded historical deduplication. State lasts for the current room lifecycle
only and is removed on clean close.

Product Chat system hints use `live.interaction.changed`; RTC hints use the
`live.interaction.v1` topic. Hints carry only a validated revision, never gift
state or authorization, and stay out of ordinary Chat messages. HTTP polling
(default two seconds) remains active when a vendor/role cannot send hints.
Hint and polling reads share one in-flight snapshot and are limited to at most
one automatic read per second, with at most one trailing read for a burst.
Explicit refreshes remain immediate. Ordinary Chat text resembling reserved
frames is escaped and restored; malformed reserved frames remain ordinary text.
Initial history does not replay animations. Newer authoritative events animate
once, including when the bounded event list stays the same length.

Media and product Chat selection are independent for all vendors, including
AWS Live. A room is bound to the selected Chat provider when created; dashboard
changes apply only to new rooms. No product Chat selection means no product
Chat. RTC chat fallback still requires bidirectional RTC data; this is distinct
from the polling-backed gift control plane.

### Platforms and evidence

The common Dart/Flutter implementation targets Web, Android, iOS and macOS.
This does not make every vendor/role Chat transport or screen-sharing method
available. Check the existing media and Chat capabilities.

Tests cover authenticated HTTP host/two-viewer state exchange against a local
mock media control plane, duplicate/conflicting submissions, rate limits,
no-host behavior, quiet initial history, revision isolation and a phone-sized
retry UI. This is not real vendor messaging or remote media acceptance.
See [interaction acceptance](ACCEPTANCE.md) for remaining checks.


---

## 统一头像与成员资料

### 公开接口

共享身份支持可选的 `avatarUrl`，原有调用方式继续兼容：

```dart
const user = RealtimeUser(
  id: 'user-1',
  name: '小明',
  avatarUrl: 'https://example.com/avatar.png',
);
```

通用 UI 可独立引用：

```dart
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';

RealtimeAvatar(name: '小明', avatarUrl: user.avatarUrl, size: 48);
```

链接接受 HTTP(S)，限制 2048 字符，禁止 URL 内嵌凭证。未填写、加载中或加载失败时，显示去除前后空白后名字的第一个完整字符；中文与组合 Emoji 不拆分。空名字显示 `?`。Web 图片还需允许浏览器访问。

会议预览、关闭摄像头的视频格、参与者缩略图、成员列表、聊天消息、直播主播和观众、课堂成员与活动使用统一头像组件。已有主题和头像大小继续由各页面控制。

### 资料传递

后端保存并返回成员的显示名称与头像链接。会议的资料更新通过现有数据通道尽力同步；发送者绑定到实际传输成员，不采信消息内声明的成员身份，资料不能授权角色或操作。没有数据通道的厂商仍依赖后端返回的资料。

本地头像直接使用加入请求的共享身份，不要求后端原样回传头像字段。当地成员的厂商 ID 与后端 ID 不同时，仍通过本地成员标记正确匹配。管理成员列表刷新时合并实时头像，同时保留后端角色、管理 ID 和其他授权字段。

Chat 通过厂商消息属性传递头像。自定义独立 Chat provisioner 可选择实现 `StandaloneChatProfileProvisioner` 接收头像；旧 provisioner 保持兼容，客户端保留自身头像资料，远端资料是否传递由其后端决定。
