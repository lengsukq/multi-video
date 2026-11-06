# Realtime 前端视觉系统

本项目统一采用单一浅色、冷灰蓝工作区外观：`#E9EDF2` 页面底、白色内容卡、琥珀色操作、青绿色状态、玫红色危险/直播。视频与直播舞台允许局部深色遮罩，它们不构成应用暗色模式。Demo 不读取外观偏好，也不提供外观切换。

自 2026-10-19 起，视觉基准改为三套参考模板（Green room / Live classroom / Screen share and recording）。所有 `*_ui` 包、内置页面与共享组件都必须遵循本文件的色板、几何、字体与响应式契约。

## 接入与边界

通用包为 `flutter_realtime_design_ui`，只依赖 Flutter。主题、颜色、几何、字体与通用组件通过 `flutter_realtime_design_ui.dart` 公开提供。宿主使用 `RealtimeUiTheme.light()`；自定义配置使用 `RealtimeUiThemeExtension` 与 `RealtimeStyle.copyWith`。

所有 UI 包可以依赖该通用包；core、runtime 和 SDK facade 不依赖 UI。房间、权限、设备采集、聊天和控制面行为继续由原有 SDK 契约承载。白板绘图颜色与媒体内容不属于界面主题色。

## 字体

| 用途 | 字体 | 字重 |
| --- | --- | --- |
| 正文、控件、表格 | Onest | 400 / 500 / 600 / 700 |
| 页面标题、卡片标题、计时 | Bricolage Grotesque | 500 / 700 |

- 字体文件随 `flutter_realtime_design_ui/fonts/` 打包，不联网加载。
- Flutter 包字体的 family 名为 `packages/flutter_realtime_design_ui/Onest` 与 `packages/flutter_realtime_design_ui/BricolageGrotesque`。
- 单包发布时，`scripts/assemble_single_sdk_candidate.py` 会把 family 前缀改写为 `packages/flutter_realtime_sdk/...`，并在生成的 pubspec 中写入 `fonts:` 段。
- 宿主可通过 `RealtimeUiThemeExtension(bodyFontFamily:, displayFontFamily:)` 覆盖；传空字符串则退回平台默认字体。

## 色板

| 语义 | Token | 值 |
| --- | --- | --- |
| 页面背景 | `background` | `#E9EDF2` |
| 卡片 / 面板 | `surface` | `#FFFFFF` |
| 次级块 / 输入 | `surfaceSubtle` | `#F4F6F9` |
| 分隔线 | `border` | `#DAE0E8` |
| 强分隔线 | `borderStrong` | `#C4CDDA` |
| 主文字 | `text` | `#18202E` |
| 次文字 | `textSecondary` | `#3D4A5C` |
| 说明文字 | `textMuted` | `#5B6678` |
| 主操作 / 选中 | `accent` | `#F5C518` |
| 黄底文字 | `onAccent` | `#2A2100` |
| 高亮块 | `accentSoft` | `rgba(245,197,24,.35)` |
| 发言描边 / 状态点 | `speak` | `#0E9E8E` |
| 青绿文字 / 白字按钮 | `speakStrong` / `success` | `#0B7F72` |
| 直播 / 录制 / 危险 | `live` | `#D93A3F` |
| 白板纸 | `board` / `boardGrid` / `boardInk` | `#FCFDFE` / `#E7ECF2` / `#1F2A3C` |
| 视频占位 | `tile` / `tileStrong` | `#D5DCE6` / `#C4CDDA` |

**关键对比度规则：** 琥珀色只作为填充色（按钮底、选中块、徽标底），其上的文字必须使用 `onAccent`。白色或浅色底上的文字、图标一律使用 `text` / `textSecondary` / `textMuted` / `speak` / `live`，不得使用琥珀色文字。

## 几何与层次

| 项 | 值 |
| --- | --- |
| 卡片圆角 | 22 |
| 控件 / 小按钮圆角 | 12 |
| 舞台 / 视频圆角 | 18 |
| 弹层顶部圆角 | 24 |
| 紧凑圆角 | 10 |
| 胶囊圆角 | 999 |
| 间距 | 4 / 8 / 12 / 16 / 24 / 32 |
| 玻璃模糊 | 16（次级 10） |
| 动效 | 160 / 240 / 340ms |

