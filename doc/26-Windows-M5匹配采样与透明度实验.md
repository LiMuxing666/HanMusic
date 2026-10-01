# Windows M5 匹配采样与透明度实验

日期：2026-10-01。开发基线 `b44205c`，本轮证据目录为 `D:\dev\setup\verification\m5-matched-cpu`。SDK、Pub、Gradle、临时文件和产物继续放在 D 盘，没有升级依赖、调整电源策略或关闭无障碍。

## 1. 匹配正确性修复版的 CPU 诊断

复用 [曲库身份修复](./24-Windows-M5曲库焦点与退出导入.md) 时冻结的 B：`D:\dev\tmp\hanmusic-m5-identity-ab\fixed`。16 个文件的大小和 SHA-256 全部与原 `fixed-source.json` 一致，`app.so` 为 `76a82059c159072613b43fbdec55957796ff65fda63c26b28ff60a2fb0da81c0`，探针源码为 `ae516cac83326c55d9cec666414be5843ba80faaf9568bbc65d95e8dfe4e197a`。它包含曲库身份修复，仍使用 dev.12 构建号，没有后来 dev.14 的队列改动；本轮已核对当前曲库实现与该修复提交相同，不把复用二进制描述为当前源码新构建。

沿用 `collect_m5_cpu_samples.dart`，在主 isolate 和 profiler 就绪后等待 5 秒、采样 15 秒，维持 VM 原有 1000 µs 周期和 128 层栈上限。采集器、应用退出码均为 0，没有强制停止；启动 PID、VM PID 和原始响应 PID 均为 31528，profiler 从 false 临时开启后已恢复。原始数据为 `matched-b-r1/cpu-samples.raw.json`，SHA-256 为 `3873eeb393e0ee3cf0adc6b4fe86a6b260905044f9f7696c6009e2ed52edde56`。

共返回 **7,774 个样本、21,502 个函数记录**。按 UTC 事件粗略对齐，采样位于探针首帧开始后 9.040–24.052 秒，落在预热后的滚动阶段；没有将 VM 时钟与 FrameTiming 时钟假定为完全相同。窗口仍为 1265.333×682.667、DPR 1.5、165 Hz、字号 1.0；语义全程开启，无窗口指标、生命周期、无障碍状态变化或框架错误。此轮开启 profiler 和服务 RPC，**其帧耗时不参与无采样器的性能对照或达标判断**。

## 2. 调用路径分组与限制

逐一解析完整函数表与样本栈，在每个分组内按样本去重，不只查看 top 40；组之间允许重叠，不能相加或直接换算成毫秒。

| 栈中出现的路径 | 去重样本数 | 占全部样本比例 |
| --- | ---: | ---: |
| 布局 | 2264 | 29.12% |
| 文本生命周期 | 1595 | 20.52% |
| 挂载 | 1484 | 19.09% |
| 语义 | 882 | 11.35% |
| 卸载 / 停用 | 517 | 6.65% |
| Layer 命名路径 | 75 | 0.96% |
| Opacity 命名路径 | 65 | 0.84% |
| Song.id | 16 | 0.21% |
| Key 命名方法 | 0 | 0.00% |

`TextPainter.layout` 命中 1335 个样本，`TextPainter._createParagraph` 命中 303 个，均已包含在文本组；文本与布局组有 1390 个重叠样本。文本组还包含创建、销毁、绘制和语义路径，不能整体称为文本布局耗时。挂载组中的 1056 个栈被截断，不能将它们归因于特定行内控件或歌曲 Key。语义分组已排除仅因继承 `SemanticsBinding` 而被误匹配的普通 `drawFrame`。

全部样本中 **1414 个栈截断（18.19%）**，**4117 个标为未知原生入口（52.96%）**，另有 61 个空栈。原始栈首帧只是保留下来的最深帧，不能当作独占 CPU：例如 `_NativeParagraph._layout` 在 1014 条栈居首，但 VM 报告的 exclusive ticks 为 0。原生堆分配的 845 个样本全部只有单帧，没有足够上下文归属到字符串、字体或 Key。本轮没有从这些记录推算 Dart 自耗时。

统计脚本为 `analyze_matched_cpu.dart`，最终明细为 `matched-b-r1/independent-groups-v2.json`，摘要为 `independent-summary.json`。初稿 `independent-groups.json` 曾过宽匹配语义继承者，并混用保留首帧与独占 ticks，已明确废弃；本记录使用修正后的 v2 口径。第二次只读复核确认脚本指纹、集合去重、摘要与明细一致，没有重复运行原始统计；以上重叠与归属边界仍保留。

