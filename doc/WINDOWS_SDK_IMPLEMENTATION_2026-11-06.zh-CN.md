# Windows SDK 功能补强与验收说明（2026-11-06）

> 范围：`flutter_multi_livestream_video` SDK 当前**开发工作树**，不是已发布的 `0.1.0-dev.27` 的新增功能声明。本轮在 macOS 开发环境完成代码补强、C++ 可移植单测和 Dart/组装检查。**没有 Windows/MSVC 原生编译及实际 RTC 双设备的成功证据，也未发布新包**。

## 一、覆盖范围与仍缺失的能力

| Windows 功能 | 当前实现状态 | 验证边界 |
| --- | --- | --- |
| LiveKit Meeting / Live RTC | Driver/Adapter 与 Windows WebRTC 原生轨道相关代码已有 | 需 Windows Release 编译、麦克风/扬声器/视频双设备验证 |
| Agora RTC Meeting / Live | Windows Driver、原生屏幕采集与外部视频帧插件代码已有 | 需校验 Agora Windows 原生 SDK 头文件、动态库与远端订阅 |
| Tencent TRTC Meeting / Live | Windows Driver、主屏幕共享、原生视频帧插件代码已有 | 需校验 TRTC 原生 SDK 和自定义采集开关、远端帧 |
| 处理后的视频 / 虚拟背景 | Media Foundation 摄像头 → PPHumanSeg ONNX → Blur/Replace BGRA → 单一 FrameHub → 三厂商 Native Sink | 原生 C++ Windows DLL 仍未链接验证；**不能把无报错预览等同于远端收到处理后画面** |
| Windows 屏幕标注 | Win32 顶层透明窗口、绘图/文本工具实现代码已有 | 多显示器、高 DPI、共享窗口捕获范围和实际直播叠加效果未验收 |
| ARTC / AWS Chime / AWS IVS RTC | **没有声明完整的 Windows Driver** | 本轮没有虚构可用驱动；需独立 Windows 原生/官方 Web SDK 桥接方案 |
| Agora Chat / Amazon IVS Chat | 无默认 Windows Chat Driver；Tencent Cloud Chat 有 Windows 声明 | 未补聊天原生厂商 SDK；不能将 RTC Data 回退等同为完整产品聊天 |

## 二、本轮实际代码修改

1. **高性能模糊算法：**`packages/flutter_realtime_processed_video/windows/include/processed_video_compositor.h` 改为行、列前缀和的分离式 box blur，单帧处理量不再随 8/16/24/32 模糊半径成倍增长。保持整数均值和 BGRA→RGBA 预览语义不变，不改 RTC Data 帧格式。
2. **隐私保护：**`packages/flutter_realtime_video_effects/windows/flutter_realtime_video_effects_plugin.cpp` 拒绝格式错误/未知的 effect 类型，不再悄悄切回未处理的 `none`；溢出整数配置被拒绝；替换图片在 WIC 转换前验证像素尺寸和压缩文件大小。
3. **异常恢复：**Windows Media Foundation 摄像头异常后，用户重新选择有效摄像头会先停止旧采集线程，再清空失败标志与 FPS 节流状态、重新启动新设备，避免永远黑屏。仍须在真实 Windows USB 热插拔场景验收。
4. **可运行的原生测试：**`packages/flutter_realtime_processed_video/windows/test/processed_video_blur_test.cpp` 将优化结果和旧实现逐字节比较，覆盖 1 像素边界、奇数尺寸、带 padding 的 BGRA stride、7 种半径；`windows/test/CMakeLists.txt` 将该测试与合成、FrameHub、I420 一起纳入 CTest。
5. **Windows CI：**`.github/workflows/windows-video-effects-smoke.yml` 增加三层真实 Windows 构建门禁：MSVC x64 + CTest；源码模块 Demo 的 Flutter Windows Release；已组装的单包 SDK 在全新独立 Windows 宿主中的 Flutter Release。校验 ONNX Runtime DLL、模型资产和 SDK DLL 是否随包输出。

## 三、验证结果与分层

