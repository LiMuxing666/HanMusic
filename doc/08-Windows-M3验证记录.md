# Windows M3 完整睡眠定时验证记录

> 日期：2026-09-29；分支：`Windows_lmx`；基线：M2 提交 `eb8c7f3`。
> 本轮交付本地播放器开发预览，M4 网络源与 M5 发行验收仍未完成。

## 1. 用户行为

| 操作 | 规则 |
| --- | --- |
| 预设倒计时 | 15 / 30 / 60 / 90 分钟 |
| 自定义倒计时 | 1–1440 的整数分钟；非法输入保持原任务不变 |
| 播完当前歌曲 | 绑定设定时的当前歌曲，完成后暂停；单曲循环也停止 |
| 暂停、继续、seek | 保留按曲结束任务；seek 到曲终仍按完成事件停止 |
| 手动切换歌曲或删除当前项 | 取消按曲结束任务，避免定时跟随到另一首；不取消普通倒计时 |
| 当前歌曲错误 | 按曲结束任务消费并阻止自动跳过；保留播放器错误提示 |
| 顺延 10 分钟 | 仅对未到期倒计时可用，在原截止时间上增加 10 分钟；不会复活已经过期的任务 |
| 取消、更换 | 同时只有一个任务；取消或新设定使旧的待处理到期通知失效 |
| 到期 | 暂停并保留当前曲目、队列和位置，显示“定时已停止播放”；不清空曲库 |
| 退出、重启 | 清理定时与监听，快照中不保存定时；重启保持暂停，不恢复旧任务 |

曲库版固定播放条直接显示剩余时间或“本曲结束”，定时图标高亮；面板支持取消、更换和顺延。按曲模式不伪造秒数，无可播放歌曲时禁用按曲结束选项。倒计时允许在无歌曲或暂停时设置，到期静默结束。

## 2. 实现与边界

`TimerService` 只管理模式、绝对截止时间与到期回调。`SleepTimerCoordinator` 将策略接到播放器的 `PlaybackGuard`，在完成、错误、自动推进和真正调用原生播放前同步检查时间，撤销过期的播放意图；周期 tick 尚未触发也不能先播放下一首。等待旧的原生暂停完成后，后续明确手动播放可以继续。

按曲结束使用后端完成事件，不以 `position >= duration` 推断。当前桥接库可能在完成时发出零位置；服务保留曲终位置，用户再次播放才回到起点。

Windows runner 新增 `WM_POWERBROADCAST` 处理，注册恢复通知，经 `hanmusic/power` MethodChannel 通知 Dart 重新检查截止时间。转发在插件分发之前完成，插件仍可接收原消息；自动恢复与用户恢复的重复通知由幂等到期逻辑处理。销毁窗口时注销系统通知，退出时移除 Dart 处理器。

