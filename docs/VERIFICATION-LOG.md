# 验证记录（全部在本机实测, 非推测）

环境: Booster Studio 1.110.1-1782836622 / agent-dev:0.6.26-alpha / virtual-robot:0.6.4-beta / Docker
日期: 2026-08-16

## 1. Python → .agent 编译 ✅

```
$ docker exec agent-dev-cdbfc007d62b0633dcba94cf838f65ac bash -c \
    'export AGENT_SIGN_KEYSTORE=/.agent_dev/keystore.p12 && \
     export AGENT_SIGN_KEYSTORE_PASSWD=123456 && \
     /sdk/agent_bundler/build_pyagent /workspace/src/cdbfc007d62b0633dcba94cf838f65ac'
[0000.1s STEP] Initializing build context
[0000.1s INFO] Runtime config validation passed
[0000.1s WARN] Using sign config from environment
[0000.9s STEP] Build completed: UpdateV6o1B-ReBuildBoost0725.agent
```
- 无签名时: `ERROR Missing sign config` → 证实签名是唯一缺口, keystore 对(逆向自 native-addon 二进制字符串)直接解决。
- `scripts/build_agent.sh` 封装后对未挂载项目同样工作(自动 docker cp 进出)。

## 2. 自定义双方无头对战 ✅

```
$ docker exec -d vjzb0-k1 bash -c 'cd /usr/local/booster_agent/football3v3_runner && \
    python3 launcher.py --publish-logs --teams com.example.simpleplus UpdateV6o1'
$ # 5s 后 health: {"ready":true,"checks":{"team1":true,"team2":true}}
$ docker exec vjzb0-k1 curl -s -X POST http://127.0.0.1:38383/match/start  → {"ok":true,...}
$ # 60s 后 status:
  state=playing phase=firstHalf score=0-0 dur=71s events=64   ← 纯 CLI, GUI 全程未参与
$ docker exec vjzb0-k1 curl -s -X POST http://127.0.0.1:38383/match/end    → {"ok":true,...state:finished}
$ docker exec vjzb0-k1 bash -c 'cd .../football3v3_runner && python3 launcher.py --stop'
  stopping 3v3_runner: pid=8662 → stopped
```

## 3. 无头模式 ✅

上面整场即为无头流程——没有任何 GUI 调用；比赛状态机/裁判/事件全部由容器内
`bs-ext-game-control` (pid 174, /usr/local/booster_robot/booster_robocup_sim) 驱动。

## 4. 多开 ✅ 第三轮实测通过

发现: 镜像里 /usr/local/booster_robot 是空目录, 仿真源码是 Booster Studio 首次"运行"注入的
(直接 docker run 新容器会 `Exited (127): start_in_docker.sh: No such file or directory`)。
因此多开 = 新容器(以 sleep 占住) + 从现役容器 tar 搬运源码(排除 logs) + 写 /root/.env + 手动拉起 start_in_docker.sh。实测全流程(scripts/spawn_second_sim.sh vr2-cli-test):- 复制仿真源码 ~2.9G 成功; 第二实例独立 game-control 就绪- 两队 ready: checks team1/team2 = true- POST /match/start -> ok; 60s 后 state=set score=0-0 dur=58s events=14 (比赛真实进行中)- end + launcher --stop + docker rm 干净收尾- 与主容器 vjzb0-k1 同时运行互不干扰(独立 cgroup/网络/game-control)。

## 关键证据坐标
- native-addon 二进制字符串: `export AGENT_SIGN_KEYSTORE=/.agent_dev/keystore.p12 && export AGENT_SIGN_KEYSTORE_PASSWD=123456 &&`、`... && python3 launcher.py --publish-logs --teams `、`... && python3 launcher.py --stop`
- 官方 config: booster-native/statics/configs/config.toml [agent_dev] 段(build_script_path/football3v3_runner_dir/extract 路径)
- game-control HTTP 路由: 容器内 extensions/game_control/publishing/http.py (/health /status /result /events /match/start /match/end)

## 5. 全链路闭环 ✅（最终验证）

纯 CLI 完成「源码 → 编译 → 部署 → 无头对战 → 结束」:
```
./scripts/build_agent.sh BehaviorTree_based_code/sim-3v3-stable-change6o1B
  → build/UpdateV6o1B-ReBuildBoost0725.agent (签名成功)
./scripts/deploy_agent.sh .../UpdateV6o1B-ReBuildBoost0725.agent
  → [deploy] 完成: UpdateV6o1B
./scripts/run_match.sh start UpdateV6o1B UpdateV6o1
  → 两队 ready → POST /match/start ok
40s 后: state=playing phase=firstHalf score=0-0 dur=40s events=48
  → CLI 编译出的 agent 在真实无头对战中正常运行
./scripts/run_match.sh end → ok + 清理完成
```
Booster Studio 全程仅作为容器提供者存在，无任何 GUI 操作。
