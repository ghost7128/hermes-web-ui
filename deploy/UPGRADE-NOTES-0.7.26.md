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

## 切换 / 回滚（`redeploy-verify-0.7.26.sh`）

`bash /tmp/redeploy-verify-0.7.26.sh [延迟秒]`，宿主 root，`setsid nohup` 脱离 ssh 会话。
流程：DB 备份（Studio DB + hermesa/state.db）→ `midclt call -job app.stop hui` → retag
`latest → v0.7.26` → `app.start` → 等容器换代 → 就绪 + 版本轮询 → 失败自动回滚 v0.7.24
→ TDAI/gateway/DB 检查 → 结果写
`/mnt/NetDisk/hermes-webui-data/upgrade-0.7.26-result.txt` → 微信通报。

相对 0.7.24 版脚本的两处修正（skill 已记录的两坑）：
1. `midclt call -job app.stop/start` —— 等 job 完成，不再抢跑；
2. 版本检查改为「等容器 `Created` 晚于脚本启动时间」+ 镜像 ID 比对 ——
   消灭上次那个把旧容器读成新版本而误报 `VERSION_MISMATCH` 的竞态。

回滚：
```bash
midclt call -job app.stop hui
docker tag ghost7128/hermes-web-ui:v0.7.24 ghost7128/hermes-web-ui:latest
midclt call -job app.start hui
```
**v0.7.24 与 v0.6.47 镜像都不要删。**

## 待办

- [ ] 用户在合适窗口执行切换（当前生产仍跑 0.7.24 + core 0.20.6，`:latest` 未动）
- [ ] 切换后按脚本结果文件核对：`status=OK`、`hermes_core=0.21.5`、
      TDAI `available: true`、gateway `vectorStore: true`、Studio DB 计数不变