| 检查 | 结果 | 证明什么 |
| --- | --- | --- |
| Clang++ C++17 / `-Wall -Wextra -Werror` | **4 项通过** | 可移植帧格式、Blur、FrameHub、I420 逻辑在 macOS 编译及运行；不是 MSVC |
| `flutter test --no-pub`（video effects） | **7 项通过** | Dart 桥 API、MethodChannel 协议、运行时加载与错误事件 |
| `python3 scripts/check_sdk_architecture.py` | **44 包结构检查通过** | 包依赖关系及 SDK Runtime 架构边界 |
| `python3 -m unittest scripts.tests.test_assemble_single_sdk_distribution -v` | **17 项通过** | 发布版单包包含 Windows 原生源码、各 Provider 注册、ONNX/许可资源及 CMake 配置 |
| Windows MSVC / `flutter build windows` | **待执行** | 源码级检查不能证明 MSVC SDK/CMake/厂商依赖链接成功 |
| ONNX 摄像头实时分割 + RTC 接收端比对 | **待执行** | 无摄像头设备和 RTC 远端回放证据，不能声称功能闭环 |

> CI 工作流需要提交/推送或手动 `workflow_dispatch` 后，在支持的 GitHub Actions Windows Runner 上执行。本次仅新增工作流文件，未执行、未推送。工作流首次运行若因厂商原生库、许可证或 MSVC 头文件失败，需要保留错误结果并针对实际日志修复，不可关闭门禁掩盖。

## 四、Windows 验收操作

Windows 10/11 x64、Visual Studio 2022（Desktop C++ + Windows SDK）、Flutter >=3.47、真实摄像头和两台终端。先执行：

```powershell
flutter pub get
flutter build windows --release
```

在 SDK 示例应用 `example/` 目录执行上述命令。调试 Windows 原生插件时使用 `example/build/windows/x64/runner/Release`，核对 `onnxruntime.dll`、`data/flutter_assets/packages/flutter_realtime_video_effects/assets/windows/pphumanseg.onnx`、媒体厂商 DLL。离线构建可使用 `REALTIME_ONNXRUNTIME_ROOT` 指向官方 ONNX Runtime x64 完整头文件、导入库及 DLL；不能跳过 SHA 校验或静默降级为无分割模型。

测试矩阵：**LiveKit / Agora / TRTC** 各做 Meeting 主持人和普通参会者、Live 主播和观众；每组测试摄像头与麦克风启停、屏幕共享（含多屏幕）、None/Blur/ReplaceImage、预览和另一台设备的实际像素、房间结束后的远端退出、断线重连、摄像头拔插、未找到 ONNX 模型后的不泄露原背景、两小时的内存和帧率稳定性。录制开始/停止/MP4 回看仍需服务端对应凭据。

**验收红线：**虚拟背景启用时若分割、模型、Provider Sink 或采集失败，必须拒绝处理后视频发布或停止发布，不允许偷偷退回未处理摄像头；设备关闭和应用退出必须停止采集并释放轨道。此要求需要从远端实际看到的帧、日志与进程资源联合确认。

## 五、尚未补齐的 Windows 项目

- 仍缺 ARTC、AWS Chime/IVS 的 Windows 完整媒体 Driver，以及 Agora Chat/IVS Chat 默认 Windows Driver。这些不应因修复虚拟背景而被标成 Windows 全供应商支持。
- 未在 Windows 真实设备上完成 MSVC 编译、ONNX 实时推理、所有厂商自定义轨道、Windows 多屏幕共享、扬声器及系统麦克风测试。
- 单包 `flutter_webrtc` 的自定义 Windows 视频轨道接口要与实际安装版本严格匹配，不能假定所有公网上游二进制都包含本仓库的扩展；Windows CI 的新宿主编译用于尽早暴露此类不匹配。
- 经过完整 Windows 门禁和多设备远端画面验收后，才能将这些项由“有代码”提升为“已验证”，并决定后续 dev 版本发布。

参见 [总能力矩阵](SDK_CAPABILITY_MATRIX.zh-CN.md) 与 [2026-11-06 当前能力审计](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md)。
