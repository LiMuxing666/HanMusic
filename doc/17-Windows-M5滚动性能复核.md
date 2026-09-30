# Windows M5 滚动性能复核

日期：2026-09-30。基线源码 `5b3a06d`，产品版本 `0.1.0-dev.7+7`。本轮针对万曲滚动的 UI p95 差距进行有边界的候选实验；不修改 16.7 ms 目标或减轻探针负载。M5 仍为进行中。

## 1. 范围与复现

证据目录：`D:\dev\setup\verification\m5-row-performance`。Flutter 3.41.9 / Dart 3.11.5；Windows 11 专业版 10.0.26200；i7-13620H（10 核 / 16 逻辑处理器），系统可见内存约 15.73 GiB；UMIS RPEYJ1T24MKN2QWY 磁盘、D 盘 NTFS。环境、产物清单及原始 JSON/CSV 均留在该目录，未更改系统设置。

沿用未修改的 `tool/windows_m5_performance_probe.dart`：实际 PlayerPage、10000 条确定性无封面索引、5 秒预热、30 秒采样、10 秒单程的逐 vsync `jumpTo` 往返滚动。数据集没有音频播放、文件扫描、封面解码或网络请求。这是程序化高速压力负载，不代表普通鼠标滚动的完整体验。

基线 A 是冻结的 **dev.7** 完整 Profile 目录，路径 `D:\dev\tmp\hanmusic-m5-row-ab\baseline`，对应既有 `4587d28` 构建；随后至 `5b3a06d` 的提交未修改产品页面。不能将更早 dev.6 的关闭焦点保活版本当作本轮基线。候选 B 在 `D:\dev\tmp\hanmusic-m5-row-ab\candidate`。两份目录各 16 个文件，逐文件比对仅 `data/app.so` 不同。

| 文件 | A SHA-256 | B SHA-256 |
| --- | --- | --- |
| `data/app.so` | `f7bb4dcc92aa656dd7ffc15e9d3c6084571d45e4665892d2729d55df0ebe50f2` | `8961275f9e61d667d0040c266cfa5875a875b0f211b19730fe51704e3df31457` |

探针源码 SHA-256 为 `dded3b5664cecaa22b459e2a1ca3c9912f9a78effd104afab3ec12f5155437ce`。候选只把列表各行的 Material 改为列表共享 Material、各行 Ink 背景，外层 ClipRect 约束绘制；文字、列、字体、行高、`cacheExtent: 0`、键盘焦点保活及交互不变。目的是检验减少组件创建的收益，不能据此预先推断文本排版更快。实验补丁保存在证据目录 `candidate.patch`。

新增 `tool/run_windows_performance_probe.ps1` 固化正式采集：独立进程、120 秒上限、只按 PID/启动时间/物理路径终止自己启动的进程；缓存进程句柄并要求明确的零退出码。每次使用新的 RunName，拒绝覆盖已存在证据，先归档编译固定目录的旧 JSON/CSV，再保存本次结果。所有输出要求 D 盘绝对路径。

