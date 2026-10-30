# HanMusic 免 Token 识曲网关部署包

这是可部署的后端源码包，**尚未部署到公网，也未配置真实 AudD Token 或域名**。桌面客户端只向网关发送短 WAV，不持有 Token；网关使用服务器环境变量中的私密 Token 调用 AudD。运行需要 Linux 或 Windows、Node.js 22 或更高版本，无 npm 依赖。

## 接口与数据处理

- `POST /v1/recognize`：`Content-Type: audio/wav`，原始 WAV 请求体；客户端不传 `api_token`、Authorization、文件 URL 或 multipart。
- 接收 RIFF/WAVE、PCM16、mono，采样率 8,000–192,000 Hz 或 384,000 Hz，时长 1–12.5 秒，完整文件不超过 8 MiB。仅允许一个 16 字节 `fmt ` 块及后续一个 `data` 块，检查 RIFF 长度、块边界、字节率及帧对齐；不接受额外嵌入内容。
- 成功返回 `{"status":"success","result":null}`，或 `result` 包含 `title`、`artist`，可选 `album`、`release_date`。其他上游字段全部丢弃。
- 错误固定为 `{"status":"error","error":{"code":"…"}}`：`service_unavailable`→503；`rate_limited` / `daily_limit`→429；`invalid_audio`→400；`upstream_timeout`→504；`upstream_failure`→502。不返回上游正文、异常细节或 Token。
- `GET /healthz`：已配置 Token 且预算存储未发生写入故障时返回 200 `{"status":"ok"}`，否则 503 `{"status":"unavailable"}`。不会发送音频、不消耗识曲额度；**不能证明 Token 在 AudD 有效或上游可用**。
- 默认读取请求头/请求体限时 10 秒，上游整个响应限时 25 秒、最多 1 MiB，不跟随重定向。超大/慢速/格式损坏的 HTTP 请求可能在解析层直接断开；Caddy 超限会返回 413。
- 上游固定为 `https://api.audd.io/`，仅发送 `api_token` 和 `file`（`sample.wav`）两个 multipart 字段；不接受客户端指定 URL，不转发客户端 Authorization。
- 音频不落盘，不记录请求正文或音频；服务仅输出固定启动/配置错误消息。请求结束时清零本服务持有的可变音频缓冲区，释放上游请求；Node/网络层的内部拷贝由运行时回收，不能承诺物理内存即时擦除。客户端断开会中止上游，但已消费额度不退还。

## 本地检查

```sh
node --version
npm test
```

测试只访问显式 loopback 模拟上游，不调用真实 AudD，不产生付费识曲请求。`createRecognitionServer(config)` 是异步工厂，返回尚未监听的 `http.Server`；`server.shutdown()` 中止活动请求并关闭监听。生产启动使用 `readConfigFromEnv()`；只有显式 `nodeEnv: 'test'` 才允许覆盖为 loopback HTTP 测试上游和测试时钟。

本地启动可在受保护的 `secret.env` 中设置真实 Token，将 `BUDGET_FILE` 改为当前用户可写的 `./data/budget.json` 后执行：

```sh
node --env-file=secret.env src/main.js
```

普通 `npm start` 使用进程环境，不自动读取 `.env`。没有 Token 时仍可启动，但 readiness 和识曲均返回 503。不要把真实 Token 放进命令行参数、客户端构建参数、Git 或日志。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `AUDD_API_TOKEN` | 空 | 仅服务端持有；空值禁用识曲。生产拒绝 `test`、`testtoken` 等示例值及控制/空白字符。 |
| `NODE_ENV` | `production` | `production` / `development` / `test`；公网服务必须为 production。 |
| `HOST` / `PORT` | `127.0.0.1` / `8787` | HOST 必须为 IP 字面量；默认不直接对外监听。 |
| `BUDGET_FILE` | `./data/budget.json` | Docker 默认 `/data/budget.json`；目录必须可写且跨重建保留。 |
| `IP_LIMIT_HOUR` | `10` | 每个 IP 滚动一小时最多 10 次上游尝试，允许 1–1000。 |
| `DAILY_LIMIT` | `100` | 单实例全局 UTC 日最多 100 次上游尝试，允许 1–100000。 |
| `MAX_CONCURRENT` | `2` | 包含读取音频、校验和等待上游；允许 1–32。超限立即 429。 |
| `IP_CACHE_SIZE` | `4096` | IP 缓存上限，允许 1–100000；满时拒绝新 IP，不驱逐仍有效额度记录。 |
| `TRUST_PROXY_LOOPBACK` | `false` | 仅当直接 peer 为 loopback 才采纳 XFF 中最后一个有效 IP；其他 peer 始终忽略 XFF。 |
| `BODY_TIMEOUT_MS` | `10000` | 1–10000；请求头/体时限。 |
| `UPSTREAM_TIMEOUT_MS` | `25000` | 1–25000；上游请求及响应体总时限。 |

配置格式错误会拒绝启动。不要将额度提高理解为 AudD 套餐允许或费用已确认；该网关只限制上游尝试次数。

## Linux Docker + 宿主 Caddy 部署

以下是部署步骤，不会在准备包时自动执行。需先有 Linux 主机、Docker Engine、宿主 Caddy、域名及私密 AudD Token。域名 DNS 指向该主机，允许公网 TCP 80/443。服务仅部署**一个进程、一个容器、一个副本**。

