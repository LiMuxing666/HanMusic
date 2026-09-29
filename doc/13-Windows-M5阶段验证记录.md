# Windows M5 阶段验证记录

日期：2026-09-29。状态：**进行中，尚未达到 Windows MVP v0.1 或公开发行验收条件**。

本轮已取得真实万文件导入、实际页面 Profile 压力滚动、原生音频两阶段和打包路径保护的证据。滚动优化后 UI 帧耗时 p95 为 **22.414 ms**，仍高于计划的 **16.7 ms**；不因有明显改善而改记为达标。最终静态检查无问题，**231 项测试通过**。正常入口开发预览 ZIP 已生成，并通过本机完整性与启动进程检查；系统交互、干净机和发行门槛仍未完成。

## 1. 环境与证据范围

本机证据目录：`D:\dev\setup\verification\m5`。硬件来自 `hardware.json`，采集于 2026-09-29 20:55:21（UTC+8）。

| 项目 | 实际记录 |
| --- | --- |
| CPU | Intel Core i7-13620H，10 核 / 16 逻辑处理器 |
| 内存 | 16,890,519,552 字节，约 15.73 GiB 可见内存 |
| 磁盘 | UMIS RPEYJ1T24MKN2QWY，NVMe，1,024,209,543,168 字节 |
| 系统 | Windows 11 专业版，10.0.26200 / Build 26200 |
| 开发工具 | Flutter 3.41.9 / Dart 3.11.5；VS 2022 / MSVC 14.37.32822，沿用现有 D 盘开发配置 |
| Profile 窗口 | 约 1265.33×682.67 逻辑像素，devicePixelRatio 1.5，显示刷新率 165 Hz，文字比例 1.0 |
| Profile 测量稳定性 | 前后两次测量均无窗口 metrics 改变、无 lifecycle 事件，`frameworkErrors` 均为空 |

部分 Dart 进程 OS 字符串返回 “Windows 10 Pro”，与系统硬件查询的 Windows 11 名称不同；Build 均为 26200。这是本机记录口径差异，**没有因此完成另一台 Windows 10 机器的验证**。

这是装有开发工具的本机，不是无 Flutter、Visual Studio、JDK 的干净机器。以下不同测试各自说明执行模式，不能把测试进程、Profile 探针和最终 Release 包结果混为一类。

## 2. 真实万文件曲库操作

入口为 `tool/windows_m5_library_benchmark_test.dart`，原始结果为 `library-result.json`，执行日志为 `library-benchmark.txt`。测试通过实际文件系统与生产 `LocalLibraryRepository` 元数据 isolate 导入，不 mock 文件扫描和解析。

数据集是**同一段 0.1 秒、9,408 字节的合成 FLAC**复制成 10,000 个不同路径的真实文件，使用中文及空格目录/文件名，无封面，总音频字节数 94,080,000。准备这些文件耗时 34.910 秒，与导入耗时分开记录。

| 项目 | 本次结果 |
| --- | --- |
| 导入 | 24.201 秒；导入 10,000 条；解析降级 0，错误 0 |
| 进度反馈 | 10,001 次处理进度通知 |
| 重复目录扫描 | 7.307 秒；仍保持 10,000 条索引 |
| 搜索 | 相同指定关键词 50 次，p95 12.491 ms |
| 状态保存 / 读取 | 509 ms / 394 ms；文件 2,980,124 字节 |
| 源文件存在性检查 | 3.828 秒 |
| 取消响应 | 此次从发出取消到导入 Future 完成为 9 ms；保留 25 条已成功记录 |
| 移除索引 | 源文件仍存在，`removeIndexPreservesFile=true` |
| 进程内存 | 导入前 RSS 145.12 MiB；100 ms 采样峰值 210.06 MiB；不是 Dart heap 指标 |
| 结果 | `passed=true`，完成时间 2026-09-29 12:50:57 UTC |

