# Booster Studio 隐藏 CLI 接口 — 逆向分析与验证报告

> 目标：绕过 Booster Studio 图形界面，直接用命令行完成 **Python → .agent 编译**、
> **容器内自定义双方对战**、**无头（headless）模式**、**多开**。
> 本文所有接口均已在 2026-08-16 于本机（Booster Studio 1.110.1 / agent-dev 0.6.26-alpha / virtual-robot 0.6.4-beta）**实际验证通过**。

## 0. TL;DR — 一图流

```
┌──────────────────────────┐      ┌───────────────────────────────┐
│ 宿主机（你的项目源码）      │      │ agent-dev 容器（编译机）         │
│  BehaviorTree_based_code/ ├──────► /workspace/src/<project_id>/  │
└──────────────────────────┘      │  /sdk/agent_bundler/build_pyagent
                                  └──────┬────────────────────────┘
                                         │ 产物: build/<id>-<ver>.agent
                                         ▼
┌────────────────────────────────────────────────────────────────┐
│ virtual-robot 容器（仿真机, 例: vjzb0-k1）                        │
│  /opt/booster/booster_agent_data/data/agents/extract/<agent_id>/│
│  /usr/local/booster_agent/football3v3_runner/launcher.py        │
│     python3 launcher.py --publish-logs --teams <A> <B>  ← 自定义对战
│     python3 launcher.py --stop                          ← 停止
│  game-control HTTP (容器内 127.0.0.1:38383):                    │
│     GET  /health   GET /status   GET /result   GET /events     │
│     POST /match/start          POST /match/end                 │
└────────────────────────────────────────────────────────────────┘
```

**无头模式不是一个单独的接口** —— 上面的流程本身就完全不依赖任何 GUI。
Booster Studio 的"运行"按钮只是额外打开了 3D 可视化窗口（websockets），
比赛逻辑（run.py + game-control HTTP）全部在容器内，纯 CLI 即可驱动。

## 1. Python 编译成 .agent 文件 ✅已验证

编译发生在 **agent-dev 容器**内（Booster Studio 点"编译"按钮时它帮你 exec 这条命令）：

```bash
# AGENT 容器名: docker ps 里 image 为 agent-dev/agent-dev 的那个
AGENT_DEV=agent-dev-cdbfc007d62b0633dcba94cf838f65ac

# 项目目录: 宿主机项目被挂载到容器 /workspace/src/<project_id>/
# (project_id 即容器名后缀; 也可直接把项目 cp 进容器任意路径)

docker exec $AGENT_DEV bash -c \
  'export AGENT_SIGN_KEYSTORE=/.agent_dev/keystore.p12 && \
   export AGENT_SIGN_KEYSTORE_PASSWD=123456 && \
   /sdk/agent_bundler/build_pyagent /workspace/src/<project_id>'
```

- **签名密钥**：容器内 `/.agent_dev/keystore.p12`，密码 `123456`（从 native-addon 二进制
  `export AGENT_SIGN_KEYSTORE=... && export AGENT_SIGN_KEYSTORE_PASSWD=123456 &&`
  字符串中逆向得到，这是官方硬编码的 dev 签名对）。
  也可以在项目 `build.toml` 里写 `[sign]` keystore_path/keystore_pass 自带密钥。
- **产物**：`<项目>/build/<agent_id>-<version>.agent`（zip 格式，已签名），落在挂载目录，
  宿主机直接可见。
- **输入**：项目根的 `agent.toml`（id/version/entry）+ `build.toml`（python 依赖/平台/混淆）。
- 首次构建 ~6s（增量缓存 `/tmp/booster_agent_build_cache/`）。

### 无 Booster Studio 从零起一个编译容器

```bash
docker run -d --name agent-dev-cli \
  -v $PWD/your_project:/workspace/src/your_project \
  booster-robotics-registry.cn-beijing.cr.aliyuncs.com/agent-dev/agent-dev:0.6.26-alpha \
  sh -c 'echo ok && exec sleep infinity'
# 注意：/.agent_dev/keystore.p12 是 Booster Studio activate 时注入的；
# 自建容器需自己生成 PKCS12 密钥 (keytool -genkeypair -storetype PKCS12) 并在 build.toml [sign] 指定，
# 或 docker cp 一个已有 keystore.p12 过去。
```