- 卡片阴影：`0 8 24 rgba(16,24,40,.06)` + `0 1 2 rgba(16,24,40,.04)`。
- 默认主题使用不透明表面；宿主可以显式开启玻璃（`glassOpacity .94`）。高对比度或关闭玻璃时强制不透明。
- 页面底色平铺，内容卡默认不带阴影；浮动 Dock 与画中画保留轻阴影。
- `speakStrong` 对白色为 4.89:1，对次级表面为 4.52:1；成功提示浅底使用 `#EFFAF8`，对比度 4.59:1。
- 分段控件继续遵守「外层半径 ≥ 高度/2，滑块半径 = 外层 − 内边距」；选中块使用琥珀色。

## 响应式契约

公共断点位于 `RealtimeBreakpoints`，页面不得再散落 600/1000/1280 字面量。

| 宽度 | 会议 | 直播 | Pre-Join | 聊天 / 课堂 / 白板 |
| --- | --- | --- | --- | --- |
| `< 600` 手机 | 56pt 常显顶栏；舞台 + 底部 Dock；无左侧栏；面板走右侧抽屉 | **同款顶栏 / 视频舞台 / 横向滚动 Dock**；聊天与观众从右侧抽屉打开，点赞/礼物在 Dock | 单列滚动；预览 16:10；底部粘性单一 CTA | 单列；工具栏横向滚动 |
| `600–999` 平板 | 顶栏 + 横向工具条 + 舞台栏 + Dock；面板走右侧抽屉 | **同款顶栏 + 横向工具轨 + 舞台 + Dock**，面板走右侧抽屉 | 单列；设备选择器两列 | 侧栏自适应 |
| `>= 1000` 桌面 | 56pt 顶栏 + 60pt 竖向工具栏 + 舞台栏 + 340pt 常驻侧栏 | **同款 56pt 顶栏 + 60pt 左工具轨 + 视频舞台 + Dock + 340pt 聊天/观众侧栏** | 两栏（预览 6 : 会话/设备 4），最大宽 1240 | 最大宽 900–1100 |
| `>= 1280` | Dock 显示文字标签 | 右栏留白增大 | 预览更大 | 更宽留白 |
| 200% 文字 | 降级一档；隐藏标签；所有行可换行或滚动 | 同左 | 选择器纵向堆叠 | 分段控件退化为列表 |

验收宽度：320、390、600、768、1024、1280、1440，另加 320×640、740×390 与 200% 文字。硬性要求：无 `RenderFlex overflow`，加入、离开、静音、摄像头、聊天发送始终可点到。

## 页面结构

### 首页与顶层导航

- `RealtimeWorkspaceShell` 新增可选 `header` 与 `compactNavigation`，旧调用保持兼容。Demo 使用固定 56pt 品牌栏；桌面为 60pt 全高工具轨，手机和平板为平整底部导航。
- 首页标题直接排在灰蓝背景上，减少重复卡片。桌面为左侧房间目录、右侧深色加入卡（约 1.35:1）；窄屏加入卡在前、目录在后。创建会议、开播、加入、聊天与设置入口保留。
- 工具轨提供标签提示、键盘焦点与稳定的 destination key。切换布局或导航不销毁已挂载的聊天宿主。
- 普通 Demo 入口只使用真实房间身份；课程、等待名单、倒计时等样例只出现在明确标识的测试/样例展示中。


### 会议

```
顶栏 (56pt, 常显)
└─ 工作区
   ├─ 工具栏 (>=1000, 60pt；白板共享时上部画笔/颜色，下部会议基础工具)
   ├─ 舞台栏 → 舞台 → Dock（常显，不自动渐隐）
   └─ 侧栏 (>=1000 且打开, 340pt)
```