采用独立电源通道的原因：Flutter `resumed` 在桌面端表示可见且获得输入焦点，不能涵盖所有系统唤醒；Windows 可在没有用户交互时发送恢复事件。保留周期和窗口恢复检查作为补充。依据：[Flutter 生命周期](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)、[Microsoft WM_POWERBROADCAST](https://learn.microsoft.com/en-us/windows/win32/power/wm-powerbroadcast)、[PBT_APMRESUMEAUTOMATIC](https://learn.microsoft.com/en-us/windows/win32/power/pbt-apmresumeautomatic)。

应用不阻止休眠、不安排系统唤醒，也不保证睡眠期间继续播放或精确暂停；只在进程恢复执行后依据墙钟检查过期。系统时间被手动调整会相应改变剩余时长。模拟通知不能证明实际设备电源行为已验收。

## 3. 验证

基线：Windows 11 专业版 x64 / Build 26200，Flutter 3.41.9 / Dart 3.11.5，VS 2022 C++ 工具链。仍通过英文入口构建，SDK/Pub/Gradle/临时目录和应用数据保持 D 盘配置。本轮无新增第三方依赖，不改状态 schema。

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
flutter analyze --no-pub lib test tool
flutter test --no-pub
```

- 静态分析：无问题。
- 仓库全量单元/Widget 测试：**141 项通过**。包含原有 M1/M2 回归，以及四种模式下按曲停止、完成与截止的两种顺序、坏曲不跳过、长加载返回后禁止起播、原截止时间顺延、已过期不可复活、模式替换、手动切歌/删除、迟到原生暂停和退出清理。
- Windows 通道测试注入平台消息，验证后台恢复后超期仅触发一次、未超期只更新剩余时间，以及未知消息/已注销监听不触发操作。这是 Dart 消息分发测试，不是实际 OS 电源事件测试。
- UI 验证覆盖 90 分钟、按曲结束、顺延、更换、取消、到期提示，以及 1441 分钟/极大整数/超长数字拒绝而不替换原任务，1440 分钟可接受。
- 额外临时 Flutter 渲染检查通过，并人工查看 1280×720 曲库按曲结束状态和 800×600 / 1.5 倍文字缩放的定时面板顶部与底部。图片位于本机 `D:\dev\tmp\hanmusic-m3-preview`，采用标明的生成测试数据，面板可滚动且操作区可见；不作为 Windows 系统 DPI 验收。
- 原生 Release 诊断入口：**6/6 项通过**，退出码 0，`frameworkErrors` 为空，stderr 为空。证据保存在 `D:\dev\setup\verification\m3\result-m3.json`，原始运行目录为 `D:\dev\tmp\hanmusic-m3-probe`。

| 原生检查 | 观察 |
| --- | --- |
| 单曲循环中播完当前停止 | 1.2 秒 FLAC 在 1200 ms 停止，设定后额外 native load 为 0，队列保留 |
| 取消按曲定时 | FLAC 自然完成后进入下一首 MP3 |
| 手动下一首 | 旧按曲任务取消，下一首正常播放 |
| 顺延与模拟恢复 | 原截止时间加 10 分钟；原时刻不暂停，扩展后到期暂停，保留 WAV 位置 271 ms 与队列 |
| 已过期时自然完成 | 设定后额外 native load 为 0，当前歌曲未变 |
| 更换待处理的到期通知 | 新任务保持有效，旧通知没有暂停播放 |

上述探针使用真实原生音频后端，墙钟与 lifecycle resumed 在检查中受控注入；没有调整系统时间或让用户电脑休眠。

最后已重新构建默认 `lib/main.dart` Windows Release 入口并启动，观察 8 秒进程存活、`Responding=true`、stderr 为空，继承数据目录 `D:\dev\data\HanMusic`。测试结束只停止本次进程，不把此操作计为正常关闭按钮验收。证据为 `D:\dev\setup\verification\m3\app-smoke.json`。可运行目录仍为 `build\windows\x64\runner\Release`，运行时保留完整 DLL 与 data 目录。

### 原生诊断复现

`tool/windows_m3_probe.dart` 使用实际 `JustAudioBackend` 和生成的低音量 FLAC/MP3/WAV；外层装饰器统计原生 load 调用，检查到期后未加载下一首。声音输出、设备切换、操作系统真实休眠不在此探针断言范围。

使用 [M2 记录](./07-Windows-M2验证记录.md) 的 FFmpeg 命令准备音调夹具，复制到独立 M3 目录：

```powershell
$probeRoot = 'D:\dev\tmp\hanmusic-m3-probe'
$fixtures = Join-Path $probeRoot 'fixtures'
New-Item -ItemType Directory -Force -Path $fixtures | Out-Null
foreach ($name in @('01-alpha.flac','02-beta.mp3','03-wave.wav')) {
  Copy-Item -LiteralPath (Join-Path 'D:\dev\tmp\hanmusic-m2-probe\fixtures' $name) -Destination (Join-Path $fixtures $name)
}
flutter build windows --release --no-pub -t tool/windows_m3_probe.dart --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-m3-probe
$exe = Join-Path (Get-Location) 'build\windows\x64\runner\Release\han_music.exe'
$probe = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru -Wait
if ($probe.ExitCode -ne 0) { throw 'M3 probe failed; inspect result-m3.json.' }
Get-Content -LiteralPath (Join-Path $probeRoot 'result-m3.json')
# 诊断程序与正常入口共用输出目录，结束后必须还原正常应用。
flutter build windows --release --no-pub -t lib/main.dart
```

探针在需要检查到期边界时只推进注入的时钟，不修改 Windows 时间，也不令机器休眠。

## 4. 尚待实机验收

- 前台和最小化两种窗口状态下真实休眠：未跨截止后继续计时，跨截止恢复后暂停；检查自动唤醒和用户唤醒通知的设备实际行为。
- M1/M2 遗留的原生文件/目录对话框、最小化持续播放、关闭按钮退出与资源释放；系统 DPI 与键鼠操作。
- M5 音频格式/设备矩阵、Profile 帧耗时、真实万曲扫描、无开发工具机器运行、原生库更新与许可证。

这些缺口不会因单元测试、Flutter 渲染或注入生命周期通知通过而被勾选。下一阶段为 M4 网络源配置协议、受控测试服务、搜索与流播放。