这些数据验证受控文件集下的真实扫描路径，**不代表混合编码、长音频、嵌入封面或外置慢盘的完整曲库性能**。执行模式是 `flutter_test`，RSS 包含测试框架与解析进程开销，100 ms 采样可能漏掉短峰值。状态读取是同一进程内新建 store 后读取，不是完整应用冷启动；9 ms 也不是所有文件解析阶段的最坏取消时间保证。

## 3. 实际页面 Profile 滚动与优化结果

入口为 `tool/windows_m5_performance_probe.dart`，使用实际 `PlayerPage` 和曲库列表、生产主题/Controller；注入 10,000 条确定性的 **synthetic Song 索引**，不读取对应音频文件，也不做封面 IO、音频播放或网络加载。播放器使用空闲适配器。

两次均先预热 5 秒，再测量 30 秒。探针每个 vsync 调用 `ScrollController.jumpTo`，10 秒走完单向总长度，再反向移动，速度约 **77,962 逻辑像素/秒**。这是固定且极高速的跳转压力负载，**不是普通鼠标滚轮、触控板或拖拽交互**。测量中发生 3 次方向变化。

本轮列表变化包括按文字比例确定 `itemExtent`、把预取范围限制为一行、禁用没有草稿状态的列表行自动保活，并配套万条索引长距离跳转用例。以下以前后两份 JSON 的实测为准，没有通过降低曲库数量或更改滚动速度掩盖结果。

| 指标 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 实测时长 | 30.025 秒 | 30.003 秒 |
| 采样帧数 | 714 | 1,316 |
| 采样帧数 / 秒 | 23.78 | 43.86 |
| UI p50 | 29.866 ms | 14.653 ms |
| **UI p95** | **41.127 ms** | **22.414 ms** |
| UI p99 | 46.306 ms | 26.570 ms |
| Raster p95 | 4.338 ms | 4.051 ms |
| totalSpan p95 | 46.281 ms | 27.163 ms |
| 以 60 Hz 预算计的超预算帧 | 714 / 714（100%） | 442 / 1,316（33.59%） |
| 以本机 165 Hz 预算计的超预算帧 | 100% | 100% |
| 进程生命周期最大 RSS | 158.36 MiB | 153.59 MiB |

超预算定义为 UI build 或 raster 任一耗时超过相应帧预算；`totalSpan` 单独表示帧延迟，不与它们相加。165 Hz 对应约 6.06 ms 的显示预算；计划另以 60 Hz / 16.7 ms 对照。表内“采样帧数 / 秒”来自已采集帧及测量时长，不宣称是用户通常操作的稳定 FPS。

UI p95 在相同探针负载下下降约 **45.5%**，但最终 **22.414 > 16.7 ms**，目标仍未通过。每个版本这里各有一次测量，不把它解释为多轮统计置信结论。优化后没有追加已验证的性能变更；后续需要进一步定位 UI 构建开销，并同时测量正常人工滚动和更接近实际的曲库。不能修改验收口径把现有结果改为成功。

原始文件：

- `performance-before.json` 与 `performance-before-frames.csv`
- `performance-after.json` 与 `performance-after-frames.csv`
- `build-performance.txt` 与 `build-performance-after.txt`

注意 `result-m5-performance.json`、`frames-m5-performance.csv` 是探针通用输出名，可能保留某次运行内容；前后比较应使用已归档、明确标注 before/after 的文件。

## 4. 大字号与页面适配

本轮增加 1280×720、800×600 下的 200% 文字比例场景，并调整曲库/队列行高与侧栏文字布局；固定播放条、详情、队列及万条索引长距离跳转有对应 Widget 用例，已包含在第 7 节最终通过的 231 项测试中。

这些用例通过 `TextScaler.linear(2.0)` 改变文字比例，**不是把 Windows 系统 DPI 改为 200%**。本次 Profile 原生窗口的 devicePixelRatio 是 1.5，但只在这个配置采样，也不能替代 100%/150%/200% 系统缩放下的完整键鼠/窗口验收。