## 2. 容器内自定义对战（任意双方）✅已验证

对战双方由 `football3v3_runner`（Booster Studio 点"运行"时注入到仿真容器的官方脚本，
宿主机原件在 `/usr/share/booster-studio/resources/app/booster-native/statics/scripts/football3v3_runner/`）决定：

```bash
SIM=vjzb0-k1   # docker ps 里 image 为 virtual-robot/virtual-robot 的容器

# ① 先把两个 .agent 部署进容器（见 §2.1），然后：
docker exec -d $SIM bash -c \
  'cd /usr/local/booster_agent/football3v3_runner && \
   python3 launcher.py --publish-logs --teams <红方agent_id> <蓝方agent_id>'
# 前台跑用 run.py（可看日志流）: python3 run.py --publish-logs --teams A B
# 同一 agent 打同一 agent 需先克隆改 id（见 scripts/deploy_agent.sh --clone-identity）

# ② 等两队 ready（health.checks.team1/team2 == true）
docker exec $SIM bash -c 'curl -s http://127.0.0.1:38383/health'

# ③ 开赛
docker exec $SIM bash -c 'curl -s -X POST http://127.0.0.1:38383/match/start'
# ④ 查状态/比分/事件
docker exec $SIM bash -c 'curl -s http://127.0.0.1:38383/status'
# ⑤ 结束/停止
docker exec $SIM bash -c 'curl -s -X POST http://127.0.0.1:38383/match/end'
docker exec $SIM bash -c 'cd /usr/local/booster_agent/football3v3_runner && python3 launcher.py --stop'
```

### game-control HTTP API 全表（容器内端口 38383）

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/health` | 就绪检查：`{"ready":bool,"checks":{"team1":bool,"team2":bool}}` |
| GET | `/status` | 比赛全量状态：比分/时间/阶段/事件数/双方 stats |
| GET | `/result` | 最终结果 JSON |
| GET | `/events` | 事件流（SSE） |
| POST | `/match/start` | 开赛（自动裁判、自动推进状态机） |
| POST | `/match/end` | 终止当前比赛 |

源码位置（容器内）：`/usr/local/booster_robot/booster_robocup_sim/extensions/game_control/publishing/http.py`

### 2.1 部署 .agent 到仿真容器 ✅已验证

官方路径（native-addon deploy 的目标）：
```
/opt/booster/booster_agent_data/data/agents/extract/<agent_id>/
```

```bash
docker cp foo.agent $SIM:/tmp/foo.agent
docker exec $SIM python3 -c "import zipfile; zipfile.ZipFile('/tmp/foo.agent').extractall('/tmp/foo_x')"
docker exec $SIM bash -c 'mkdir -p /opt/booster/booster_agent_data/data/agents/extract/<id> &&
  cp -a /tmp/foo_x/. /opt/booster/booster_agent_data/data/agents/extract/<id>/ &&
  find /opt/booster/booster_agent_data/data/agents/extract/<id> -name "pyagent*" -o -name "*.so*" | xargs -r chmod +x'
```
（仓库 `scripts/deploy_agent.sh` 封装了全流程，含同 id 克隆改名。）

## 3. 无头模式 ✅已验证

**无头 = 不打开 Booster Studio 的 3D 窗口，其余步骤完全相同。**
本机已用纯 docker/curl 命令完成"部署→开赛→playing(71s,64 events)→结束→停止"全流程，
期间 Booster Studio 一直开着但没有参与。

注意事项（来自社区插件 booster-match-runner 的踩坑总结，本机亦验证）：
- 开着 GUI 时不要点"运行"按钮 —— 它会重置 game-control、打断无头比赛。
- 比赛只在容器内运行；关掉 Booster Studio 也不影响无头比赛。

## 4. 多开 ✅已验证（脚本见 scripts/spawn_second_sim.sh）

Booster Studio 一个虚拟机器人只管理一个容器，但 CLI 可以无限开：

```bash
docker run -d --name vr2 --privileged --shm-size=256m -P \
  -e MODEL_PATH=mjcf/football_match_pitch_6_K1.xml -e SIM_TRANSPORT=shm \
  booster-robotics-registry.cn-beijing.cr.aliyuncs.com/virtual-robot/virtual-robot:0.6.4-beta