1. 在服务器上把本目录放到 `/opt/hanmusic-recognition`，准备私密环境文件：

   ```sh
   cd /opt/hanmusic-recognition
   umask 077
   cp .env.example secret.env
   chmod 600 secret.env
   ```

   在服务器编辑器中填写 `AUDD_API_TOKEN`，保留 `HOST=127.0.0.1`、`BUDGET_FILE=/data/budget.json`，并将 `TRUST_PROXY_LOOPBACK=true`（仅用于以下单个宿主 Caddy 拓扑）。`secret.env` 已被 `.gitignore`、Docker 白名单上下文及 npm 打包白名单排除。

2. 本地构建容器并创建持久卷，以唯一固定名称运行：

   ```sh
   docker build -t hanmusic-recognition:1.0.0 .
   docker volume create hanmusic-recognition-budget
   docker run -d --name hanmusic-recognition \
     --network host --restart unless-stopped --stop-timeout 35 \
     --read-only --cap-drop ALL --security-opt no-new-privileges \
     --memory 256m --cpus 1 --pids-limit 64 \
     --env-file secret.env \
     --mount type=volume,src=hanmusic-recognition-budget,dst=/data \
     hanmusic-recognition:1.0.0
   curl --fail --silent http://127.0.0.1:8787/healthz
   ```

   镜像以非 root 的 `node` 用户运行。新命名卷沿用镜像内 `/data` 的所有权；使用已有卷/宿主目录时须确保 UID 1000 可读写。`--network host` 是此 Linux 部署方案的一部分，不使用 `-p`：Caddy 到 Node 的直接 peer 仍为 loopback。不要随意换成 Docker bridge 后继续信任 XFF；默认关闭信任时所有代理流量将共用代理 IP 的小时额度。

3. 将 `Caddyfile.example` 的 `recognize.example.com` 换成实际域名，按现有 Caddy 配置的管理方式合入站点，然后验证/加载：

   ```sh
   sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   sudo systemctl reload caddy
   curl --fail --silent https://recognize.example.com/healthz
   ```

   示例覆盖 XFF 为 `{remote_host}`，不追加客户端伪造的链；Node 只信任来自 loopback 的这个头。不启用请求体/调试日志，不在 Caddyfile 放 Token。公网 HTTPS 地址准备好后，再由客户端构建配置指向该网关；URL 示例不是已开通的服务。

## 预算、升级和恢复

每次有效请求在访问 AudD **之前**，在同一串行事务中检查 IP 与日额度，并写入临时预算文件、fsync、原子 rename；Linux 还同步父目录。上游失败、超时、客户端中断都计入日额度，不自动重试。预算文件只含版本、UTC 日期、已用次数，不含 IP、Token 或音频。IP 小时额度在内存中，重启会重置；全局日额度从持久卷恢复。系统时钟倒退不会重置日额度。

启动会按预算文件的真实路径取得**内核 IPC 独占锁**：Linux 使用 abstract Unix socket，Windows 使用 named pipe。同一主机/IPC 网络命名空间内第二个实例即使更换 HTTP 端口，也会在读取预算前拒绝启动。预算文件本身必须为普通、单一硬链接的文件，不允许文件符号链接或多个硬链接；父目录的 symlink/junction 会解析为真实目录。正常关闭、监听失败以及进程异常退出均释放锁；不创建持久 PID 锁文件，无需手动删锁。遇到占用错误，检查并正常停止旧 Node/容器实例，再重启；不要删除预算文件来绕过占用。

仍不得使用 Node cluster、PM2 多进程、多个容器/副本或滚动更新重叠。内核锁不是跨主机/跨 Linux 网络命名空间的分布式锁，部署必须保持示例中的 `--network host` 和单副本；不同主机、不同命名空间或不同路径的同一底层存储不能依靠此锁提供多实例全局保障。多实例需要事务数据库/集中限额服务，不属于本包范围。

升级先停止旧实例再启动新实例，保留同一命名卷与 `secret.env`：

```sh
docker stop --time 35 hanmusic-recognition
docker rm hanmusic-recognition
# 使用新版本镜像重新执行上面的同名 docker run；不要删除预算卷。
```

预算不存在时初始化；预算损坏、无权限、磁盘满时拒绝服务，不静默清零。运行中的写入故障使 readiness 变为 503，此后拒绝所有识曲，修复存储后重启。备份/恢复应先停服务，并保留当天最新计数；恢复较旧备份、删除文件或丢失卷会使额度保护失效。若无法确认当天计数，应保守地将当天已用次数设为日上限后再恢复，或等下一个 UTC 日，不能凭旧备份继续放量。

不带客户端密钥的公网接口允许他人消耗共享额度；默认日上限负责限制单实例总调用量。上线前由运维根据实际使用设置额度和基础网络访问限制。部署完成前无需发送真实音频验收；health、mock tests 和配置校验均不调用付费服务。

## 参考资料

- [AudD 官方接口文档](https://docs.audd.io/)：Token 与文件 multipart 接口。
- [Node HTTP 文档](https://nodejs.org/api/http.html)：请求时限和连接关闭。
- [Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) 与 [request_body](https://caddyserver.com/docs/caddyfile/directives/request_body)：转发头与请求大小限制。
- [Docker host 网络](https://docs.docker.com/engine/network/drivers/host/)：本部署所用 Linux host network。
