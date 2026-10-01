#!/bin/bash
# 冒烟测试：空数据目录 + 6070 端口，验证 v0.7.26 镜像能独立起来（不动生产容器/数据）
set -u
IMG=ghost7128/hermes-web-ui:v0.7.26
rm -rf /tmp/smoke-hermes /tmp/smoke-webui; mkdir -p /tmp/smoke-hermes /tmp/smoke-webui
docker rm -f studio-smoke >/dev/null 2>&1
docker run -d --name studio-smoke -p 6070:6060 -e PORT=6060 \
  -e HERMES_WEB_UI_MANAGED_GATEWAY=0 -e HERMES_WEB_UI_HOME=/tmp/smoke-webui \
  -e HERMES_ALLOW_ROOT_GATEWAY=1 \
  -v /tmp/smoke-hermes:/home/agent/.hermes -v /tmp/smoke-webui:/home/agent/.hermes-webui \
  "$IMG" >/dev/null
echo "=== 等待 40s 启动 ==="
sleep 40
echo "=== logs (tail 30) ==="
docker logs studio-smoke 2>&1 | tail -30
echo "=== HTTP ==="
for i in 1 2 3 4 5 6; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:6070/ || true)
  echo "  try $i: $CODE"; [ "$CODE" = "200" ] && break; sleep 8
done
echo "=== 版本 ==="
docker exec studio-smoke sh -c 'grep -m1 "\"version\"" /app/package.json; /opt/hermes/.venv/bin/hermes --version | head -1; command -v sshpass; ls -d /app/dist/client >/dev/null && echo "client dist OK"'
echo "=== copilot patch 是否进产物 ==="
docker exec studio-smoke sh -c 'grep -o "copilot:{[^}]*}" /app/dist/server/index.js | head -2'
echo "=== 清理 ==="
docker rm -f studio-smoke >/dev/null 2>&1 && echo "smoke container removed"
