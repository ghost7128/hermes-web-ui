# Hermes Web UI 0.7.24 本地构建 / 部署记录

> 本 fork (`ghost7128/hermes-web-ui`) 的 `main` 分支停留在 **v0.6.29**：
> 上游 `EKKOLearnAI/hermes-studio`（原 `hermes-web-ui`）在 v0.7.x 里改了
> `.github/workflows/*`，而当前 PAT 没有 `workflow` scope，push 含 workflow
> 变更的分支会被 403 拒绝。因此 0.6.35 / 0.6.47 / 0.7.24 的升级都是
> 「上游 tag + 本地 patch」直接构建，patch 与构建配方落在本目录，随代码一起版本化。

## 目标版本

| 项 | 值 |
|----|----|
| 上游 tag | `EKKOLearnAI/hermes-studio` **v0.7.24** (2026-09-22) |
| package.json | `name: ekko-studio`, `version: 0.7.24`, `engines.node >= 23` |
| 注意 | 上游 tag `v1.0.x` 是 **Android App** 版本，不是 Web UI；Web UI 最新是 `v0.7.24` |
| 架构 | 仍是单容器：Web UI + bridge + Hermes Agent 同容器（`HERMES_WEB_UI_MANAGED_GATEWAY=1`） |

## 必须的自定义 patch

`deploy/patches/copilot-provider-fix.patch`

改 `packages/server/src/modules/hermes/services/profiles/config.ts` 中
`PROVIDER_ENV_MAP` 的 copilot 一行：

```diff
-  copilot: { api_key_env: 'GITHUB_TOKEN', base_url_env: '' },
+  copilot: { api_key_env: '', base_url_env: '' },
```

否则 Web UI 会把容器环境里的 `GITHUB_TOKEN` 当成 Copilot 的 API Key，
绕过 Copilot OAuth（device flow）凭据。

## 构建

`deploy/Dockerfile.local` = 上游 `Dockerfile` + 本地化改动：

1. 去掉 `apt-get install`（base image 已有 ffmpeg / make / g++ / git / curl）；
2. `sshpass` 从旧镜像 `COPY --from=ghost7128/hermes-web-ui:v0.6.47 /usr/bin/sshpass`（宿主机 apt 外网不稳）；
3. Node 24.15.0 与 npm 走 `npmmirror.com`（中国网络）；
4. 其余（npm ci → npm run build → npm prune --omit=dev → verify:sharp-runtime → ENTRYPOINT `bin/start-studio-all.sh`）与上游一致。

构建命令（在 TrueNAS 宿主 root，构建目录 `/tmp/studio-build-0724`）：

```bash
docker build -t ghost7128/hermes-web-ui:v0.7.24 -f Dockerfile.local .
```

**base image 注意**：`nousresearch/hermes-agent:latest` 用的是 TrueNAS 本地缓存
（2026-08-29，Hermes core **v0.20.6**）。当时 TrueNAS 直连 Docker Hub 已断
（`registry-1.docker.io` 超时），dockerd 又没有 proxy drop-in，所以**没有** `--pull`。
要同步升级 Hermes core：先在宿主写
`/etc/systemd/system/docker.service.d/http-proxy.conf`（`HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:7890`）
→ `systemctl daemon-reload && systemctl restart docker`（会重启所有容器），
再 `docker build --no-cache --pull ...`。

## 部署（TrueNAS Custom App `hui`）

App 的 compose（`midclt call app.config hui`）：

```json
{"services":{"hermes-webui":{
  "image":"ghost7128/hermes-web-ui:latest",
  "environment":["PORT=6060","HERMES_HOME=/home/agent/.hermes","NODE_ENV=production","HERMES_WEB_UI_HOME=/home/agent/.hermes-web-ui","TZ=Asia/Shanghai"],
  "ports":["6060:6060"],
  "volumes":["/mnt/NetDisk/hermesa:/home/agent/.hermes","/mnt/NetDisk/hermes-webui-data/webui:/home/agent/.hermes-web-ui"],
  "restart":"unless-stopped"}}}
```

因为 compose 用的是 `:latest`，切换版本 = 本地 retag 后重启 App：

```bash
midclt call app.stop hui
docker tag ghost7128/hermes-web-ui:v0.7.24 ghost7128/hermes-web-ui:latest
midclt call app.start hui
```

⚠️ 该容器同时是 Hermes Agent 的运行容器：**重启会中断正在跑的 Hermes 会话**。
升级脚本（`redeploy-verify-0.7.24.sh`）用 `setsid nohup` 脱离 ssh 会话，
自带 DB 备份、启动健康检查、失败自动回滚、以及 TDAI 验证 + 微信通报。

### 回滚

```bash
midclt call app.stop hui
docker tag ghost7128/hermes-web-ui:v0.6.47 ghost7128/hermes-web-ui:latest
midclt call app.start hui
```

数据库备份在 `/mnt/NetDisk/hermes-webui-data/backup-pre-0.7.24-*/`。

## 新镜像带来的部署差异（0.7.x）

- `/home/agent/.hermes-web-ui` 变成**必须持久化**的目录：Studio 自己的 auth token、
  DB、uploads、以及 coding-agent 的 npm 全局前缀都放这里
  （`NPM_CONFIG_PREFIX=/home/agent/.hermes-web-ui/coding-agent/npm`）。本部署已挂载。
- 镜像 ENTRYPOINT 变成 `/app/bin/start-studio-all.sh`（支持 `HERMES_PATCH_SCRIPT`
  在启动时给 Hermes Agent 打补丁）。
- 镜像内新增 `ENV HOME=/home/agent`（0.6.x 镜像没设 HOME）。若 Hermes 会话的
  `$HOME` 随之变化，注意 `~/.git-credentials`（0.6.x 时在
  `/home/agent/.hermes/home/.git-credentials`）是否需要跟到新 HOME。
- 镜像不带 `jq`；`sshpass` 由 `Dockerfile.local` 从旧镜像带入。