- 顶栏：品牌插槽（与标题之间留 1pt 分隔线）、房间/课程标题、副标题、角色胶囊、在线人数、时长胶囊（课堂模式为红色 LIVE 胶囊）、录制胶囊、连接状态、头像堆叠、Invite 按钮、离开。离开按钮是唯一退出入口，顶栏常显。录制胶囊只显示 `Recording` / `录制中`，具体时长放在 tooltip，避免和时长胶囊重复。
- 课堂工作区（`showClassroom && room.classroom != null`）：使用与参考稿一致的课堂布局；侧栏一级标签为 Chat / People / Classroom / Recording（可用时）/ Notes（服务端支持时）。课堂内二级导航为概览、举手审批（仅教师）、问答和投票测验（有课堂工具能力时），防止 340pt 面板中堆积标签；发起投票、计时与管理入口位于左侧基础工具区。
- 白板共享：桌面左侧只使用**一条 60pt 工具轨**，上方优先展示白板画笔、图形、颜色与撤销等工具，下方展示会议基础工具，分别滚动；停止共享后白板段立刻消失。会议 Shell 和白板舞台同时订阅共享状态变化，不应依赖调整窗口尺寸触发合并。小屏白板工具以舞台中的横向条展示。
- 共享内容激活时，舞台栏整行隐藏：屏幕共享条、白板页签栏已承载这一区域的标题，缩略图开关位于基础工具轨，不重复占用 Dock。
- 非课堂会议：沿用通用工具栏 + 胶囊 Tabs 侧栏；两者共用同一 56pt 顶栏、340pt 侧栏、Dock 分组与舞台几何。
- 工具栏：桌面左侧 60pt 纵向轨负责聊天、成员、课堂、举手审批（仅教师）、视图切换、摄像头翻转、虚拟背景、录制控制/结果、投票/计时及课堂工具；能力和角色不支持的项目不渲染。平板与手机在顶栏下方复用 52pt **横向轨**，支持鼠标滚轮/拖动和左右箭头，代替底部「更多」弹层，避免低频操作挤占底部。
- Dock：白色圆角胶囊分组，底部只保留**麦克风、摄像头、共享内容、快捷表情及学生举手**等高频即时控制；直播只保留主播麦克风/摄像头与可用的礼物、点赞互动。工具设置、录制控制/结果、布局切换、教师举手审批、投票/计时改走功能轨或对应工作台。**Dock 常显，不随空闲计时渐隐**；离开房间始终位于顶栏，会议/直播的内置页面不再出现「更多」弹窗。
- 轻量二级操作：**共享内容（白板、屏幕、停止）、互动反馈、少于等于三个的简单 More 操作**使用 `RealtimeDockCompactMenu` 锚定触发按钮展示，不再打开全屏宽底部面板。菜单保留能力禁用、当前选中标识、危险操作样式，点选后调用原 SDK 指令，点空白区域仅关闭菜单。无共享内容能力时不能访问供应商能力 getter，避免页面构建时抛错。富文本输入、复杂设备设置、成员管理等依旧采用专门工作台/对话框。
- 舞台栏：未共享时可以通过工具轨切换发言人 / 宫格与缩略图；共享时保留工具轨里的缩略图可见性切换，不占用 Dock。
- 舞台：18pt 圆角、1pt 描边；说话人 2pt teal 描边；关闭摄像头使用 `tile` 底 + 饱和色头像；右上角本地画中画（共享/白板期间同样保留；窄小窗口避免遮挡）。缩略图始终独占舞台下方一行。
- 侧栏：使用基于 `RealtimeWorkspaceTab` 的语义化下划线导航；课堂里的 `RealtimeClassroomWorkspace` 按真实 ClassroomState 显示在线人数、待答问题、举手审批和进行中测验，教师/学生根据 capabilities 分别渲染操作，拒绝模拟统计。非课堂会议只显示真实可用的 Chat / People；置顶消息用 `accentSoft`；举手审批与投票收纳到 Classroom 二级导航。
- 手机/平板：面板通过右侧全高抽屉打开，不再使用底部弹层。

#### 宿主插槽（会议）

| 参数 | 类型 | 语义 |
| --- | --- | --- |
| `sessionInfo` | `RealtimeMeetingSessionInfo` | 课程/房间标题与副标题；缺省回退到房间号 |
| `brand` | `Widget?` | 顶栏产品标识 |
| `pinnedMessage` | `String?` | Chat 面板顶部置顶消息 |
| `classroomNotesPanel` | `Widget?` | 可选宿主笔记视图覆盖。未传且服务端支持 `ClassroomState.notes` 时教师看到内置记录/章节编辑器；学生不可见 |
| `initialSharedContentMode` | `SharedContentMode?` | 入会后请求的共享内容模式（如“共享屏幕开始”） |

课堂标题、等待室、议程、倒计时、材料、置顶消息在 SDK 中都没有权威状态，必须由宿主通过上述插槽提供；SDK 不会伪造这些内容。

### 直播

