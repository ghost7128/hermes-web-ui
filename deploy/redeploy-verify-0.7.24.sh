#!/bin/bash
# Hermes Web UI 0.6.47 -> 0.7.24 : 切换镜像 + 启动 + 验证 + 失败自动回滚
# 由 Hermes Agent 生成，在 TrueNAS 宿主 root 下 setsid 脱离 ssh 会话运行。
# 日志: /tmp/hui-upgrade-verify.log   结果: /mnt/NetDisk/hermes-webui-data/upgrade-0.7.24-result.txt
set -u

IMG=ghost7128/hermes-web-ui
NEW_TAG=v0.7.24
OLD_TAG=v0.6.47
APP=hui
DATADIR=/mnt/NetDisk/hermes-webui-data
LOG=/tmp/hui-upgrade-verify.log
RESULT="$DATADIR/upgrade-0.7.24-result.txt"
DELAY=${1:-30}

exec >>"$LOG" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
container() { docker ps --format '{{.Names}}' | grep -E 'hui|hermes-webui' | head -1; }
notify() {
  local ct; ct="$(container)"
  [ -n "$ct" ] && docker exec -w /opt/hermes "$ct" /opt/hermes/.venv/bin/hermes send --to weixin "$1" >/dev/null 2>&1 \
    && log "  [notify sent]" || log "  [notify FAILED]"
}

log "==================== $(date) 升级 0.6.47 -> 0.7.24 ===================="
log "=== 0. 延迟 ${DELAY}s（留给 Hermes 会话输出最终消息） ==="
sleep "$DELAY"

log "=== 1. 备份 Web UI 数据库 ==="
BK="$DATADIR/backup-pre-0.7.24-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
for f in hermes-web-ui.db hermes-web-ui.db-wal hermes-web-ui.db-shm config.json; do
  [ -f "$DATADIR/webui/$f" ] && cp -a "$DATADIR/webui/$f" "$BK/" && log "  backed up: $f"
done

log "=== 2. 停止 App ($APP) ==="
midclt call app.stop "$APP"; sleep 6

log "=== 3. retag latest -> $NEW_TAG ==="
docker tag "$IMG:$NEW_TAG" "$IMG:latest"

log "=== 4. 启动 App ==="
midclt call app.start "$APP" 2>&1 | tail -2

log "=== 5. 等待 Web UI 就绪 (最多 300s) ==="
OK=0
for i in $(seq 1 60); do
  CT="$(container)"
  if [ -n "$CT" ]; then
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:6060/ || true)"
    log "  try $i: container=$CT http=$CODE"
    case "$CODE" in 200|302|401|403) OK=1; break;; esac
  else
    log "  try $i: 容器尚未启动"
  fi
  sleep 5
done

if [ "$OK" != "1" ]; then
  log "!!! Web UI 未就绪 -> 自动回滚到 $OLD_TAG"
  midclt call app.stop "$APP" >/dev/null; sleep 6
  docker tag "$IMG:$OLD_TAG" "$IMG:latest"
  midclt call app.start "$APP" >/dev/null; sleep 25
  notify "[Hermes WebUI 升级] ❌ v0.7.24 启动失败，已自动回滚到 v0.6.47。日志: TrueNAS /tmp/hui-upgrade-verify.log"
  echo "ROLLED_BACK $(date)" > "$RESULT"
  exit 1
fi

CT="$(container)"
log "=== 6. 版本检查 ==="
WV="$(docker exec "$CT" sh -c "grep -m1 '\"version\"' /app/package.json" | tr -d ' \",')"
log "  webui version: $WV"
HV="$(docker exec "$CT" /opt/hermes/.venv/bin/hermes --version 2>&1 | head -1)"
log "  hermes core: $HV"
CD="$(docker exec "$CT" sh -c '[ -f /app/dist/client/index.html ] && echo OK || echo MISSING')"
log "  client dist: $CD"
SP="$(docker exec "$CT" sh -c 'command -v sshpass || echo MISSING')"
log "  sshpass: $SP"

log "=== 7. TDAI 检查 ==="
TDAI_OUT="$(docker exec -i "$CT" /opt/hermes/.venv/bin/python3 - <<'PYEOF'
import sys, json
sys.path.insert(0, '/opt/hermes')
res = {}
try:
    from plugins.memory import discover_memory_providers, load_memory_provider
    names = [n for n, _, _ in discover_memory_providers()]
    res['discover'] = 'memory_tencentdb' in names
    p = load_memory_provider('memory_tencentdb')
    res['type'] = type(p).__name__
    res['available'] = bool(p.is_available())
except Exception as e:
    res['error'] = f'{type(e).__name__}: {e}'
print(json.dumps(res, ensure_ascii=False))
PYEOF
)"
log "  $TDAI_OUT"
GW="$(docker exec "$CT" sh -c 'curl -s --max-time 12 http://127.0.0.1:8420/health')"
log "  gateway: $(printf '%s' "$GW" | cut -c1-220)"
VDB="$(docker exec "$CT" sh -c '[ -f /home/agent/.hermes/memory-tencentdb/memory-tdai/vectors.db ] && echo OK || echo MISSING')"
log "  vectors.db: $VDB"
GWP="$(docker exec "$CT" sh -c 'ps -eo args | grep -c "[t]sx.*gateway/server"')"
log "  gateway 进程数: $GWP"
ACT="$(grep -i "memory_tencentdb.*activat" /mnt/NetDisk/hermesa/logs/agent.log 2>/dev/null | tail -1)"
log "  agent.log: $ACT"

STATUS="OK"
echo "$TDAI_OUT" | grep -q '"available": true' || STATUS="TDAI_DEGRADED"
printf '%s' "$GW" | grep -q '"vectorStore":true' || STATUS="TDAI_GATEWAY_DOWN"
[ "$CD" = "OK" ] || STATUS="CLIENT_DIST_MISSING"
printf '%s' "$WV" | grep -q '0.7.24' || STATUS="VERSION_MISMATCH"

{
  echo "status=$STATUS"
  echo "time=$(date '+%F %T')"
  echo "webui_version=$WV"
  echo "hermes_core=$HV"
  echo "client_dist=$CD"
  echo "sshpass=$SP"
  echo "tdai=$TDAI_OUT"
  echo "gateway=$GW"
  echo "vectors_db=$VDB"
} > "$RESULT"

if [ "$STATUS" = "OK" ]; then
  log "=== ✅ 升级成功，状态 OK ==="
  notify "[Hermes WebUI 升级] ✅ v0.7.24 已上线（core: $HV）。TDAI 正常（gateway vectorStore+embedding OK）。若页面显示旧版本请 Ctrl+Shift+R 强刷。"
else
  log "=== ⚠️ 升级完成但状态: $STATUS ==="
  notify "[Hermes WebUI 升级] ⚠️ v0.7.24 已上线，但检查异常: $STATUS（TDAI: $TDAI_OUT）。日志: TrueNAS /tmp/hui-upgrade-verify.log"
fi
exit 0
