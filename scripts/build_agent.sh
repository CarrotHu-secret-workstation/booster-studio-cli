#!/bin/bash
# build_agent.sh — 把 Python agent 项目编译成 .agent（绕过 Booster Studio GUI）
# 用法: ./build_agent.sh <项目目录> [agent-dev容器名]
# 产物: <项目目录>/build/<agent_id>-<version>.agent
set -euo pipefail

PROJECT_DIR=$(realpath "${1:?用法: $0 <项目目录> [agent-dev容器名]}")
AGENT_DEV="${2:-}"

# 自动发现 agent-dev 容器（优先 running）
if [ -z "$AGENT_DEV" ]; then
  AGENT_DEV=$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.State}}' \
    | awk -F'\t' '$2 ~ /agent-dev\/agent-dev/ && $3=="running" {print $1; exit}')
  [ -z "$AGENT_DEV" ] && AGENT_DEV=$(docker ps -a --format '{{.Names}}\t{{.Image}}' \
    | awk -F'\t' '$2 ~ /agent-dev\/agent-dev/ {print $1; exit}')
fi
[ -z "$AGENT_DEV" ] && { echo "ERROR: 未找到 agent-dev 容器（请先在 Booster Studio 打开过任一项目, 或手动传容器名）"; exit 1; }
echo "[build] agent-dev 容器: $AGENT_DEV"

# 容器内路径: 优先直接用挂载路径（Booster Studio 挂载到 /workspace/src/<id>）
CTR_PATH=$(docker inspect "$AGENT_DEV" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' \
  | awk -v src="$PROJECT_DIR" -F' -> ' '$1==src {print $2; exit}')
if [ -z "$CTR_PATH" ]; then
  CTR_PATH="/tmp/cli-build-$(basename "$PROJECT_DIR")"
  echo "[build] 项目未挂载, 复制到容器 $CTR_PATH"
  docker exec "$AGENT_DEV" rm -rf "$CTR_PATH"
  docker cp "$PROJECT_DIR" "$AGENT_DEV:$CTR_PATH"
fi
echo "[build] 容器内路径: $CTR_PATH"

# 官方编译命令（签名对逆向自 native-addon: /.agent_dev/keystore.p12 / 123456）
docker exec "$AGENT_DEV" bash -c \
  "export AGENT_SIGN_KEYSTORE=/.agent_dev/keystore.p12 && \
   export AGENT_SIGN_KEYSTORE_PASSWD=123456 && \
   /sdk/agent_bundler/build_pyagent $CTR_PATH"

# 若项目是 cp 进容器的, 把产物拷回宿主机
if ! docker inspect "$AGENT_DEV" --format '{{range .Mounts}}{{.Source}}{{println}}{{end}}' | grep -qxF "$PROJECT_DIR"; then
  rm -rf "$PROJECT_DIR/build"
  docker cp "$AGENT_DEV:$CTR_PATH/build" "$PROJECT_DIR/build"
fi
echo "[build] 产物:"
ls -la "$PROJECT_DIR"/build/*.agent
