#!/bin/bash
# Hermes Web UI 0.7.24 -> 0.7.26 (Ekko Studio) + Hermes core 0.20.6 -> 0.21.5
# 由 Hermes Agent 生成（复用 skill hermes-webui-upgrade 的 0.7.24 脚本，修两处坑）
#  坑1: midclt call -job app.stop/start 等待 job 完成，不再抢跑
#  坑2: 版本检查等「容器 Created 晚于脚本启动时间」+ 镜像 ID 比对，避免读到旧容器
# 运行: setsid nohup bash /tmp/redeploy-verify-0.7.26.sh [延迟秒] &
set -u

IMG=ghost7128/hermes-web-ui
NEW_TAG=v0.7.26
OLD_TAG=v0.7.24
APP=hui
CN=ix-hui-hermes-webui-1
DATADIR=/mnt/NetDisk/hermes-webui-data
LOG=/tmp/hui-upgrade-verify.log
RESULT="$DATADIR/upgrade-0.7.26-result.txt"
DELAY=${1:-30}
EXPECT_UI=0.7.26
EXPECT_CORE=0.21.5
ROLLBACK=0

exec >>"$LOG" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
container() { docker ps --format '{{.Names}}' | grep -E 'hui|hermes-webui' | head -1; }
notify() {
  local ct; ct="$(container)"
  if [ -n "$ct" ] && docker exec -w /opt/hermes "$ct" /opt/hermes/.venv/bin/hermes send --to weixin "$1" >/dev/null 2>&1; then
    log "  [notify ok]"
  else
    log "  [notify FAILED]"
  fi
}
wait_new_container() {
  local ts="$1" i c cr
  for i in $(seq 1 40); do
    c=$(docker ps -q --filter "name=$CN")
    if [ -n "$c" ]; then
      cr=$(docker inspect -f '{{.Created}}' "$c")
      if [[ "$cr" > "$ts" ]]; then log "  container renewed (try $i): Created=$cr"; return 0; fi
      log "  still old container (try $i): Created=$cr"
    else
      log "  container not up (try $i)"
    fi
    sleep 5
  done
  return 1
}

log "==================== $(date) 0.7.24(core 0.20.6) -> 0.7.26(core 0.21.5) ===================="
log "=== 0. delay ${DELAY}s ==="
sleep "$DELAY"

log "=== 1. backup Studio DB + Hermes state ==="
BK="$DATADIR/backup-pre-0.7.26-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
for f in hermes-web-ui.db hermes-web-ui.db-wal hermes-web-ui.db-shm config.json; do
  [ -f "$DATADIR/webui/$f" ] && cp -a "$DATADIR/webui/$f" "$BK/" && log "  backed up: webui/$f"
done
for f in state.db sessions.db; do
  [ -f "/mnt/NetDisk/hermesa/$f" ] && cp -a "/mnt/NetDisk/hermesa/$f" "$BK/hermes-$f" && log "  backed up: hermesa/$f"
done

START_TS=$(date -Iseconds)
log "=== 2. stop App ($APP)  [START_TS=$START_TS] ==="
midclt call -job app.stop "$APP" >/dev/null 2>&1 || midclt call app.stop "$APP"
sleep 8

log "=== 3. retag latest -> $NEW_TAG ==="
if ! docker tag "$IMG:$NEW_TAG" "$IMG:latest"; then
  log "!!! retag failed, abort (nothing switched)"
  notify "[Hermes UI upgrade] retag failed, aborted"
  echo "RETAG_FAILED $(date)" > "$RESULT"; exit 1
fi
log "  latest -> $(docker image inspect "$IMG:$NEW_TAG" -f '{{.Id}}' | cut -c1-19)"

log "=== 4. start App ==="
midclt call -job app.start "$APP" >/dev/null 2>&1 || midclt call app.start "$APP"

log "=== 5. wait for container renewal ==="
wait_new_container "$START_TS" || { log "!!! container not renewed"; ROLLBACK=1; }

if [ "$ROLLBACK" != "1" ]; then
  log "=== 5b. readiness + version poll (max 180s) ==="
  for i in $(seq 1 36); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:6060/ || true)
    WV=$(docker exec "$CN" sh -c "grep -m1 '\"version\"' /app/package.json" 2>/dev/null | tr -d ' ",')
    log "  try $i: http=$CODE webui=$WV"
    if [ "$CODE" = "200" ] && [[ "$WV" == *"$EXPECT_UI"* ]]; then break; fi
    sleep 5
  done
  [ "$CODE" = "200" ] || { log "!!! http not ready"; ROLLBACK=1; }
  [[ "$WV" == *"$EXPECT_UI"* ]] || { log "!!! version mismatch ($WV)"; ROLLBACK=1; }
fi

