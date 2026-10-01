# Windows M5 曲库焦点与退出导入

日期：2026-10-01。开发基线 `a90fc2c`，证据目录为 `D:\dev\setup\verification\m5-library-identity`。SDK、Pub、Gradle、临时文件及预览产物继续放在 D 盘，没有升级依赖或修改系统设置。

## 1. 缺陷与修复

曲库列表原来只在行内 InkWell 设置歌曲 ID Key，最外层列表子项没有身份映射。聚焦某首歌曲后，移除它前面的歌曲会改变索引；Flutter 按旧索引更新子项，原歌曲的焦点节点随旧子树销毁。即使该歌曲仍在曲库，用户也无法继续对它使用键盘操作。

在 Windows 平台的 1280×720 / 100% 和 800×600 / 200% 字号下，各自测试焦点行可见与 PageDown 后离屏保活两种状态。最终同一份测试在修复前四项均于前方删除后的焦点身份检查失败，原焦点 Element 已成为 DEFUNCT，见 `widget-red-final.txt`。测试使用框架内 Tab/PageDown/Enter 和 Controller 曲库操作，不能替代真实 Windows 键鼠或系统 DPI 验收。

修复为最外层行设置稳定歌曲 ID Key，并提供 `findChildIndexCallback`，让列表按歌曲身份找回新索引；删除的歌曲返回 null。索引映射按当前歌曲快照按需建立，不在每个滚动帧线性查找。内部操作 Key、行高、缓存范围、自动保活、文字、封面和菜单保持原实现。

## 2. 退出期间的迟到文件选择

退出开始原先只取消 LibraryService 已经创建的导入任务。如果原生文件/目录选择器仍在等待，此时没有导入 token；选择器在最终保存期间返回有效路径，Controller 尚未关闭，便会开启新导入。最终保存可能已经截取旧曲库，新增歌曲触发的延迟保存又会被退出清理取消，造成已显示导入的索引没有落盘。

当前锁定的 `windows_file_picker 2.0.0` 默认不锁定父窗口，因此不能用“对话框打开时无法关闭主窗口”排除该序列。真实 HanMusicApp、可控 picker 和保存 Future 的框架退出测试，在原代码的文件/目录/单曲三个入口均复现失败：前两个在旧保存快照之后入库，单曲入口实际发出了音频加载，见 `exit-picker-red.txt`。这是受控异步序列证据，尚未操作真实原生选择器或系统关闭按钮。

Controller 新增退出门禁和导入 generation，从等待 picker 到导入结束都检查结果是否仍有效。退出开始同步使旧操作失效，再进行最终保存；取消退出仅解除门禁，旧成功/错误仍被忽略。活动操作 token 独立负责 finally 清理，保留未结算选择器的忙碌状态，避免开启第二个原生对话框。原 Picker API 不能主动关闭已打开的对话框，用户仍需结束它，随后才能重新导入。main 通过注册检查兼容尚未创建 Controller 的生命周期边界。

新增六项集成回归和三项 Controller 单元回归：三入口各覆盖最终保存后的迟到选择、取消退出后等待旧选择器结束并重新导入、退出门禁和旧错误不覆盖当前提示。Controller 与退出集成定向合集 **32 项通过**，见 `exit-picker-green-final.txt`；定点静态检查通过。首轮测试因单曲加载动画令 `pumpAndSettle` 无法结束而主动中止，改用有界 pump 后完整重跑通过；该失败属于测试等待方式，原日志 `exit-picker-green.txt` 保留。

## 3. 功能回归

曲库新增四项回归连续覆盖：删除目标前方歌曲、筛选仍保留目标、清除筛选，以及目标本身被删除。目标保留时 FocusNode 不变，Enter 只播放它；目标删除后，Enter 不会误激活替代索引的歌曲。复用万曲长距离跳转、键盘分页及离焦后回收测试，定向合集 **8/8 通过**，见 `widget-green-final.txt`。首次增强用例在紧凑大字号下尚未把第三行滚入视口，修正测试前置滚轮步骤后，用最终同一测试重新执行修复前失败和修复后通过，源码恢复指纹见 `restoration-verification.json`。

两处修复完成后，全量 `flutter test --no-pub --reporter expanded` **355 项通过**（本轮新增 13 项，64 秒），`dart analyze lib test tool` 无问题，格式检查 **81 个文件、0 个变化**。日志为 `tests-final.txt`、`analyze-all-final.txt` 和 `format-all-final.txt`。两处补丁经过独立代码复核；未注册 Controller 的退出分支仅做源码检查，新增集成测试没有单独模拟该分支。

## 4. 性能复核

修复前对照复用已冻结的 `D:\dev\tmp\hanmusic-m5-actions-ab\baseline`，没有冒称新构建。全部 16 个文件的大小和哈希与上轮 `a-source.json` 一致；`5bc551a` 与 `a90fc2c` 的 lib Git 树相同。冻结构建的探针源码 SHA-256 与当前一致，均为 `ae516cac83326c55d9cec666414be5843ba80faaf9568bbc65d95e8dfe4e197a`；编译常量仍为 `HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-m5-performance`。构建输入以原始指纹和 `reused-baseline.json` 为准，不能仅凭旧 baseCommit 推定全部输入。

修复版以相同探针和编译常量构建 Profile，耗时 186.7 秒，仍使用 dev.12 构建号以便对照；最终正常入口另以 dev.13 打包。完整目录冻结在 `D:\dev\tmp\hanmusic-m5-identity-ab\fixed`，源码在构建前后的哈希一致。两目录各 16 个文件，仅 `data/app.so` 不同：A 为 `5271fdcb5a303c49340acade34095ec73e58bd315f4b363036f439013cbaaf34`，B 为 `76a82059c159072613b43fbdec55957796ff65fda63c26b28ff60a2fb0da81c0`。见 `fixed-source.json`、`production.patch`、`bundle-comparison.json`。