- **共用框架**：`RealtimeMeetingPage` 和 `RealtimeLivePage` 均使用 `RealtimeRoomShell`；顶栏、横向/竖向导航、舞台与 Dock、340pt 常驻侧栏以及紧凑抽屉遵循同一响应式契约。新增通用外层布局优先改这个 Shell，不单独复制会议或直播布局。
- **桌面**：左侧 60pt 工具轨 + 中央圆角视频舞台 + 底部常显 Dock + 右侧 340pt Chat / People 下划线标签；聊天室沿用会议统一时间线样式，礼物/点赞保留在互动区。
- **平板/手机**：直播页面也使用会议式常显白色顶部栏、舞台与 Dock；两个尺寸均显示上方可滚动工具轨，聊天/观众由工具轨打开全高抽屉，礼物/点赞继续位于 Dock。原 `RealtimeLiveMobileOverlay` 仅供单独嵌入，不再作为内置 `RealtimeLivePage` 主界面。
- **角色能力**：主播底部只显示可用麦克风与摄像头；主播工具、视频适应/填充、清屏移入功能轨，观众不可见主播管理项。原「显示选项」弹层从内置直播页面移除；对外组件保留旧回调兼容已有调用。所有操作仍走 SDK 能力检查。
- **嵌入式移动直播浮层**：独立使用 `RealtimeLiveMobileOverlay` 的旧接入者，常规显示选项也改成锚点菜单；观众仅见可用的画面显示操作，主播额外见管理入口。只有宿主注入复杂 `extraTopActions` 自定义组件时才保留原有较大的面板以防破坏插件兼容性。
- 礼物横幅、爱心浮层、录制徽标统一使用新色板；清屏模式保留。

### Pre-Join / Green room

- 桌面（>=1000 且高度 >=420）：`maxWidth 1240`，左右约 1.35 : 1、间距 24。
  - 左栏：38pt 标题 + 说明 → 16:10 预览卡（左上真实分辨率/网络胶囊，底部 mic / camera 圆形快捷开关）→ 单一的「设备与效果」卡（Camera / Microphone / Speaker 同排下拉 → 真实麦克风/摄像头开关与电平 → 画面效果 → 就绪检查 → Run again）。预览卡不再重复背景与设置入口。
  - 右栏：深色课程卡（subject 琥珀胶囊、课程标题、日期/时段/报名人数、真实倒计时、琥珀主 CTA、Audio only / Start with screen share）→ 隐私说明 → 等待室 → 课程议程 → 课堂材料。后四块只在宿主传入数据时出现；`Run again` 不在深色卡内，避免主操作区拥挤。
- 平板/手机：单列滚动，顺序为预览 → 设备与效果 → 课程卡 → 宿主插槽；底部粘性栏只保留一个主 CTA，避免重复主操作。
- 顶栏只渲染品牌、标题和宿主传入的 `headerActions`，不放没有行为的主题或帮助按钮。
- 默认关闭麦克风与摄像头；观众不渲染本地预览与设备选择。
- 噪声抑制、静音电平表、试音、自动录制、实时字幕没有底层能力，不渲染假控件。开关激活色使用 teal `speak`。

#### 宿主插槽（Pre-Join）

| 参数 | 类型 | 语义 |
| --- | --- | --- |
| `sessionInfo` | `RealtimePreJoinSessionInfo` | 课程标题、学科、日期/时段、`startsAt` 倒计时、报名人数 |
| `waitingGuests` / `onAdmitGuest` / `onAdmitAll` | 列表与回调 | 等待室名单与准入请求；准入结果由宿主更新名单状态 |
| `agenda` | `List<RealtimePreJoinAgendaItem>` | 编号课程议程 |
| `materials` / `onOpenMaterial` | 列表与回调 | 课堂材料 |
| `brand` / `headerActions` | `Widget?` / `List<Widget>` | 顶栏品牌与额外操作 |
| `onEnterWithIntent` | `RealtimePreJoinEnterWithIntent` | 接收 `standard / audioOnly / screenShare` 意图；`audioOnly` 会强制麦克风开、摄像头关 |

### 聊天、课堂、白板

- 聊天：扁平行（头像、姓名、时间、正文），自己的消息右对齐并使用 `surfaceSubtle`；输入框为方框 + 图标行 + 深色圆形发送，房间面板在输入框上方显示 `To Everyone` / `发送给所有人`。
- 课堂：统一 RealtimeClassroomSidePanel + RealtimeClassroomWorkspace，一级标签只负责切换业务区域，二级按概览 / 举手 / 问答 / 互动组织；保留原独立 RealtimeClassroomPanel 供第三方组件级调用，课堂活动结果取自插件真实 counts。即使 Chat 不可用或语言改变，外部入口仍按语义 ID 进入目标页面。

### Tandem 参考侧边栏视觉规范

