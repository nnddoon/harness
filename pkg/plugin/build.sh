#!/usr/bin/env bash
# 把 pkg/ 里的 harness 打包成一个 Claude Code 插件目录（不改源码，只生成到 <输出目录>）。
#   用法：bash pkg/plugin/build.sh <输出目录>      然后：claude plugin validate <输出目录>
#   本机试装：claude --plugin-dir <输出目录>
#   发布：bash pkg/plugin/build.sh plugins/harness 并提交（marketplace 指向它；pkg/tests/test_plugin_install.sh 会检查它是最新的）
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
# plugin skills are namespaced: /task-run -> /harness:task-run
SKILLS = sorted(p.name for p in (pkg / ".claude" / "skills").iterdir() if p.is_dir()) + ["setup"]
SLASH = re.compile(r"(?<![\w:./-])/(" + "|".join(map(re.escape, SKILLS)) + r")\b")


def for_plugin(text: str) -> str:
    return SLASH.sub(r"/harness:\1", REPO_HOOKS.sub(PLUGIN_HOOKS, text))


def for_repo(text: str) -> str:
    """Text installed into a plugin-mode repo: the lib lives in .harness/lib, commands are namespaced."""
    return SLASH.sub(r"/harness:\1", REPO_HOOKS.sub(".harness/lib/", text))

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
for sub, base in (("skills", pkg / ".claude" / "skills"), ("agents", pkg / ".claude" / "agents"),
                  ("skills", pkg / "plugin" / "skills")):
    for f in sorted(base.rglob("*")):
        if not f.is_file() or "__pycache__" in f.parts:
            continue
        dst = out / sub / f.relative_to(base)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if f.suffix == ".md":
            dst.write_text(for_plugin(f.read_text(encoding="utf-8")), encoding="utf-8")
        else:
            shutil.copy2(f, dst)

# what /harness:setup (harness init --plugin) installs into a repo, and the CLI that installs it
DEV_ONLY = {"test-harness.sh", "demo", "testdata"}  # harness's own test tools: not for user repos


def copy_tree(src: Path, dst: Path, text_fix=None):
    for f in sorted(src.rglob("*")):
        rel = f.relative_to(src)
        if not f.is_file() or set(rel.parts) & ({"__pycache__", "worktrees", "logs", "reports"} | DEV_ONLY) \
                or f.name == "STATUS.md":
            continue
        (dst / rel).parent.mkdir(parents=True, exist_ok=True)
        if text_fix and f.suffix == ".md":
            (dst / rel).write_text(text_fix(f.read_text(encoding="utf-8")), encoding="utf-8")
        else:
            shutil.copy2(f, dst / rel)
pay = out / "payload"
pay.mkdir(parents=True, exist_ok=True)
(pay / "CLAUDE.md").write_text(for_repo((pkg / "CLAUDE.md").read_text(encoding="utf-8")), encoding="utf-8")
shutil.copy2(pkg / ".gitattributes", pay / ".gitattributes")
copy_tree(pkg / ".harness", pay / ".harness", for_repo)
copy_tree(pkg / "scripts", pay / "scripts")
copy_tree(pkg / ".claude" / "rules", pay / ".claude" / "rules", for_repo)
shutil.copy2(pkg / ".claude" / "settings.json", pay / ".claude" / "settings.json")
copy_tree(pkg / "bin", out / "bin")
for f in sorted((pkg / "cli").glob("*.py")):
    (out / "cli").mkdir(exist_ok=True)
    shutil.copy2(f, out / "cli" / f.name)

(out / "README.md").write_text(for_plugin(f"""# harness（Claude Code 插件）v{version}

装上后，任何仓库都有这些护栏和工作流：路径与命令护栏、Stop 检查、改后快检、权限自动放行、GitHub 门卡收件箱；
skills：/task-align、/task-run、/task-close、/spec、/human-gate、/tower、/replan、/backlog-groom、/handoff；
子代理：verifier、critic、judge、tester、builder、impact-analyst、security-auditor、backlog-reviewer。

## 一行安装
```bash
claude plugin marketplace add nnddoon/harness && claude plugin install harness@harness
```
然后在任何仓库里打开 Claude Code，输入 `/harness:setup`：识别技术栈、生成验证配置，把 `.harness/`（任务卡、门卡、配置）和 `scripts/` 放进仓库。

注意：
- 插件不能带权限设置：`/harness:setup` 会把「不读 .env / 密钥」的 deny 列表合并进项目的 `.claude/settings.json`。
- 装了插件就不要再把 hooks 装进仓库的 `.claude/hooks/`，否则每个 hook 会跑两次；`/harness:setup` 发现时会提醒。
- `scripts/*.sh` 在插件模式下用 `.harness/lib/` 里的库副本；插件更新后重跑 `/harness:setup` 即可更新。

本机试装：`claude --plugin-dir <这个目录>`
"""), encoding="utf-8")
print(f"✓ 插件 v{version} → {out}")
PY
