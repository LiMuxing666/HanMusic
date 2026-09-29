# Windows M2 本地曲库与队列验证记录

> 日期：2026-09-29；分支：`Windows_lmx`；基线：M1 提交 `3fd4c6e`。
> 本记录区分自动测试、原生业务验证和未完成的系统窗口交互验收；不是 Windows MVP 发布记录。

## 1. 本轮实现

- 批量文件与递归目录导入、重复路径去重、进度显示和取消。导入只添加索引，点击歌曲才按当前搜索结果建立队列并播放；取消保留已经完成的曲目。
- 标题、歌手、专辑、时长及内嵌封面；解析失败使用文件名和占位封面。元数据在可终止的后台 isolate 读取，单文件默认 5 秒上限；目录扫描不递归跟随目录符号链接。
- 曲库搜索、缺失文件检查和灰显；删除操作只删除曲库/队列索引，不修改源文件。已导入后移动的文件需要刷新存在性，或由下次启动检查。
- 队列增删、重排、上一首/下一首、顺序、列表循环、单曲循环和随机模式。顺序模式自然结束停在末尾，遇到坏尾曲也不会绕回；显式上一首/下一首允许首尾环绕。随机按一轮候选袋选择，上一首回访历史。
- 默认自动跳过缺失或损坏歌曲，可在队列页关闭；全坏队列有限停止并提示。加载与播放意图分开编号，处理快速切歌、删除当前项、迟到错误和定时暂停的竞争。
- 保存曲库、队列顺序、当前曲目、位置、模式、音量和跳过设置。重启保持暂停就绪，第一次点击播放时再打开原生文件并 seek；睡眠定时不跨进程恢复。
- 曲库、正在播放、播放队列三页及固定底部播放条，保留 M1 的播放、进度、音量和简易睡眠定时能力。

## 2. 数据与缓存

生产入口优先使用绝对路径环境变量 `HANMUSIC_DATA_DIR`，未配置时由 `path_provider` 选择应用支持目录。本机已设置为 `D:\dev\data\HanMusic`，同时加入 `D:\dev\setup\Enter-HanMusic.ps1` 和本机 VS Code 环境；程序没有硬编码该路径。

| 文件/目录 | 用途 |
| --- | --- |
| `state.json` | 带 `schemaVersion: 1` 的当前状态 |
| `state.backup.json` | 上一次验证有效的完整状态 |
| `state.next.json` | 写入中的临时状态，完成后重命名为主文件 |
| `artwork/` | SHA-256 内容命名的提取封面；仅 PNG/JPEG，最多 4 MiB、4096×4096 |

写入串行执行，JSON 编解码在后台 isolate 完成，`save()` 等待写入与重命名完成。普通编辑合并 700 ms 后保存，播放位置每 5 秒保存一次，正常退出会等待最后写入。强制结束进程不能保证最后几秒进度保存。

主文件损坏时尝试有效备份；双文件损坏、数据目录不可访问或遇到较新 schema 时保留原文件，并提示本次更改不能保存。备份不用于覆盖较新版本数据。此实现没有多实例写入协调，多窗口同时运行的数据冲突处理留待发行阶段。

## 3. 自动验证