会议/课堂右侧 340pt 工作台不复制参考 HTML 的示例数据。所有页面复用
`classroom_sidebar_visuals.dart` 的卡片、章节标题、状态胶囊和指标样式，
用 `RealtimeStyle` 跟随 SDK 的明暗主题。一级标签采用带图标的下划线导航、
选中滚动定位及明确的左右翻页按钮（防止 340pt 宽度下录制/笔记不可访问）；
课堂二级导航采用轻背景选中状态。

- **课堂概览**：响应式两列真实指标卡，进行中投票仅在后端存在活动时显示，
  百分比只从服务端 `counts` 计算。其余举手、Q&A 和互动卡片共用圆角、
  头像、状态标签和按钮层级，权限仍由 SDK 控制。
- **录制**：状态/时长与开始停止按钮组成第一张强调卡；布局、媒体、云端输出
  放在第二层配置卡；真实课堂章节可在录制栏只读展示。录制开始时间与房间
  开始时间未映射前，章节只能标注“课堂时间”，不能跳转录制。无真实数据时
  不出现伪音量波形、虚假云存储容量或不支持的录制开关。
- **真实操作接入**：录制栏教师可通过 Add lesson chapter 调用课堂 SDK
  `addNote(chapter: true)` 并订阅课堂状态以实时刷新，不能用本地伪数据。
  课堂互动页教师可创建 Poll/Quiz，提交到 `publishActivity`，学生只在
  后端授予答题权限后可回答；成功/失败以控制器和服务端反馈为准。
- **笔记**：编辑器、存储状态、章节标记和 Markdown 课堂纪要复制位于同一
  卡片；已保存记录使用可编辑时间线卡，教师可修改/确认删除，学生不可访问。
  非持久会话显示醒目的保存风险说明。
- **响应式**：标签必须在鼠标、触控板、窄侧栏可访问；使用全局设计色、
  字重、渐变/动效 tokens，而不是硬编码仅亮色的 Tandem 画面。
- 白板：`RealtimeBoardSurface`（白纸 + 细网格 + 18pt 圆角）。宽屏为 60pt 竖向教学工具轨 + 顶部页签条 + 16:9 白板；工具轨提供选择、画笔、高亮、圆、箭头、文字、**按笔迹橡皮擦**、颜色、撤销、清空，选中态琥珀色。橡皮擦使用场景坐标几何命中检测，点击/拖动删除实际矢量笔迹、圆形、箭头或文本对象，调用 `AnnotationController.erase(id, canvasId:)` 而非画白线；操作由课堂/共享后端校验权限并广播快照，随后可撤销恢复。擦除粒度是整笔/整对象，暂不分割单条线段。页签读取 `WhiteboardState.pages`；窄屏页签横向滚动，缩放/删除/停止固定在尾部。屏幕标注工具条约束在实际共享画面内，不覆盖聊天或录制侧栏。
- 屏幕共享 / 录制：会议舞台内的共享条由 Dock 的共享入口承担；独立共享舞台仍保留深青 `#0B7F72` 实底白字条与白色 `Stop Sharing` 按钮。`RealtimeRecordingPanel` 只展示权威录制状态、真实时长、已请求的布局/媒体/输出选项与结果入口，不含聊天/字幕/章节/存储额度等假开关。
- 多步骤或长内容弹层：24pt 顶部圆角、拖拽条、56pt 标题行、白色表面；少量简单选项使用紧邻触发器的 14pt 圆角小菜单，不使用大面积遮罩。

## 可访问性

- 玻璃、阴影与选中态在 `glassEnabled: false` 或高对比度时退化为不透明表面与实线描边。
- 减少动态效果时移除缩放、位移与渐隐动画；状态点不使用无限循环动画。
- 触控目标：图标按钮 ≥ 44pt，可点击胶囊 ≥ 48pt，列表行 ≥ 44pt。
- 文字遵循系统缩放；组件使用滚动或弹性布局，不用裁切掩盖溢出。

## 验收边界

质量门禁、单测、布局检查、测试数据截图、浏览器验证和真实厂商调用分别记录。测试数据与组件截图不代表真实音视频、多设备、原生平台或云资源清理完成。

必须覆盖：

```sh
python3 scripts/check_sdk_quality.py --resolve --analyze --test
python3 scripts/check_sdk_architecture.py
python3 scripts/format_sdk.py --check
python3 scripts/generate_capability_matrix.py --check
cd example && flutter test --no-pub
python3 -m unittest scripts.tests.test_assemble_single_sdk_distribution
```

