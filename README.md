# dsh-search-proxy

让 DeepSeek Harness 的联网搜索在阿里云百炼网关上真正生效。

```bash
git clone <repo> dsh-search-proxy && cd dsh-search-proxy && ./install.sh
```

就这一条。脚本会读你现有的 DSH 配置、装上代理、配好服务、开出开机自启，然后自检。

---

## 问题

DSH 的 `@deepseek-ai/dsh-web-search-deepseek` 插件依赖 Anthropic 的**服务端** `web_search` 工具（`web_search_20250305`）。但阿里云百炼的 Anthropic 兼容网关有个隐藏要求：

> 请求的 `system` 字段里必须包含 `x-anthropic-billing-header: cc_entrypoint=cli;`，否则网关**静默丢弃**该工具。

插件从不发送 `system` 字段，所以请求返回 HTTP 200 却没有任何搜索结果 —— 看起来成功，实际是模型在靠训练数据硬撑。这个失败模式极其隐蔽，是本项目存在的唯一原因。

## 方案

一个本地反向代理，转发时注入缺失的字段：

```
DSH 搜索插件
    │  POST http://127.0.0.1:8787/v1/messages   (无 system)
    ▼
dsh-search-proxy                              ← 注入 billing header
    │  POST https://<workspace>.maas.aliyuncs.com/apps/anthropic/v1/messages
    ▼
阿里云百炼网关                                 ← 识别到标识，启用联网搜索
```

监听仅限 `127.0.0.1`，密钥原样透传、不落盘。上游网关地址从你的 DSH 配置里读取，**不硬编码在仓库里**。

## 安装

**前置条件**：DSH 已装好，且 `cordis.patch.yml` 里已配置阿里云模型（本项目正是为你这种配置而写）。

```bash
git clone <repo> dsh-search-proxy
cd dsh-search-proxy
./install.sh
```

装完后**重启 DSH**，然后随便搜点什么验证。

### 选项

```bash
./install.sh --dry-run             # 只预览，不写任何文件
./install.sh --upstream URL        # 手动指定网关（自动侦测失败时用）
./install.sh --port 8788           # 换监听端口（默认 8787）
./install.sh --profile DIR         # 指定 DSH profile 目录
./install.sh --prefix DIR          # 指定安装位置
./install.sh --no-enable           # 装好但不开机自启
./install.sh --uninstall           # 卸载
```

`--dry-run` 会打印它侦测到的网关、端口和配置路径 —— 拿不准时先跑这个。

### 自动侦测

| 项目 | 处理方式 |
|---|---|
| 上游网关 | 从 `cordis.patch.yml` 里已有的阿里云地址提取 |
| DSH profile | 优先 `~/.dsh/profiles/web`，否则取 `~/.dsh/profiles/` 下第一个 |
| 缺失 `/v1` | 自动补全（缺这段会 404，是踩过的坑） |
| lingering | 检测状态；关闭时打印开启命令 |

## 安装位置

文件装到 `~/.local/share/dsh-search-proxy/`（可用 `--prefix` 改），systemd 单元指向那里。

**因此 clone 目录用完可以随便删**。想更新时：

```bash
~/.local/share/dsh-search-proxy/proxy-ctl upgrade
```

它会 `git pull` 你原来的 clone 目录（路径在安装时记录）并重装。若 clone 已删除，重新 clone 跑一次 `./install.sh` 即可 —— 安装是幂等的。

## 日常使用

```bash
CTL=~/.local/share/dsh-search-proxy/proxy-ctl

$CTL status          # 单元状态 + PID + 端口健康（退出码反映可用性）
$CTL info            # 安装位置、源目录、版本、网关
$CTL upgrade         # 拉取更新并重装
$CTL health          # 探测 /healthz
$CTL logs 50         # 读 journal 日志
$CTL restart         # 重启
$CTL stop / start    # 停止 / 启动
$CTL enable/disable  # 开关开机自启
```

`status` 退出码可直接用于脚本判断：`0` = 单元 active **且**端口返回 200。

### 原始 systemctl 等价命令

```bash
systemctl --user status anthropic-search-proxy.service
journalctl --user -u anthropic-search-proxy.service -f
```

## 验证搜索是否工作

代理每次响应后都会在日志里打印诊断行：

```
[proxy] POST /v1/messages -> .../apps/anthropic/v1/messages (injected, 326B)
[proxy] <- HTTP 200 search=OK reqs=1
```

- `search=OK` — 收到 `web_search_tool_result`，联网搜索正常
- `WARN no web_search_tool_result` — 网关未返回结果（见下方排查）
- `injected` / `passthrough` — 是否注入了标识（仅含 `tools` 的请求会注入）

