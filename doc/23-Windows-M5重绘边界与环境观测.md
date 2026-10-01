# Windows M5 重绘边界与环境观测

日期：2026-10-01。基线 `5bc551a`，继续执行 M5 性能验收；原 UI/raster p95 16.7 ms 目标保持不变。证据统一保存在 `D:\dev\setup\verification\m5-row-actions`，SDK、Pub、Gradle、临时文件和产物继续放在 D 盘，未升级依赖或修改系统设置。

## 1. CPU 诊断与证据边界

先独立运行冻结的 dev.7 行结构基线 `D:\dev\tmp\hanmusic-m5-row-ab\baseline`，`app.so` SHA-256 为 `f7bb4dcc92aa656dd7ffc15e9d3c6084571d45e4665892d2729d55df0ebe50f2`。它是已有库行行为的诊断对照，不冒称当前源码构建。使用现有 `collect_m5_cpu_samples.dart`，就绪后延迟 5 秒、采样 15 秒，保留原 1000 µs 周期；采集器和应用退出码均为 0，VM PID 与启动进程 15176 一致，940 个非空样本，profiler 已恢复为原先的 false。

| 调用路径分组（组内去重） | 样本数 / 总样本占比 |
| --- | --- |
| 语义更新 | 100 / 10.64% |
| 绘制 | 39 / 4.15% |
| mount / inflateWidget | 138 / 14.68% |
| unmount | 58 / 6.17% |
| Paragraph / TextPainter | 202 / 21.49% |

分组之间重叠，不能相加，不代表实际调用次数或墙钟耗时。513 个样本为未知原生入口（54.57%），162 个栈截断（17.23%）；71 个 `RtlAllocateHeap` 和 11 个 `RtlFreeHeap` 样本全部只有单帧原生栈，不能将其归因于字体 shaping 或 Widget 创建。语义更新样本说明本窗口存在该路径，旧程序缺少初始状态快照，不能据此认定具体屏幕阅读器或历史性能波动的来源。分组统计为 `cpu-groups.json`，原始采样和会话保留在 `cpu-diagnostic-r1/`。

该轮开启 profiler/VM Service RPC，帧时间不用于正式 A/B 达标判定。采集脚本在结束归档时误用了 CSV 文件名，导致归档步骤返回错误；实际采样与应用均已成功。确认真实 CSV 时间属于本次启动后，从正确路径复制归档，没有重跑或伪报脚本零退出；修正记录为 `cpu-archive-recovery.json`，旧轮帧数据仍保留在原证据目录。

## 2. 增加环境和无障碍观测

