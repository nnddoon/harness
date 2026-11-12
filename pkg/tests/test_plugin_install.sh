#!/usr/bin/env bash
# T-007 验收：插件一行安装 + /harness:setup + init --plugin（仓库里不再需要 .claude/hooks、skills、agents）。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"; TOP="$(cd "$SRC/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-pinst.XXXXXX")"; trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
yn() { if eval "$1"; then echo yes; else echo no; fi; }
P="$T/plug"; bash "$SRC/plugin/build.sh" "$P" >/dev/null 2>&1
expect "build ok" yes "$(yn '[ -f "$P/.claude-plugin/plugin.json" ]')"

# ---------------------------------------------------------------- 插件里有什么
expect "setup skill packaged" yes "$(yn '[ -f "$P/skills/setup/SKILL.md" ]')"
expect "setup skill runs the plugin's own init" yes "$(yn 'grep -q "\${CLAUDE_PLUGIN_ROOT}/bin/harness\" init --plugin" "$P/skills/setup/SKILL.md"')"
expect "init CLI packaged" yes "$(yn '[ -x "$P/bin/harness" ] && [ -f "$P/cli/init_cmd.py" ]')"
expect "install payload packaged" yes "$(yn '[ -d "$P/payload/.harness" ] && [ -d "$P/payload/scripts" ] && [ -f "$P/payload/CLAUDE.md" ] && [ -d "$P/payload/.claude/rules" ]')"
expect "skill cross-references use the plugin namespace" yes "$(yn 'grep -rq "/harness:task-run" "$P/skills" && ! grep -rqE "(^|[^a-z:./-])/task-(run|align|close)\b" "$P/skills"')"

# ---------------------------------------------------------------- init --plugin
R="$T/repo"; mkdir -p "$R/tests" && cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
printf '[project]\nname = "d"\n[project.optional-dependencies]\ndev = ["pytest"]\n' > pyproject.toml
printf 'def test_ok():\n    assert True\n' > tests/test_ok.py
OUT="$(python3 "$P/bin/harness" init --plugin --dry-run --target "$R" 2>&1)"
expect "dry run writes nothing" no "$(yn '[ -e .harness ] || [ -e .claude ] || [ -e scripts ]')"
expect "dry run says it is plugin mode" yes "$(yn 'printf "%s" "$OUT" | grep -q "插件模式"')"
python3 "$P/bin/harness" init --plugin --yes --target "$R" > "$T/init.out" 2>&1
expect "init --plugin exits 0" 0 "$?"
expect "no repo hooks/skills/agents" no "$(yn '[ -e .claude/hooks ] || [ -e .claude/skills ] || [ -e .claude/agents ]')"
expect "library copied to .harness/lib" yes "$(yn '[ -f .harness/lib/harness_lib.py ] && [ -f .harness/lib/gate_github.py ] && [ -f .harness/lib/notify.sh ]')"
expect "verify.sh generated" yes "$(yn 'grep -q "pytest -q" .harness/verify.sh')"
expect "rules installed" yes "$(yn '[ -f .claude/rules/harness-guardrails.md ]')"
expect "settings: deny list, no hooks" yes "$(python3 -c 'import json; d=json.load(open(".claude/settings.json")); print("yes" if any(".env" in x for x in d["permissions"]["deny"]) and "hooks" not in d else "no")')"
expect ".harness/lib is frozen" yes "$(yn 'grep -q "^\.harness/lib/\*\*" .harness/locks.txt')"
expect "lib_cmd points at .harness/lib" "python3 .harness/lib/harness_lib.py" "$(cd "$R" && python3 -B -c 'import sys; sys.path.insert(0, ".harness/lib"); import harness_lib as H, pathlib; print(H.lib_cmd(pathlib.Path(".")))')"
git add -A && git commit -qm "chore: add harness" -q
expect "board works from the lib copy" 0 "$(python3 .harness/lib/harness_lib.py board >/dev/null 2>&1; echo $?)"
expect "scheduler dry run works without repo hooks" yes "$(yn 'bash scripts/harness-loop.sh --dry-run --no-groom > "$T/loop.out" 2>&1 && ! grep -q "No such file" "$T/loop.out"')"

