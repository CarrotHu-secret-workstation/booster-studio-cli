#!/bin/bash
# spawn_second_sim.sh — 多开: 用纯 CLI 起第二个（第 N 个）3v3 仿真容器并跑无头对战
# 原理: 镜像里 /usr/local/booster_robot 是空的（仿真源码由 Booster Studio 首次"运行"时注入），
#       所以要先从现役容器把仿真源码搬过去, 写好 /root/.env, 再手动拉起 start_in_docker.sh。
# 用法: ./spawn_second_sim.sh <新容器名> [源容器名]
set -euo pipefail

NAME="${1:?用法: $0 <新容器名> [源容器名]}"
SRC="${2:-$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Command}}' | awk -F'\t' '$2 ~ /virtual-robot\/virtual-robot/ && $3 ~ /ros_entrypoint/ {print $1; exit}')}"
IMG=$(docker inspect "$SRC" --format '{{.Config.Image}}')
echo "[spawn] 新容器: $NAME  源: $SRC  镜像: $IMG"

docker rm -f "$NAME" 2>/dev/null || true

# 1. 起新容器（参数逆向自 Booster Studio 创建的容器: privileged + shm 256m;
#    镜像入口脚本会因缺 /usr/local/booster_robot 退出, 故先用 sleep 占住）
docker run -d --name "$NAME" --privileged --shm-size=268435456 -P \
  --entrypoint sleep "$IMG" infinity

# 2. 搬运仿真源码 (~2.9G, tar 流式 container->container)
echo "[spawn] 复制仿真源码 /usr/local/booster_robot (~2.9G)..."
# --exclude: logs 是运行产物(且比赛进行中会持续变化导致 tar 报错), 不需要搬运
docker exec "$SRC" tar cf - --exclude=booster_robot/booster_robocup_sim/logs -C /usr/local booster_robot | docker exec -i "$NAME" tar xf - -C /usr/local

# 3. agent 解包目录 + runner
docker exec "$NAME" mkdir -p /opt/booster/booster_agent_data/data/agents/extract /usr/local/booster_agent
docker exec "$SRC" tar cf - -C /opt/booster/booster_agent_data/data/agents/extract . | \
  docker exec -i "$NAME" tar xf - -C /opt/booster/booster_agent_data/data/agents/extract
docker exec "$SRC" tar cf - -C /usr/local/booster_agent football3v3_runner | \
  docker exec -i "$NAME" tar xf - -C /usr/local/booster_agent

# 4. 3v3 场地配置（等价于 Booster Studio 切场景时写的 $HOME/.env）
docker exec "$NAME" bash -c 'printf "MODEL_PATH=mjcf/football_match_pitch_6_K1.xml\nSIM_TRANSPORT=shm\n" > /root/.env'

# 5. 拉起完整仿真栈（detached）
echo "[spawn] 启动仿真栈..."
docker exec -d "$NAME" bash -c '/usr/local/booster_robot/start_in_docker.sh'

# 6. 等 game-control(38383) 就绪
echo "[spawn] 等待 game-control 就绪..."
for i in $(seq 1 30); do
  sleep 5
  H=$(docker exec "$NAME" bash -c 'curl -s --max-time 3 http://127.0.0.1:38383/health' 2>/dev/null || true)
  echo "  health[$i]: ${H:-<not up yet>}"
  [ -n "$H" ] && break
  [ "$i" = 30 ] && { echo "[spawn] 150s 未就绪, 日志:"; docker exec "$NAME" tail -30 /usr/local/booster_robot/booster-server.log 2>/dev/null; exit 1; }
done

echo "[spawn] 完成。开赛示例:"
echo "  ./run_match.sh start com.example.simpleplus UpdateV6o1 $NAME"
echo "  ./run_match.sh watch $NAME"
echo "  ./run_match.sh end $NAME && docker rm -f $NAME"