```

要点（从 vjzb0-k1 容器配置逆向）：
- `--privileged` + `--shm-size=256m`（原容器 268435456 字节）必须；
- `MODEL_PATH=mjcf/football_match_pitch_6_K1.xml` = 6 机器人足球场（3v3 对战场），
  缺省则是单机器人场景；`SIM_TRANSPORT=shm`；
- 新容器没有 football3v3_runner / agent（它们是 Booster Studio 首次"运行"时注入的）——
  从现有容器 `docker cp` 过去即可（`scripts/spawn_second_sim.sh` 全自动）；
- 端口全部 `-P` 自动分配，互不冲突；每个实例有独立 game-control(38383)；
- 资源：每实例 ~1 个物理核（2 队 pyagent + 6 个 motion 进程）+ ~200MB 内存。

## 5. 关键逆向坐标（想深挖时看这里）

| 东西 | 位置 |
|---|---|
| native-addon（Rust，全部 host 逻辑） | `/usr/share/booster-studio/resources/app/booster-native/@booster-studio/native-addon.linux-x64-gnu.node` |
| native-addon 类型定义（agentDevBuild 等） | 同目录 `index.d.ts` |
| native-addon 配置（路径/端口/镜像名） | 同目录 `statics/configs/config.toml` |
| football3v3_runner 官方脚本原件 | 同目录 `statics/scripts/football3v3_runner/{run,launcher,supervisor,sandbox}.py` |
| 编译工具链（build_pyagent 等） | agent-dev 容器 `/sdk/agent_bundler/` |
| 仿真源码（game_control 等，可读！） | virtual-robot 容器 `/usr/local/booster_robot/booster_robocup_sim/` |
| 比赛产物（events.jsonl/result.json） | 同上 `logs/game-control/` |
| 社区对战插件（逆向参考） | `~/.booster-studio/extensions/samge.booster-match-runner-0.2.6`（github.com/Samge0/booster-match-runner） |

native-addon 里与对战相关的隐藏逻辑（strings 逆向）：
`deploy_football3v3_ai_agent_if_needed`（内置 AI agent 部署）、
`sync_football3v3_runner_if_needed`（runner 注入）、
`start_football3v3_runner_if_needed`（`cd <dir> && python3 launcher.py --publish-logs --teams <A> <B>`）、
`stop_football3v3_runner_if_needed`（`... && python3 launcher.py --stop`）。
UI 点"运行"时若当前 agent 是内置 AI 就只启动它一个队 —— 这就是"自打内置 AI"的来源；
`--teams A B` 传两个自定义 id 即为自定义对战。

## 6. 已知坑

1. **容器重建后 runner 会丢**（runner 是注入的，不在镜像里）——重新 docker cp 或点一次 GUI"运行"。
2. **同 agent 对打**必须整包改名（agent.json id + ros2.package_name + 目录布局），
   否则 ROS2 包名冲突第二队起不来（scripts/deploy_agent.sh 已处理）。
3. **残留进程**：异常中断后 `ros2 launch`/pyagent 可能残留占用 ROS2 名字，
   清理：`echo 1 > /sys/fs/cgroup/3v3_runner/team_{1,2}/cgroup.kill` + pkill。
4. **python zipfile 不保留执行位**：解压后必须 chmod +x pyagent*/*.so*。
5. 本机 agent-dev 容器是 Booster Studio 创建的；直接复用即可（见 scripts/build_agent.sh 自动发现）。
