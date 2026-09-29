# Windows M4 验证记录

日期：2026-09-29。分支：`Windows_lmx`。基于 M3 `0435c11` 继续开发；用户确认按通用协议推进。本阶段完成匿名 JSON HTTP(S) 网络源的配置、测试、搜索、解析和播放核心，Windows MVP 尚未发布。

## 1. 环境与交付范围

- Windows 11 专业版 x64，Build 26200；Flutter 3.41.9、Dart 3.11.5，既有 Visual Studio 工具链和原生音频组合。
- 项目通过 `D:\project\HanMusic` 英文目录入口构建；SDK、Pub、Gradle、IDE 配置、应用数据与验证文件继续放 D 盘，本轮无依赖升级。
- `OnlineSourceConfig` schema 1、`OnlineMusicRepository`、`OnlineMusicService`、独立源配置主/备文件，以及在线导航/源编辑/连接测试/分页搜索页面。
- `Song.online` 稳定身份与 `AppSnapshot` schema 2，兼容 v1；本地和在线共用队列，重启保持暂停，首次播放才重新解析。
- 首次原生地址加载失败仅重新解析一次；API 请求不嵌套重试。源删除、鉴权要求、断连、超时、映射错误和整队失败均有安全提示。
- 额外修复慢解析阻塞手动切歌、编辑写盘期间新请求使用旧配置，以及定时暂停失败却先显示成功的问题。

协议、请求/响应与本地服务说明见 [网络源协议](./09-Windows网络源协议.md)。这里的测试源只生成测试音，不代表任何商业音乐平台已经接通。

## 2. 全量自动测试

在加载 `D:\dev\setup\Enter-HanMusic.ps1` 后，于英文项目入口运行：

```powershell
flutter analyze --no-pub lib test tool
flutter test --no-pub
```

结果：静态分析 `No issues found!`，**221 项测试全部通过**。全量测试输出结束于 `00:24 +221: All tests passed!`。不将并行运行时间或单次本机耗时作为性能达标结论。

覆盖包括：

- 配置版本/未知字段、同源路径、URL 账号信息、字段路径范围、参数编码、可选字段与坏条目降级。
- 真正的本地 HttpServer 请求：分页、HTTP 状态、禁止 API 重定向、响应体阶段超时、取消、2 MiB 上限、播放 URI scheme 校验与错误不泄漏地址。
- 500ms 防抖、旧查询/旧源返回丢弃、重复分页终止；测试先于保存、写盘失败保留原值、备份与新版只读保护。
- 编辑落盘期间发起搜索/解析、后续编辑排队的竞态；空关键词测试结果的限定提示保留。
- 在线源 ID/歌曲 ID 稳定性，v1→v2 文件迁移、混合队列恢复、拒绝把临时 HTTP 地址落盘。
- 解析失败不重试、原生加载失败仅重试一次、旧解析不阻塞新选择、迟到成功/错误失效、M3 定时优先级、暂停失败不误报成功。
- 页面中的源增改删/选择、连接失败修正、当前搜索列表建队列、加载更多与加入队列；800×600、1.5 字号的固定条和详情。
- 文档 JSON 与本地测试服务互通，以及 WAV、HEAD、Range/206/416、过期 ticket 后重解析。

原有本地曲库、元数据/封面、四种模式、持久化和睡眠定时测试也在同次全量回归中通过。

## 3. Windows 原生探针

入口：`tool/windows_m4_probe.dart`。使用与正常应用相同的 `JustAudioBackend`、Player、Timer、在线服务与文件存储，内嵌仅监听回环的 `OnlineFixtureServer`，以低音量加载生成的 WAV。探针分两个独立 Windows 进程运行：exercise 保存状态，restore 恢复状态并启用新的服务端口。

最终原生探针 Release 构建成功，两个进程退出码均为 0，**9 项检查全部通过**，Flutter/异步错误记录为空。

| 检查 | 实际观察 |
| --- | --- |
| 配置→搜索→分页→受控异常 | 2+1 首分页正常，空结果无错误；401、缺少列表和 2 秒总超时分别显示对应提示 |
| 混合队列播放与操作 | 在线→本地自然切换成功；暂停、1 秒 seek、音量 0.02 有效 |
| 失效地址重新解析与全坏停止 | `refresh` 解析恰好 2 次后播放；`broken` 恰好 2 次后停止，没有无限重试 |
| 解析期间倒计时到期 | 迟到的地址没有自动起播，最终显示“定时已停止播放” |
| 手动下一首不等待旧解析 | 旧解析延迟 3 秒，切到本地用时 343ms；旧地址返回后没有音频请求或抢回播放 |
| 在线歌曲结束优先于单曲循环 | 停在 6000ms 曲终位置；没有重新解析循环；等待后端暂停后显示成功 |
| 保存稳定身份与进度 | schema 2 保存在线+本地两项、2000ms 进度；state.json 不含 HTTP 地址和测试 ticket |
| 新进程恢复 | 不自动播放、不提前解析；2000ms 位置保留；更新相同源 ID 的端口后首次播放获取新地址 |
| 删除源 | 两项队列仍保留；关闭跳过时提示“该歌曲的网络源已删除，请重新配置或换一首。” |

