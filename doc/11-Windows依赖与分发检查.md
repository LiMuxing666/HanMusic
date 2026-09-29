# Windows 依赖与分发检查（M5）

审计日期：2026-09-29。范围为当前 `pubspec.lock`、本地 SDK/包源码，以及 `build/windows/x64/runner/Release` 现有构建产物。没有升级依赖、修改项目许可、构建或运行 GUI。本记录说明已核实的技术证据和待补材料，不把“能启动”视为发行条件全部满足。

## 1. 当前结论

可以生成供本机开发验证的 `development-preview` ZIP，保留完整 Release、Flutter 展开的 NOTICE、本记录、`licenses/`、锁文件和文件哈希。**目前不能将该预览包标注为已完成对外发行许可检查。** 把 ZIP 发给第三方仍需处理实际分发条件，“预览版”本身不是许可证豁免。

尚未闭合的主要事项：

1. 项目根目录没有 `LICENSE`、`LICENCE` 或 `COPYING`，README 也没有明确许可声明。需要由有权授权的人确认 HanMusic 原有代码、图标及新增代码的发布权限与最终许可；本轮未代替作者添加许可。GitHub 允许查看/fork 公开仓库，并不等同于取得任意软件再分发授权。[GitHub 官方许可说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)
2. `libmpv-2.dll` 的具体二进制来源已定位，但与该 DLL 对应的完整源码、补丁、构建脚本版本及全部静态依赖许可证尚未归档。不能用 `media_kit` 或原生包装插件的 MIT 文本替代这些材料。
3. 原生 FFmpeg 明确采用 LGPL 3 或更新版本。补充通用许可证文本只能补上部分告知材料，不能替代对应源码、重建/替换机制和发行条款核对。
4. VC++ 运行库需采用官方可再分发方式，并在无开发工具的干净 Windows x64 环境验证。现有开发机成功运行不能证明运行库已经随包解决。

## 2. 锁定版本与许可证层次

SDK 取自 `D:/dev/flutter/bin/cache/flutter.version.json`：Flutter **3.41.9**，framework `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`；engine `42d3d75a56efe1a2e9902f52dc8006099c45d937`；Dart **3.11.5**。SDK 不由 `pubspec.lock` 完整锁定，发布清单须同时记录这组版本。

下表按锁文件及 `D:/dev/cache/pub/hosted/pub.flutter-io.cn/<包名>-<版本>/LICENSE` 核对；不是只读取 pub.dev 标签。它列出直接依赖与重要 Windows 原生链，完整传递依赖仍以锁文件和 Flutter NOTICE 为准。

| 组件 | 锁定版本 | 已核对的包级许可/说明 |
| --- | --- | --- |
| Flutter、Dart | 3.41.9 / 3.11.5 | BSD 3-Clause；引擎包含另行列出的第三方组件 |
| get | 4.7.3 | MIT |
| file_picker / windows_file_picker | 13.1.0 / 2.0.0 | MIT |
| just_audio | 0.10.6 | MIT |
| just_audio_media_kit | 2.1.0 | **Unlicense**，不是 MIT |
| media_kit | 1.2.6 | MIT；不代表其调用的 libmpv 或随带第三方 JS 的许可 |
| media_kit_libs_windows_audio | 1.0.9 | 包装插件 MIT；下载的原生 DLL 另行审计 |
| audio_metadata_reader | 1.8.0 | MIT |
| path / crypto | 1.9.1 / 3.0.7 | BSD 3-Clause |
| path_provider / path_provider_windows | 2.1.6 / 2.3.0 | BSD 3-Clause |
| win32 | 6.4.0 | BSD 3-Clause |
| jni / jni_flutter | 1.0.3 / 1.0.3 | 包级 BSD 3-Clause；JNI 原生生成文件另含 AOSP Apache-2.0 来源 |

锁文件审计快照 SHA-256：`D286232CBBA98F8AF592070F768A172E3A5B8F2114463AC5FDE0CE3F8AACCA9C`。最终包如重新解析依赖，应重新生成本表及哈希，不能沿用旧验收。