```bash
$CTL logs 20 | grep -E "search=|WARN"
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `UPSTREAM_BASE_URL` | 无（必须提供） | 上游 Messages 基址 |
| `PROXY_PORT` | `8787` | 本地监听端口 |

`install.sh` 会把它们写进 systemd 单元的 `Environment=`，日常无需手动设置。直接跑 `node src/proxy.mjs` 调试时需自行提供 `UPSTREAM_BASE_URL`。

## 故障排查

**搜索报 `fetch failed`** —— 代理没在跑：

```bash
$CTL status
$CTL start
```

**搜索返回 200 但无结果** —— 看日志是否 `WARN no web_search_tool_result`。有两种可能：

1. **查询太短或无需联网** —— 模型判断不必搜索，属正常。换成明确需要实时信息的问题再试
2. **标识失效** —— 阿里云改了要求或网关行为，需重新抓包确认

若日志显示 `injected` 但持续 `WARN`，则是网关侧问题。

**端口被占用** —— 检查残留进程：

```bash
ss -ltnp | grep 8787
pkill -f proxy.mjs        # 然后 proxy-ctl restart
```

**改了代理代码后** —— 从 clone 目录重装，或直接改安装目录后重启：

```bash
./install.sh                       # 重装（刷新安装目录的副本）
$CTL restart                       # 若直接改了 ~/.local/share/dsh-search-proxy/proxy.mjs
```

**改了 `cordis.patch.yml` 后** —— 必须重启 DSH（代理不受影响）。

## 架构：为什么是 systemd 而不是 DSH 后台任务

DSH 的 `dsh-jobs` 是**进程内注册表** —— 任务生命周期绑死在 DSH 进程上，DSH 一重启代理就死，搜索随即失败。因此采用职责分离：

| 层 | 负责 | 技术 |
|---|---|---|
| 存活 | 开机自启、崩溃重启、脱离 DSH 生命周期 | systemd user service |
| 感知 | 查状态、读日志、重启、停止 | `proxy-ctl` |

systemd 保证代理「活着」，`proxy-ctl` 保证 DSH 能「管」。两者不冲突。

## 设计细节

- **只对含 `tools` 的请求注入** —— 普通聊天请求完全不受影响
- **幂等** —— 若 `system` 已含该标识则跳过
- **保留原 `system`** —— 字符串转为 text block 后追加，不覆盖
- **密钥透传** —— `x-api-key` / `authorization` 原样转发，不记录、不落盘
- **非流式** —— 插件只用 `await response.json()`，故代理无需处理 SSE
- **不依赖响应头** —— 插件只看 `response.ok` 和 JSON body
- **安装器改配置前先备份并校验 YAML** —— 校验失败自动还原，避免 DSH 起不来
- **不把网关 ID 写进仓库** —— 由 `install.sh` 通过 unit 的 `Environment=` 注入

## 配置参考

`~/.dsh/profiles/web/cordis.patch.yml` 中的相关片段（由 `install.sh` 写入）：

```yaml
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  config:
    baseURL: http://127.0.0.1:8787/v1
```

改动此项后需**重启 DSH**。端口要与 unit 里的 `PROXY_PORT` 一致。

## 备选方案

**直接改插件源码** —— 在 `node_modules/@deepseek-ai/dsh-web-search-deepseek/lib/index.js` 的请求 body 里加 `system` 字段。缺点是 DSH 升级会被覆盖，故未采用。

## 项目结构

```
install.sh         安装/升级/卸载
src/proxy.mjs      代理本体（Node 内置模块，零依赖）
bin/proxy-ctl      管理脚本
```

无构建步骤，无 npm 依赖。

## 验证记录

| 项目 | 结果 |
|---|---|
| 插件原始请求（无 `system`）经代理 | HTTP 200，5 条真实结果 |
| 已有 `system` 字符串 | 合并未覆盖，正常响应 |
| 无 `tools` 的普通请求 | 原样透传 |
| 错误 key | `401` 正确透传 |
| SIGKILL 崩溃自愈 | PID 自动更换，恢复服务 |
| 删除 clone 目录后 | 服务照常运行、搜索正常 |
| `proxy-ctl upgrade` | 完整跑通；无 remote 时优雅降级 |
| 安装器幂等性 | 重复运行不重复追加配置节 |
| 参数校验 | 端口越界、非 https、未知选项、错误 profile 全拒绝 |
| 占位符保护 | 未提供上游时安装目录外的直接运行会明确报错 |

## License

MIT