if [ "$ROLLBACK" = "1" ]; then
  log "!!! switch failed -> auto rollback to $OLD_TAG"
  notify "[Hermes UI upgrade] v0.7.26 failed to start, rolling back to v0.7.24"
  midclt call -job app.stop "$APP" >/dev/null 2>&1; sleep 8
  docker tag "$IMG:$OLD_TAG" "$IMG:latest"
  RT_TS=$(date -Iseconds)
  midclt call -job app.start "$APP" >/dev/null 2>&1
  RCODE=000
  for i in $(seq 1 40); do
    RCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:6060/ || true)
    c=$(docker ps -q --filter "name=$CN"); cr=""
    [ -n "$c" ] && cr=$(docker inspect -f '{{.Created}}' "$c")
    if [ "$RCODE" = "200" ] && [[ "$cr" > "$RT_TS" ]]; then break; fi
    sleep 5
  done
  notify "[Hermes UI upgrade] rolled back to v0.7.24 (http=$RCODE). See TrueNAS /tmp/hui-upgrade-verify.log"
  echo "ROLLED_BACK $(date)" > "$RESULT"; exit 1
fi

log "=== 6. detailed checks ==="
CT="$CN"
WANT=$(docker image inspect "$IMG:$NEW_TAG" -f '{{.Id}}')
GOT=$(docker inspect -f '{{.Image}}' "$CT")
HV=$(docker exec "$CT" /opt/hermes/.venv/bin/hermes --version 2>&1 | head -1)
CD=$(docker exec "$CT" sh -c '[ -f /app/dist/client/index.html ] && echo OK || echo MISSING')
SP=$(docker exec "$CT" sh -c 'command -v sshpass || echo MISSING')
DBS=$(docker exec "$CT" /opt/hermes/.venv/bin/python3 -c "import sqlite3;c=sqlite3.connect('/home/agent/.hermes-web-ui/hermes-web-ui.db');print({t:c.execute('select count(*) from '+t).fetchone()[0] for t in ('sessions','messages','users')})" 2>&1 | tail -1)
TDAI_OUT=$(docker exec -i "$CT" /opt/hermes/.venv/bin/python3 - <<'PYEOF'
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
)
GW=$(docker exec "$CT" sh -c 'curl -s --max-time 12 http://127.0.0.1:8420/health')
VDB=$(docker exec "$CT" sh -c '[ -f /home/agent/.hermes/memory-tencentdb/memory-tdai/vectors.db ] && echo OK || echo MISSING')
GWP=$(docker exec "$CT" sh -c 'ps -eo args | grep -c "[t]sx.*gateway/server"')
CRONHB=$(ls -l --time-style=+%F_%T /mnt/NetDisk/hermesa/cron/ticker_heartbeat 2>/dev/null | awk '{print $6}')
log "  image: $(printf '%s' "$GOT" | cut -c1-19) (want $(printf '%s' "$WANT" | cut -c1-19))"
log "  webui=$WV  core: $HV"
log "  client_dist=$CD  sshpass=$SP"
log "  db=$DBS"
log "  TDAI: $TDAI_OUT"
log "  gateway: $(printf '%s' "$GW" | cut -c1-200)"
log "  vectors.db=$VDB  gateway_procs=$GWP  cron_heartbeat=$CRONHB"

STATUS=OK
[ "$GOT" = "$WANT" ] || STATUS=IMAGE_MISMATCH
[[ "$WV" == *"$EXPECT_UI"* ]] || STATUS=VERSION_MISMATCH
[[ "$HV" == *"$EXPECT_CORE"* ]] || STATUS=CORE_MISMATCH
[ "$CD" = "OK" ] || STATUS=CLIENT_DIST_MISSING
echo "$TDAI_OUT" | grep -q '"available": true' || STATUS=TDAI_DEGRADED
printf '%s' "$GW" | grep -q '"vectorStore":true' || STATUS=TDAI_GATEWAY_DOWN

{
  echo "status=$STATUS"
  echo "time=$(date '+%F %T')"
  echo "image=$GOT"
  echo "webui_version=$WV"
  echo "hermes_core=$HV"
  echo "client_dist=$CD"
  echo "sshpass=$SP"
  echo "studio_db=$DBS"
  echo "tdai=$TDAI_OUT"
  echo "gateway=$GW"
  echo "vectors_db=$VDB"
  echo "gateway_procs=$GWP"
  echo "cron_heartbeat=$CRONHB"
  echo "backup=$BK"
} > "$RESULT"

if [ "$STATUS" = "OK" ]; then
  log "=== upgrade OK ==="
  notify "[Hermes UI 升级] Ekko Studio v0.7.26 + Hermes core 0.21.5 已上线。Studio DB: $DBS；TDAI gateway 正常。页面显示旧版本请 Ctrl+Shift+R 强刷。"
else
  log "=== online but status: $STATUS ==="
  notify "[Hermes UI 升级] v0.7.26 已上线但检查异常: $STATUS（core: $HV）。日志 TrueNAS /tmp/hui-upgrade-verify.log"
fi
exit 0
