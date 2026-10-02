# Windows M5 中文歌曲标题字体复核

日期：2026-10-02。用户提供 dev.15 桌面截图（2560×1536），反馈部分中文显示变形，并明确指出歌曲标题最明显。截图中的歌名与下方文件名基本一致，没有明显乱码、缺字方框或元数据截断；普通歌曲标题的中文字形比同一行拉丁字母更细且笔画不均，当前歌曲的粗体标题相对正常。这是视觉线索，不能仅凭静态图片断言唯一原因。

## 字体候选修复

原 `HanMusicTheme` 没有指定 `fontFamily`。当前 Flutter Windows Material 排版默认以 Segoe UI 为主，汉字交给系统字体回退；普通曲名使用 `FontWeight.w500`，当前曲名使用 `w700`。在本机环境中，`Microsoft YaHei UI` 同时提供 Regular 与 Bold 字体。现在将主题字体统一设为 `Microsoft YaHei UI`，缺失时依次尝试 `Microsoft YaHei`、`DengXian`；普通曲名改为对应 Regular 的 `w400`，当前曲名保持对应 Bold 的 `w700`，减少合成字重的风险。Flutter 的[字体指南](https://docs.flutter.dev/cookbook/design/fonts)说明主题可统一字体，缺少对应字重时引擎可能推算字形。歌曲标题、歌手、专辑和文件名的字符串处理均未改动。

这轮只修改字体家族与普通曲名字重，未改字号、布局代码、缩放规则或无障碍设置；字体度量变化仍可能影响字宽、行高和换行，真实窗口须同时检查侧栏、按钮、弹窗及 150%/200% 缩放。`GetMaterialApp` 尚未显式设置中文 locale；中文排版几何可能另有差异，但它不能单独解释截图中的笔画轮廓，本轮不把本地化与字体候选混在一起。

## 验证边界

本机字体清单确认 `Microsoft YaHei UI` 有 Regular 和 Bold。`flutter analyze --no-pub` 无问题，`dart format --output=none --set-exit-if-changed lib test tool` 检查 82 个文件、0 个待格式化，串行全量 `flutter test --no-pub --concurrency=1` **374/374 通过**，日志为 `D:\dev\tmp\hanmusic-dev16-analyze.txt` 和 `D:\dev\tmp\hanmusic-dev16-tests.txt`。这些检查覆盖布局与业务回归，不能代替同一首歌曲在真实 Windows 窗口里的新旧截图对比。dev.16 需要由用户在相同屏幕缩放下重看普通曲名（例如截图中的“G.E.M. 邓紫棋…”）和当前绿色标题，判断笔画是否恢复正常。其他干净 Windows 机器的字体可用性仍属于 M5 验收，不将本机结果推广为跨机器保证。