# 插件的 hooks 守着插件模式的仓库
gb() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$R" "$1" | CLAUDE_PLUGIN_ROOT="$P" python3 "$P/hooks/guard_bash.py" | grep -q '"deny"' && echo deny || echo allow; }
pp() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"old_string":"a","new_string":"b"}}))' "$R" "$1" | CLAUDE_PLUGIN_ROOT="$P" python3 "$P/hooks/protect_paths.py" | grep -q '"deny"' && echo deny || echo allow; }
pa() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$R" "$1" | CLAUDE_PLUGIN_ROOT="$P" python3 "$P/hooks/permission_allow.py" | grep -q '"allow"' && echo allow || echo ask; }
expect "plugin guard: force push denied" deny "$(gb 'git push --force origin main')"
expect "plugin guard: Claude cannot grant trust via the lib copy" deny "$(gb 'python3 .harness/lib/harness_lib.py trust --apply ui')"
expect "plugin path guard: lib copy frozen" deny "$(pp "$R/.harness/lib/harness_lib.py")"
expect "plugin path guard: ordinary edit allowed" allow "$(pp "$R/src/x.py")"
expect "read-only lib command auto-allowed" allow "$(pa 'python3 .harness/lib/harness_lib.py board')"

# 已有设置：只合并；仓库里已有 harness hooks：提示重复
R2="$T/repo2"; mkdir -p "$R2/.claude/hooks" && cd "$R2" && git init -q -b main
printf '{"permissions": {"allow": ["Bash(ls)"], "deny": ["Read(./secret.txt)"]}}\n' > .claude/settings.json
: > .claude/hooks/harness_lib.py
OUT2="$(python3 "$P/bin/harness" init --plugin --yes --target "$R2" 2>&1)"
python3 "$P/bin/harness" init --plugin --yes --target "$R2" >/dev/null 2>&1
expect "existing allow kept" yes "$(python3 -c 'import json; d=json.load(open(".claude/settings.json")); print("yes" if "Bash(ls)" in d["permissions"]["allow"] else "no")')"
expect "existing deny kept, harness deny merged once" yes "$(python3 -c 'import json; d=json.load(open(".claude/settings.json"))["permissions"]["deny"]; print("yes" if "Read(./secret.txt)" in d and any(".env" in x for x in d) and len(d) == len(set(d)) else "no")')"
expect "warns about duplicate hooks" yes "$(yn 'printf "%s" "$OUT2" | grep -q "跑两次"')"

# ---------------------------------------------------------------- marketplace（本仓库根目录）
expect "marketplace manifest" yes "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d["plugins"][0]; print("yes" if d["name"]=="harness" and p["name"]=="harness" and p["source"]=="./plugins/harness" else "no")' "$TOP/.claude-plugin/marketplace.json" 2>/dev/null || echo no)"
expect "committed plugin is up to date with a fresh build" "" "$( [ -d "$TOP/plugins/harness" ] && diff -r "$P" "$TOP/plugins/harness" | head -5 || echo missing)"
if command -v claude >/dev/null 2>&1; then
  expect "claude plugin validate: marketplace" 0 "$(claude plugin validate "$TOP" >/dev/null 2>&1; echo $?)"
  H="$T/home"; mkdir -p "$H"
  HOME="$H" claude plugin marketplace add "$TOP" > "$T/mk.out" 2>&1; RC1=$?
  HOME="$H" claude plugin install harness@harness > "$T/in.out" 2>&1; RC2=$?
  expect "one-line install from the marketplace" "0 0" "$RC1 $RC2"
  [ "$RC1 $RC2" = "0 0" ] || { sed 's/^/    /' "$T/mk.out" "$T/in.out" | head -12; }
  expect "installed plugin listed" yes "$(yn 'HOME="$H" claude plugin list 2>/dev/null | grep -q "harness"')"
else
  echo "SKIP claude CLI 不在，跳过真实安装"
fi

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
