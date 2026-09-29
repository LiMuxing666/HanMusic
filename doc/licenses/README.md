# 补充第三方许可证与来源

收集日期：2026-09-29。下列原文是 [Windows 分发检查](../11-Windows依赖与分发检查.md) 的补充材料。请把本目录整体随该检查文档复制，并同时保留本次构建生成的 Flutter `NOTICES.Z` 及其展开文本。

**这些文件不授予 HanMusic 本身新的许可，也不表示原生库对应源码已经交付完整。** mpv 具体 commit 已知；FFmpeg 二进制包含 `n6.0` 及 `LGPL version 3 or later`，但精确补丁、静态依赖和整套构建源码仍待确认。FFmpeg 许可原文取自官方 n6.0，用于说明已辨认出的许可条款，不是宣称 n6.0 仓库与 DLL 完全可复现对应。GPL-3.0 正文与 LGPL-3.0 一并保留，因为 LGPL-3.0 引用 GPL-3.0 条款；它不是给本项目换许可证。

| 本地文件 | 原始来源 | 覆盖范围 |
| --- | --- | --- |
| [mpv-Copyright.txt](mpv-Copyright.txt) | [mpv 652a1dd90711839acdccc08004056d25514ef2d8 / Copyright](https://raw.githubusercontent.com/mpv-player/mpv/652a1dd90711839acdccc08004056d25514ef2d8/Copyright) | 指定 mpv 源码的许可模式与例外说明 |
| [LGPL-2.1.txt](LGPL-2.1.txt) | [同一 mpv commit / LICENSE.LGPL](https://raw.githubusercontent.com/mpv-player/mpv/652a1dd90711839acdccc08004056d25514ef2d8/LICENSE.LGPL) | mpv LGPL 模式许可正文 |
| [FFmpeg-LICENSE-n6.0.md](FFmpeg-LICENSE-n6.0.md) | [FFmpeg n6.0 / LICENSE.md](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.0/LICENSE.md) | FFmpeg 原始许可说明与构建选项关系 |
| [LGPL-3.0.txt](LGPL-3.0.txt) | [FFmpeg n6.0 / COPYING.LGPLv3](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.0/COPYING.LGPLv3) | 已辨识的 FFmpeg LGPL v3 条款 |
| [GPL-3.0.txt](GPL-3.0.txt) | [FFmpeg n6.0 / COPYING.GPLv3](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.0/COPYING.GPLv3) | LGPL v3 所引用的通用条款 |
| [hls.js-1.4.10-LICENSE.txt](hls.js-1.4.10-LICENSE.txt) | [hls.js v1.4.10 / LICENSE](https://raw.githubusercontent.com/video-dev/hls.js/v1.4.10/LICENSE) | 随 media_kit 资产包携带的 JS；Dailymotion 与 Brightcove 原始 attribution |
| [Apache-2.0.txt](Apache-2.0.txt) | [Apache Software Foundation 官方全文](https://www.apache.org/licenses/LICENSE-2.0.txt) | HLS 与 JNI 的 Apache-2.0 原始条款 |
| [JNI-AOSP-ATTRIBUTION.txt](JNI-AOSP-ATTRIBUTION.txt) | 本地锁定 `jni-1.0.3/third_party/jni.h` 原始文件头；`src/third_party/global_jni_env.c` 保留同一 AOSP 许可头 | JNI 原生生成代码的 2006 Android Open Source Project attribution；不是完整 JNI 源码 |

JNI 锁定包由 `.dart_tool/package_config.json` 定位，根目录 `LICENSE` 为 Dart BSD 条款且已进入 Flutter NOTICE；本文件补充的是其内部 AOSP Apache 来源。JNI 源码包锁文件 SHA-256 为 `f038e58b4dc2c9037f50e233175086337e0b305e356d28211bf55f21c504cbd3`。

## 原文校验值

前七份文件从上述官方地址直接保存，未改写正文。JNI 文件是按原始头注释边界提取并添加一个末尾换行，保留版权与许可文本。可用 `Get-FileHash -Algorithm SHA256` 复核；最终包另外生成整包文件清单。

| 文件 | SHA-256 |
| --- | --- |
| mpv-Copyright.txt | `CA8F78358716FF15098BF681E07D508007E4E5F1BBCBEFC5D859BEF55559D00D` |
| LGPL-2.1.txt | `DC626520DCD53A22F727AF3EE42C770E56C97A64FE3ADB063799D8AB032FE551` |
| FFmpeg-LICENSE-n6.0.md | `CB48BF09A11F5FB576CDDB0431C8F5ED0A60157A9EC942ADFFC13907CBE083F2` |
| LGPL-3.0.txt | `DA7EABB7BAFDF7D3AE5E9F223AA5BDC1EECE45AC569DC21B3B037520B4464768` |
| GPL-3.0.txt | `8CEB4B9EE5ADEDDE47B31E975C1D90C73AD27B6B165A1DCD80C7C545EB65B903` |
| hls.js-1.4.10-LICENSE.txt | `CA8773CF798C7ED997D4DD7C8E23C348699F8D5B7462636694CC14DE6CDA12DB` |
| Apache-2.0.txt | `CFC7749B96F63BD31C3C42B5C471BF756814053E847C10F3EB003417BC523D30` |
| JNI-AOSP-ATTRIBUTION.txt | `AD70C73DB807EC83A8041BB3D61F819E049A9F244AD572F7C554566965F69017` |

## 还没有覆盖的事项

此目录没有提供原生 mpv/FFmpeg 全套对应源码、全部静态链接依赖的源码/许可证或发行者自己的 LGPL 履行方案；也没有处理 HanMusic 项目自身授权、Visual C++ 运行库再分发资格、签名或干净机运行验收。后续取得原生构建材料时，应继续补充实际依赖的 attribution，不能仅增加一个“MIT”或“LGPL”标签后结束审计。
