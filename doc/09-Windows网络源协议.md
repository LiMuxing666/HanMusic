# Windows M4 网络源协议

更新：2026-09-29。用户选择先推进通用协议，本阶段只接入无需认证的 HTTP(S) JSON GET 服务，不绑定商业音乐平台。完整配置见 [本地测试源 JSON](./examples/online-source.local.json)，对应实现为 `OnlineSourceConfig`、`OnlineMusicRepository` 和 `OnlineMusicService`。

## 1. 本地复现

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
dart run tool/online_fixture_server.dart
```

服务仅监听 `127.0.0.1:8765`；可传端口参数，配置中的端口也须对应修改。它在内存生成 6 秒低振幅 WAV，支持 HTTP Range 和 HEAD，无需下载音乐或额外工具。Ctrl+C 结束服务。

启动默认应用，进入“在线音乐”，添加网络源，粘贴样例 JSON，以 `test` 测试并保存，然后搜索 `test`，加载更多或点击歌曲播放。连接测试会校验搜索与第一首歌曲的播放地址映射，不会播放音频；测试关键词无结果时可以保存，但会提示播放映射尚未验证。添加/编辑均先测试再保存，测试或磁盘写入失败保留原配置。

测试源固定返回三首生成的测试音，不是通用音乐搜索引擎。除以下特殊词外，任意关键词均返回相同三首：

| 关键词/歌曲 | 行为 |
| --- | --- |
| `test` | 每页 2 首，第二页为末页 |
| `empty` | 空列表，`hasMore: false` |
| `unauthorized` | HTTP 401，提示当前仅支持匿名服务 |
| `error` | HTTP 503，提示服务错误 |
| `malformed` | 缺少映射字段，提示配置/响应错误 |
| `timeout` | 延迟 35 秒，超过配置的 1–30 秒总超时 |
| ID `refresh` | 第一次解析返回已失效地址；重新解析后可播 |
| ID `broken` | 每次解析都返回失效地址，用于原生失败终止测试 |
| ID `slow` | 解析延迟 900ms，用于定时到期竞态测试 |
| ID `switch-slow` | 解析延迟 3 秒，用于验证手动切歌不被旧请求拖住 |

## 2. 配置 schemaVersion 1

| 字段 | 规则 |
| --- | --- |
| `schemaVersion` | 必填整数 `1`；更高版本拒绝读取并保护存储 |
| `id` | 必填、区分大小写，1–64 个英文字母/数字/`_`/`-`；编辑时保持不变 |
| `name` | 必填显示名，最多 80 字符 |
| `baseUrl` | 必填绝对 HTTP(S) URL；不能有账号信息、查询参数或片段；末尾自动补 `/` |
| `timeoutSeconds` | 可省略，默认 10，整数 1–30；覆盖连接、响应头和全部响应体 |
| `search.path` / `playback.path` | 必填同源端点路径；不接受越域地址、`.`/`..`、反斜线、查询和片段；相对路径基于 Base URL，`/` 开头基于站点根目录 |
| `search.queryParameter` | 默认 `q`；搜索词的 URL 查询参数名 |
| `search.pageParameter` / `limitParameter` | 默认 `page` / `limit`；三个参数名不能重复 |
| `search.firstPage` | 默认 1，整数 0–10000 |
| `search.pageSize` | 默认 20，整数 1–100 |
| `search.itemsPath` | 必填，结果数组的点分字段路径 |
| `search.fields.id` / `title` | 必填，单条结果内歌曲 ID / 标题的路径 |
| `search.fields.artist` / `album` / `durationSeconds` | 可省略，分别为歌手、专辑、数值秒数 |
| `search.hasMorePath` | 可省略；配置后必须解析为布尔值；省略则原始结果数量达到 pageSize 时允许下一页 |
| `playback.idParameter` | 默认 `id`；取播放地址时发送的歌曲 ID 参数名 |
| `playback.urlPath` | 必填，播放响应内 URL 路径 |

配置文本上限 64 KiB，最多保存 100 个源。各层未知字段均拒绝，避免让未生效的认证配置看似有效。参数名使用字母或下划线开头，后接字母、数字、下划线或短横线，最长 64 字符。参数值由 `Uri` 编码，不通过字符串拼接构造请求。

字段路径最长 128 字符、最多 12 段。支持 `data.items`、`data.0.url` 形式的对象键和数组数字索引；对象键以英文字母或下划线开头，后接英文字母、数字、下划线或短横线。不支持 `$`、通配符、转义点号、过滤表达式或脚本。

歌曲 ID 接受整数或非空字符串，最长 512 字符；标题须为非空字符串。必填字段无效的条目跳过并计数；非空列表全部无效时报错。同一源内重复 ID 去重。可选歌手/专辑缺失时使用通用占位，时长缺失、非数值或超出 0–2592000 秒时留空，起播后使用后端时长。在线封面本期使用占位图。

## 3. 请求与响应示例

搜索：`GET /search?q=test&page=1&limit=2`

```json
{"data":{"items":[{"id":"tone-a","title":"测试音 A","artist":"HanMusic 测试","album":"本地生成","duration":6},{"id":"tone-b","title":"测试音 B","duration":6}],"hasMore":true}}
```

末页：`GET /search?q=test&page=2&limit=2`

```json
{"data":{"items":[{"id":"refresh","title":"过期地址重试测试","duration":6}],"hasMore":false}}
```

空结果：`GET /search?q=empty&page=1&limit=2`

```json
{"data":{"items":[],"hasMore":false}}
```

取地址：`GET /play?id=tone-a`

```json
{"data":{"url":"http://127.0.0.1:8765/audio/tone-a.wav?ticket=probe-only-1"}}
```

`ticket` 仅为生成的测试值，服务实际每次生成新值，1 分钟后过期。允许返回不同 CDN 的绝对 HTTP(S) 地址；不允许用户信息或片段，不接收本地文件、脚本或其他 scheme。

错误样例：HTTP 503 + `{"error":"controlled fixture failure"}`。应用只使用状态码分类提示，不展示服务响应体。401/403 提示需要鉴权，429 提示稍后重试，3xx 提示使用最终 API 地址，其他非 200 状态提示服务错误。API 请求不跟随重定向；音频地址交由原生播放器加载。

## 4. 生命周期、重试与存储

- 输入后 500ms 搜索；输入变化、切源、编辑、删除和关闭取消旧请求，并用序号校验结果。分页失败保留已加载项，可显式重试。
- 每个 API 动作只发一次请求，不自动重试。总超时到期会中止请求和连接；自动解压后的 JSON 响应体最多 2 MiB，超限停止读取。TLS 使用系统信任校验。
- 在线歌曲使用 `hanmusic://track/<sourceId>/<trackId>` 稳定身份。每次加载重新解析临时地址；首次原生加载失败仅再解析并加载一次。解析错误直接提示。自动跳过关闭时保留失败曲目；开启时有限遍历失败项，整队失败后停止。
- 手动换歌会立即结束对旧解析结果的等待，新选择仍遵循原生加载串行约束；旧请求后来成功或失败均不能覆盖当前歌曲。尚未完成的 HTTP 请求仍受总超时约束，源更改或应用关闭会主动取消连接。
- 在线与本地曲目共用队列、模式、进度和睡眠定时；解析期间到期同样阻止迟到自动起播。按当前歌曲结束优先于循环和跳过。
- `AppSnapshot` schema 2 的队列支持在线身份，曲库仍仅为本地文件；schema 1 可迁移。临时流地址不写入快照，重启保持暂停，首次播放才重新解析。
- 源配置独立存放于应用数据目录的 `online/sources.json`，保留 `sources.backup.json`。坏主文件可恢复有效备份；新版本、主备均损坏、目录不可写时保护原文件并提示。保存成功后才发布新的内存配置。
- 删除源会保留队列中的歌曲；下次加载提示源已不存在。编辑源后旧请求不能套用新配置。若原生后端已缓冲音频，删除配置不会主动删除或清空当前播放队列。
- 当前不支持 Cookie、Token、API Key、自定义 Header、POST、脚本或商用平台登录；不要把凭据写进 URL 路径。需要认证的协议在未来接入安全存储后单独实现。普通错误不含请求 URL/响应体；音频桥接的 MPV 控制台输出在专用 Zone 中过滤，应用错误流仍保留。

## 5. 适配边界和官方依据

本轮无需新增依赖；`dart:io HttpClient` 封装在 Repository 内，针对已确定的 Windows 范围提供取消、总超时和大小限制。将来扩展 Web 时可替换为 `package:http` 适配层，当前不据此声明 Web 已支持。

连接及响应体生命周期依据 [Dart HttpClient 文档](https://api.dart.dev/dart-io/HttpClient-class.html)；API 跳转限制使用 [followRedirects](https://api.dart.dev/dart-io/HttpClientRequest/followRedirects.html)，主动中止使用 [abort](https://api.dart.dev/dart-io/HttpClientRequest/abort.html)。本轮结果与未完成的系统验收见 [M4 验证记录](./10-Windows-M4验证记录.md)。
