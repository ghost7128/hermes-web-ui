# Hermes Web UI 0.7.24 → 0.7.26 升级记录（2026-10-01/02）

> 复用 `hermes-webui-upgrade` skill 的 0.6.47 → 0.7.24 成功路径。
> fork `ghost7128/hermes-web-ui` 的 `main` 仍停在 v0.6.29（PAT 只有 `repo` scope，
> 没有 `workflow` scope，推含 `.github/workflows/*` 的新分支必 403）→ 继续用
> 「上游 tag + 本地 patch」直接构建，配方与本目录一起版本化。

## 目标版本

| 项 | 值 |
|----|----|
| 上游 tag | `EKKOLearnAI/ekko-studio`（原 hermes-studio）**v0.7.26** (2026-09-30) |
| package.json | `name: ekko-studio`, `version: 0.7.26` |
| base image | `nousresearch/hermes-agent:v2026.9.24` = **Hermes core v0.21.5**（含在本次升级内） |
| 上一版 | Web UI 0.7.24 + core v0.20.6（回滚目标，镜像保留） |
| 镜像 | `ghost7128/hermes-web-ui:v0.7.26`（4.35GB，id 82d51761d309） |

## 本轮预检结论（都实测过）

1. **上游根 `Dockerfile` 在 v0.7.24 → v0.7.26 之间逐字节相同** → 上一版的 `Dockerfile.local`
   四处本地化配方原样可用，无需重新适配。
2. `package.json` 只多一个纯 JS 依赖 `@typesafe-ai/sdk`（JEV）；`engines` / scripts 未变。
3. `docs/docker.md` 无 diff → 无新增挂载点/环境变量要求。
4. copilot-provider-fix **上游仍未修**，位置不变：
   `packages/server/src/modules/hermes/services/profiles/config.ts:52`
   ```diff
   -  copilot: { api_key_env: 'GITHUB_TOKEN', base_url_env: '' },
   +  copilot: { api_key_env: '', base_url_env: '' },
   ```
5. TrueNAS 直连 Docker Hub 仍死（`registry-1.docker.io` 25s 超时 code=000）。
   **新增可用路径：镜像源 `docker.m.daocloud.io`**（0.12s 响应），
   `docker pull docker.m.daocloud.io/nousresearch/hermes-agent:v2026.9.24` → 本地 retag，
   **完全不需要启用 dockerd proxy drop-in、也不需要 `systemctl restart docker`**。
   （旧记录里的「改 http-proxy.conf + 重启 docker」方案可以退休了，除非镜像源也挂。）
   - 备用镜像源实测：`docker.1ms.run` 0.28s、`dockerproxy.net` 3.3s、`docker.1panel.live` 1.1s；
     `registry.dockermirror.com` 525 挂了。
6. 宿主机内存：15.9GB / 构建时可用 ~4.4GB，ZFS ARC 5.7GB 可回收 → vite 未 OOM。

## 构建

`deploy/Dockerfile.local` = 上游 `Dockerfile` + 四处本地化：

1. 去掉 `apt-get install`（base image 已有 ffmpeg/make/g++/git/curl）；
2. `COPY --from=ghost7128/hermes-web-ui:v0.6.47 /usr/bin/sshpass /usr/bin/sshpass`；
3. Node 24.15.0 tarball 与 npm registry 走 `npmmirror.com`；
4. **去掉 `npm prune --omit=dev`**（TrueNAS ZFS+overlayfs 上会挂死，镜像因此 4.35GB）。

```bash
# TrueNAS 宿主，源码 /tmp/studio-build-0726
docker build -t ghost7128/hermes-web-ui:v0.7.26 -f Dockerfile.local \
  --build-arg BASE_IMAGE=nousresearch/hermes-agent:v2026.9.24 .
```

实测：`=== build exit=0`，全程约 16 分钟（npm ci ≈4min → vite+tsc+build-server ≈2.5min →
export layers ≈11min；export 阶段日志静默 10 分钟属正常，别误判卡死）。

镜像内验证：
```
"version": "0.7.26"
Hermes Agent v0.21.5 (2026.9.24) · upstream f97608f1
/usr/bin/sshpass
copilot:{api_key_env:"",base_url_env:""}   ← patch 已进 dist/server
```

## 冒烟测试（`smoke-verify-0.7.26.sh`，空数据目录 + 6070 端口）

启动链特征（缺一不可）：
```
hermes-web-ui v0.7.26 starting...
[bootstrap] Hermes source=user-cli version=0.21.5 path=/opt/hermes/.venv/bin/hermes
[bootstrap] ekko-agent setup complete
[bootstrap] profile gateways checked
[bootstrap] agent bridge started
[bootstrap] all stores initialized
[bootstrap] listening on 0.0.0.0:6060
[bootstrap] startup complete
```
HTTP 200（首次即通），`client dist OK`，copilot patch 在产物中 ✓。

## 切换实跑（2026-10-02 08:14–08:22）

**结论：切换成功，但 v1 脚本误报失败。**

