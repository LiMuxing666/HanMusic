# 免 Token 识曲与部署

**客户端与后台代码已准备，识曲服务尚未上线。** 当前先交付部署源码包；尚未配置服务地址的客户端会显示“识曲服务暂未开通”，开始按钮禁用，不会采样或发送音频。普通用户不需要、也没有入口填写 Token 或服务地址。

截至 2026-10-30，尚缺部署服务器、可用域名及运营方的真实 AudD 凭证。现有 Netlify 连接需要重新授权，不能用于本次部署；本机虽有 Docker CLI，Docker 引擎尚未启动。因此，本轮可以直接运行 Node 测试和准备源码 ZIP，但不能将它们写成镜像构建成功、公网服务上线或真实免 Token 识别通过。

[上一轮听歌识曲文档](47-听歌识曲.md)保留旧会话 Token 方案与 686 项测试、原生采样及公开样本 API 验收证据。它是历史记录，不是当前客户端的操作指南，也不能代替本轮后台部署验收。

## 客户端使用体验

| 状态 | 页面与行为 |
| --- | --- |
| 构建未配置服务地址 | 显示“识曲服务暂未开通”和“此版本暂不能使用听歌识曲，服务开通后即可直接使用。”；开始按钮不可用，不采样、不上传 |
| 后台已部署，使用已绑定服务地址的客户端 | 默认选择电脑声音，可改选麦克风；点击“开始识曲”后采样 12 秒并发送，不需要填写任何凭证 |
| 后台不可达、限额已用完或未匹配 | 显示对应提示；用户可取消或稍后显式重试，不自动持续采样或重试 |

开始按钮前说明：本次音频会发送至识曲服务，并由 AudD 完成识别；点击“开始识曲”或“再试一次”表示同意本次采样和发送。电脑声音是 Windows 默认输出设备的声音，可能包含其他应用同时播放的内容；麦克风使用默认录音设备。

识别结果显示歌名、歌手、专辑和发行日期，可复制歌名或跳转本地/在线搜索，不自动播放。取消、离开页面和退出应用会取消任务；旧任务迟到结果不会复活，已发送的音频无法撤回。保存失败后选择“返回播放器”，识曲操作恢复可用。

本轮不增加识曲录音档案或客户端凭证持久化，应用状态仍为 **schema 5**；曲库、队列、歌单、历史和设置的既有迁移规则不变。

## 服务与凭证的边界

请求路线为：Windows 客户端采样 → 自托管识曲服务 → AudD → 返回歌曲信息。

- 客户端向公开的 HTTPS `/v1/recognize` 端点发送原始 WAV 请求体，`Content-Type: audio/wav`。客户端不直接提交 AudD Token。
- 运营方只在服务器环境配置 `AUDD_API_TOKEN`。它不进入 Flutter 编译参数、客户端、应用设置、歌单或交付源码 ZIP。
- 客户端仅在构建时配置公开地址 `HANMUSIC_RECOGNITION_URL=https://域名/v1/recognize`。地址不是密钥；页面不展示开发参数或要求用户自行配置。
- 未配置地址的旧构建不会在后台上线后自动获得地址。服务准备好后，需要生成并交付绑定正确地址的新客户端。

服务已配置不等于服务可用。带地址的客户端必须在发布前完成真实 HTTPS 访问及识别验收；服务额度、音频质量和第三方匹配结果仍会影响识别成功率。

## 生成交付包

从项目根目录用 PowerShell 7 生成后台源码包：

```powershell
pwsh -NoProfile -File .\tool\package_recognition_server.ps1
```

默认输出：

- `build/recognition-delivery/hanmusic-recognition-server.zip`
- `build/recognition-delivery/SHA256SUMS.txt`

后台源码位于 [`server/recognition`](../server/recognition/README.md)。打包脚本按允许列表收集源码、测试、`package.json`、`Dockerfile`、`.dockerignore`、`.gitignore`、`.env.example`、`Caddyfile.example` 与服务 README；真实 `.env`、预算数据、日志和运营凭证不属于交付内容。ZIP 是可部署源码，不是已经构建好的镜像或正在运行的服务。

后台及 HTTPS 端点准备好后，构建绑定该端点的 Windows 客户端。以下域名只是格式示例，执行时必须替换为已验收的真实地址：

```powershell
pwsh -NoProfile -File .\tool\build_recognition_release.ps1 `
  -RecognitionUrl 'https://recognition.example.com/v1/recognize'
