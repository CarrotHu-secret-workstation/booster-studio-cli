# Booster Studio 隐藏 CLI 接口（逆向 + 实测验证）

绕过 [Booster Studio](https://studio.booster.tech/) 图形界面，纯命令行驱动 RoboCup 3v3 仿真足球的全部关键接口：
**Python → .agent 编译**、**自定义双方对战**、**无头（headless）模式**、**仿真容器多开**。

> 官方确认这些功能由 CLI 实现，但未对外暴露接口。本项目通过逆向 Booster Studio 的
> native-addon 二进制、容器内注入脚本与 game-control 服务，定位并**在本机完整实测**了全部链路。

## 验证环境

| 组件 | 版本 |
|---|---|
| Booster Studio | 1.110.1-1782836622 |
| agent-dev 镜像 | 0.6.26-alpha |
| virtual-robot 镜像 | 0.6.4-beta |

## 快速开始

```bash
# 1. 编译（签名密钥对已从 native-addon 逆向定位）
./scripts/build_agent.sh <你的agent项目目录>
# → <项目>/build/<agent_id>-<version>.agent

# 2. 部署进仿真容器
./scripts/deploy_agent.sh <产物.agent> [容器名] [--id 自定义ID]

# 3. 无头对战（自定义双方！）
./scripts/run_match.sh start <红方agent_id> <蓝方agent_id>
./scripts/run_match.sh watch      # 盯比分
./scripts/run_match.sh end        # 收场+清理

# 4. 多开第二个仿真容器
./scripts/spawn_second_sim.sh <新容器名>
```

## 文档

- [docs/README.md](docs/README.md) — 完整接口文档：编译/对战/无头/多开原理、game-control HTTP API 全表、逆向坐标、已知坑
- [docs/VERIFICATION-LOG.md](docs/VERIFICATION-LOG.md) — 每项验证的实际命令输出记录（含全链路闭环）

## 核心发现速览

1. **编译**：`docker exec <agent-dev> ... /sdk/agent_bundler/build_pyagent <项目>`，
   签名用容器内 `/.agent_dev/keystore.p12`（密码 `123456`，逆向自 native-addon 字符串）
2. **自定义对战**：`football3v3_runner/launcher.py --teams <A> <B>`（Studio 点“运行”时注入的官方脚本，
   UI 只传单个 agent 所以永远打内置 AI；CLI 传两个即任意组合）
3. **无头**：不是独立接口 —— 比赛逻辑全在容器内（`bs-ext-game-control` + HTTP 38383），不碰 GUI 即无头
4. **多开**：镜像里 `/usr/local/booster_robot` 是空的（源码由 Studio 首次运行注入），
   多开 = 新容器 + tar 搬运源码 + 写 `MODEL_PATH` env + 手动拉起

## 致谢

- [booster-match-runner](https://github.com/Samge0/booster-match-runner)（MIT，社区对战插件）的踩坑记录提供了交叉验证

## 免责声明

仅供学习研究。Booster Studio / Booster Robotics 为加速进化（Booster Robotics）的商标与产品。