此前 wrapper 只保留系统 CPU 前后快照。新增 `tool/windows_performance_environment.ps1`：复用单个 PDH query，以英文计数器路径兼容中文系统；记录总体 CPU 占用、频率、Processor Performance、Maximum Frequency、Performance Limit 和原始 Limit Flags。每项具有独立状态、错误码和不可用原因，未知值保留 null，不写成零。[Microsoft 查询说明](https://learn.microsoft.com/en-us/windows/win32/perfctrs/creating-a-query)、[格式化计数器说明](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhgetformattedcountervalue)

同时读取电源接入/方案、物理与提交内存，以及 wrapper 自己启动的精确进程句柄对应的 `ProcessPowerThrottling`。`ControlMask/StateMask` 只表示该进程显式策略；`system_managed` 不证明没有线程级或系统自动 QoS。只读 API 不安装工具、不需要管理员，不设置进程优先级或电源策略，不读取无关进程命令行。[进程信息 API](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessinformation)、[Windows QoS 边界](https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service)

`run_windows_performance_probe.ps1 -CollectEnvironment` 可选启用每秒采集，默认关闭以保持原流程。初始化和完整预热在启动应用前执行，数据留在内存、退出后写入 session。每样本保留观察时间和开销；不对延迟采样补发密集调用。观测失败不改变采集是否完整的原判断，而是留下环境证据缺口。正式 A/B 必须使用相同开关。

本机系统 PowerShell 5.1 的 helper **7 项验证通过**，包括实际 API、精确进程查询、缺失/部分缺失计数器与重复释放。初始化约 1273 ms，预热后四次完整 Read 为 2.19–3.01 ms，其中 PDH 0.92–1.45 ms；正式采样开销另按各轮实际值报告。PDH 原始 FILETIME 在本机转换后出现 8 小时差异，故仅保留为原值，UTC 使用真实观察时刻；不拿原始值伪造同步时间。见 `environment-helper-20261001-02/report.json`。

新的 Profile 探针通过 Flutter listener/observer 记录 `semanticsEnabled` 和八个 AccessibilityFeatures 的初始、测量开始/结束快照，以及测量期间变化。原数据、预热、30 秒时长、10 秒单程滚动速度均不变，不逐帧查询、不开启或关闭无障碍服务。wrapper 拒绝测量期状态变化、首尾不一致或损坏字段；旧二进制无字段时兼容但明确缺少该证据。**7 项校验通过**：旧数据与启用/禁用的稳定状态通过，变化事件、首尾变化、缺失字段和错误类型拒绝。原始证据哈希未变，校验过程未启动应用，见 `accessibility-guards/results.json`。随后整理为仓库工具 `test_windows_performance_evidence.ps1`，使用本轮真实 A1 又验证 7/7 通过，JSON/CSV/session 哈希均未改变，见 `evidence-tool-test/results.json`。

初始只读快照显示 AC Online、电量 95%、均衡方案、总体频率 1515 MHz、Processor Performance 54%、可用内存约 1.76 GiB；这是测量前某时刻的状态，不能反推以前的慢帧。ACPI 温度查询拒绝访问，不能判断热降频。当前进程 Session 1、`SM_REMOTESESSION=false` 与控制台会话一致，但不排除第三方远控/虚拟显示。原始字段和采集时间边界保留在 `environment-initial.json`。

## 3. 重绘边界候选

候选仅给曲库 `ListView.builder` 设置 `addRepaintBoundaries: false`，减少逐行独立重绘边界和图层维护；文字、列、图片、Material、菜单、固定行高、`cacheExtent: 0`、焦点保活和语义索引不变。高速压力负载经常整屏替换行，该候选可能减少挂载成本，但普通小步滚动或 hover 时也可能扩大重绘范围，必须同时看 UI 与 raster，不预先宣称收益。

本轮另评估过 `PopupMenuButton.child` 简化菜单按钮，但它会改变 M3 overlay、点击区域和语义处理，未将该方案混入本次单变量实验。

两份程序都从当前 dev.12 源码和同一更新后的诊断入口构建，A/B 耗时分别为 155.2 / 118.8 秒。完整目录冻结在 `D:\dev\tmp\hanmusic-m5-actions-ab\baseline`、`candidate`，各 16 个文件，逐文件比对仅 `data/app.so` 不同。探针源码 SHA-256 为 `ae516cac83326c55d9cec666414be5843ba80faaf9568bbc65d95e8dfe4e197a`；A 的 app.so 为 `5271fdcb5a303c49340acade34095ec73e58bd315f4b363036f439013cbaaf34`，B 为 `e5ed4b4335e385edfe9a11503dab13a637ee79e8c34e0f62d3121a90732280dd`。清单与源码指纹为 `a-source.json` / `b-source.json`，实验补丁为 `repaint-candidate.patch`。

### A/B/B/A 实测

四轮均启用 `-CollectEnvironment`，期间无测试、构建或 CPU collector 并发；全部自行零退出，`validCapture=true`，帧 CSV 重算一致，未强制停止应用。

| 顺序 | UI p95 (ms) | raster p95 (ms) | 帧数 / 秒数 | 采样 FPS | 超过 60 Hz 预算 | 峰值采样 RSS (MiB) |
| --- | --- | --- | --- | --- | --- | --- |
| A1 | 28.772 | 4.848 | 836 / 30.002439 | 27.86 | 37.68% | 150.41 |
| B1 | 30.841 | 4.610 | 829 / 30.007751 | 27.63 | 45.60% | 149.59 |
| B2 | 23.518 | 4.544 | 916 / 30.007744 | 30.53 | 30.02% | 149.67 |
| A2 | 30.653 | 5.673 | 840 / 30.006251 | 27.99 | 53.57% | 149.47 |

保持万条无封面索引、5 秒预热、30 秒采样、10 秒单程的逐 vsync 高速往返滚动。四轮逻辑窗口均为 1265.333×682.667、DPR 1.5、165 Hz、文字倍率 1.0；extent 779620.333 logical px、速度 77962.033 logical px/s、三次方向改变，实际距离 2331014.355–2337153.320 logical px。没有框架错误、metrics 变化、生命周期中断或测量期无障碍变化。

四轮 `semanticsEnabled=true`，`supportsAnnounce=true`，其余七个 AccessibilityFeatures 为 false。不能把框架语义开启等同于某个系统屏幕阅读器正在运行，也没有关闭它来降低测量成本。

每轮 37 份环境观测，含一份启动前快照和 36 份精确应用句柄样本，CPU 计数器均有效。四轮 AC 始终接入、方案 GUID 相同，CPU 总体频率计数器均为 1515 MHz；进程 PowerThrottling 两个 mask 都为 0，即 `system_managed`，不是线程调度和系统 QoS 的完整结论。运行期 Processor Performance 平均值依次为 55.36%、55.90%、56.06%、53.44%；系统 CPU 平均值为 18.64%、19.99%、14.75%、23.20%，可用物理内存范围为 2.53–2.92 GiB。B2 与其他轮系统负载不同，但相关性不能证明因果；总体频率也不能代表 UI 线程每时刻的核心频率。

采集器首次目标进程查询及其他预热样本的整次 Read 最大约 67–84 ms。按探针开始时间加预热 5 秒近似划定测量期，每轮约 30 份观测，平均 Read 2.82–3.57 ms、最大 6.91–23.35 ms。这里记录的是外部采集器墙钟耗时，不是它的 CPU 消耗或某帧损失；没有做“开关采集完全零影响”的证明，因此 A/B 使用相同配置，不拿本轮绝对值直接当历史无采集运行的改进。完整字段见 `ab-summary.json` 和 `environment-window-summary.json`。

**撤回重绘候选。** B2 明显快于两次 A，但 B1 高于两次 A，当前样本不能证明稳定 UI 收益；不为这样的结果承担普通滚动/动画扩大重绘范围的代价。候选已完全撤回，最终 `lib/` 与基线相同。由于没有通过初步收益检查，不再追加已撤回候选的慢滚动性能实验。所有四轮 UI p95 均高于 16.7 ms，M5 性能仍未通过。

## 4. 回归与交付

新增两个 Windows 平台场景：1280×720 / 100% 与 800×600 / 200% 字号。验证真实 PNG、损坏封面回退、滚出再返回的实际像素，使用语义动作打开菜单/加入队列，确认缺失歌曲禁播且保留移除入口；已有小步滚动、当前背景、hover、分页和离焦测试继续复用。基线与候选定向合集均 **12/12 通过**。首次测试中的 FileImage/FakeAsync 等待冲突改为在 `runAsync` 中等待真实 IO，属于测试工具修正，不作为产品缺陷。

候选撤回后，完整 `flutter test --no-pub --reporter expanded` **342 项通过**（新增 2 项，52 秒），`dart analyze lib test tool` 无问题，见 `tests-final.txt`、`analyze-final.txt`。这些是框架与绘制回归，不代替原生键鼠、真实系统 DPI 或文件选择器验收。

最终格式检查为 **81 个文件、0 个变化**。首次检查发现撤回候选时产生的混合换行，修正后复查通过；最终 `git diff --exit-code -- lib` 为 0，产品源码与基线相同。初次与最终日志分别保留为 `format-initial.txt`、`format-final.txt`。

wrapper 更新后，在系统 PowerShell 5.1 复跑原有采集保护 **9/9 通过**：真实旧证据正对照、过期文件、生命周期中断、窗口指标变化、重复帧、帧数减少、伪造 p95，以及两种输出文件冲突。未启动应用，原始证据未改变，见 `capture-guard-results.json`。README、开发计划和本记录共 58 个本地链接有效，`git diff --check` 通过。

恢复正常入口 `lib/main.dart` 的 Windows Release 构建成功，耗时 172.3 秒，见 `build-normal.txt`。`app.so` SHA-256 为 `c1bdaa6a7159b9087a9d8825ca15743bb55568c7ff2afd4d4145dc490b3f0979`，与现有 dev.12 相同；原预览 ZIP SHA-256 仍为 `4ca066a1039ff9e5e743468f86fb1d54b0a11e7ff3ae72b759b2bbb2a1c4e06d`，没有重新打包，见 `normal-entry-and-package.json`。历史完整包验证结果继续引用上一轮记录，不计作本轮新执行的检查。

产品仍为 `0.1.0-dev.12+12`。本轮保留诊断工具、校验脚本、测试与文档，未创建正式 Release；物理出声与完整页面起播、真实系统操作/休眠/设备切换、干净机器、项目许可和原生对应源码门槛继续按 [开发计划](./05-Windows版本开发计划.md) 保留。
