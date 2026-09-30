# Windows M5 进程音频输出测量

日期：2026-09-30。基线 `241551e`，产品仍为 `0.1.0-dev.7+7`。本轮补充诊断与验收证据，不升级音频依赖，不改变产品入口。SDK、Pub、Gradle、临时数据与证据继续使用 D 盘；本机环境沿用 [开发环境](./04-Windows开发环境.md)。

## 1. 测量范围

此前 [六格式与起播验证](./13-Windows-M5阶段验证记录.md) 测量的是播放状态和进度事件，不能据此判断是否已产生输出 PCM。本轮新增仅供诊断使用的原生 DLL，通过 Windows 进程回环接口限定为加载它的当前进程树；不接受任意目标 PID，不回退到系统混音或麦克风，不保存原始音频数据。微软说明该接口可限定进程树，且不绑定特定输出端点，所需系统版本为 Build 20348 或以上；本机 Build 26200 满足该接口条件。[微软进程回环说明](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)

探针调用生产 `JustAudioBackend` 与 `OnlineMusicService`，播放同一份 6 秒、22,050 Hz、单声道 s16le WAV，440 Hz 合成音，源采样峰值 1,000 LSB；最终诊断应用音量为 0.2，不修改系统音量或默认设备。网络样本通过本机回环 HTTP 服务和通用源协议解析，不代表公网、TLS 或商业音乐服务。

原生回环按 48,000 Hz、双声道 s16 统计，检测条件为 `abs(sample) > 1`，即超过 1 LSB。无播放的原生自测也观察到最大 1 LSB 的量化噪声，因此这里的静默指不超过阈值，不是每个采样严格为零。计时在在线解析及音频加载之前 arm，使用同一 QPC 时基；首个超过阈值的 PCM 帧采用包首时间加帧偏移，换算为毫秒。WASAPI 的包时间戳已经是 100 ns 单位，不能再当成原始计数器 ticks。[GetBuffer 时间戳定义](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer)

每次正式测量前均暂停并排空，观察至少 450 ms 不出现超过阈值的残留；暂停时可以没有数据包，这只是排空等待。另播放专门的静默 WAV 作为负对照，要求实际有效 PCM 覆盖至少 400 ms，且最后采集帧距快照不超过 150 ms，防止采集停滞却因墙钟经过而假通过。HRESULT 错误、时间戳异常或只有播放器事件不能作为输出成功证据；播放样本必须实际观测到超过阈值的 PCM。每次保存统计快照、时间戳、计数与错误标记，原始 PCM 不落盘。p95 使用 nearest-rank，每组 10 次，因此 p95 为该组最大值。

这里的“冷”仅指新探针进程中的首次后端加载，不包括 Flutter 进程启动、原生回环初始化，也不清除系统缓存；“热”指同一后端再次加载。计时不包含正常产品页面的真实点击派发或完整 `PlayerService` 调度。结果只能证明 Windows 渲染通路中存在该测试进程的 PCM，不能证明 DAC、外接设备或扬声器实际出声，不能据此关闭计划中的物理出声门槛。

## 2. 工具与复现

- `tool/native/process_loopback_probe.cpp`：进程限定采集、QPC 时间戳与 PCM 统计，只由诊断入口加载。
- `tool/build_process_loopback_probe.ps1`：复用现有 MSVC/Windows SDK，编译到独立 D 盘目录。
- `tool/windows_m5_output_probe.dart`：静默控制、本地/回环网络冷/热播放、异常和报告处理。
- `tool/run_windows_output_probe.ps1`：设置本次进程环境、记录二进制哈希和进程身份、保存标准输出及会话结果；超时仅清理本次启动且身份核对一致的进程。