这份匹配样本支持优先调查文本布局，以及每行子树创建/销毁次数。ID、Opacity 和 Layer 的命名路径占比较低，不能据此称为主要瓶颈；同时，命名路径低命中并不能排除其创建、遍历成本落在通用框架函数中。Key 零命中也不能证明零成本或排除内联。上轮 [身份微基准](./25-Windows-M5队列拖拽与身份成本.md) 继续保留为局部成本测量，不能用来解释整个帧耗时差距。

## 3. 透明度包装候选

为界定一个可撤回的小范围改动，本轮仅试验普通歌曲省去封面和标题区域的两个 `Opacity(1)` 包装。缺失歌曲继续使用 `.45` / `.5`，返回 child 的私有方法不新增 Widget 层。外层歌曲 Key、懒索引映射、InkWell、Material、列表默认重绘边界、自动焦点保活、行高、列、文字、菜单及封面内容均不变。

本机 Flutter 的 `RenderOpacity` 在 alpha 为 255 且存在 child 时，仍维护重绘边界和 OpacityLayer；1.0 的快速路径省去中间像素缓冲，并不省去这些对象。这是候选的源码依据，不是收益结论，也不同于此前关闭整个列表逐行重绘边界的实验。

两项新增回归先在旧实现上 **2/2 通过**，再用于候选，覆盖 1280×720 / 100% 和 800×600 / 200% 字号的正常→缺失→恢复：实际 PNG 封面和标题像素、菜单焦点、布局位置、缺失时禁播且可移除、恢复后的语义动作，以及最终音频加载目标。测试通过真实 LibraryService 更新状态，没有使用真实文件检查或系统输入。既有封面回收、小步滚动、身份焦点、键盘分页、hover 和当前背景测试继续复用。

性能协议在测量前记录于 `opacity-experiment-plan.json`：从同一 dev.14 源码构建对照与候选，固定探针、编译常量和环境采样开关，依次 A/B/B/A，无测试、构建或 CPU collector 并发。若两次 B 的 UI p95 不能同时优于两次 A，或差距未超过同一对照的波动，不宣称稳定收益并恢复生产源码；同时检查 raster 与内存，不能仅靠 UI 指标保留候选。短窗口改善也不等于跨时段、真实曲库或整个 M5 达标。

候选的核心定向合集 **14/14**、当前背景像素 **2/2** 通过；临时目录清理补物理路径核对后，两项新增回归再次 **2/2** 通过，定点静态分析和格式检查通过。日志分别为 `opacity-candidate-targeted-tests.txt`、`opacity-candidate-background-tests.txt`、`opacity-candidate-new-tests-final.txt`、`opacity-analyze.txt` 和 `opacity-format.txt`。功能通过没有作为性能收益证明。

两份程序均从当前 dev.14 源码构建，固定版本 `0.1.0-dev.14+14` 与编译常量 `HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-m5-performance`；命令墙钟耗时分别为 117.7 / 285.8 秒，不把编译耗时差异当作播放器性能数据。构建前后输入哈希不变，两组输入仅 `library_widgets.dart` 不同。完整目录冻结在 `D:\dev\tmp\hanmusic-m5-opacity-ab\control`、`candidate`，各 16 个文件，逐文件比较仅 `data/app.so` 不同：A 为 `8a3e7eb74d4825bd9305d6a5f94c4d28a21d317f528b09fbf02f521a4359062f`，B 为 `c9ee876b8a096c60d4d9049d8ed5709f526d30782550a4dd044dbabf2d20ff3a`。清单为 `control-source.json`、`candidate-source.json` 和 `bundle-comparison.json`。