在英文入口 `D:\project\HanMusic` 执行，先加载 D 盘环境脚本：

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
flutter analyze --no-pub lib test tool
flutter test --no-pub
```

- 静态分析：无问题。
- 全量单元/Widget 测试：**119 项通过**。
- 默认 `lib/main.dart` Windows Release 构建成功；随后使用 D 盘环境启动正常应用，观察 8 秒进程存活且 `Responding=true`，stderr 为空。测试后只结束本次启动的进程；未将此过程计为窗口关闭验收。证据为本机 `D:\dev\setup\verification\m2\app-smoke.json`。
- 关键覆盖：真实 MP3/FLAC/WAV 标签与 MP3/FLAC 封面、递归/去重/链接、解析超时与取消、只删索引、四种模式、完成事件、坏文件终止、重排/删除当前项、暂停恢复、定时竞态、写入次序、损坏与较新 schema 保护、非法 file URI 回退备份、10,000 条索引往返。
- Widget 覆盖 1280×720、800×600、1.5 倍文字缩放；10,000 曲目列表采用虚拟化，首屏实际挂载少于 25 行并能滚动到底。文字缩放测试不等同于 Windows 系统 DPI 验收。
- 已人工查看真实 Flutter 测试渲染的曲库和队列页面，包含中文、缺失条目和固定播放条。画面使用明确标注的测试数据；未替代操作系统窗口验收。

测试夹具位于 `test/library/fixtures/`，均为本地生成短音调与纯色图片；生成参数见该目录 README，无需安装 FFmpeg 即可运行上述测试。

## 4. Windows 原生业务探针

`tool/windows_m2_probe.dart` 使用实际 `JustAudioBackend`、曲库、队列、持久化和页面，以两个独立进程验证保存与恢复。路径注入绕过系统文件对话框，解码状态/播放时钟不代表可听输出或设备切换验收。

Release 探针在 17:09（UTC+8）完成两次独立进程运行，**9/9 项通过**，两进程退出码均为 0，`frameworkErrors` 均为空，stderr 为空。

| 阶段 | 检查 | 结果 |
| --- | --- | --- |
| 首进程 | 递归导入、FLAC/MP3 中文标签、重复导入、歌手搜索 | 4 项入库；再次导入新增 0 项 |
| 首进程 | 自然完成事件推进队列 | Alpha FLAC 完成后进入 Beta MP3 |
| 首进程 | 坏文件跳过及终止 | 坏 WAV 后进入有效 WAV；全坏停止并提示 |
| 首进程 | 重排与 1 秒定时 | 当前曲目不变，索引变为 2；到期暂停 |
| 首进程 | 保存 | 保存 3 项队列、WAV 当前曲目、2 秒位置、列表循环 |
| 首进程 | 万条索引往返与搜索 | 10,000 条完整恢复，10 次查询结果正确 |
| 新进程 | 恢复且不自动播放 | 4 首曲库、3 项队列、2 秒位置、列表循环；暂停就绪且无旧定时 |
| 新进程 | 恢复后点击播放 | 原生时钟从保存位置推进至 2184 ms 后暂停 |
| 新进程 | 删除索引 | 曲库和队列移除目标项，源文件仍存在 |

本机证据文件：`D:\dev\setup\verification\m2\result-m2-write.json`、`result-m2-restore.json`；原始运行目录为 `D:\dev\tmp\hanmusic-m2-probe`。日志和性能 JSON 不进入源码仓库。

### 万条索引测量边界

硬件为 i7-13620H、15.7 GiB 内存、D 盘 UMIS RPEYJ1T24MKN2QWY NVMe，系统为 Windows 11 专业版 x64 / 10.0.26200（CIM 确认；Dart 原生字符串仍报告 Windows 10 Pro）。使用 Flutter 3.41.9 / Dart 3.11.5、Release 构建、10,000 条合成元数据索引、100 项队列、无封面；没有联网。此检查不涉及显示刷新率和帧采样。

| 指标 | 本次结果 |
| --- | --- |
| 主 JSON 大小 | 2,144,433 bytes |
| 保存（包括编码 isolate 与写入等待） | 88.209 ms |
| 新存储实例读取与解析 | 259.699 ms |
| 搜索 10 次逐次耗时（ms） | 5.462、6.324、5.625、5.459、5.430、5.462、5.432、11.548、5.537、5.481 |

这是一次开发机索引实验，不包含源文件存在性检查、真实目录元数据扫描、冷盘条件、峰值内存、可听输出或 UI/raster 帧计时；不能据此宣称 M5 性能验收完成。

### 复现

在独立目录 `D:\dev\tmp\hanmusic-m2-probe\fixtures` 用 FFmpeg 生成 3 个低音量音调文件与 1 个故意损坏文件。以下 `$ffmpeg` 为本机既有诊断工具路径，其他机器替换为自己的 FFmpeg：

```powershell
$probeRoot = 'D:\dev\tmp\hanmusic-m2-probe'
$fixtures = Join-Path $probeRoot 'fixtures'
New-Item -ItemType Directory -Force -Path $fixtures | Out-Null
$ffmpeg = (Get-ChildItem 'D:\dev\tools\audio-test\imageio_ffmpeg\binaries' -Filter '*.exe' | Select-Object -First 1).FullName
& $ffmpeg -y -f lavfi -i 'sine=frequency=440:duration=1.2:sample_rate=44100' -af volume=0.03 -metadata 'title=测试曲目 Alpha' -metadata 'artist=HanMusic Probe' -metadata 'album=Windows M2' -c:a flac (Join-Path $fixtures '01-alpha.flac')
& $ffmpeg -y -f lavfi -i 'sine=frequency=550:duration=4:sample_rate=44100' -af volume=0.03 -metadata 'title=测试曲目 Beta' -metadata 'artist=HanMusic Probe' -c:a libmp3lame (Join-Path $fixtures '02-beta.mp3')
& $ffmpeg -y -f lavfi -i 'sine=frequency=660:duration=30:sample_rate=44100' -af volume=0.03 -c:a pcm_s16le (Join-Path $fixtures '03-wave.wav')
Set-Content -LiteralPath (Join-Path $fixtures '90-bad.wav') -Value 'HanMusic intentionally invalid audio fixture.' -Encoding ascii
flutter build windows --release --no-pub -t tool/windows_m2_probe.dart --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-m2-probe
$exe = Join-Path (Get-Location) 'build\windows\x64\runner\Release\han_music.exe'
$first = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru -Wait
if ($first.ExitCode -ne 0) { throw 'Initial M2 probe failed; inspect result-m2-write.json.' }
$second = Start-Process -FilePath $exe -ArgumentList 'restore' -WindowStyle Hidden -PassThru -Wait
if ($second.ExitCode -ne 0) { throw 'Restore M2 probe failed; inspect result-m2-restore.json.' }
Get-Content -LiteralPath (Join-Path $probeRoot 'result-m2-write.json')
Get-Content -LiteralPath (Join-Path $probeRoot 'result-m2-restore.json')
# 诊断入口覆盖同一个 EXE，完成后必须还原正常应用入口。
flutter build windows --release --no-pub -t lib/main.dart
```

## 5. 尚未完成的验收

- 原生文件/目录对话框、最小化后播放、窗口关闭退出、系统 DPI 与键鼠实机操作。本轮桌面自动化连接再次失败，已停止重复连接；Widget 和诊断入口结果不替代这些项目。
- M5 的 M4A/OGG/AAC 格式矩阵、可听起播计时、音频设备切换、真实大目录扫描耗时/峰值内存、Profile 30 秒滚动帧耗时和无开发环境机器分发。
- 内嵌封面没有独立清理界面；删除索引不会立即删除缓存。其他平台未作验收。
- 网络源、完整睡眠定时（90 分钟、播完当前曲目、顺延）、歌单与历史仍属于后续阶段。

M2 核心能力已有对应验证，M1 系统交互缺口继续保留；下一阶段是 M3 完整睡眠定时。全部 Windows MVP 门槛通过前，不标记发布 v0.1。