先加载本机环境脚本，从英文工程入口运行。`$runRoot` 每次使用全新的 `D:\dev\tmp\hanmusic-m5-output-<标识>`，不重复覆盖旧证据；DLL 位于其 `native` 子目录。两个阶段共用同一 DLL 和相同字节的 WAV，各自为全新的 Windows 进程。

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
$runRoot = 'D:\dev\tmp\hanmusic-m5-output-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $runRoot | Out-Null
& './tool/build_process_loopback_probe.ps1' -OutputDirectory (Join-Path $runRoot 'native')
flutter build windows --release --no-pub -t tool/windows_m5_output_probe.dart
& './tool/run_windows_output_probe.ps1' -RunDirectory $runRoot -Phase all
& './tool/run_windows_output_probe.ps1' -RunDirectory $runRoot -Phase cold-network
# 诊断构建覆盖同一 Release 目录；完成后恢复产品入口。
flutter build windows --release --no-pub -t lib/main.dart
```

运行期间只使用受控根内的诊断文件、源配置和数据目录。工具拒绝链接路径和已有结果。测试进程的正常自行退出与外层超时强制停止分别记录，均不代表通过 Windows 关闭按钮验收。

## 3. 本轮实测

本轮证据目录为 `D:\dev\setup\verification\m5-output`。原生工具通过系统 PowerShell `5.1.26100.9444`、既有 MSVC `14.37.32822` 与 Windows SDK `10.0.22621.0` 编译。原生无播放自测启动 16 ms、停止 0 ms，收到 29 包、13,920 帧；超过阈值的计数、时间戳错误与 HRESULT 均为 0。这只证明采集与清理能够工作，不单独作为有声验证。

首轮使用应用音量 0.02，在本地冷加载后的播放证据等待 5 秒超时后，记录到 477 个有效包、228,776 帧；从 arm 到该快照约 5,114.81 ms，包含加载时间。峰值始终只有 1 LSB，没有符合阈值的 PCM，因此按设计失败并退出 1。原始报告、会话与标准输出保留为 `initial-*`，没有将这次失败删除或混入最终热启动统计。

根因检查发现桥接把应用 0.02 转换为 mpv 的音量 2，而本机二进制对应 commit `652a1dd90711839acdccc08004056d25514ef2d8` 的软件增益采用立方曲线。由该源码推算，1,000 LSB 样本峰值经 0.02 刻度后仅约 0.008 LSB，低于采集阈值。最终仅将诊断音量改为 0.2，理论峰值约 8 LSB（实际声道转换和量化另有影响）；不修改固定 WAV、检测阈值、1 秒/3 秒热启动目标、生产播放器音量逻辑或系统设置。[对应 mpv 音量实现](https://github.com/mpv-player/mpv/blob/652a1dd90711839acdccc08004056d25514ef2d8/player/audio.c)

同时完善失败报告，保留当时的播放/加载状态、首个播放和进度事件、最后进度、分阶段耗时及有界事件轨迹。初版报告只在成功路径保存事件时间，故不能仅凭首轮报告断言播放事件也没有出现。

09:16:23 的只读端点查询记录三个默认输出角色均为 `扬声器 (Realtek(R) Audio)`、active、未静音，主音量标量约 0.350337446。查询没有打开渲染或采集流，也没有调用设置接口；它仅代表该时刻的默认端点，不是对已退出进程会话静音状态的追溯。原始结果为 `endpoint-readonly.json`。

## 4. 最终两阶段结果

最终受控根为 `D:\dev\tmp\hanmusic-m5-output-20260930-091627`，使用同一 DLL 和同一诊断 Release bundle。最终诊断构建耗时 120.8 秒；构建前后的校验、格式和测试未与计时并发。系统 PowerShell 5.1 依次运行两阶段，均自行退出 0、`passed=true`，没有触发外层强制停止。两份结果的后台错误、清理错误和 stderr 均为空，结束后的采集状态为 `running=false`、HRESULT 为 0。

| 阶段 | PID | 起播样本数 | 外层运行耗时 | 主机 CPU 单次读数：前 / 后 |
| --- | ---: | ---: | ---: | ---: |
| all | 10184 | 22 | 36,788 ms | 20% / 42% |
| cold-network | 1808 | 1 | 4,984 ms | 20% / 8% |

CPU 读数只是前后快照，不是连续负载轨迹。机器为 i7-13620H、16 逻辑处理器、约 15.73 GiB 内存、NVMe、Windows Build 26200，显示配置沿用此前本机；本轮测音频，不重新测滚动或显示缩放。

| 起播组 | 次数 | 输出 PCM 单次 / p95 (ms) | 输出 PCM 中位数 (ms) | 同组首个非零进度事件单次 / p95 (ms) |
| --- | ---: | ---: | ---: | ---: |
| 本地冷 | 1 | 724.4961 | — | 101.226 |
| 本地热 | 10 | **445.1230** | 396.4321 | 94.418 |
| 网络预热（已用过本地后端） | 1 | 431.8177 | — | 86.822 |
| 回环网络热 | 10 | **445.5309** | 409.2786 | 120.198 |
| 回环网络冷（新进程） | 1 | 554.7690 | — | 86.249 |

本轮本地热样本全部严格低于 1,000 ms，网络热样本全部严格低于 3,000 ms。冷/预热组单独记录，不将热启动门槛施加于它们。每组 10 次的 p95 已由原始样本独立重算；样本量有限，不代表长期上界。输出 PCM 的定义仍为首个超过 1 LSB 的采样，最终正样本峰值仅 2–3 LSB，检测时刻会受到音量和量化影响。不得把这些数字解释为不受阈值影响的绝对首帧或其他音量、设备的保证。

| 热启动次序 | 本地输出 PCM (ms) | 回环网络输出 PCM (ms) |
| --- | ---: | ---: |
| 1 | 335.0730 | 445.5309 |
| 2 | 391.6939 | 404.5739 |
| 3 | 379.1877 | 404.2053 |
| 4 | 376.4461 | 372.9368 |
| 5 | 401.1703 | 413.9833 |
| 6 | 406.4072 | 420.8597 |
| 7 | 411.4023 | 387.5513 |
| 8 | 340.8719 | 414.3686 |
| 9 | 412.5131 | 397.5385 |
| 10 | 445.1230 | 427.4322 |

每次正样本均有超过阈值的实际 PCM、有效播放和进度事件，原生时间戳错误与数据不连续标记均为 0。首个非零进度事件明显早于本轮 PCM 检测时刻，进一步说明原有事件计时不能替代输出测量。

两阶段各执行一次实际静默 WAV 负对照。all 阶段收到 45 包、21,314 帧（约 444.04 ms），cold-network 阶段收到 45 包、21,317 帧（约 444.10 ms）；最后有效帧距快照分别约 8.48 ms、4.22 ms。两次峰值均不超过 1 LSB，无时间戳错误，满足至少 400 ms 有效 PCM 和最多 150 ms 滞后的要求。暂停排空窗口和实际静默 WAV 控制分别记录，没有把“无包”当作有效负对照。

原始结果为 `result-output-all.json`、`result-output-cold-network.json`；对应 `output-*.session.json` 保留进程身份、起止时间与二进制哈希，`samples.csv` 保留逐次 PCM/事件时间，`summary.json` 为汇总。

| 指纹 | SHA-256 |
| --- | --- |
| 两阶段诊断 `app.so` | `b7050442cdf2e7c44694f4d01ee43c960d532693faaddaf362624449b3d7eec8` |
| 进程回环 DLL | `870a477527add7d9b87aa49d1a9ae239cc9f58bfd34c814e77f449082741f646` |
| 本地/回环相同 WAV（264,644 字节） | `a30a3f24ce3d1387bc1a1a8e94b21a5e3b5e77556ca92834bca04cfd13ab95fb` |

## 5. 自动检查、产品入口与剩余门槛

最终格式检查覆盖 78 个 Dart 文件，无变更；`dart analyze lib test tool` 无问题；全量 `flutter test --no-pub --reporter expanded` **275 项通过**（43 秒测试运行时间），包括 11 项输出证据、统计和失败事件诊断测试。原始日志为 `format-final.txt`、`analyze-final.txt`、`tests-final.txt`。两个 PowerShell 工具的非法输出路径拒绝记录单独归档；构建脚本还通过系统 PowerShell 5.1 的悬挂目录符号链接用例，提前拒绝且没有创建缺失目标，见 `native-build-dangling-link-guard.json`。

本轮从基线工作区加入诊断源码构建，不把未提交工作区描述为干净检出；`source-fingerprints-final.json` 保留 6 个工具/测试源码的哈希，原生构建报告另含 C++ 源码、编译器和 SDK 信息。测量后仅加固构建脚本的悬挂链接拒绝，Dart 探针、C++ 源码及实测 DLL 没有改变；最终提交前已核对源码指纹。

最后重新执行 `flutter build windows --release --no-pub -t lib/main.dart`，23.7 秒构建成功。恢复后的 `app.so` SHA-256 为 `cac911e53d538430964474ff1482314263d111676869055abc1ce44000786deb`，与已验证的 dev.7 包中对应文件完全一致；Release 目录没有诊断 DLL。恢复日志和哈希核对为 `restore-product-main.txt`、`restored-product.json`。现有 dev.7 预览 ZIP、产品版本及 ZIP 哈希均不变，没有另行发布新包。

本轮补齐了本机受控音源的 Windows 渲染通路证据；实际扬声器出声、普通页面点击到输出的完整时延、设备切换、原生窗口/对话框、真实休眠、系统 DPI、万曲性能、干净机器及发行授权仍按 [开发计划](./05-Windows版本开发计划.md) 保留。M5 和 Windows MVP 均未标记完成。