## 5. 打包保护与依赖材料

`tool/package_windows_preview.ps1` 每次强制以 `lib/main.dart` 重建 Release，复制完整运行目录、Flutter NOTICE、许可补充材料、运行说明、锁文件与哈希清单。当前只面向 `development-preview`，`publicReleaseReady=false`。

`tool/test_windows_packaging_guards.ps1` 在系统自带 Windows PowerShell 5.1 下的记录 `packaging-guards.txt` 显示 **9 项保护检查通过**，原包标记、外部目录标记及已有构建 EXE 保持不变。覆盖：路径名穿越、已存在产物、build 内输出、许可输入目录内输出、父级 junction、生成树内 junction、路径别名归一，以及 native stderr 的退出码 0/7 两种处理。日志中的两行 `warning-only` 是专门保留 stderr 的测试输入，不是打包失败。

脚本同时要求 9 份许可目录输入（8 份补充文本与 README）存在且非空。路径与错误退出保护通过，**不等同于最终 ZIP 已成功生成、已通过干净机运行或已完成法律发行条件**。

依赖审计和原文来源见 [Windows 依赖与分发检查](./11-Windows依赖与分发检查.md) 与 [补充许可目录](./licenses/README.md)。项目无根许可、原生完整对应源码及静态依赖材料尚未全部取得，公开发行门槛仍未满足。本轮没有自行添加项目开源许可，也没有升级音频后端依赖。

## 6. 最终音频两阶段证据

入口为 `tool/windows_m5_audio_probe.dart`，以 Windows Release 构建运行，使用生产 `JustAudioBackend` / `just_audio_media_kit` / `media_kit` Windows 原生解码。构建日志为 `build-audio-final.txt`。相同探针先以 `HANMUSIC_PROBE_PHASE=all` 运行，再以 `cold-network` 在新进程运行；最终结果如下，时间为 UTC。

| 阶段 | 原始结果 | 开始 / 完成 | 结果 |
| --- | --- | --- | --- |
| all | `result-m5-audio-all.json` | 13:17:38.985 / 13:18:03.313 | 12 项检查通过，`passed=true` |
| cold-network | `result-m5-audio-cold-network.json` | 13:18:05.219 / 13:18:05.816 | 3 项检查通过，`passed=true` |

两份最终 JSON 的 `startupFailures`、`frameworkErrors` 均为空，`fatalError=null`，235 秒 watchdog 均未触发。错误恢复用例中刻意制造的 `PlayerException` 单独记录，不能与非预期起播失败混算；本轮也没有进行泄漏压力测试。

### 6.1 六格式固定样本矩阵

样本通过 `tool/generate_m5_audio_fixtures.ps1` 生成，位于包含中文和空格的路径。`audio-fixtures.json` 与最终结果保存文件 SHA-256，生成工具为 FFmpeg 7.1 essentials；**该版本只描述测试样本生成工具，不是应用内 libmpv 的 FFmpeg 版本**。每种格式本次使用一个短合成样本。

| 扩展名 | 实际编码 / 容器 | 文件字节数 | 原生返回时长 | 播放 / 暂停 / seek / 完成 |
| --- | --- | ---: | ---: | --- |
| MP3 | MP3 / MP3 | 96,812 | 6,024 ms | 全部通过 |
| FLAC | FLAC / FLAC | 82,855 | 6,000 ms | 全部通过 |
| WAV | PCM signed 16-bit / RIFF-WAVE | 576,078 | 6,000 ms | 全部通过 |
| M4A | AAC-LC / MPEG-4-M4A | 74,620 | 6,021 ms | 全部通过 |
| OGG | Vorbis / Ogg | 35,489 | 6,000 ms | 全部通过 |
| AAC | AAC-LC / ADTS | 74,663 | 5,941 ms | 全部通过 |

