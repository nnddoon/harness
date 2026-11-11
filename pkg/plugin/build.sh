#!/usr/bin/env bash
# 把 pkg/ 里的 harness 打包成一个 Claude Code 插件目录（不改源码，只生成到 <输出目录>）。
#   用法：bash pkg/plugin/build.sh <输出目录>      然后：claude plugin validate <输出目录>
#   本机试装：claude --plugin-dir <输出目录>
# 生成的结构：.claude-plugin/plugin.json、hooks/hooks.json + hooks/*.py、skills/、agents/、README.md
# 仓库里的 .claude/hooks/... 路径一律改成 ${CLAUDE_PLUGIN_ROOT}/hooks/...（Claude Code 在加载时替换）。
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?用法：build.sh <输出目录>}"
rm -rf "$OUT"
mkdir -p "$OUT/.claude-plugin" "$OUT/hooks" "$OUT/skills" "$OUT/agents"
python3 -B - "$PKG" "$OUT" <<'PY'
import json, re, shutil, sys
from pathlib import Path
pkg, out = Path(sys.argv[1]), Path(sys.argv[2])
version = (pkg / "plugin" / "VERSION").read_text(encoding="utf-8").strip()
REPO_HOOKS = re.compile(r"(?<![\w/])\.claude/hooks/")
PLUGIN_HOOKS = "${CLAUDE_PLUGIN_ROOT}/hooks/"

manifest = {
    "name": "harness",
    "version": version,
    "description": "Agentic loop harness: 对齐需求 → 执行 → 对抗审查 → 人工门 → 交接；任务卡、门卡与晨报都在仓库文件里。",
    "author": {"name": "harness"},
    "keywords": ["harness", "workflow", "human-in-the-loop", "worktree", "review"],
}
(out / ".claude-plugin" / "plugin.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

settings = json.loads((pkg / ".claude" / "settings.json").read_text(encoding="utf-8"))
def fix_cmd(cmd: str) -> str:
    # python3 .claude/hooks/x.py  ->  python3 "${CLAUDE_PLUGIN_ROOT}/hooks/x.py"
    # also: "$CLAUDE_PROJECT_DIR"/.claude/hooks/x.py  (the form settings.json uses)
    return re.sub(r'(?:"\$CLAUDE_PROJECT_DIR"/|\$CLAUDE_PROJECT_DIR/|\$\{CLAUDE_PROJECT_DIR\}/)?\.claude/hooks/([\w.-]+)',
                  r'"${CLAUDE_PLUGIN_ROOT}/hooks/\1"', cmd)
hooks = json.loads(json.dumps(settings["hooks"]))
for matchers in hooks.values():
    for m in matchers:
        for h in m.get("hooks", []):
            if "command" in h:
                h["command"] = fix_cmd(h["command"])
(out / "hooks" / "hooks.json").write_text(json.dumps({"hooks": hooks}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

for f in sorted((pkg / ".claude" / "hooks").iterdir()):
    if f.is_file() and f.suffix in (".py", ".sh"):
        shutil.copy2(f, out / "hooks" / f.name)
for sub in ("skills", "agents"):
    for f in sorted((pkg / ".claude" / sub).rglob("*")):
        if not f.is_file() or "__pycache__" in f.parts:
            continue
        dst = out / sub / f.relative_to(pkg / ".claude" / sub)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if f.suffix == ".md":
            dst.write_text(REPO_HOOKS.sub(PLUGIN_HOOKS, f.read_text(encoding="utf-8")), encoding="utf-8")
        else:
            shutil.copy2(f, dst)

(out / "README.md").write_text(f"""# harness（Claude Code 插件）v{version}

装上后，任何仓库都有这些护栏和工作流：路径与命令护栏、Stop 检查、改后快检、权限自动放行、GitHub 门卡收件箱；
skills：/task-align、/task-run、/task-close、/spec、/human-gate、/tower、/replan、/backlog-groom、/handoff；
子代理：verifier、critic、judge、tester、builder、impact-analyst、security-auditor、backlog-reviewer。

仓库里还需要 `.harness/`（任务卡、门卡、配置）和 `scripts/`：在仓库根目录跑一次 `harness init`。

注意：
- 插件不能带权限设置。「不读 .env / 密钥」的 deny 列表仍要写进项目的 `.claude/settings.json`（`harness init` 会写）。
- 装了插件就不要再把 hooks 装进仓库的 `.claude/hooks/`，否则每个 hook 会跑两次（例如门卡被发两次 Issue）。
- `scripts/*.sh` 目前仍从仓库里的 `.claude/hooks/harness_lib.py` 读状态；插件模式下的 init 是下一步（T-007）。

本机试装：`claude --plugin-dir <这个目录>`
""", encoding="utf-8")
print(f"✓ 插件 v{version} → {out}")
PY
