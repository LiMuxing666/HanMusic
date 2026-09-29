# Windows M1 单曲原型验证记录

验证日期：2026-09-29。分支：`Windows_lmx`。本记录对应 M0 环境收尾与 M1 单曲原型，不代表 Windows MVP v0.1 已发布。

## 环境与选型

- Windows 11 x64，系统报告 Build 26200；Flutter 3.41.9 / Dart 3.11.5。
- 复用 Visual Studio 2022 C++ 桌面工具链，构建从 `D:\project\HanMusic` 英文入口进行。
- 开发者模式注册表值为 1，真实 SymbolicLink 创建成功；原生插件已完成 Release 编译和运行。
- SDK、Pub、Gradle、IDE 配置与测试工具保持 D 盘约定，详见 [开发环境](./04-Windows开发环境.md)。

| 用途 | 本次锁定版本 |
| --- | --- |
| 状态、路由、依赖注入 | get 4.7.3 |
| Windows 系统文件选择 | file_picker 13.1.0 |
| 播放器接口 | just_audio 0.10.6 |
| Windows 播放桥接 | just_audio_media_kit 2.1.0 |
| 原生音频库 | media_kit_libs_windows_audio 1.0.9 |
| 传递依赖 | media_kit 1.2.6；完整依赖以 pubspec.lock 为准 |

初始化顺序为 Flutter binding → `JustAudioMediaKit.ensureInitialized(windows: true, linux: false)` → PlayerService/TimerService → GetMaterialApp。UI 经 PlayerController 调用业务服务，实际播放器被 AudioBackend 接口隔离。

## 已实现范围

- 系统选择单个本地音频，取消选择保留当前歌曲；展示文件名、格式、路径和解码时长。导入成功后自动播放。
- 播放、暂停、完成后重新播放；拖动进度时先预览，释放后 seek；应用音量控制。
- 15/30/60 分钟及自定义正整数分钟定时，显示剩余时间、取消和到期暂停；恢复应用时检查绝对截止时间。
- 空态、加载禁用、用户可读错误及重新导入恢复；关闭应用释放播放器。
- 1280×720、800×600 与 1.5 倍字号布局测试。标题使用文件名，封面为占位；没有伪造曲库或搜索数据。

M2 的批量导入、元数据、曲库、队列、四种模式及持久化尚未实现。M3 的 90 分钟预设、播完当前曲目、顺延与完整休眠验收也不在本原型完成范围内。

## 自动验证与业务链路

- `flutter analyze --no-pub lib test tool`：No issues found。
- `flutter test --no-pub`：43 项通过（服务/控制器/定时器 34 项，Widget 9 项）。覆盖加载中定时到期、关闭、迟到错误、错误后原生暂停与重新导入排序，以及定时取消、替换、恢复与异常回调。
- 默认 `lib/main.dart` 的 Windows Release 构建通过；启动后观察 8 秒，进程保持运行且 stderr 为空。随后终止本次测试进程，这不是关闭按钮的交互验收。记录位于 `D:\dev\setup\verification\m1\main-smoke.json`。
- `tool/windows_app_probe.dart`：正式 PlayerService → PlayerController → PlayerPage 与实际原生音频后端集成，9/9 通过，无 Flutter framework 错误。
- 业务链实测 WAV/MP3/FLAC 导入及自动播放、暂停/seek/继续、1 秒定时约 1031ms 后暂停、取消后继续、损坏文件禁用播放、重新导入恢复。
- 正式页面运行期间连续观察 30 秒，音频位置推进约 29.98 秒。`result-app.json` 未记录 hidden/resumed 生命周期事件，因此此项只算连续播放，**不算最小化验收**。

桌面自动化连接未能建立：`list_windows` 超时，重试时 app-server 退出，重置连接后再次超时。按工具恢复边界停止重试，没有通过其他方法伪造点击结果。原生文件对话框、最小化/恢复和实际关闭按钮仍需补验；M1 在计划中保留这些未完成门槛。

另外使用真实 Flutter Widget 渲染导出了 1280×720 空态/载入态及 800×600 载入态 PNG，加载微软雅黑与 MaterialIcons 后检查中文、图标和排版。1280×720 完整显示；800×600 播放器完整可用，定时卡需向下轻微滚动，没有布局溢出。文件位于 `D:\dev\tmp\hanmusic-preview`，数据来自测试替身；这些图是布局预览，不是实际音乐播放截图。

## 原生后端实测

独立入口：`tool/windows_audio_probe.dart`。使用自动生成的低幅度正弦波 WAV，以及同源 MP3/FLAC，播放器音量为 0.01；没有读取用户音乐。2026-09-29 16:20 的修复后运行结果为 **9/9 通过，进程退出码 0**。