各样本 seek 目标与观察值均为 1,200 ms，暂停稳定后的观察窗口内进度漂移均为 0 ms，原生 `playing=false`；每种格式收到 1 次完成事件。请求音量为 0.02。此矩阵验证这些具体编码/容器样本，不能扩展为所有采样率、损坏形态、编码变体或含 DRM 文件均支持。

坏文件在 54 ms 内受控失败，同一后端随后恢复播放，恢复后的暂停检查通过。混合队列自然推进为本地 MP3 → 网络歌曲 → 本地 M4A，手动上一首/下一首通过；过期 URL 解析 2 次后恢复，持续无效 URL 在 2 次解析上限后跳到本地项，队列仍保存本地 URI 与 `hanmusic://track/...` 逻辑身份。

### 6.2 冷/热起播事件计时

计时样本为同一份 6 秒、22,050 Hz、单声道 PCM s16le WAV，本地文件与回环 HTTP 返回相同字节，SHA-256 为 `a30a3f24ce3d1387bc1a1a8e94b21a5e3b5e77556ca92834bca04cfd13ab95fb`。计时从可选在线解析和 `backend.load` 之前开始，到同时满足播放状态与本次 play 后首个非零进度事件为止。后端对象、低音量准备、Flutter/进程启动及 load 前的设备初始化均不在计时内。

“冷”指新探针进程首次加载，未清理 OS 文件缓存；“热”指同一后端再次加载。网络每次重新解析临时地址，数据来自受控 loopback 服务，未测公网、TLS、认证或商业平台。

| 项目 | 总延迟 |
| --- | ---: |
| 本地冷：all 进程首次加载 | 247.949 ms |
| 本地 10 次热启动 p95 | 162.796 ms |
| 网络预热：已使用过本地后端的 all 进程 | 83.110 ms |
| 网络冷：单独 cold-network 进程首次加载 | 205.309 ms |
| 网络 10 次热启动 p95 | 176.535 ms |

20 次热启动总延迟原始样本（ms，保持测量顺序）：

| 次序 | 本地 | 回环网络 |
| --- | ---: | ---: |
| 1 | 51.065 | 176.535 |
| 2 | 123.989 | 140.150 |
| 3 | 123.896 | 172.114 |
| 4 | 162.796 | 156.835 |
| 5 | 125.556 | 75.129 |
| 6 | 112.380 | 171.016 |
| 7 | 120.848 | 129.446 |
| 8 | 108.182 | 156.460 |
| 9 | 116.528 | 126.697 |
| 10 | 135.831 | 176.490 |

p95 使用 nearest-rank 的 `ceil(0.95 × n)`，每组 n=10，因此本次 p95 等于组内最大值。本地中位数 122.372 ms，网络中位数 156.6475 ms。样本量有限，不能当作长时间运行的稳定上界。

统计边界：起播指标来自生产原生后端事件/进度，进度可能按后端时钟插值，**没有声卡回录或扬声器实际出声测量**；即使事件计时通过，也不能直接勾选计划中“输出音频”指标已完成。

`audio-initial-failure.json` 保留首轮调试记录：探针错误要求经 distinct 过滤的进度流每次重置都重新发送 0。修正探针假设后取得以上最终成功结果，本次没有为这个问题修改生产音频代码。

## 7. 最终全量测试与静态检查

本轮最终日志位于证据目录，命令及结果如下：

| 命令 | 结果 | 日志 |
| --- | --- | --- |
| `flutter analyze --no-pub lib test tool` | `No issues found!`，22.7 秒 | `analyze.txt` |
| `flutter test --no-pub --reporter expanded` | **231 项全部通过**，日志末行 `00:42 +231: All tests passed!` | `tests.txt` |

范围包含新增大字号/万曲跳转用例以及既有播放器、定时竞态、在线源、曲库与状态恢复回归。独立万文件 benchmark、原生音频探针和打包 guard 已分别记录，不混算为这 231 项测试。以上自动检查通过不替代真实系统 DPI、系统文件对话框、设备变化和干净机器验收。

