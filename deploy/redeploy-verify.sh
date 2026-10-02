#!/bin/bash
# Ekko Studio 镜像切换 + 验证 + 失败自动回滚（通用版，参数化 tag）
# 用法（TrueNAS 宿主 root）:
#   setsid nohup bash /tmp/redeploy-verify.sh <NEW_TAG> <OLD_TAG> [DELAY] &
#   EXPECT_CORE 环境变量可指定期望 core（默认 0.21.5）
#
# v2 相对 v1（0.7.26 那次实跑）修掉的坑：
#  1) 容器换代判定改用 epoch 比较。docker inspect .Created 是 UTC（...Z），
#     而 `date -Iseconds` 是本地 +08:00 → 字符串字典序比较永远为假，
#     导致 v1 误判「container not renewed」并对一次**成功**的切换触发假回滚。
#  2) 回滚分支每步都记日志并校验 app 真停了/真起了（v1 里 app.stop 静默无效，
#     回滚只改了 latest tag，留下「容器跑新镜像、latest 指向旧镜像」的地雷）。
#  3) 内置 Hermes gateway 处理：切换前优雅停（写 desired_state=stopped），
#     切换后清陈旧 gateway_state.json（pid 已不存在）并拉起宿主网关，
#     校验 `gateway list` 与 cron 心跳刷新。0.7.26 起 gateway 自动启动由
#     Studio 设置 gatewayAutoStart.enabled 控制，默认关闭 → 不处理就是「网关永久不启动」。
#  4) notify 失败不算部署失败：微信 iLink 会话需用户先给 bot 发消息，否则
#     返回 "session not ready"。
set -u