截图验收使用 `example/test/support/design_capture.dart` 生成 meeting / live / prejoin / chat 在 390、768、1440 的预览，并单独检查 320×640、740×390 与 200% 文字。

---

## 会议、直播与聊天的角色 UI 权限

### Authority and ownership

- For the **post-join room UI**, use the backend's `roomMode` metadata as the
  source of truth. If it is unavailable, use the SDK's connected role as a
  conservative fallback. A stale pre-join choice of Live must not turn a
  Meeting participant into a Live broadcaster.
- In Meeting, RTC `participant` means *symmetric media participation*, not
  *no meeting administration*. The creator may also hold a separate
  `roomOwnerCredential`. Check `media.isLogicalOwner` **and** the specific
  management capability, rather than assuming only `MediaRole.host` can
  manage meetings or that any `participant` can.
- Live's `MediaRole.host` is not the same as Chat's `ChatRole.host`. UI
  must require the actual corresponding session role; `role != viewer` is
  insufficient. Legacy host panels should also block standalone mounting by
  guests; simply hiding the top-level entry is not enough.
- For independent Chat, use `ChatSession.role` returned by the connected
  provider (based on trusted provisioned credentials), not the user-provided
  `join` request. The Demo Server never allows a public Chat join to
  self-promote to host. The Chat UI controller owns all management gating.
  If the remote join response omits a valid role, `HttpStandaloneChatProvisioner`
  treats the caller as a `participant`, **not** as its caller-requested `host`.
- The HTTP Media join contract behaves similarly: a public join that asks for
  `MediaRole.host` but receives no assigned role from the server is treated as
  an unprivileged `participant`. Create and credential-refresh flows retain
  their separate existing role contracts. Backend capabilities and provider
  tokens remain the real authorization boundary.
- Display roles for **remote** video users only when a trusted source supplies
  their authoritative role. `MediaParticipant` alone has display name,
  camera/microphone status and local identity, **not** a guaranteed remote
  host role. Do not label the first user with a video track as a verified host.
- A status tooltip/semantic label can replace long badges in tight 320px
  Meeting headers. The text roles in the independent Chat header remain
  visible and localized. UI semantics are an accessibility and usability
  feature, **not an authorization boundary**.

### Validation

Offline tests cover Meeting logical-owner/guest labels, 320px text scaling,
desktop Meeting sidebars, Live host/viewer/non-host participant gating, Chat
creator/guest management affordances, and backend mode winning over a stale
pre-join hint. These tests cannot prove all vendor adapters issue and refresh
the intended roles on physical devices. Before pub.dev release, test both
devices concurrently (create, join, reconnect, rejoin as owner/guest, leave)
on the selected vendors and confirm server authorization independently.

See [SDK integration](APP_INTEGRATION_QUICKSTART.zh-CN.md),
[provider capabilities](SDK_CAPABILITY_MATRIX.zh-CN.md) and
[UI composition](REALTIME_DESIGN_SYSTEM.md).


---

## 房间离开、关闭与组件生命周期

### 3. 组合式 UI 的 Scope 规则

`RealtimeRoomUiScope.of(context)` 只能访问 **Context 祖先链中确实存在**
的 Scope。以下是常见错误：

```dart
class RoomPageState extends State<RoomPage> {
  // 错误：当前 State.context 是 Scope 的父级。
  void closeRoom() {
    RealtimeRoomUiScope.of(context).leave();
  }
  Widget build(BuildContext context) =>
      RealtimeRoomUiScope(room: room, child: const SizedBox());
}
```

正确做法：在 Scope **内部**的 `Builder` 中获得控制器，并将
`controller` 显式传给事件回调、异步逻辑或弹窗：

```dart
RealtimeRoomUiScope(
  room: room,
  child: Builder(
    builder: (scopedContext) {
      final controller = RealtimeRoomUiScope.of(scopedContext);
      return Scaffold(
        body: Column(
          children: [
            const Expanded(child: RealtimeVideoGrid()),
            const RealtimeMicrophoneButton(),
            RealtimeLeaveButton(
              closeForEveryone: false, // 只离开当前参会者
              onLeft: () {
                if (scopedContext.mounted) {
                  Navigator.of(scopedContext).maybePop();
                }
              },
            ),
          ],
        ),
      );
    },
  ),
);
```

不要通过吞掉 Scope 断言、空 catch 或随意 `maybeOf` 返回 null
来掩盖错误的祖先关系。布局切换时可以注入同一个 Controller；将
Controller 注入新 Scope 时由**调用方**负责最终 `close()`。

