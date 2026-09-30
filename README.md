# DSH Web Search Proxy

让 DeepSeek Harness 的联网搜索在阿里云百炼网关上真正生效。

## 问题

DSH 的 `@deepseek-ai/dsh-web-search-deepseek` 插件依赖 Anthropic 的**服务端** `web_search` 工具（`web_search_20250305`）。但阿里云百炼的 Anthropic 兼容网关有个隐藏要求：

> 请求的 `system` 字段里必须包含 `x-anthropic-billing-header: cc_entrypoint=cli;`，否则网关**静默丢弃**该工具。

插件从不发送 `system` 字段，所以请求返回 HTTP 200 却没有任何搜索结果 —— 看起来成功，实际是模型在靠训练数据硬撑。这个失败模式很隐蔽，是本项目存在的唯一原因。

## 方案

一个本地反向代理，在转发时注入缺失的字段：

```
DSH 搜索插件
    │  POST http://127.0.0.1:8787/v1/messages   (无 system)
    ▼
anthropic-search-proxy                        ← 注入 billing header
    │  POST https://<workspace>.maas.aliyuncs.com/apps/anthropic/v1/messages
    ▼
阿里云百炼网关                                 ← 识别到标识，启用联网搜索
```

上游地址在代理里**硬编码**（地址稳定，无需配置）。监听仅限 `127.0.0.1`。

## 架构：为什么是 systemd 而不是 DSH 后台任务

DSH 的 `dsh-jobs` 是**进程内注册表** —— 任务生命周期绑死在 DSH 进程上，DSH 一重启代理就死。搜索随即失败。

因此采用**职责分离**：

| 层 | 负责 | 技术 |
|---|---|---|
| 存活 | 开机自启、崩溃重启、脱离 DSH 生命周期 | systemd user service |
| 感知 | 查状态、读日志、重启、停止 | `proxy-ctl` 脚本 |

systemd 保证代理「活着」，`proxy-ctl` 保证 DSH 能「管」。两者不冲突。

## 文件

| 文件 | 说明 |
|---|---|
| `anthropic-search-proxy.mjs` | 代理本体，Node 内置模块，零依赖 |
| `proxy-ctl` | 管理脚本 |
| `install.sh` | 安装脚本（新机器一键部署） |
| `anthropic-search-proxy.service` | systemd 单元模板（由 `install.sh` 生成，供参考） |
| `~/.config/systemd/user/anthropic-search-proxy.service` | 实际生效的 systemd 单元 |
| `~/.dsh/profiles/web/cordis.patch.yml` | DSH 配置（`web-search-deepseek.baseURL`） |

## 安装到新机器

把整个目录拷过去，运行 `install.sh` 即可：

```bash
cd ~/DSH-Workspace
./install.sh
```

脚本会自动完成：侦测阿里云网关 → 配置 DSH → 安装 systemd 服务 → 开启开机自启 → 验证端口可用。

### 选项

```bash
./install.sh --dry-run          # 只预览将要做的事，不写任何文件
./install.sh --port 8899        # 换监听端口（默认 8787）
./install.sh --upstream https://<WorkspaceId>.<region>.maas.aliyuncs.com/apps/anthropic/v1
./install.sh --profile ~/.dsh/profiles/web   # 指定 DSH profile
./install.sh --no-enable        # 装好但不开机自启
./install.sh --help
```

### 自动侦测的差异点

不同机器上会变的东西，脚本都替你处理：

| 项目 | 处理方式 |
|---|---|
| 上游网关 | 从 `cordis.patch.yml` 里已有的阿里云地址自动提取 |
| DSH profile | 优先 `~/.dsh/profiles/web`，否则取 `~/.dsh/profiles/` 下第一个 |
| 监听端口 | `--port` 指定，默认 8787 |
| 缺失 `/v1` | 自动补全（缺这段会 404，是踩过的坑） |
| lingering | 检测状态并提示开启命令 |

### 安全设计

- **幂等** —— 重复运行只更新配置，不会重复追加 `web-search-deepseek` 节
- **YAML 校验** —— 改完配置立即解析验证；失败则自动还原，不会留下坏配置导致 DSH 起不来
- **输入校验** —— 端口范围、强制 https、缺失参数一律拒绝
- **环境变量** —— 代理与 `proxy-ctl` 均支持 `UPSTREAM_BASE_URL` / `PROXY_PORT`，同时保留硬编码兜底

> 装完后**需重启 DSH** 才能让新配置生效（代理本身不用）。

### 手动安装

不想用脚本时，照做即可：

```bash
# 1. 复制单元并改路径/地址
mkdir -p ~/.config/systemd/user
cp anthropic-search-proxy.service ~/.config/systemd/user/

# 2. 在 cordis.patch.yml 追加
#    - id: web-search-deepseek
#      name: "@deepseek-ai/dsh-web-search-deepseek"
#      config:
#        baseURL: http://127.0.0.1:8787/v1

# 3. 启动
systemctl --user daemon-reload
systemctl --user enable --now anthropic-search-proxy.service
sudo loginctl enable-linger $USER    # 开机自启（未登录也要跑）
```

## 日常使用