NEW_TAG=${1:?usage: redeploy-verify.sh <NEW_TAG> <OLD_TAG> [DELAY]}
OLD_TAG=${2:?usage: redeploy-verify.sh <NEW_TAG> <OLD_TAG> [DELAY]}
DELAY=${3:-30}
IMG=ghost7128/hermes-web-ui
APP=hui
CN=ix-hui-hermes-webui-1
DATADIR=/mnt/NetDisk/hermes-webui-data
LOG=/tmp/hui-upgrade-verify.log
RESULT="$DATADIR/upgrade-${NEW_TAG#v}-result.txt"
EXPECT_UI=${NEW_TAG#v}
EXPECT_CORE=${EXPECT_CORE:-0.21.5}
HEARTBEAT=/mnt/NetDisk/hermesa/cron/ticker_heartbeat
ROLLBACK=0

exec >>"$LOG" 2>&1
log()  { echo "[$(date '+%F %T')] $*"; }
container() { docker ps --format '{{.Names}}' | grep -E 'hui|hermes-webui' | head -1; }
notify() {
  local ct; ct="$(container)"
  if [ -n "$ct" ] && docker exec -w /opt/hermes "$ct" /opt/hermes/.venv/bin/hermes send --to weixin "$1" >/dev/null 2>&1; then
    log "  [notify ok]"
  else
    log "  [notify FAILED - 微信会话未就绪，需用户先给 bot 发消息；不影响部署结论]"
  fi
}
# 容器 Created 的 epoch（UTC 字符串 -> epoch，跨时区安全）
ct_epoch() {
  local c; c=$(docker ps -q --filter "name=$CN")
  [ -z "$c" ] && { echo 0; return; }
  date -u -d "$(docker inspect -f '{{.Created}}' "$c")" +%s 2>/dev/null || echo 0
}
wait_new_container() {   # $1 = 起始 epoch
  local t0="$1" i e
  for i in $(seq 1 40); do
    e=$(ct_epoch)
    if [ "$e" -gt "$t0" ]; then log "  container renewed (try $i) created_epoch=$e"; return 0; fi
    log "  still old/absent (try $i) created_epoch=$e"
    sleep 5
  done
  return 1
}
ensure_gateway() {
  log "  -- gateway: 清理陈旧状态（pid 已不存在者）"
  docker exec "$CN" sh -c 'for f in /home/agent/.hermes/gateway_state.json /home/agent/.hermes/profiles/*/gateway_state.json; do
      [ -f "$f" ] || continue
      p=$(sed -n "s/.*\"pid\":\([0-9]\{1,7\}\).*/\1/p" "$f" | head -1)
      if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then mv "$f" "$f.stale-$(date +%s)" && echo "    stale removed: $f (pid $p gone)"; fi
    done' 2>/dev/null | tail -4
  if docker exec -w /opt/hermes "$CN" /opt/hermes/.venv/bin/hermes gateway status 2>&1 | grep -q "is running"; then
    log "  -- gateway: 已在运行"
  else
    log "  -- gateway: 未运行，拉起宿主网关（run --replace）"
    docker exec -d -w /opt/hermes "$CN" /opt/hermes/.venv/bin/hermes gateway run --replace
    sleep 45
  fi
  docker exec -w /opt/hermes "$CN" /opt/hermes/.venv/bin/hermes gateway list 2>&1 | sed 's/^/    /' | head -8
}

log "==================== $(date) switch to $NEW_TAG (from $OLD_TAG) ===================="
log "=== 0. delay ${DELAY}s ==="
sleep "$DELAY"

log "=== 1. backup Studio DB + Hermes state ==="
BK="$DATADIR/backup-pre-${NEW_TAG#v}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
for f in hermes-web-ui.db hermes-web-ui.db-wal hermes-web-ui.db-shm config.json; do
  [ -f "$DATADIR/webui/$f" ] && cp -a "$DATADIR/webui/$f" "$BK/" && log "  backed up: webui/$f"
done
for f in state.db sessions.db; do
  [ -f "/mnt/NetDisk/hermesa/$f" ] && cp -a "/mnt/NetDisk/hermesa/$f" "$BK/hermes-$f" && log "  backed up: hermesa/$f"
done

log "=== 2. 优雅停 Hermes gateway（避免留下 desired_state=running 的僵尸状态） ==="
docker exec -w /opt/hermes "$CN" /opt/hermes/.venv/bin/hermes gateway stop 2>&1 | tail -2 | sed 's/^/  /' || true

START_EPOCH=$(date -u +%s)
log "=== 3. stop App ($APP) [START_EPOCH=$START_EPOCH] ==="
midclt call -job app.stop "$APP" >/dev/null 2>&1 || midclt call app.stop "$APP" >/dev/null 2>&1
for i in $(seq 1 12); do [ -z "$(container)" ] && break; sleep 5; done
log "  容器已停: $([ -z "$(container)" ] && echo yes || echo 'no（继续，后续以 Created 判定）')"

log "=== 4. retag latest -> $NEW_TAG ==="
if ! docker tag "$IMG:$NEW_TAG" "$IMG:latest"; then
  log "!!! retag 失败，中止（未切换）"; notify "[Hermes UI] retag $NEW_TAG 失败，已中止未切换"
  echo "RETAG_FAILED $(date)" > "$RESULT"; exit 1
fi
log "  latest = $(docker image inspect "$IMG:latest" -f '{{.Id}}' | cut -c1-19)"

log "=== 5. start App ==="
midclt call -job app.start "$APP" >/dev/null 2>&1 || midclt call app.start "$APP" >/dev/null 2>&1

log "=== 6. 等容器换代（epoch 比较） ==="
wait_new_container "$START_EPOCH" || { log "!!! 容器未换代"; ROLLBACK=1; }

if [ "$ROLLBACK" != "1" ]; then
  log "=== 7. 就绪 + 版本轮询（最多 180s） ==="
  CODE=000; WV=""
  for i in $(seq 1 36); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:6060/ || true)
    WV=$(docker exec "$CN" sh -c "grep -m1 '\"version\"' /app/package.json" 2>/dev/null | tr -d ' ",')
    log "  try $i: http=$CODE webui=$WV"
    if [ "$CODE" = "200" ] && [[ "$WV" == *"$EXPECT_UI"* ]]; then break; fi
    sleep 5
  done
  [ "$CODE" = "200" ] || { log "!!! http 不就绪"; ROLLBACK=1; }
  [[ "$WV" == *"$EXPECT_UI"* ]] || { log "!!! 版本不匹配 ($WV != $EXPECT_UI)"; ROLLBACK=1; }
fi

if [ "$ROLLBACK" = "1" ]; then
  log "!!! 切换失败 -> 回滚 $OLD_TAG"
  notify "[Hermes UI] $NEW_TAG 启动/版本检查失败，正在回滚 $OLD_TAG"
  midclt call -job app.stop "$APP" >/dev/null 2>&1; sleep 10
  log "  app.stop 后容器: $(container || echo 无)"
  docker tag "$IMG:$OLD_TAG" "$IMG:latest" && log "  latest -> $OLD_TAG"
  RT_EPOCH=$(date -u +%s)
  midclt call -job app.start "$APP" >/dev/null 2>&1; sleep 10
  RCODE=000
  for i in $(seq 1 40); do
    RCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:6060/ || true)
    e=$(ct_epoch)
    if [ "$RCODE" = "200" ] && [ "$e" -gt "$RT_EPOCH" ]; then break; fi
    sleep 5
  done
  log "  回滚后 http=$RCODE created_epoch=$(ct_epoch) (>$RT_EPOCH 为真)"
  docker exec -w /opt/hermes "$CN" /opt/hermes/.venv/bin/hermes gateway stop >/dev/null 2>&1 || true
  ensure_gateway
  notify "[Hermes UI] 已回滚 $OLD_TAG (http=$RCODE)。日志 TrueNAS /tmp/hui-upgrade-verify.log"
  echo "ROLLED_BACK $(date) old=$OLD_TAG http=$RCODE" > "$RESULT"; exit 1
