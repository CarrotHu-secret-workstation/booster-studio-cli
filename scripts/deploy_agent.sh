#!/bin/bash
# deploy_agent.sh — 把 .agent 文件部署进 virtual-robot 仿真容器（官方 extract 路径）
# 用法: ./deploy_agent.sh <foo.agent> [sim容器名] [--id 自定义ID]
#   --id: 以自定义 ID 部署（同包双开/自打自用；自动整包改名避免 ROS2 包冲突）
set -euo pipefail

AGENT_FILE=$(realpath "${1:?用法: $0 <foo.agent> [sim容器名] [--id 自定义ID]}")
shift || true
SIM=""; NEW_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id) NEW_ID="$2"; shift 2 ;;
    *) SIM="$1"; shift ;;
  esac
done
SIM="${SIM:-$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Command}}' | awk -F'\t' '$2 ~ /virtual-robot\/virtual-robot/ && $3 ~ /ros_entrypoint/ {print $1; exit}')}"
[ -z "$SIM" ] && { echo "ERROR: 未找到 virtual-robot 容器"; exit 1; }
EXTRACT_ROOT=/opt/booster/booster_agent_data/data/agents/extract

# 1. 上传 + 解压（容器内无 unzip, 用 python zipfile）
docker cp "$AGENT_FILE" "$SIM:/tmp/cli_deploy.agent"
docker exec "$SIM" rm -rf /tmp/cli_deploy_x
docker exec "$SIM" mkdir -p /tmp/cli_deploy_x
docker exec "$SIM" python3 -c "import zipfile; zipfile.ZipFile('/tmp/cli_deploy.agent').extractall('/tmp/cli_deploy_x')"

# 2. 读 agent id
ORIG_ID=$(docker exec "$SIM" python3 -c "import json; print(json.load(open('/tmp/cli_deploy_x/agent.json'))['id'])")
AGENT_ID="${NEW_ID:-$ORIG_ID}"
echo "[deploy] $ORIG_ID -> $AGENT_ID @ $SIM"

# 3. 落位 + 恢复执行位（python zipfile 不保留 unix mode, pyagent/*.so 必须 +x）
docker exec "$SIM" bash -c "rm -rf $EXTRACT_ROOT/'$AGENT_ID' && mkdir -p $EXTRACT_ROOT/'$AGENT_ID' && cp -a /tmp/cli_deploy_x/. $EXTRACT_ROOT/'$AGENT_ID'/ && find $EXTRACT_ROOT/'$AGENT_ID' \\( -name 'pyagent*' -o -name '*.so*' \\) -exec chmod +x {} + 2>/dev/null; true"

# 4. 整包改名（同 agent 双开必须: agent.json id + ros2 包名 + 目录布局, 否则第二队起不来）
if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "$ORIG_ID" ]; then
  docker exec "$SIM" env D="$EXTRACT_ROOT/$AGENT_ID" ORIG_ID="$ORIG_ID" NEW_ID="$AGENT_ID" python3 - << 'PYEOF'
import json, os, shutil
from pathlib import Path

d = Path(os.environ['D'])
orig = os.environ['ORIG_ID']; new = os.environ['NEW_ID']
orig_pkg = ''.join(c if c.isalnum() and c.isascii() else '_' for c in orig.lower()).strip('_') or 'agent'
new_pkg = ''.join(c if c.isalnum() and c.isascii() else '_' for c in new.lower()).strip('_') or 'agent'

meta = d / 'agent.json'
obj = json.loads(meta.read_text())
obj['id'] = new
if isinstance(obj.get('ros2'), dict):
    obj['ros2']['package_name'] = new_pkg
meta.write_text(json.dumps(obj, indent=4))

ap = d / 'agent'
src = ap / orig_pkg; dst = ap / new_pkg
if src.is_dir() and src != dst:
    shutil.move(str(src), str(dst))
    for sub in ('lib', 'share'):
        s, t = dst / sub / orig_pkg, dst / sub / new_pkg
        if s.is_dir():
            shutil.move(str(s), str(t))
    for f in dst.rglob('package.xml'):
        f.write_text(f.read_text().replace(f'<name>{orig_pkg}</name>', f'<name>{new_pkg}</name>'))
    for f in dst.rglob('launch.py'):
        f.write_text(f.read_text().replace(f"package='{orig_pkg}'", f"package='{new_pkg}'"))
    ament = dst / 'share/ament_index/resource_index/packages'
    if (ament / orig_pkg).exists():
        shutil.move(str(ament / orig_pkg), str(ament / new_pkg))
    colcon = dst / 'share/colcon-core/packages'
    if colcon.is_dir():
        for f in colcon.glob(f'{orig_pkg}*'):
            shutil.move(str(f), str(f.with_name(new_pkg + f.name[len(orig_pkg):])))
    for sp in (dst / 'lib').glob('python*/site-packages'):
        if (sp / orig_pkg).is_dir():
            shutil.move(str(sp / orig_pkg), str(sp / new_pkg))
        for f in list(sp.glob(f'{orig_pkg}-*')):
            shutil.move(str(f), str(f.with_name(new_pkg + f.name[len(orig_pkg):])))
print(f'renamed {orig_pkg} -> {new_pkg}')
PYEOF
  echo "[deploy] 已整包改名为 $NEW_ID"
fi

docker exec "$SIM" rm -rf /tmp/cli_deploy.agent /tmp/cli_deploy_x
echo "[deploy] 完成: $AGENT_ID"
echo "[deploy] 容器内全部 agent:"
docker exec "$SIM" ls "$EXTRACT_ROOT" | tr '\n' ' '; echo