实测事实：
- 容器换代成功：`ix-hui-hermes-webui-1` → `83d0c531bab4`，image `82d51761d309` = v0.7.26，
  Created `2026-10-02T00:15:26Z`，RestartCount 0 → **从未回滚**。
- core：`Hermes Agent v0.21.5 (2026.9.24) · upstream f97608f1`。
- Studio DB：切前 `112/36054/2` → 切后 `112/36062/2`（sessions/messages/users），数据零丢失。
- TDAI provider `available: true`；TDAI gateway `vectorStore:true, embeddingService:true`。

### v1 脚本的三个 bug（`redeploy-verify-0.7.26.sh`，已被 `redeploy-verify.sh` v2 取代）

1. **时区陷阱 → 假「未换代」→ 假回滚**：`docker inspect .Created` 是 UTC（`...Z`），
   `date -Iseconds` 是本地 `+08:00`，字符串字典序比较永远为假。轮询 40 次全判
   “still old container”→ 对一次成功的切换走了回滚分支。
2. **回滚静默无效**：回滚里 `midclt call -job app.stop` 没生效，导致
   `docker tag latest -> v0.7.24` 生效、容器却仍是 v0.7.26 →
   **「容器跑新镜像、`latest` 指旧镜像」**，下次重启会静默降级。
   已于 10:07 用 `docker tag ...:v0.7.26 ...:latest` 拆弹。
3. **notify 失败被当成异常信号**：微信 iLink 返回
   `session not ready: ... the user must send the bot a message first (or re-pair)`。

### 0.7.26 新增的 gateway 门槛（本次最大的隐藏坑）

- 服务端 `e0e()` 第一句即 `if (t?.enabled !== true) return`，开关是 Studio 的
  `gatewayAutoStart`，实际写在 **`/home/agent/.hermes-web-ui/config.json`**
  （服务端 `UCe = ue.appHome`；未设置时默认**关闭**，形状 `{enabled, include?, exclude?}`）。
  ⚠️ 两个同名文件是陷阱：`~/.hermes/webui/settings.json` 是**前端 UI 偏好**（主题/布局，
  服务端不读），`~/.hermes-web-ui/settings.json` 在本部署**不存在**。
  叠加老毛病：`gateway_state.json` 记
  `desired_state=running` + 已随旧容器消失的 pid 111 → 启动恢复判定「已在跑」→ 跳过。
- 症状：三个 profile 的 gateway 全未启动，`hermesa/cron/ticker_heartbeat` 卡在 08:14:30，
  平台 bot / webhook 全挂。
- 修复：清掉陈旧 `gateway_state.json`（pid 不存在者）→
  `docker exec -d -w /opt/hermes <ct> /opt/hermes/.venv/bin/hermes gateway run --replace`
  → 现在 **core 0.21.5 是「一个宿主网关多路复用全 profile」**：
  ```
  ✓ default (current)   — PID 2464
  ✓ copilot             — served by the default multiplexer
  ✓ qwn                 — served by the default multiplexer
  ```
  default 平台 `api_server/webhook/weixin` 全部 `connected`；心跳恢复每 60s 刷新。

## 切换 / 回滚（v2 通用脚本 `deploy/redeploy-verify.sh`）

```bash
# TrueNAS 宿主 root
setsid nohup bash /tmp/redeploy-verify.sh <NEW_TAG> <OLD_TAG> [DELAY] &
# 例: EXPECT_CORE=0.21.5 setsid nohup bash /tmp/redeploy-verify.sh v0.7.27 v0.7.26 30 &
```

v2 相对 v1 的改进：**epoch 比较**（跨时区安全）、**回滚分支逐步记日志 + 校验容器真换代**、
**内置 gateway 处理**（切前 `hermes gateway stop`；切后清陈旧状态 + 拉起 + 校验
`gateway list` 与心跳 age < 120s）、**notify 失败不算部署失败**，并且 tag 参数化。

回滚：
```bash
midclt call -job app.stop hui
docker tag ghost7128/hermes-web-ui:v0.7.24 ghost7128/hermes-web-ui:latest
midclt call -job app.start hui
```
**v0.7.24 与 v0.6.47 镜像都不要删。**

## 遗留（需要用户动作）

1. ~~微信出站~~ **已完成**：用户给 bot 发消息后 iLink 会话恢复，实测
   `hermes send --to weixin` → `Sent to weixin home channel (chat_id: o9cq808gY0-7XI-PmLosd-ZVkbhE@im.wechat)`。
2. ~~Gateway 自动启动~~ **已完成**：用户在 Studio 里打开开关后，
   `/home/agent/.hermes-web-ui/config.json` 于 `2026-10-02 11:36:16` 写入
   `{"gatewayAutoStart":{"enabled":true}}`。无 include/exclude → 三个 profile 全覆盖，
   静态判定 `e0e()` 首道门（`enabled === true`）通过。
   真正的验证点在下次容器重启（届时 Studio 应自行拉起宿主网关，不再需要手工
   `hermes gateway run --replace`）。