fi

log "=== 8. 校验 ==="
WANT=$(docker image inspect "$IMG:$NEW_TAG" -f '{{.Id}}')
GOT=$(docker inspect -f '{{.Image}}' "$CN")
HV=$(docker exec "$CN" /opt/hermes/.venv/bin/hermes --version 2>&1 | head -1)
CD=$(docker exec "$CN" sh -c '[ -f /app/dist/client/index.html ] && echo OK || echo MISSING')
SP=$(docker exec "$CN" sh -c 'command -v sshpass || echo MISSING')
DBS=$(docker exec "$CN" /opt/hermes/.venv/bin/python3 -c "import sqlite3;c=sqlite3.connect('/home/agent/.hermes-web-ui/hermes-web-ui.db');print({t:c.execute('select count(*) from '+t).fetchone()[0] for t in ('sessions','messages','users')})" 2>&1 | tail -1)
TDAI_OUT=$(docker exec -i "$CN" /opt/hermes/.venv/bin/python3 - <<'PYEOF'
import sys, json
sys.path.insert(0, '/opt/hermes')
res = {}
try:
    from plugins.memory import discover_memory_providers, load_memory_provider
    res['discover'] = 'memory_tencentdb' in [n for n, _, _ in discover_memory_providers()]
    res['available'] = bool(load_memory_provider('memory_tencentdb').is_available())
except Exception as e:
    res['error'] = f'{type(e).__name__}: {e}'
print(json.dumps(res, ensure_ascii=False))
PYEOF
)
GW=$(docker exec "$CN" sh -c 'curl -s --max-time 12 http://127.0.0.1:8420/health')
VDB=$(docker exec "$CN" sh -c '[ -f /home/agent/.hermes/memory-tencentdb/memory-tdai/vectors.db ] && echo OK || echo MISSING')

log "=== 9. gateway 保证（0.7.26 起必须显式拉起） ==="
ensure_gateway
HB_AGE2=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0) ))
log "  cron 心跳: $(ls -l --time-style=+%F_%T "$HEARTBEAT" 2>/dev/null | awk '{print $6}') (age ${HB_AGE2}s)"
sleep 60
HB_AGE2=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0) ))
log "  60s 后心跳 age: ${HB_AGE2}s （应 < 120s 才算 ticker 活着）"

log "  image: $(printf '%s' "$GOT" | cut -c1-19) (want $(printf '%s' "$WANT" | cut -c1-19))"
log "  webui=$WV core: $HV"
log "  client_dist=$CD sshpass=$SP"
log "  studio_db=$DBS"
log "  TDAI: $TDAI_OUT"
log "  tdai_gateway: $(printf '%s' "$GW" | cut -c1-200)"

STATUS=OK
[ "$GOT" = "$WANT" ] || STATUS=IMAGE_MISMATCH
[[ "$WV" == *"$EXPECT_UI"* ]] || STATUS=VERSION_MISMATCH
[[ "$HV" == *"$EXPECT_CORE"* ]] || STATUS=CORE_MISMATCH
[ "$CD" = "OK" ] || STATUS=CLIENT_DIST_MISSING
echo "$TDAI_OUT" | grep -q '"available": true' || STATUS=TDAI_DEGRADED
printf '%s' "$GW" | grep -q '"vectorStore":true' || STATUS=TDAI_GATEWAY_DOWN
[ "$HB_AGE2" -lt 120 ] || STATUS=CRON_TICKER_STALE

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
  echo "tdai_gateway=$(printf '%s' "$GW" | cut -c1-400)"
  echo "vectors_db=$VDB"
  echo "cron_heartbeat_age_s=$HB_AGE2"
  echo "backup=$BK"
} > "$RESULT"

if [ "$STATUS" = "OK" ]; then
  log "=== upgrade OK ==="
  notify "[Hermes UI] $NEW_TAG + core $HV 上线，gateway/cron 正常。DB: $DBS"
else
  log "=== online but status: $STATUS ==="
  notify "[Hermes UI] $NEW_TAG 上线但检查异常: $STATUS（core: $HV）"
fi
exit 0
