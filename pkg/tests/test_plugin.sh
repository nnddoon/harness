#!/usr/bin/env bash
# T-005 验收：把 harness 打包成 Claude Code 插件，清单通过校验，hooks 不依赖仓库里的 .claude/hooks/。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-plugin.XXXXXX")"; trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
OUT="$T/harness-plugin"

bash "$SRC/plugin/build.sh" "$OUT" > "$T/build.out" 2>&1
expect "build exits 0" 0 "$?"
expect "manifest in .claude-plugin/" yes "$([ -f "$OUT/.claude-plugin/plugin.json" ] && echo yes || echo no)"
expect "only plugin.json inside .claude-plugin/" 1 "$(ls -A "$OUT/.claude-plugin" | wc -l | tr -d ' ')"
expect "manifest name" harness "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$OUT/.claude-plugin/plugin.json")"
expect "manifest version = pkg/plugin/VERSION" "$(cat "$SRC/plugin/VERSION")" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$OUT/.claude-plugin/plugin.json")"
if command -v claude >/dev/null 2>&1; then
  claude plugin validate "$OUT" > "$T/validate.out" 2>&1; RC=$?
  expect "claude plugin validate passes" 0 "$RC"
  [ $RC -eq 0 ] || sed 's/^/    /' "$T/validate.out" | head -20
else
  echo "SKIP claude plugin validate（没有 claude 命令）"
fi
expect "same hook events as settings.json" yes "$(python3 - "$SRC/.claude/settings.json" "$OUT/hooks/hooks.json" <<'PY'
import json, sys
a = set(json.load(open(sys.argv[1]))["hooks"]); b = set(json.load(open(sys.argv[2]))["hooks"])
print("yes" if a == b else f"no {a ^ b}")
PY
)"
expect "every hook command uses CLAUDE_PLUGIN_ROOT" yes "$(python3 - "$OUT/hooks/hooks.json" <<'PY'
import json, sys
cmds = [h["command"] for ev in json.load(open(sys.argv[1]))["hooks"].values() for m in ev for h in m["hooks"]]
print("yes" if cmds and all("${CLAUDE_PLUGIN_ROOT}" in c for c in cmds) else "no")
PY
)"
expect "every script a hook calls is in the plugin" yes "$(python3 - "$OUT" <<'PY'
import json, re, sys, os
root = sys.argv[1]
cmds = [h["command"] for ev in json.load(open(os.path.join(root, "hooks/hooks.json")))["hooks"].values() for m in ev for h in m["hooks"]]
missing = [p for c in cmds for p in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([\w./-]+)", c) if not os.path.exists(os.path.join(root, p))]
print("yes" if not missing else "no " + ",".join(missing))
PY
)"
expect "no repo-relative hook paths left in hooks/skills/agents" "" "$(grep -rln '\.claude/hooks/' "$OUT/hooks/hooks.json" "$OUT/skills" "$OUT/agents" 2>/dev/null)"
expect "all skills packaged" "$(ls "$SRC/.claude/skills" | wc -l | tr -d ' ')" "$(ls "$OUT/skills" | wc -l | tr -d ' ')"
expect "all agents packaged" "$(ls "$SRC/.claude/agents" | wc -l | tr -d ' ')" "$(ls "$OUT/agents" | wc -l | tr -d ' ')"
expect "README for the plugin" yes "$([ -s "$OUT/README.md" ] && echo yes || echo no)"

# 装了插件、仓库里没有 .claude/hooks/ 的仓库：hooks 仍然生效
R="$T/repo"; mkdir -p "$R" && cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.harness" . && git add -A && git commit -qm init
expect "fixture has no repo hooks" no "$([ -e .claude/hooks ] && echo yes || echo no)"
gb() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$R" "$1" \
       | CLAUDE_PLUGIN_ROOT="$OUT" python3 "$OUT/hooks/guard_bash.py" | grep -q '"deny"' && echo deny || echo allow; }
pp() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"old_string":"a","new_string":"b"}}))' "$R" "$1" \
       | CLAUDE_PLUGIN_ROOT="$OUT" python3 "$OUT/hooks/protect_paths.py" | grep -q '"deny"' && echo deny || echo allow; }
expect "plugin guard blocks force push" deny "$(gb 'git push --force origin main')"
expect "plugin guard allows ordinary commands" allow "$(gb 'git status')"
expect "plugin path guard protects locked files" deny "$(pp "$R/.harness/verify.sh")"
expect "plugin path guard allows ordinary edits" allow "$(pp "$R/src/app.py")"

# 重跑得到同样的结果
bash "$SRC/plugin/build.sh" "$T/again" >/dev/null 2>&1
expect "rebuild is reproducible" "" "$( [ -d "$OUT" ] && [ -d "$T/again" ] && diff -r "$OUT" "$T/again" || echo missing-build)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