### 4. Navigator Overlay：Dialog / BottomSheet

`showDialog`、`showModalBottomSheet`、一些 Drawer/Popup
会在 Navigator 的 Overlay 中建立新路由；它们的 builder 并不是
会议页面 Scope 的子树。直接在弹窗 builder 的 Context 上调用
`RealtimeRoomUiScope.of` 可能报：

```text
RealtimeRoomUiScope is required above this widget
```

**SDK dev.15 已发布 API：**

```dart
// controller 来自会议页面 Scope 内的 Builder，而非 State.context。
await showRealtimeRoomUiBottomSheet<void>(
  scopedContext,
  controller: controller,
  builder: (sheetContext) => RealtimeMediaDevicePicker(
    kind: MediaDeviceKind.microphone,
  ),
);

await showRealtimeRoomUiDialog<void>(
  scopedContext,
  controller: controller,
  builder: (dialogContext) => AlertDialog(
    title: const Text('会议设置'),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('关闭'),
      ),
    ],
  ),
);
```

两个 helper 都将原 Controller **借给** Overlay，不创建新的媒体房间，
也不会负责销毁借入的 Controller。关闭弹窗时优先使用
其 builder 提供的 `sheetContext`/`dialogContext`，
不要用宿主页面 Context 盲目调用 `Navigator.pop()`。
在关闭整个会议前，先关闭依赖房间状态的弹窗，避免重建已释放资源的组件。
尚未升级到新版本时，宿主必须自行在 Overlay 下方显式传入已有 Controller。

### 5. Leave / Close / Dispose 的责任边界

| 操作 | 含义 | 不能替代的操作 |
| --- | --- | --- |
| `controller.close()` | 释放 UI 订阅、UI 状态；借用的 `room` 保持存在 | 离会、结束会议 |
| `controller.leave(closeForEveryone: false)` | 请求本地离会，并释放相应 Room 资源 | 结束所有人会议 |
| `controller.leave(closeForEveryone: true)` | 请求结束整个房间；权限、录制收尾和后端校验均可能失败 | 无权限情况下强行结束 |
| `controller.leave()` | 按房间所有权自动选择：主持人结束全员会话，其他人仅离开自己 | 后端无法关闭房间时不能视为退出成功 |
| `connection.dispose()` | 释放 Connection/Room 等本地资源 | 后端管理操作或结束全员会议 |
| `Navigator.pop()` | 退出视觉页面 | 任何 RTC/IM 资源清理 |

会议和直播统一使用自动退出策略：
`room.media.isLogicalOwner == true` 时，点击离开会尝试关闭整个房间，
使所有参会者/观众退出；其他用户则只退出本人。不再提供退出方式选择。
SDK 内置页面仅保留单次确认：主持人提示“结束会议/直播”，其他人提示“离开”。
普通会议创建者可能持有 owner 凭证但媒体角色仍是 `participant`，
因此不能只靠 `MediaRole.host` 判断主持人身份。最终关房权限以服务端为准。
若客户端或服务端不支持关房，则返回错误并保留当前连接，避免主持人误以为
全员已经退出。第三方自定义应用也应按 `isLogicalOwner` 处理退出。

**远端结束同步（源码实现，需发布新的单包版本）：**
连接成功后的媒体心跳若获得后端的 `room-not-found`，SDK 将停止重复心跳，
向 `room.events` 发出 `RealtimeBackendFailure`，其中
`error.operation == 'room.presence.heartbeat'`。SDK 内置会议与直播页
由此提示房间结束并触发宿主 `onLeft`。宿主如使用组合式/无头页面，需自己
监听并释放连接。高层 `Realtime` 默认媒体心跳间隔为 5 秒；异常网络连接失败
不视为房间结束。该机制是跨厂商的*最终一致*兜底，不保证即时踢出远端
RTC 连接；如需服务端强制断连，必须使用厂商关房能力并在后端实现授权。

退出过程中不要重复点击，也不要让第二个调用者在首次销毁完成之前
提前导航。近期源码已为并发 `leave()` 提供共享 Future，并防止
等待确认时 Widget 已卸载后继续执行。**已经关闭的 UI Controller**
再次收到 `leave()` 时会抛出 `RealtimeErrorCode.invalidState`，
而不是谎报房间已释放；此时应由仍持有 Connection 的宿主决定如何清理。
错误应提供明确的处理路径，而不是视为离会成功。

### 6. 还需通过的回归场景