脚本复核模式、规模、采样时间、窗口/生命周期变化及框架错误，并从 CSV 重算帧数、时间顺序、nearest-rank p95 和超预算比例。`validCapture=true` 只表示采集证据有效，**不代表性能达标**。不连接 VM Service 或启动 profiler；调用者仍需避免外部 profiler、构建和测试干扰。

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
flutter build windows --profile --no-pub -t tool/windows_m5_performance_probe.dart --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-m5-performance
# 在构建下一个候选前复制整个 Profile 目录，保留 DLL/data。
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File tool/run_windows_performance_probe.ps1 -BundleDirectory D:/dev/tmp/hanmusic-m5-row-ab/baseline -EvidenceDirectory D:/dev/setup/verification/new-performance-run -RunName a1
```

`ProbeDirectory` 须与 `--dart-define` 编译常量匹配；运行时环境变量不能改变该输出目录。重复 A/B 必须串行运行，并保持尺寸、DPR、刷新率、字号、extent 和速度一致；每次先归档结果。诊断入口不能作为产品交付入口。

## 2. 实测结果与决定

先进行预跑 A0/B0（UI p95 27.401 / 27.815 ms），随后通过新脚本按 **A1 → B1 → B2 → A2** 正式测量。各次均为新进程，无 CPU collector、并行构建或测试；进程正常自行退出、退出码为 0，原始 CSV 重算与 JSON 一致，`validCapture=true`，无框架错误、窗口 metrics 变化或生命周期事件。

| 顺序 | UI p95 (ms) | raster p95 (ms) | 帧数 / 实际秒数 | 采样 FPS | 超过 60 Hz 预算 | 峰值采样 RSS (MiB) | CPU 前 → 后 (%) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A1 | 26.444 | 4.579 | 889 / 30.019799 | 29.61 | 46.57% | 147.96 | 20 → 26 |
| B1 | 26.602 | 5.008 | 881 / 30.012091 | 29.35 | 55.16% | 148.65 | 26 → 8 |
| B2 | 27.884 | 5.033 | 871 / 30.030273 | 29.00 | 60.85% | 148.83 | 22 → 12 |
| A2 | 26.196 | 4.721 | 884 / 30.022196 | 29.44 | 47.96% | 148.84 | 14 → 7 |

四次逻辑窗口均为 1265.333×682.667、DPR 1.5、165 Hz、文字倍率 1.0；最大滚动 extent 均为 779620.333 logical px、速度 77962.033 logical px/s、三次方向改变。离散采样的实际累计距离为 2334892.733–2337049.084 logical px，随首尾帧时刻变化，不能要求每个采样 offset 完全相同。CPU 是启动前/退出后的系统快照，不是整个测量期负载或应用 CPU 占用；仍存在其他系统活动和温度等未控制变量，四次小样本不构成统计显著性证明。

**候选没有证明收益，已撤回。** 本轮两次 B 的 UI/raster p95 和超预算比例均高于两次 A，不保留这项生产页面改动。保留实验补丁、冻结产物和完整原始数据用于复核，不用以前更慢的主机结果来宣称优化。最终 `lib/` 与基线一致，仍使用每行 Material。

当前基线本次 UI p95 为 26.196–26.444 ms，仍超过 16.7 ms；raster 在目标内。下一步应围绕仍存在的行创建/文本布局成本继续分析，不能仅凭组件数量减少判断性能。正式记录为 `ab-*.json`、`ab-*.frames.csv`、`ab-*.session.json`、`ab-summary.json`；预跑 A0/B0 单独保留。

## 3. 回归与交付

新增页面像素测试覆盖 1280×720 / 100% 和 800×600 / 200% 字号下的当前歌曲底色、圆角、行间隙、半行滚动、返回与切歌；另检查鼠标悬停和 Tab 焦点可见、焦点行离屏后绘制不越过列表边界。捕获整个页面，包含祖先绘制的 ink，不能只截图单行后漏掉背景。

候选页面的 31 项测试已通过，包含新增 4 项像素检查和原有键盘分页、离焦释放、滚轮往返及菜单测试。这些是 Flutter 框架与绘制回归，不是原生 Windows 键鼠、真实系统 DPI 或音频设备验收。

撤回候选后，全量 `flutter test --no-pub --reporter expanded` **279 项通过**（47 秒），`dart analyze lib test tool` 无问题；分析发现的一处冗余测试导入已移除。Dart 格式检查覆盖 78 个文件。日志为 `tests-final.txt`、`analyze-clean.txt` 和 `format.txt`。

系统 PowerShell **5.1.26100.9444** 的 9 项采集校验通过：真实 A1 数据作正对照；旧写入时间、生命周期中断、窗口变化、重复帧、帧数减少、伪造 p95 六类副本均拒绝；相同 RunName 和仅有 stdout 文件的两类覆盖冲突均在启动前拒绝。原始证据哈希/时间未变，没有启动应用，详见 `Test-EvidenceGuards.ps1`、`guard-results.json`。四轮真实采集验证正常路径，静态复核和负向检查验证部分失败路径；本轮没有额外实测 120 秒超时强制清理分支。

随后正常入口 `lib/main.dart` Release 构建成功（130.2 秒），`data/app.so` SHA-256 为 `cac911e53d538430964474ff1482314263d111676869055abc1ce44000786deb`，与已验证 dev.7 包完全相同。本轮最终修改仅涉及测试、开发工具和文档，未修改产品依赖或版本，也未重新打包或发布 Release。

已有 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.7-M5.zip` 的 SHA-256 仍为 `c364f77dc7de506862a96d531c6b93ca2535c539e904a574b024e943520da7c4`，核对结果见 `normal-entry-and-package.json`。正常入口构建日志为 `build-normal.txt`，候选 Profile 构建日志为 `build-candidate.txt`；冻结候选只用于实验复核。

万曲滚动、物理出声与完整页面起播、原生文件对话框/窗口操作、休眠和设备变化、真实系统 DPI、干净机器及对外发行材料仍按 [开发计划](./05-Windows版本开发计划.md) 保留。开发预览仍为 `0.1.0-dev.7+7`。