原生测试中的失败 URL 带 `probe-only-*` 测试 ticket。最终四份 stdout/stderr 检查中 `probe-only` 及 `http://127.0.0.1:` 命中数均为 **0**。这验证应用/桥接控制台过滤仍保留错误恢复能力，不声明所有系统崩溃转储的日志行为。

音频状态与进度来自真实 Windows 原生后端，但未用麦克风或声卡回录测量实际扬声器输出。343ms 是单次切换观察，不是 M5 规定的十次起播 p95 验收。

复现（探针内有 4 分钟 watchdog，正常应远早于此结束）：

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
flutter build windows --release --no-pub -t tool/windows_m4_probe.dart --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-m4-probe
foreach ($phase in @('exercise', 'restore')) {
  $env:HANMUSIC_PROBE_PHASE = $phase
  $probeProcess = Start-Process -FilePath '.\build\windows\x64\runner\Release\han_music.exe' -WindowStyle Hidden -PassThru
  $probeProcess.WaitForExit()
  if ($probeProcess.ExitCode -ne 0) { throw "Probe failed: $phase" }
}
flutter build windows --release --no-pub -t lib/main.dart
```

## 4. 页面渲染

使用真实 Flutter Widget 渲染、中文字体与合成测试数据，检查在线列表、固定播放条和可滚动源编辑器。已验看：

- `1280x720-online.png`
- `800x600-online-large-text.png`
- `800x600-source-editor-large-text.png`

800×600、1.5 字号下，导航折叠为图标，播放条可达；结果列表可滚动；配置弹窗可滚动到测试关键词与“测试并保存”。编辑器截图取滚动后的底部，因此标题在截图之外。未发现影响主要操作的溢出。

这些图使用模拟业务数据，不展示真实第三方平台。它们验证 Flutter 排版，不替代 Windows 系统 DPI 或原生键鼠/窗口验收。

## 5. 正常入口与证据目录

最终执行 `flutter build windows --release --no-pub -t lib/main.dart` 成功，耗时 88.4 秒，已将诊断入口替换回正常应用。Release EXE 启动 8 秒后仍存活且 `Responding=true`，stderr 为 0 字节，继承的应用数据目录位于 D 盘。检查结束只终止本次启动的进程；这是启动冒烟检查，不计作原生关闭按钮或资源释放验收。

本次 EXE SHA-256：`F149A12C186B8206A7A9D584A3114E9CD64CAA8A206211CDD00E8EAD1CD8D7B1`。它仅标识本次开发构建；尚未整理 M5 发行 ZIP，不可脱离 Release 目录中的 DLL 和 data 单独分发。

本机证据归档：`D:\dev\setup\verification\m4`，包含全量测试日志、分析结果摘要、构建日志、两个原生结果 JSON、控制台日志及泄漏检查、三张页面图和系统环境信息。原始服务数据在 `D:\dev\tmp\hanmusic-m4-probe`；渲染脚本与图片在 `D:\dev\tmp\hanmusic-m4-preview`。生成音频、SDK、构建包与日志不进入 Git。

系统查询 `OsName` 为 Windows 11 专业版、`OsBuildNumber` 为 26200；注册表产品名兼容字段可能返回 Windows 10 Pro，因此个别 Dart 进程的 OS 名称字符串不同，不能据此视为完成 Windows 10 验证。

## 6. 保留的验收缺口

- M1/M2 原生文件与目录对话框、最小化/恢复/关闭窗口交互尚未通过实机验收。
- M3 前台/后台真实系统休眠，跨截止与不跨截止两种情况仍待验证；模拟时钟不替代真实电源事件。
- M4 没有用户指定公网服务或认证资料，只交付通用匿名协议和受控源；未知商业平台兼容性不在此结论中。
- M5 100%/150%/200% 系统缩放、更多音频格式/设备变化、万曲 Profile 性能、十次起播指标、许可证梳理和干净机器完整 Release ZIP 验收尚未完成。

下一阶段按 [Windows 计划 1.4](./05-Windows版本开发计划.md) 执行 M5，完成发行门槛后才标记 Windows MVP v0.1。