首组 A/B/B/A 中 B 的 UI p95 高于两次 A，因此增加定点路径检查和反向顺序 B/A/A/B 复测。临时 assert 仅用于 Debug 框架测试：12 次万曲长跳期间身份查找回调 **0 次**，滚动阶段之外 9 次；说明这些长跳没有逐帧重建索引映射。两项诊断测试通过，生产文件和测试文件已逐字节恢复，SHA-256 与修复前诊断起点一致，见 `remap-frequency.json`。这不能代替 Profile 耗时证据，也不排除每行新增 key 的开销或曲库变更时的 O(N) 映射成本。

八轮均启用 `-CollectEnvironment`，保持万条无封面索引、5 秒预热、30 秒采样、10 秒单程高速往返，期间没有测试、构建或 CPU profiler 并发。所有运行自行零退出，`validCapture=true`，CSV 复算一致，没有强停、框架错误、窗口指标/生命周期或无障碍状态变化。

| 顺序 | UI p95 (ms) | raster p95 (ms) | 帧数 | 采样 FPS | 峰值采样 RSS (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 | 31.194 | 5.903 | 860 | 28.66 | 149.27 |
| B1 | 32.898 | 5.381 | 841 | 28.02 | 150.07 |
| B2 | 36.904 | 5.067 | 795 | 26.49 | 148.49 |
| A2 | 30.833 | 5.437 | 831 | 27.67 | 150.14 |
| B3 | 63.345 | 5.275 | 608 | 20.25 | 149.45 |
| A3 | 32.413 | 5.256 | 828 | 27.59 | 149.51 |
| A4 | 45.538 | 4.960 | 745 | 24.81 | 149.29 |
| B4 | 33.851 | 4.869 | 802 | 26.72 | 149.02 |

逻辑窗口均为 1265.333×682.667、DPR 1.5、165 Hz、字号 1.0；最大 extent 779620.333 logical px、三次方向改变。全部保持 `semanticsEnabled=true`、`supportsAnnounce=true`、其余七项 accessibility features 为 false，没有关闭无障碍以压低数据。每轮 37–38 份环境观测，其中 36–37 份为目标进程存活期间；计数器有效，AC 接入、均衡方案 GUID 和总体频率 1515 MHz 一致，进程 QoS masks 为 0，仅说明 system managed。系统 CPU 平均占用依次为 26.10%、25.40%、28.76%、26.96%、33.60%、20.83%、22.27%、22.01%，这些总体值不能证明具体线程调度或 p95 差异的原因。

**M5 性能仍未通过，且本轮不能证明没有回退。** A 的四个单轮 UI p95 为 30.833–45.538 ms，B 为 32.898–63.345 ms；单轮 p95 的中位数分别为 31.804 / 35.378 ms，B 约高 11.2%（不是合并全部帧后重新计算的 p95，也不是统计显著性结论）。相同旧基线也出现明显波动，不能把全部变化归因于代码；同样不能用波动排除新增 Key 的实际开销。保留解决焦点正确性的补丁，继续把性能差距和潜在回退列为待定位问题，不宣称滚动优化达标。原始八组 JSON/CSV/session、首组摘要及完整 `capture-summary.json` 均保留，原 16.7 ms 目标不变。

## 5. 交付与边界

从干净提交 `59212202abfdb183fac3f1c77fb11c38ae13a7ec` 重建正常入口 `lib/main.dart` 的 Windows Release，耗时 121.3 秒。产品版本为 `0.1.0-dev.13+13`，完整 ZIP 为 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.13-M5.zip`，大小 **20,496,795 字节**，SHA-256 为 `4569c44847be147d4062bd7b46eb1411f82508cae90714e3cb1bd1be7ce97dae`。34 个内容文件加清单共 35 个文件，`gitDirty=false`、`entryPoint=lib/main.dart`、`publicReleaseReady=false`；正常应用 `app.so` SHA-256 为 `bd6670ecb5a4ea87bfce6c2bdd9f27c52833ccfe804db792fbb83fbab21c5383`。构建日志为 `package-dev13.txt`。

使用系统 PowerShell **5.1.26100.9444** 在 D 盘独立中文、空格目录解压，完整包 **6 项检查通过**：ZIP 校验、所有清单文件哈希与无预置 UserData、x64 运行库检查、用户启动器八秒响应、运行中独占数据目录，以及停止后的锁释放。启动器返回 0，数据创建在解压目录的 D 盘 UserData；锁冲突 Win32 错误为 33，精确核对本轮 PID/EXE/启动时间后停止测试进程，首次重试 23 ms 取得锁。应用及辅助进程均已清理，报告为 `package-verification-dev13.json`。

这六项是开发机上的完整性、启动和进程锁检查；强制结束不等于正常关窗或持久化验收，没有在该包上操作页面播放、原生选择器或干净机器。四份修改文档共 51 个本地链接检查通过，`git diff --check` 通过。

真实物理出声和完整页面起播、原生系统对话框/窗口/休眠/设备切换、真实系统 DPI、干净 Windows 机器和发行授权/原生对应源码门槛继续按 [开发计划](./05-Windows版本开发计划.md) 保留。M5 完成前不标记正式 v0.1，也不开始依赖它的 M6。

后续优先验证一条代码审查线索：拖动队列歌曲期间，通过已聚焦的上/下移按钮改变相同长度队列，松手时 Flutter 可能仍提交原拖拽索引。当前只有源码路径证据，尚未复现；需要先构造框架混合输入回归，再决定是否修复，不能把它列为本轮已修复缺陷。
