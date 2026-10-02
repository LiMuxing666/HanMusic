# Windows M5 在线加载切歌（dev.26）

日期：2026-10-02。版本：`0.1.0-dev.26+26`。代码提交：`6a277c09620a31e890b1f6be00be3913b0b11e05`。M5 仍在进行中。

## 本轮改动

- 修复在线歌曲打开期间无法选择其他结果的问题：歌曲 A 正在打开时，只禁用 A 的行和播放按钮防止重复触发，其他歌曲 B 仍可通过鼠标或键盘选择。
- 为打开操作记录代次。切换到 B 后，A 的迟到完成不能解除 B 的等待状态，避免 B 尚未完成时恢复重复操作入口。
- 复用 `PlayerService` 已有的选择代次检查，旧歌曲的解析结果不覆盖新选择；本轮不增加网络协议、音频后端或依赖。
- 已进入原生音频加载的工作仍按既有串行屏障完成。允许用户提交新选择，不代表能即时中断已经开始的原生加载，也不承诺切歌延迟降低。

## 验证与交付

- **5 项定向测试通过**：`online_controller_test.dart` 中 `online opening` 前缀的两项场景，确认旧操作迟到成功或失败均不解除新操作的等待状态；`online_widget_test.dart` 中同前缀的两项场景，覆盖 800×600 / 200% 字号下鼠标选择和 Tab / Enter 键盘选择，A 等待期间可选择 B 播放，A 迟到不覆盖 B。
- `online_playback_test.dart` 既有 `replacing a source still serializes native loads` 场景通过，确认切换来源仍保留原生加载串行屏障；该项计入上述 5 项。
- 四个修改的 Dart 文件定向 `dart analyze` 无问题，格式检查 0 变化，`git diff --check` 及只读 review 通过。
- 本轮未运行全量回归或性能采集。

Windows 正常 `lib/main.dart` Release 构建通过。完整 ZIP：`D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.26-M5.zip`，21,003,126 字节，SHA-256：`bb8ed4ab7f18084266b5bdf8b7e03893cb2899ddfeb2661933fb72f866b4c8f9`。`BUILD-MANIFEST.json` 记录上述源码提交、`version=0.1.0-dev.26+26`、`gitDirty=false`、`publicReleaseReady=false`，文件清单为 35 项；包内 README 已包含在线加载期间切歌的说明和手工验收步骤。

开发机包检查 **6/6 通过**：ZIP 校验、完整清单、x64 运行库、系统 PowerShell 启动器 8 秒响应，以及数据目录锁持有/释放。记录：`D:\dev\tmp\hanmusic-m5-package-verification\验收 包 20261002-234200-780-e09eb380\verification.json`。没有执行 GUI 操作、实际播放、正常关窗或干净机验收；包的启动与手工验收步骤见[预览说明](./12-Windows预览运行与验收.md)。受控异步测试不代表真实网络、原生音频加载或 Windows 键鼠交互验收通过。

## 验收边界

真实 Windows 窗口中的鼠标/键盘切歌、慢网络下的等待提示、原生加载与实际出声仍需实机复核。控制器和框架测试不能替代真实网络、原生系统及正常关窗验收。

万曲性能、实际出声、真实休眠、系统缩放、干净机和发行条件仍按[开发计划](./05-Windows版本开发计划.md)保留；dev.26 仍为开发预览，M5 尚未完成。
