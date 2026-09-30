# Windows M5 队列焦点与样式实验

日期：2026-09-30。基线提交 `ea5e4a6`。本轮修复队列键盘反馈，并单独评估曲库文字样式的构建成本。证据目录为 `D:\dev\setup\verification\m5-text-queue`；SDK、Pub、Gradle、临时文件及产物继续沿用 D 盘配置，没有升级依赖。

## 1. 队列标题的可见焦点

原队列行使用不透明 Container 绘制背景，标题 InkWell 的最近 Material 位于背景下面。用 Tab 能聚焦标题并按 Enter 播放，但焦点和鼠标悬停的墨水反馈被背景遮住。用户无法可靠辨认键盘当前操作目标。

在标题 InkWell 外增加局部透明 Material，使反馈绘制在行背景之上。行背景、圆角、尺寸、外层歌曲 ID Key、播放与重排逻辑保持原行为。

新增四项 Windows 平台 Widget 回归，覆盖 1280×720 / 100% 与 800×600 / 200% 字号下的 hover 和键盘焦点。测试捕获整个页面的真实绘制像素，断言高亮可见，并确认 Enter 只加载、播放目标歌曲一次；键盘场景还验证重排后同一 FocusNode 保留、激活目标仍为同一歌曲。

旧代码四项均在高亮像素不变处失败，证据为 `before-fix-tests.txt`。修复后新增四项、既有五种布局和队列移除重排一项共 **10 项通过**，见 `after-fix-tests.txt`、`queue-summary.json`。这些是 Flutter 框架内输入和绘制验证，不代替真实 Windows 键鼠或系统 DPI 验收。

## 2. 曲库样式实验

本轮没有引入跨行 TextPainter/原生段落缓存。当前 Flutter 的 RenderParagraph 独立持有私有 TextPainter；跨行复用需要另行实现排版、绘制、语义、字体失效和资源回收。现有 CPU 样本只能提示文本布局/组件挂载路径，不能把仅有单帧原生栈的堆分配归因到字体 shaping，也不能据此宣称缓存收益。

小范围候选仅在列表构建时从 Theme.bodyMedium 预合成标题、当前标题、副标题、元数据和时长样式，设置 `inherit:false` 后供各行复用。保留原 Text 处理缩放、无障碍覆盖与语义，不改变文字、列、行高、缓存范围和焦点保活。该候选只尝试减少 TextStyle 合并，不声称减少原生段落布局；它绕过行内 AnimatedDefaultTextStyle 的中间过渡值，收益不足时不保留这项行为差异。

A/B 均从本轮队列修复后的相同源码构建，唯一产品差异为样式候选；两次构建均使用未修改的 `tool/windows_m5_performance_probe.dart` 和相同输出编译常量。完整目录分别冻结至 `D:\dev\tmp\hanmusic-m5-text-ab\baseline`、`candidate`，正式测量通过已校验的 `tool/run_windows_performance_probe.ps1` 串行执行，期间不运行构建、测试或 CPU collector。

两次 Profile 构建仍使用 `0.1.0-dev.7+7` 构建号，耗时分别 86.2 / 80.7 秒；最终产品另以 dev.8 正常入口打包。完整目录各 16 个文件，只有 `data/app.so` 不同：A 为 `549497eb3d3aeb1947d998ac05f9775e1547e81a004340f7215e27a55c266254`，B 为 `f1f4b933068a49c9dff27fae173572300c42c33e273cdb834921e20642867fda`。探针 SHA-256 仍为 `dded3b5664cecaa22b459e2a1ca3c9912f9a78effd104afab3ec12f5155437ce`。

测试机为 Windows 11 专业版 10.0.26200、i7-13620H（10 核 / 16 逻辑处理器）、约 15.73 GiB 可见内存、UMIS RPEYJ1T24MKN2QWY 磁盘；Flutter 3.41.9 / Dart 3.11.5。保持 10000 条无封面合成索引、5 秒预热、30 秒采样、10 秒单程的逐 vsync `jumpTo` 压力负载。所有运行均自行退出且退出码为 0，`validCapture=true`，CSV 复算一致，无框架错误、metrics 变化或生命周期事件。

| 顺序 | UI p95 (ms) | raster p95 (ms) | 帧数 / 实际秒数 | 采样 FPS | 超过 60 Hz 预算 | 峰值采样 RSS (MiB) | CPU 前 → 后 (%) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A1 | 14.392 | 3.653 | 1685 / 30.017471 | 56.13 | 0.59% | 151.51 | 15 → 24 |
| B1 | 14.045 | 3.667 | 1728 / 30.017477 | 57.57 | 1.16% | 152.81 | 12 → 28 |
| B2 | 14.476 | 3.915 | 1724 / 30.002350 | 57.46 | 1.57% | 150.89 | 12 → 31 |
| A2 | 14.399 | 3.794 | 1719 / 30.003335 | 57.29 | 1.40% | 151.97 | 26 → 19 |
| 旧二进制对照 | 13.978 | 3.766 | 1708 / 30.005511 | 56.92 | 1.35% | 152.07 | 15 → 12 |