| 检查 | 观察结果 |
| --- | --- |
| WAV / MP3 / FLAC | 解码时长约 4 秒；播放推进、暂停、seek 到 1 秒、音量设置、自然结束均通过 |
| 中文与空格音频路径 | 解码和全部播放控制通过；源码中文路径构建问题与音频路径支持分别验证 |
| 同实例切换音源 | 两个音源均推进，第二首从新的播放位置开始 |
| 本地 HTTP 直链 | 受控 loopback 服务收到请求，解码及播放控制通过 |
| 损坏文件 | 生产适配器约 55ms 返回解码错误，同一个适配器重新加载有效 WAV 后可播放 |
| 不可达 URL | 约 5.1 秒返回连接错误，同一个适配器随后恢复播放 |
| 播放中释放资源 | dispose 完成后可重命名测试文件，无文件占用 |

原始结果在本机 `D:\dev\tmp\hanmusic-audio-probe\result.json`。暂停观察先等待原生位置回填稳定，再独立连续观察至少 700ms；本次持续区间漂移为 0ms。不能直接用 `pause()` 返回瞬间的位置作为静止基线，桥接事件可能稍后回填原生位置。

### 发现并处理的问题

`just_audio_media_kit 2.1.0` 的原生错误监听会发布错误事件，却不结束待完成的加载 Future。首轮损坏文件和无效 URL 均触发了探针 12 秒超时。生产 JustAudioBackend 现在并行等待加载与错误事件，另以 15 秒超时兜底；失败时 stop 释放原生实例，下次导入重新创建。修复后上述两个用例均由实际错误事件结束，没有用探针超时冒充正常错误，也不代表上游库本身已修复。

服务层通过加载代次与播放意图，防止迟到的加载结果覆盖错误、定时暂停或应用关闭。运行中遇到音频错误会请求实际暂停，并在新导入前等待错误暂停完成，避免 UI 已停止而原生音频继续播放。

## 复现方式

所有命令在英文工程入口执行，先加载本机环境脚本：

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
flutter pub get --enforce-lockfile
flutter analyze --no-pub lib test tool
flutter test --no-pub
```

准备测试目录和两个压缩格式样本。`ffmpeg` 指向本机测试工具目录中的实际 EXE；其他机器也可以使用自行准备的约 4 秒测试音频。不要使用重要文件作为诊断样本。

```powershell
$probeDir = 'D:\dev\tmp\hanmusic-audio-probe'
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
$ffmpeg = (Get-ChildItem -LiteralPath 'D:\dev\tools\audio-test\imageio_ffmpeg\binaries' -Filter '*.exe' | Select-Object -First 1).FullName
& $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:duration=4:sample_rate=44100' -af 'volume=0.03' -c:a libmp3lame "$probeDir\sample.mp3"
& $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:duration=4:sample_rate=44100' -af 'volume=0.03' -c:a flac "$probeDir\sample.flac"
flutter build windows --release --no-pub -t tool/windows_audio_probe.dart --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-audio-probe
& '.\build\windows\x64\runner\Release\han_music.exe'
```

服务、Controller 与页面的真实原生链路使用第二个诊断入口，生成较长 WAV 并写入 `result-app.json`。它绕过系统文件对话框，使用固定样本选择器，不能替代原生文件选择器验收。

```powershell
flutter build windows --release --no-pub -t tool/windows_app_probe.dart --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-audio-probe
& '.\build\windows\x64\runner\Release\han_music.exe'
```

诊断入口覆盖相同构建输出目录。交付前必须恢复默认应用入口：

```powershell
flutter build windows --release --no-pub -t lib/main.dart
& '.\build\windows\x64\runner\Release\han_music.exe'
```

## 发行边界

- 自动化证明了原生解码、时钟与状态控制，不能代替人工扬声器听感验收。
- 原生文件对话框的选择/取消、最小化后继续播放、恢复窗口后的进度以及关闭窗口退出，尚无本次实机 UI 验收证据。
- 音频设备切换/拔出、系统实际睡眠恢复、长时间播放和干净 Windows 机器运行仍需专项验证。
- 当前原生包为 unlisted 包，固定下载 2023-09-24 的 libmpv 构建；M5 前需评估更新与许可证，不视为最新音频库。
- 当前只对 MP3、FLAC、WAV 完成原生格式验收；选择器也允许 M4A、OGG、AAC，但这些格式尚无本次实测承诺。
- 分发必须保留整个 Release 目录，包括 `flutter_windows.dll`、`libmpv-2.dll`、`media_kit_libs_windows_audio_plugin.dll` 和 `data`。不只复制 EXE。
- HTTP 检查仅为受控直链解码验证，网络源配置、搜索、鉴权和在线播放界面属于 M4。

参考：[just_audio](https://pub.dev/packages/just_audio)、[just_audio_media_kit](https://pub.dev/packages/just_audio_media_kit)、[media_kit_libs_windows_audio](https://pub.dev/packages/media_kit_libs_windows_audio)、[file_picker](https://pub.dev/packages/file_picker)。上述缺陷以本次锁定版本本地源码和运行结果为依据。