## 8. 最终正常入口与预览 ZIP

系统自带 Windows PowerShell 5.1 执行 `tool/package_windows_preview.ps1`，内部强制运行 `flutter build windows --release --no-pub -t lib/main.dart`，构建耗时 110.6 秒，打包退出码为 0。日志为 `package-build.txt`。全量测试后没有修改应用生产代码；诊断入口覆盖的二进制已通过这次正常入口构建替换。

| 项目 | 本次产物 |
| --- | --- |
| 版本 | `0.1.0-dev.5+5` |
| 入口 / 架构 | `lib/main.dart` / Windows x64 |
| 渠道 | `development-preview`，`publicReleaseReady=false` |
| ZIP | `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.5-M5.zip` |
| ZIP 大小 | 20,449,418 字节 |
| ZIP SHA-256 | `330726635b27a8a44a42a9a1633f045ac507c94d136340e4b4dee7ebc5bcc59a` |
| 文件数 | 清单记录 32 个文件，加 `BUILD-MANIFEST.json` 共 33 个 |
| 清单 Git 状态 | `gitCommit=d712a555e3941218d07d3ee9f30ac70c021c9d5f`，`gitDirty=true` |

清单记录的是包含本轮 M5 尚未提交修改的工作区构建，不是这个 commit 对应的干净检出构建，也不是旧 M4 二进制。产物包含完整 Release DLL/data、展开的 Flutter NOTICE、补充许可目录、运行说明与便携数据启动器，未捆绑 Flutter SDK、JRE 或 VC++ 再分发包。运行库准备与步骤见 [Windows 预览运行与验收](./12-Windows预览运行与验收.md)。

最终使用系统 PowerShell **5.1.26100.9444** 执行 `tool/verify_windows_preview.ps1`，报告 `package-verification.json` 的 `passed=true`，日志为 `package-verification.txt`。ZIP 与相邻 `.sha256` 一致，32 个清单文件的字节数、SHA-256 和路径均通过，合计 **48,960,869 字节**；打包时没有包含 `UserData`。相邻哈希校验说明文件完整性，不是数字签名或发行者身份验证。

验证在 `D:\dev\tmp\hanmusic-m5-package-verification\验收 包 20260929-212510-278-3d62b2d5\展开 程序` 下解压，实际执行用户入口 `Start-HanMusic.cmd`，调用系统 PowerShell 并返回 0。新应用进程持续至少 8 秒存活且 `Responding=true`，报告总观察耗时 9,349 ms；默认创建包内 `UserData\online`。随后按本轮新 PID、精确 EXE 路径与进程启动时间复核身份，强制结束测试进程，应用和辅助进程清理结果均为 true。

该检查只验证本开发机上的完整解压、启动器和短时进程响应。**没有验证 GUI 操作、正常关窗、关闭持久化、播放、系统对话框、真实休眠、设备切换或干净机运行**；不能把强制结束进程视为原生关闭按钮/资源释放验收通过。

## 9. 保留的里程碑门槛

- 万曲压力滚动 UI p95 尚未达到 16.7 ms；真实常规滚动及带封面混合曲库负载仍需补充。
- 本地/网络起播尚未以声卡实际输出计时；音频设备变化仍待实机验证。
- 原生文件/目录对话框、最小化/恢复/正常关闭，前台和后台真实休眠/跨截止恢复仍待人工验收。
- 100%/150%/200% 系统 DPI 和真实键鼠操作待补；Widget 文字缩放不能替代。
- 无 Flutter、Visual Studio、JDK 的干净 Windows x64 环境，需要使用完整预览包回归本地/网络播放、定时、正常退出及重开。
- 项目发行授权/许可决定、原生完整对应源码与第三方通知、VC++ 运行库部署条件仍待闭合。

开发预览构建与 ZIP 检查通过后，仍保留上述未完成事项；不能仅凭最终构建或 ZIP 成功把 M5 或 Windows MVP 标记为完成。
