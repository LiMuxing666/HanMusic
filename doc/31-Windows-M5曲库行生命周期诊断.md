# Windows M5 曲库行生命周期诊断

日期：2026-10-02。目的仅是确认万曲高速滚动时列表行是否反复创建；正常产品仍为 `0.1.0-dev.16+16`，本轮没有重新打 Release 包，也不把诊断帧率用于 M5 性能验收。

## 计数口径

真实 `PlayerPage` 的曲库 `ListView.builder` 在传入 `LibraryRowLifecycleDiagnostics` 时，才为每个 Sliver 直接子节点加透明 `StatefulWidget` 包装。其 `initState`、`dispose` 记录行 Element 挂载和销毁，`_LibrarySongRow.build` 记录行构建；未传入时保持原有直接子节点及 `ValueKey(song.id)`。诊断包装仍以歌曲 ID 为 Sliver 直接子节点的 Key。探针在测量首末帧之后各读取一次累计计数，取差值；此机制只在独立 Profile 诊断入口启用。

曾尝试通过 VM Service `getAllocationProfile(reset:true)` 获取累计分配，但原始 `run-01` 的 `_LibrarySongRow` 数值从 59 降到 42，四类对象的 `instancesAccumulated` 始终等于 `instancesCurrent`。核对本机 Dart 3.11.5 的 [ClassTable 实现](https://raw.githubusercontent.com/dart-lang/sdk/3.11.5/runtime/vm/class_table.cc) 后确认两个字段都来自当前堆对象数；不能用它们推算本轮创建量。VM 查询也打断了近同期帧窗口，原探针以退出码 1 正确拒绝；失败原件保留在 `D:\dev\setup\verification\m5-allocation-dev16\run-01`，未据此修改产品或性能结论。采样式 `getAllocationTraces` 不能保证 20 秒窗口内的精确创建次数，因此没有继续沿用 VM 计数方案。

## 独立诊断结果

使用 D 盘冻结的 16 文件 Profile 包 `D:\dev\tmp\hanmusic-m5-row-lifecycle-bundle-r1`，`app.so` SHA-256 为 `3fdc4c2ed0bca241392e82e382e0343c5f2fce65342567e688ca99b3d5b21fe8`。程序自行退出码 0、`completed=true`、无框架错误。结果与原始帧 CSV 位于 `D:\dev\tmp\hanmusic-m5-row-lifecycle-r1`。

负载仍为 10,000 条确定性合成索引、无封面；5 秒预热后连续往返滚动 **30.008 秒**，窗口 1265.333×682.667 逻辑像素、DPR 1.5、165 Hz、字号倍率 1.0，测量期间窗口指标与无障碍设置未变化。期间曾收到一次 `inactive` 生命周期事件；计数不代表用户普通滚轮或真实曲库文件负载。

| 30 秒测量差值 | 宽行 | 窄行 |
| --- | ---: | ---: |
| 行 Element 挂载 | 10,007 | 0 |
| 行 Element 销毁 | 10,006 | 0 |
| `_LibrarySongRow.build` | 10,007 | 0 |

每秒约挂载 333 行。宽行源码每次构建含 5 个 `Text`，因此按结构推算约 **50,035 次 Text widget 构造**；这不是实测 `RenderParagraph` 分配或文字布局耗时。高频行创建已确认，但无法单凭次数将 UI 耗时归因于文字，也没有证明改变 `cacheExtent`、合并文本或共享组件会带来收益。该诊断增加包装，结果中的 UI p95 即使可读也**不得**与无包装基线比较或用于 16.7 ms 门槛。

## 本轮验证与下一步

只对改动的两个页面文件和探针入口做 `dart analyze`，运行一项现有万曲跳转 Widget 测试；诊断入口通过 Profile 构建和上述一次实测。五份改动文档的 67 个相对链接均可解析，`git diff --check` 无问题。未跑 374 项全量回归、未构建正常 Release 或生成新开发包。下一步应在保留歌曲身份、焦点、无障碍和相同滚动负载的前提下，选一个能减少实际行/文本工作量的单变量候选，做与无包装基线匹配的测量；若没有稳定收益就撤回。M5 万曲性能仍未通过，其他原生交互、干净机和发行门槛仍按[开发计划](./05-Windows版本开发计划.md)保留。