```

脚本将公开地址写入 `HANMUSIC_RECOGNITION_URL`，构建默认 `lib/main.dart`，随后输出 `build/recognition-delivery/hanmusic-windows-recognition.zip` 及 `client-release.json`。ZIP 包含完整 Release 目录，运行时须保留全部依赖 DLL 与 `data` 目录，不能只复制 `han_music.exe`。客户端包不包含任何 AudD 商用密钥。

这份 Windows ZIP 是识曲功能构建交付物，不能替代既有干净机、许可与正式发行检查；现有 rc.2 发行门槛仍保留。

## 运营方部署步骤

详细配置及可执行部署命令以[后台 README](../server/recognition/README.md)为准。当前部署目标是单进程 Node 服务配合 HTTPS 反向代理，不应直接扩为多个各自计数的副本。

1. **准备资源。** 提供可运行 Node 22 或更新版本的服务器、已解析到该服务器的域名，以及具有可用额度的运营方 AudD 凭证。运营凭证仅在部署主机配置。
2. **传送源码包并检查内容。** 校验 ZIP 的 SHA-256，在服务器解压，阅读服务 README 与 `.env.example`。本服务没有第三方 Node 运行依赖；可在 `server/recognition` 目录用 `npm test` 运行本地测试。
3. **配置环境和持久化预算。** 按下表配置服务环境；直接运行时将环境传给 `npm start`，使用容器时按后台 README 的环境文件和持久卷方案启动。不要把真实 `.env` 放回源码交付包。
4. **启动并检查本机服务。** 默认仅监听 `127.0.0.1:8787`，以 `GET /healthz` 检查就绪状态。已配置运营凭证且预算存储未发生写入故障时返回 200，否则返回 503；检查不发送音频、不消费额度，也不能证明 AudD 凭证有效或公网识别链路已验收。
5. **配置 HTTPS。** 参考 `Caddyfile.example`，替换为真实域名，由同机 Caddy 反向代理到本机服务。按后台 README 配置可信代理与转发 IP，避免把客户端自行提供的转发头当成真实来源。
6. **验证实际识别。** 使用允许发送的测试音乐片段，确认 HTTPS 端点接受 `audio/wav` 并返回歌曲信息；同时检查无匹配、限额、并发、断网和取消场景。服务重启后还应确认当日预算没有被清空。
7. **构建并复核客户端。** 用上面的构建脚本绑定已验收地址，解压完整 Windows 包，确认无需配置凭证即可一键识曲，退出、重试及本地/在线搜索仍正常；再交付该客户端。

| 服务配置 | 默认值及作用 |
| --- | --- |
| `AUDD_API_TOKEN` | 无默认值；只在服务器环境提供的运营凭证 |
| `HOST` / `PORT` | `127.0.0.1` / `8787`；默认不直接向公网开放 Node 端口 |
| `IP_LIMIT_HOUR` | `10`；每个 IP 滚动一小时最多 10 次上游尝试 |
| `DAILY_LIMIT` | `100`；单实例全局 UTC 日上游尝试预算 |
| `BUDGET_FILE` | `./data/budget.json`；每日预算原子持久化，向上游请求前先消费，失败也计入预算 |
| `MAX_CONCURRENT` | `2`；覆盖请求体接收、样本校验和上游识别过程 |
| `TRUST_PROXY_LOOPBACK` | 默认 `false`；默认不相信外部传入的转发 IP 头，仅按后台 README 对同机代理启用 |

Docker 方案使用非 root 的 `node` 用户与 `/data` 持久卷；应保持卷可写且不随容器重建删除。IP 小时额度只在内存中，重启会重置；全局日预算须从持久存储恢复。服务按单实例独占预算运行，独占保护不能充当多实例共享配额；升级时先停旧实例再启新实例，保留同一预算卷。服务端限额与运营方 AudD 账户额度同时约束可用次数，不代表无限免费识别。

## 本轮验证状态

以下为 2026-10-30 在 `D:\project\HanMusic` 工作副本的验证记录。此前 686 项测试属于旧 Token 版本。

| 项目 | 当前记录 |
| --- | --- |
| Flutter 定向与全量测试 | 识曲专项 39/39；全量 688/688。日志：`build/gateway-client-tests.log`、`build/gateway-full-tests.log` |
| 静态分析、格式与空白检查 | 正式源码范围 `flutter analyze --no-pub lib test tool` 无问题；143 个 Dart 文件格式检查零修改；`git diff --check` 通过。根目录无范围分析会包含旧 `build/parity-smoke-data` 探针的两条 info，本次未修改这些历史临时文件 |
| Node 服务直接测试 | Windows / Node 24.15.0，源码与解压交付包均通过 30/30（28 个实际用例、2 个自动发现的辅助模块），无跳过；覆盖额度持久化、并发、限流、取消、异常响应和独占锁。解压验收日志：`build/gateway-package-tests.log`。Linux 内核锁及容器运行仍待部署主机验证 |
| Dart 客户端 → Node 后台联调 | 使用实际客户端仓库代码、合成 WAV 和本机模拟上游通过；客户端无凭证，后台添加测试凭证，响应裁剪且额度记账一次；无外网请求。日志：`build/gateway-e2e-result.log` |
| 后台源码 ZIP 内容及 SHA-256 | `build/recognition-delivery/hanmusic-recognition-server.zip`，20 个文件、26,870 字节；检查无真实环境文件、运行数据、日志或密钥。解压后测试通过，清单及摘要见同目录 `package-contents.txt`、`SHA256SUMS.txt` |
| 未配置服务地址的 Windows 构建 | 默认 `lib/main.dart` Release 构建成功，日志：`build/gateway-windows-build.log`。通过 Computer Use 观察真实窗口：无 Token/地址表单，显示“暂未开通”，开始按钮灰显；未配置不采样/不请求由专项测试验证。仅查看界面，没有发送用户音频，随后正常退出 |
| 已绑定真实服务地址的 Windows ZIP | 尚待服务器、域名及运营凭证就绪后构建并验收 |
| Docker 镜像构建与容器运行 | 未验收；本机 Docker 引擎尚未启动 |
| 公网 HTTPS 与真实免 Token 识别 | 未验收；识曲服务尚未上线 |

交付 ZIP 的 SHA-256：

```text
C907AEA8BF1287C9E33DCF46913648F3E6D9F8C9A99F4D95CEE22554316140F9
```

`tool/build_recognition_release.ps1` 已通过语法检查，且调用实际 Dart 配置校验器验证端点：公开 HTTPS 示例通过，私网地址拒绝。真实服务尚未就绪，所以本轮没有生成绑定虚假地址的客户端 ZIP。

文档中的命令是交付与部署步骤，不表示已经在公网执行。部署完成后，应把实际域名、版本、预算持久卷、检查结果及日志位置补入运维记录；不要在文档或日志中写入运营凭证。