五次逻辑窗口均为 1265.333×682.667、DPR 1.5、165 Hz、文字倍率 1.0；最大 extent 779620.333 logical px、速度 77962.033 logical px/s、三次方向改变。A/B 实际采样距离 2335783.215–2338333.431 logical px，离散首尾帧造成少量差异。CPU 只是系统前后快照，不是整个窗口或应用自身 CPU 占用。

**撤回样式候选，保留队列修复。** B 的 p95 范围与 A 重叠，B2 高于两次 A，未证明稳定收益；不为这一差距保留额外样式类及动画行为差异。原始补丁 `styles-candidate.patch`、两份冻结产物、`a-source.json` / `b-source.json`、完整文件哈希、帧 CSV 和会话记录均保留在 D 盘。

本轮五个短窗口的 UI/raster p95 均低于 16.7 ms，但不能把比上一轮变快归因于新代码。最后一次特意重跑 [上一轮](./17-Windows-M5滚动性能复核.md) 的原始 dev.7 二进制，`app.so` SHA-256 仍为 `f7bb4dcc92aa656dd7ffc15e9d3c6084571d45e4665892d2729d55df0ebe50f2`；它此前为 26.196–26.444 ms，本次为 13.978 ms。跨轮差异的具体系统因素未定位，不能仅靠两次 CPU 快照解释。保留本次达到阈值的事实，也保留历史失败及跨时段稳定性问题；这不是所有真实曲库或原生鼠标滚动都达标的结论。

A/B 摘要为 `ab-summary.json`，额外对照为 `historical-control.*`；测量期间没有测试、构建或 CPU profiler 并发，也没有改变系统设置。

## 3. 最终验证与预览

撤回样式候选后的全量 `flutter test --no-pub --reporter expanded` **283 项通过**（40 秒）；`dart analyze lib test tool` 无问题，`dart format lib test tool` 检查 78 个文件、无格式变化。日志为 `tests-final.txt`、`analyze-final.txt`、`format.txt`。最终产品差异只有队列标题局部 Material 及版本号，曲库行恢复原有样式处理。

从干净提交 `cfe094d76228a3b1ba0a7958529ecd3c64f57c99` 重建正常入口 `lib/main.dart` 的 Release（102.8 秒），生成 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.8-M5.zip`。版本为 `0.1.0-dev.8+8`，ZIP 大小 **20,474,532 字节**，SHA-256 为 `35e198b45fe6b287e293a285cffa4a79ea91e07e883877d0ccc99e1b7f86b02f`。32 个内容文件加清单共 33 个文件，`gitDirty=false`、`channel=development-preview`、`publicReleaseReady=false`；正常应用的 `data/app.so` SHA-256 为 `29388363ce57e28f437388fb29a178411217d6a8cef283db2459fe9816aaf1f1`，未将性能探针打入预览包。

通过系统 PowerShell **5.1.26100.9444** 执行 `tool/verify_windows_preview.ps1 -CheckDataDirectoryLock`，在 D 盘独立中文、空格路径解压后验收通过：ZIP 校验和及全部内容文件哈希一致，包内没有 UserData；经 `Start-HanMusic.cmd` 启动后持续八秒响应，启动器退出码为 0，数据写入包内 D 盘 UserData。运行时文件范围锁产生预期 Win32 错误 33；核对 PID、EXE 路径及启动时间后终止本轮测试进程，首次重试即重新取得锁（21 ms），测试进程与启动辅助进程均已清理。

构建日志为 `package-dev8.txt`，完整验收报告归档为 `package-verification-dev8.json`，原始报告保留在 `D:\dev\tmp\hanmusic-m5-dev8-package-verification\验收 包 20260930-133344-048-b37d9e9f\verification.json`。本次是开发机上的完整性、启动响应及目录锁验证；强制终止不代表正常关窗或持久化验收，锁冲突不代表第二实例 UI 验收，也没有执行页面播放或干净机器测试。

万曲 16.7 ms 目标与跨时段稳定性、物理出声/完整页面起播、原生窗口与文件对话框、真实休眠/设备变化/系统 DPI、干净机器及发行许可门槛仍按 [开发计划](./05-Windows版本开发计划.md) 执行。