```bash
cd ~/DSH-Workspace

./proxy-ctl status          # 单元状态 + PID + 端口健康（退出码反映可用性）
./proxy-ctl health          # 探测 /healthz
./proxy-ctl logs 50         # 读 journal 日志
./proxy-ctl restart         # 重启
./proxy-ctl stop            # 停止
./proxy-ctl enable          # 开机自启
./proxy-ctl disable         # 取消自启并停止
```

`status` 的退出码可直接用于脚本判断：`0` = 单元 active **且**端口返回 200，否则非 0。

### 原始 systemctl 等价命令

```bash
systemctl --user status anthropic-search-proxy.service
systemctl --user restart anthropic-search-proxy.service
journalctl --user -u anthropic-search-proxy.service -f
```

## 验证搜索是否工作

代理每次响应后都会在日志里打印诊断行：

```
[proxy] POST /v1/messages -> .../apps/anthropic/v1/messages (injected, 326B)
[proxy] <- HTTP 200 search=OK reqs=1
```

- `search=OK` — 收到 `web_search_tool_result`，联网搜索正常
- `WARN no web_search_tool_result` — 网关未返回结果（标识失效或上游变更）
- `injected` / `passthrough` — 是否注入了标识（仅含 `tools` 的请求会注入）

快速自检：

```bash
./proxy-ctl logs 20 | grep -E "search=|WARN"
```

## 设计细节

- **只对含 `tools` 的请求注入** —— 普通聊天请求完全不受影响
- **幂等** —— 若 `system` 已含该标识则跳过，不重复注入
- **保留原 `system`** —— 字符串会被转为 text block 并追加，不覆盖
- **密钥透传** —— `x-api-key` / `authorization` 原样转发，不记录、不落盘
- **非流式** —— 插件只用 `await response.json()`，故代理无需处理 SSE
- **不依赖响应头** —— 插件只看 `response.ok` 和 JSON body
- **注入条件** —— 只有含 `tools` 的请求才会触发注入；不含 `tools` 的普通聊天原样透传

## 环境变量

代理与 `proxy-ctl` 都读取这两个变量，便于多设备/多端口部署：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `UPSTREAM_BASE_URL` | 硬编码的阿里云网关 | 上游 Messages 基址 |
| `PROXY_PORT` | `8787` | 本地监听端口 |

`install.sh` 会把它们写进 systemd 单元的 `Environment=`，日常无需手动设置。临时换端口时：

```bash
PROXY_PORT=8899 ./proxy-ctl status
```

## 故障排查

**搜索报 `fetch failed`** —— 代理没在跑：

```bash
./proxy-ctl status
./proxy-ctl start
```

**搜索返回 200 但无结果** —— 看日志是否 `WARN no web_search_tool_result`。有两种可能：

1. **查询太短或无需联网** —— 模型判断不必搜索，属正常。换成明确需要实时信息的问题再试
2. **标识失效** —— 阿里云改了要求或网关行为，需重新抓包确认

诊断命令：

```bash
./proxy-ctl logs 20 | grep -E "search=|WARN|injected"
```

`injected` 表示注入已发生。若显示 `injected` 但持续 `WARN`，则是网关侧问题。

**端口被占用** —— 检查是否有手动启动的残留进程：

```bash
ss -ltnp | grep 8787
pkill -f anthropic-search-proxy.mjs   # 然后 proxy-ctl restart
```

**改了代理代码后** —— 必须重启服务：

```bash
./proxy-ctl restart
```

**改了 `cordis.patch.yml` 后** —— 必须重启 DSH（代理不受影响）。

## 配置参考

[`~/.dsh/profiles/web/cordis.patch.yml`](~/.dsh/profiles/web/cordis.patch.yml) 中的相关片段：

```yaml
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  config:
    baseURL: http://127.0.0.1:8787/v1
```

改动此项后需**重启 DSH** 才生效。代理本身的改动只需 `./proxy-ctl restart`。

注意端口要与 systemd 单元里的 `PROXY_PORT` 一致，否则请求会打到没人监听的端口。

## 备选方案

**直接改插件源码** —— 在 `node_modules/@deepseek-ai/dsh-web-search-deepseek/lib/index.js` 的请求 body 里加 `system` 字段。缺点是 DSH 升级会被覆盖，故未采用。

## 验证记录

**代理行为**

| 项目 | 结果 |
|---|---|
| 插件原始请求（无 `system`）经代理 | HTTP 200，5 条真实结果 |
| 已有 `system` 字符串 | 合并未覆盖，正常响应 |
| 无 `tools` 的普通请求 | 原样透传 |
| 错误 key | `401` 正确透传 |
| SIGKILL 崩溃自愈 | PID 自动更换，恢复服务 |
| 开机自启 | `Linger=yes` + `enabled` |

**安装脚本**

| 项目 | 结果 |
|---|---|
| `--dry-run` 自动侦测 | 正确识别网关与 profile |
| 真实安装 | 全部通过，服务启动 |
| 幂等性（重复运行） | 8 条目、web-search 仅 1 个、无残留备份 |
| 参数校验 | 端口非数字/越界、非 https、未知选项、缺值全拒绝 |
| 缺失 `/v1` 补全 | 自动追加 |
| 自定义端口 8899 | 端到端搜索返回 7 条结果 |