| 顺序 | UI p95 (ms) | raster p95 (ms) | 帧数 | 采样 FPS | 峰值采样 RSS (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 | 73.254 | 6.490 | 501 | 16.68 | 150.23 |
| B1 | 75.380 | 5.946 | 510 | 17.00 | 148.00 |
| B2 | 467.049 | 6.290 | 132 | 4.37 | 145.67 |
| A2 | 54.290 | 5.836 | 841 | 28.03 | 148.63 |

四轮均启用 `-CollectEnvironment`，期间没有测试、构建或 CPU collector 并发。全部自行零退出，`validCapture=true`，无强制停止、框架错误或测量期窗口指标变化。原始 JSON、CSV 和 session 按四个 run name 保存，含每秒环境观测。B2 的慢帧是实际保留的数据，不能因为数值异常就从比较中删除。

独立只读审计重新从四份 CSV 计算 p95，核对帧顺序和数量、采样窗口、PID、退出、几何及无障碍状态，并核对构建输入和完整包的前后哈希，全部一致。脚本与结果为 `Audit-OpacityComparison.ps1`、`independent-ab-summary-verified.json`。

| 运行 | 整机 CPU 样本均值 | 可用物理内存最小值 (MiB) | 环境读取耗时均值 (ms) |
| --- | ---: | ---: | ---: |
| A1 | 33.26% | 1499.08 | 10.81 |
| B1 | 33.14% | 1399.29 | 8.59 |
| B2 | 31.29% | 1407.41 | 40.53 |
| A2 | 39.35% | 1251.51 | 7.42 |

这些环境统计仅取精确目标进程存活期间的观测，包含启动、预热和退出前阶段，与帧测量窗口不完全相同；均值是样本算术均值，CPU 是整机指标。四轮均使用交流电和同一电源方案，进程 QoS 为系统管理；这不能排除线程或系统自动调度差异。前三轮频率观测为 1515 MHz，A2 为 1515–2250 MHz。B2 环境读取最大耗时 755.43 ms，说明采集本身也存在波动；没有温度或线程等待证据，不能据此归因为热降频、争用或具体候选开销。

**撤回候选，M5 性能仍未通过。** 两次 B 的 UI p95 都高于两次 A，未满足测量前的保留条件；同一 A 也有 18.964 ms 波动。不能把 B2 的巨大变化归因于这几行代码，也不能用环境波动排除候选本身的开销；现有证据没有支持保留它的稳定收益。所有四轮 UI p95 均高于 16.7 ms。没有继续扩大已失败候选的实验次数以寻找好结果。

生产文件已从 `library_widgets.control.bytes` 按原始字节恢复，SHA-256 为 `0f1dd6496c0878da267c470723373a16d2787f76abd02631bbc9d7ee3347a32f`，与冻结 A 的输入一致；`git diff --exit-code -- lib` 为 0。恢复凭据为 `candidate-restoration.json`，候选补丁和原始证据继续保留，两项有意义的缺失状态恢复测试保留在仓库。

## 4. 恢复后的验证与交付边界

恢复生产源码后，`flutter test --no-pub --reporter expanded` **371/371 通过**，`dart analyze lib test tool` 无问题，格式检查 81 个文件、0 改动。全量测试命令墙钟为 367.1 秒，包含启动和编译，不作为播放器性能数据。证据为 `tests-final.txt`、`tests-final-result.json`、`analyze-final.txt` 和 `format-final.txt`；最终测试文件 SHA-256 为 `d4de053ae12319e27da280bd6f96f4dc06b0b0522475a3530550cf6f6fa9da27`。

随后从 `lib/main.dart` 重新执行 Windows Release 构建，退出码 0，命令墙钟 247.6 秒。正常入口的 `app.so` SHA-256 为 `1101b455b81ae1f19de2c9cac73fa10d431fce459ff46de804052c65a48457c1`，与现有 dev.14 预览包一致。`D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.14-M5.zip` 的 SHA-256 仍为 `44d97dc21ed9d7ec1fadf871e189b0c1356aab2cd50cbd48258cd82776c5dc62`；证据为 `build-normal.txt` 和 `normal-entry-and-package.json`。本轮没有重打包、升级版本或重新执行完整包的 6 项检查；既有包检查属于 [dev.14 交付记录](./25-Windows-M5队列拖拽与身份成本.md)。

本轮仓库交付仅包含两项回归与文档，`lib` 相对开发基线没有差异。下一步优先量化文本与行内子树创建/销毁次数，并结合 UI 线程 CPU 时间和帧墙钟时间区分计算与等待；保留歌曲身份、内容、语义和焦点正确性要求。

README、开发计划与本记录共 57 个本地链接均可解析，结果为 `document-links.json`；提交前差异空白检查通过。

M5 的 UI/raster p95 16.7 ms 目标保持不变。原生窗口/对话框、真实休眠和设备变化、物理出声与完整页面起播、真实系统 DPI、干净 Windows 机器，以及发行授权和原生对应源码门槛继续按 [开发计划](./05-Windows版本开发计划.md) 保留。
