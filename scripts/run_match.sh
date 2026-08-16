#!/bin/bash
# run_match.sh — 纯 CLI 无头对战（自定义双方, 不开任何 GUI）
# 用法:
#   ./run_match.sh start <红方agent_id> <蓝方agent_id> [sim容器]   # 清场+启动两队+等ready+开赛
#   ./run_match.sh status [sim容器]                                # 比分/状态一行摘要
#   ./run_match.sh watch [sim容器]                                 # 每5s报比分直到比赛结束
#   ./run_match.sh end   [sim容器]                                 # 结束比赛+停runner+清进程
set -euo pipefail
CMD="${1:?用法: $0 start <红> <蓝> [容器] | status [容器] | watch [容器] | end [容器]}"; shift

find_sim() { docker ps --format '{{.Names}}\t{{.Image}}\t{{.Command}}' | awk -F'\t' '$2 ~ /virtual-robot\/virtual-robot/ && $3 ~ /ros_entrypoint/ {print $1; exit}'; }
gc() { docker exec "$SIM" bash -c "curl -s --max-time 5 -X $1 http://127.0.0.1:38383$2"; }

case "$CMD" in
  start)
    T1="${1:?缺红方agent_id}"; T2="${2:?缺蓝方agent_id}"; SIM="${3:-$(find_sim)}"
    echo "[match] 清理残留进程/cgroup..."
    docker exec "$SIM" bash -c "echo 1 > /sys/fs/cgroup/3v3_runner/team_1/cgroup.kill 2>/dev/null; echo 1 > /sys/fs/cgroup/3v3_runner/team_2/cgroup.kill 2>/dev/null; sleep 1; pkill -9 -f football3v3 2>/dev/null; pkill -9 -f 'run.py.*teams' 2>/dev/null; rmdir /sys/fs/cgroup/3v3_runner/team_1 /sys/fs/cgroup/3v3_runner/team_2 2>/dev/null; true" || true
    echo "[match] 启动 headless runner: $T1 vs $T2"
    docker exec -d "$SIM" bash -c "cd /usr/local/booster_agent/football3v3_runner && python3 launcher.py --publish-logs --teams '$T1' '$T2'"
    for i in $(seq 1 24); do
      sleep 5
      H=$(gc GET /health || true)
      echo "[match] health[$i]: $H"
      if echo "$H" | grep -q '"checks":{"team1":true,"team2":true}'; then echo "[match] 两队 ready"; break; fi
      if [ "$i" = 24 ]; then
        echo "[match] 120s 未 ready, run.py 日志尾部:"
        docker exec "$SIM" tail -20 /usr/local/booster_agent/football3v3_runner/football3v3-run.log 2>/dev/null || true
        exit 1
      fi
    done
    echo "[match] POST /match/start"
    gc POST /match/start | head -c 120; echo
    echo "[match] 已开赛。'$0 status' 查比分; '$0 watch' 盯完整场。"
    ;;
  status)
    SIM="${1:-$(find_sim)}"
    gc GET /status | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["match"]; g=m["game"]; print("state={} phase={} score={}-{} dur={}s events={}".format(g["state"], g["phase"], m["score"]["home"], m["score"]["away"], round(m["durationSeconds"]), m["eventsTotal"]))'
    ;;
  watch)
    SIM="${1:-$(find_sim)}"
    while true; do
      S=$(gc GET /status)
      echo "$(date +%H:%M:%S) $(echo "$S" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["match"]; g=m["game"]; print("{}\t{}-{}\t{}s\tevents={}".format(g["state"], m["score"]["home"], m["score"]["away"], round(m["durationSeconds"]), m["eventsTotal"]))')"
      echo "$S" | grep -q '"isFinal":true' && { echo "[match] 比赛结束"; break; }
      sleep 5
    done
    ;;
  end)
    SIM="${1:-$(find_sim)}"
    gc POST /match/end | head -c 80; echo
    docker exec "$SIM" bash -c "cd /usr/local/booster_agent/football3v3_runner && python3 launcher.py --stop"
    docker exec "$SIM" bash -c "echo 1 > /sys/fs/cgroup/3v3_runner/team_1/cgroup.kill 2>/dev/null; echo 1 > /sys/fs/cgroup/3v3_runner/team_2/cgroup.kill 2>/dev/null; pkill -9 -f 'ros2 launch' 2>/dev/null; true" || true
    echo "[match] 已结束并清理"
    ;;
  *) echo "未知命令 $CMD"; exit 1 ;;
esac