## 3. Release 文件与 Flutter/Dart NOTICE

审计时顶层文件为 `han_music.exe`、`flutter_windows.dll`、`libmpv-2.dll`、`media_kit_libs_windows_audio_plugin.dll`、`dartjni.dll`、`native_assets.json`。`data/` 内还有 `app.so`、`icudtl.dat`、字体、shader、Flutter assets 和 `NOTICES.Z`。最终包应从本次完整 Release 复制，不能只交付 EXE。[Flutter 官方 ZIP 分发说明](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows)

本地核验结果：

- `NOTICES.Z` 可以用 GZip 解压；本次展开约 **1,415,170 字符**，包含 Flutter、Dart、JNI 及 Dart 包版权内容。
- `D:/dev/flutter/LICENSE` 与 `D:/dev/flutter/bin/cache/dart-sdk/LICENSE` 是 SDK 本体许可；`D:/dev/flutter/bin/cache/pkg/sky_engine/LICENSE`（Windows 文件系统不区分大小写）为约 1.3 MB 的引擎第三方许可汇总。
- `windows-x64-release/license.windows_flutter.md` 指向同一 engine commit 的 `sky_engine/LICENSE`，它本身只有来源指引，**不能只复制这份短链接说明代替许可证正文**。
- 解压后的 NOTICE 中没有 `libmpv`、`FFmpeg`；也没有 HLS 的 Dailymotion/Brightcove 或 JNI 的 2006 AOSP 版权行。因此展开 NOTICE 是必要的可读材料，但不是原生及资产审计的完整替代品。
- Release 实际携带 `data/flutter_assets/packages/media_kit/assets/web/hls1.4.10.js`。即使 Windows 播放路径不用它，打入 ZIP 的文件仍需附上对应许可。官方 v1.4.10 为 Apache-2.0，并保留 Dailymotion、Brightcove 来源说明；已放入 `licenses/`。[hls.js v1.4.10 官方 LICENSE](https://raw.githubusercontent.com/video-dev/hls.js/v1.4.10/LICENSE)
- `jni-1.0.3/src/third_party/global_jni_env.c` 和 `third_party/jni.h` 明确带 AOSP Apache-2.0 头；保留了原文归属与 Apache 正文，见 `licenses/README.md`。[Apache 官方许可证](https://www.apache.org/licenses/LICENSE-2.0)

审计时 `NOTICES.Z` SHA-256 为 `5FF932345563AC11E6E92D42D7AE612941E27BCFE9E3C0725CF1891A4280A957`；`flutter_windows.dll` 为 `92E7AA320AFE026E90780E4049DC6F6A480696400A269C179B1CCA0EF751D175`。这些是审计输入指纹，打包脚本仍应对最终文件重新计算。

## 4. libmpv 与 FFmpeg：已经定位什么，仍缺什么

### 4.1 可复核的二进制来源

`media_kit_libs_windows_audio-1.0.9/windows/CMakeLists.txt:66–70` 固定下载：

- 归档：`mpv-dev-x86_64-20230924-git-652a1dd.7z`
- [原维护者 2023-09-24 release](https://github.com/media-kit/libmpv-win32-audio-build/releases/tag/2023-09-24)
- CMake 固定 MD5：`cd738e16e2a19626d7cfa48801524f8c`；本地归档实测一致。
- 本地归档 SHA-256：`583AF5A291FC99AE2641794EDE1955C368EB4C19DC05F4F0A9C7F9456EDEB6A8`
- Release `libmpv-2.dll` SHA-256：`0A5A0B476866C91A639A4E511E8153968F8FA23564461B0AA09ACDBA816164A4`，大小 **15,525,902 字节**。
- release 指向 mpv commit：`652a1dd90711839acdccc08004056d25514ef2d8`；该构建发布仓库目前为归档只读状态。

用 `cmake -E tar tf` 检查原始 7z，只含四个 `include/mpv/*.h`、`libmpv.dll.a`、`libmpv-2.dll` 与目录项，**没有完整 LICENSE/NOTICE/源码包**。GitHub release 的三个上传附件是普通、dev、debug 二进制归档；其 tag `2023-09-24` 的 Git tree 只有 `version` 文件，所以页面自动生成的 “Source code” ZIP 也不是完整的 mpv/FFmpeg 对应源码。

### 4.2 许可判断基于 DLL 与对应上游文本

对 DLL 读取字节并提取字符串，没有加载或执行 DLL，得到：

```text
mpv v0.36.0-403-g652a1dd907
-Dgpl=false ... -Dlibmpv=true ... -Ddefault_library=shared -Dprefer_static=True
n6.0
--disable-gpl --disable-nonfree --enable-version3 --enable-static --disable-shared
LGPL version 3 or later
```

对应 mpv commit 的 `Copyright` 说明默认整体许可和 `-Dgpl=false` 模式不同，并特别指出链接库可能影响最终许可。因此本 DLL 中的 mpv 采用 LGPL 模式的证据充分，不能声称整包只有 MIT。[对应 mpv Copyright](https://github.com/mpv-player/mpv/blob/652a1dd90711839acdccc08004056d25514ef2d8/Copyright)

FFmpeg 内嵌许可字符串和配置共同指向 **LGPL-3.0-or-later**；`n6.0` 只提供版本线索，不能证明是否应用补丁。`--enable-static --disable-shared` 也说明不能因目录里只有一个 libmpv DLL 就忽略其内部 FFmpeg。FFmpeg n6.0 官方许可说明把 `--enable-version3` 与 LGPL/GPL v3 条款关联；已附 LGPL v3 及其引用的 GPL v3 正文，**附 GPL 正文不表示本次把 HanMusic 或该 FFmpeg 构建声明为 GPL 项目**。[FFmpeg n6.0 许可说明](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.0/LICENSE.md)、[LGPL v3 正文](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.0/COPYING.LGPLv3)

### 4.3 对应源码仍未闭合

mpv 指定 commit 的源码可以获取；[音频构建 recipe 仓库](https://github.com/media-kit/libmpv-win32-audio-cmake)也仍可访问。但当前 master 或按时间近似选出的提交不能证明就是这份 DLL 使用的完整 recipe：不同历史脚本的 GPL/FFmpeg 设置存在差异，不能机械把任意当前仓库压缩包当作对应源码。

公开发行前需要整理并验证：mpv 和 FFmpeg 的精确源码版本、全部 patches、原生静态依赖版本/许可证、构建配置与工具链、可实际取得的源码归档及哈希。根据所选择的 LGPL 分发路径，还需核对替换/重新链接所需材料与发行条款中对相关库修改、调试的限制。这里不把“动态加载 DLL”直接等同于全部义务已满足。[FFmpeg 官方合规清单](https://ffmpeg.org/legal.html)、[LGPL v3 第 4 节](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.0/COPYING.LGPLv3)

推荐先向原构建维护者核实这份 7z 的完整对应源码集合；如无法取得可验证材料，再评估自行制作可复现构建。此处只是后续发行方案，本轮没有替换或升级任何依赖。

## 5. VC++ 运行库与 JNI

本地 `CMakeCache.txt` 指向 VS 2022 Community MSVC **14.37.32822**；生成工程 Release 使用 `MultiThreadedDLL`。`dumpbin /dependents` 实测：

| 二进制 | 关键导入 |
| --- | --- |
| han_music.exe | Flutter/plugin DLL，`MSVCP140.dll`、`VCRUNTIME140.dll`、`VCRUNTIME140_1.dll`、UCRT/API-set 与 Windows 系统库 |
| media_kit_libs_windows_audio_plugin.dll | 同一组 VC++ 运行库及 UCRT |
| flutter_windows.dll | Windows 系统库；没有直接导入 `dartjni.dll` |
| libmpv-2.dll | UCRT/API-set 与 Windows 系统库；没有独立 FFmpeg DLL 导入 |
| dartjni.dll | `jvm.dll`、`VCRUNTIME140.dll`、UCRT 与系统库 |

当前 Release 顶层尚无上述三份 VC++ CRT DLL。可以由用户安装 Microsoft 官方 **x64 v14 Redistributable**，或由打包负责人依许可选择 app-local 可再分发文件。官方要求运行库架构匹配、版本不早于编译工具链；最新下载地址是可变目标，应另记实际安装/附带文件版本与哈希。[Microsoft 官方运行库下载与版本条件](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170)

Microsoft 明确把可再分发包及单独 DLL 的分发限制在相应 Visual Studio 授权及许可条款下，并提供 REDIST 清单和开发工具安装目录来源。对外发行时应由发行者核对资格与文件范围，不能从 `System32` 随意收集 DLL。微软推荐中央安装运行库以便服务更新；若选择 app-local，应来自可再分发目录并承担后续更新。[Microsoft Redistribute Visual C++ files](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170)

`dartjni.dll` **不是本轮认定的残留文件**：依赖链为 `path_provider → path_provider_android → jni/jni_flutter`，JNI 声明 Windows FFI 插件；`generated_plugins.cmake` 把其 `jni_bundled_libraries` 复制进 Release。本地有 JVM 时 `jni/src/CMakeLists.txt` 会构建该库，`jni/lib/src/jni.dart` 通过惰性的 `DynamicLibrary.open` 加载它。runner 并未直接链接该 DLL，项目 Windows 主路径也未调用 `Jni.spawn`；据此不能推导用户启动应用必须安装 JRE。当前策略是保留正式构建产物、**不捆绑 JRE**，并由干净机验证确认 Windows 路径不依赖本机 Java。

## 6. 包内材料与对外发行前清单

建议预览包保留如下结构（具体目录由打包脚本统一）：

```text
完整 Release 文件和 data/
THIRD_PARTY_NOTICES.txt       # 从本次 NOTICES.Z 原样解压，保留原文件
docs/11-Windows依赖与分发检查.md
docs/licenses/               # 连同 README 与所有原文一起复制
docs/12-...运行手册.md
pubspec.lock
BUILD-INFO / SHA256SUMS      # 版本、commit、SDK、架构、生成时间及实际文件指纹
```

打包时不要把这里列出的“待补”项目改成“已完成”。对外发布前逐项完成：

- 取得并记录 HanMusic 本身及资源的发行授权，确定项目 LICENSE；不得把第三方许可证挪为本库许可证。
- 补齐原生库对应源码/构建材料和完整第三方 attribution；确认选择的 LGPL 分发路径可实际履行。
- 将所有随包资产（含 HLS JS、JNI 生成代码、字体和引擎）的版权/许可证纳入材料；核对任何新增依赖。
- 选择并验证 VC++ 运行库部署方式；在没有 Flutter、Visual Studio、JDK 的 Windows x64 环境检查启动、音频、退出和配置保存。
- 检查包内没有开发者缓存、个人配置、音频测试素材或带鉴权信息的临时 URL；验证最终 ZIP 文件清单和 SHA-256。
- 决定正式签名与发布渠道。本次 EXE 签名状态为 `NotSigned`，不能标为已签名正式版；签名也不能替代许可证检查。

## 7. 复核办法

使用本机只读命令即可复核关键证据：`Get-FileHash -Algorithm SHA256`；VS 的 `dumpbin.exe /dependents <file>`；CMake 的 `-E tar tf <archive>`；`.NET GZipStream` 展开 `NOTICES.Z`；按 `.dart_tool/package_config.json` 定位锁定包源码。DLL 版本/编译配置来自只读字节字符串检查。最后对最终 ZIP 重新生成清单，不复用中间构建目录的文件哈希。

已补许可证文本的来源、范围和剩余缺口见 [licenses/README.md](licenses/README.md)。它们提供可审阅的原文，**尚未构成完整原生依赖对应源码交付或发行批准**。