开发者可对照以下场景测试 SDK 集成：成品会议/直播页面退出；
组合页面确认/取消；手机 Drawer/弹窗；嵌套 Navigator；
离会连续点击与重复释放；录制正在启动/停止时关房；
网络断线、超时与权限不足；页面被系统返回先卸载；
重新进入同房间；不同用户角色与不同 Provider。

**当前验证状态（2026-11-02 SDK 工作树）：**
SDK UI 和 Room UI 静态分析通过；新加的 SDK 嵌入/Scope/退出测试通过；
SDK UI 全量回归现已通过 151 项测试（其中包括修复后的大字体直播工具栏
Host tools 可达性测试）；Room UI 6 项测试通过，相关静态分析通过。
此外，厂商真实设备、多平台发布构建、聚合单包与第三方 pub 依赖应用
仍未在本次修复中完成验收。只能在维护者手动发布新 SDK 后，
用保持不变的第三方 Demo 做发布后回归。


---

## 标准页面与可组合组件

### 1. 完整页面

| 场景 | 公开入口 |
| --- | --- |
| 自动选择会议 / 直播 | `RealtimeRoomView(room: room)` |
| 会议 / 直播页面单独使用 | `RealtimeMeetingPage` / `RealtimeLivePage` |
| 独立产品聊天 | `RealtimeChatPage(chatRoom: chatRoom)` |
| 入会准备 | `RealtimePreJoinPage` |
| 房间页面配置 | `RealtimeRoomViewConfig` |
| 异步预加入回调 | `RealtimePreJoinEnter` |

```dart
RealtimeRoomView(
  room: room,
  config: RealtimeRoomViewConfig(initialMediaSettings: settings),
  onLeave: () => Navigator.of(context).pop(),
);
```

后端权威 `roomMode` 选择会议或直播，配置的模式仅作无元数据时的提示。
RTC 角色不能代替逻辑房主、教师或主播权限。默认麦克风和摄像头关闭；
预加入设备与媒体选择在准备完成、权限允许后应用。

Demo 的 Chat / Pre-Join 路由直接调用 SDK 页面；Meeting / Live 适配层只注入
本地背景图片及自定义挥手事件。断点、侧栏、手机弹层、浮动工具栏、聚焦/网格、
清屏、虚拟背景和录制交互均在 SDK 中维护。

### 2. 可组合组件与依赖边界

```text
Domain Core / Foundation
  ├─ Runtime                  会话、成员、功能插件、生命周期，无 UI/厂商依赖
  ├─ chat_ui                  独立聊天组件，不依赖 Media UI / RTC
  ├─ design_ui                设计系统
  └─ media_ui                 Media Core + design_ui + Flutter 组件
       ↑
room_ui                       房间作用域、媒体组件与控制器
       ↑
sdk_ui                        标准页面与可选 Classroom / Live / 共享内容组合
       ↑
App / Demo                    连接、路由、内容注入；也可自由组合组件
```

独立 UI 组件继续公开。完整页面和自定义布局共享相同会话与权威状态，
不需要复制业务操作或引入供应商实现。

- `RealtimeRoomUiScope` 清理它创建的 UI Controller，传入自建 controller 则由调用方释放。
- Room/Chat UI 卸载不关闭连接；显式离开操作先离开/关闭房间再回调导航，连接所有者最终调用 `connection.dispose()`。
- 完整预加入页面拥有并释放 `RealtimePreJoinController`；自行组合时由宿主初始化和关闭它。预览在入会前释放，失败后可保留选择并重试，过期操作不能触发晚到导航。
- Classroom/Live 是显式注册的可选插件，权限与快照以可信后端为准，瞬时消息不能授权。
- RTC Data 调试不等于产品 Chat；成员目录按 Runtime 的逻辑身份合并，媒体/Chat 管理能力分别判断。

### 3. 扩展与录制

通过 `header`、`participantBuilder`、`loadImagePresets`、
`onCustomReaction`、`stageOverlayBuilder` 以及功能可见性参数调整标准页面。
原子组件可以放入宿主的 `Row`、`Column`、`Stack`、抽屉或弹窗。

录制是否可用由注入的执行器决定，布局由后端报告，不维护厂商名字名单。
会议和直播共用启动/停止/结果流程。结果对话框展示中英文权威任务状态，
卸载或切换房间后失效旧查询，完成后才提供下载。
背景处理需要显式注册特效服务；不支持时展示原因，不能静默发布未经保护的帧。
