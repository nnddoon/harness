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
expect "all skills packaged (repo skills + plugin-only skills)" "$(( $(ls "$SRC/.claude/skills" | wc -l) + $(ls "$SRC/plugin/skills" 2>/dev/null | wc -l) ))" "$(ls "$OUT/skills" | wc -l | tr -d ' ')"
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

# ================================================================ T-017（S-002#20）：新命令、新 hook 随插件发布；文档与新流程一致
yn() { if eval "$1"; then echo yes; else echo no; fi; }
for c in launch_cmd doctor_cmd inbox_cmd; do
  expect "T-017 plugin ships cli/$c.py" yes "$(yn '[ -f "$OUT/cli/$c.py" ]')"
done
for h in audit_log chat_answer; do
  expect "T-017 plugin ships hooks/$h.py" yes "$(yn '[ -f "$OUT/hooks/$h.py" ]')"
done
hk() {  # hk <事件> <matcher|-> <脚本>：hooks.json 里该事件、该 matcher（- = 无 matcher）下有调用该脚本的命令
  python3 - "$OUT/hooks/hooks.json" "$1" "$2" "$3" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
ev, want, script = sys.argv[2], sys.argv[3], sys.argv[4]
ok = any((m.get("matcher") or "-") == want and any(f"${{CLAUDE_PLUGIN_ROOT}}/hooks/{script}" in h.get("command", "") for h in m.get("hooks", []))
         for m in hooks.get(ev, []))
print("yes" if ok else "no")
PY
}
expect "T-017 hooks.json: PreToolUse * -> audit_log.py" yes "$(hk PreToolUse '*' audit_log.py)"
expect "T-017 hooks.json: PostToolUse * -> audit_log.py" yes "$(hk PostToolUse '*' audit_log.py)"
expect "T-017 hooks.json: UserPromptSubmit -> chat_answer.py" yes "$(hk UserPromptSubmit - chat_answer.py)"
expect "T-017 hooks.json: PostToolUse AskUserQuestion -> chat_answer.py" yes "$(hk PostToolUse AskUserQuestion chat_answer.py)"
HELP="$(python3 "$OUT/bin/harness" --help 2>&1)"
for c in launch doctor down inbox; do
  expect "T-017 harness --help lists $c" yes "$(yn 'printf "%s\n" "$HELP" | grep -qE "^[[:space:]]+$c([[:space:]]|$)"')"
done
expect "T-017 harness --help: down documents --prune-audit" yes "$(yn 'printf "%s\n" "$HELP" | grep -E "^[[:space:]]+down([[:space:]]|$)" | grep -q -- "--prune-audit"')"
expect "T-017 harness --help: inbox lists setup" yes "$(yn 'printf "%s\n" "$HELP" | grep -E "^[[:space:]]+inbox([[:space:]]|$)" | grep -q "setup"')"

# ---------------------------------------------------------------- 文档（grep）
RD="$SRC/README.md"; HG="$SRC/.claude/rules/human-gates.md"; GR="$SRC/.claude/rules/harness-guardrails.md"; SK="$SRC/.claude/skills/human-gate/SKILL.md"
for pat in 'strict' 'harness doctor' 'harness down' 'harness inbox setup' 'sandbox-runtime' 'srt'; do
  expect "T-017 README mentions '$pat'" yes "$(yn 'grep -qF -- "$pat" "$RD"')"
done
expect "T-017 README: terminal answer command (answer <GID>)" yes "$(yn 'grep -qE "answer (G-[A-Za-z0-9-]+|<[^>]+>) " "$RD"')"
expect "T-017 README: srt install command (npm … sandbox-runtime)" yes "$(yn 'grep -qE "npm (install|i) (-g|--global) [^ ]*sandbox-runtime" "$RD"')"
expect "T-017 README: standard-mode residual risk (standard … 只靠护栏 … 边界)" yes "$(yn 'grep -E "standard" "$RD" | grep -F "只靠护栏" | grep -qF "边界"')"
expect "T-017 README: harness down --prune-audit" yes "$(yn 'grep -qF -- "harness down --prune-audit" "$RD"')"
expect "T-017 README: Telegram inbox mentioned" yes "$(yn 'grep -qF "Telegram" "$RD"')"
expect "T-017 README no longer says Claude writes answers into cards/decisions.md" "" "$(python3 - "$RD" <<'PY'
import re, sys
bad = []
for line in open(sys.argv[1], encoding="utf-8"):
    for s in re.split(r"[。；]", line):
        if "Claude" in s and "不" not in s and ("记进 `decisions.md`" in s or "关闭门卡" in s
                                                or re.search(r"写[^，,]*(`answer:?`|answer:)", s)):
            bad.append(s.strip()[:60])
print(" | ".join(bad))
PY
)"
sec() {  # sec <文件> <节号>：从 "## <n>." 到下一个 "## " 之间的内容
  awk -v n="$2" 'index($0, "## " n ".") == 1 {on=1; print; next} on && /^## / {exit} on {print}' "$1"
}
HG3="$(sec "$HG" 3)"
expect "T-017 human-gates §3 is 答复处理" yes "$(yn 'printf "%s\n" "$HG3" | grep -qF "答复处理"')"
for ch in 终端 看板 GitHub 对话 Telegram; do
  expect "T-017 human-gates §3 lists channel $ch" yes "$(yn 'printf "%s\n" "$HG3" | grep -qF "$ch"')"
done
expect "T-017 human-gates §3: control plane records answers" yes "$(yn 'printf "%s\n" "$HG3" | grep -qF "控制面"')"
expect "T-017 human-gates §3: Claude never edits answer:" yes "$(yn 'printf "%s\n" "$HG3" | grep -E "Claude" | grep -E "不(写|改)|从不|永远不" | grep -qE "answer"')"
expect "T-017 SKILL: no unconditional 'PostToolUse hook 会自动把它开成 GitHub Issue'" no "$(yn 'grep -qF "PostToolUse hook 会自动把它开成" "$SK"')"
expect "T-017 SKILL: strict mode publishing is by the control plane" yes "$(yn 'grep -E "strict|无人值守" "$SK" | grep -E "控制面|调度器|gate-sync" | grep -qE "发布|Issue"')"
GR1="$(sec "$GR" 1)"
expect "T-017 guardrails §1: unlock refers to the answers store" yes "$(yn 'printf "%s\n" "$GR1" | grep -E "解锁|unlock" | grep -qF "答案库"')"
expect "T-017 guardrails §1: no longer 'status: approved' as the unlock condition" no "$(yn 'printf "%s\n" "$GR1" | grep -qF "status: approved"')"

# ---------------------------------------------------------------- gates.sh 以答案库为准（gate_state），不看卡上的 status:
G="$T/gates-repo"; mkdir -p "$G" && cd "$G" && git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" "$SRC/scripts" . && rm -f .harness/gates/G-*.md
card() {  # card <gid> <status> <标题>
  printf -- '---\nid: %s\ntask: T-201\nkind: ui\nstatus: %s\nrecommended: A\nanswer:\n---\n\n# %s %s\n\n## 选项\n- **A（推荐）**：甲\n- **B**：乙\n' \
    "$1" "$2" "$1" "$3" > ".harness/gates/$1.md"
}
card G-T201-1 approved "卡上写着已答但库里没有"
card G-T201-2 open "库里已答但卡上还是 open"
card G-T201-3 open "真的没答"
card G-T201-4 answered "库和卡都已答"
git add -A && git commit -qm gates
export XDG_STATE_HOME="$T/gstate"
rec() { python3 -B -c 'import sys; sys.path.insert(0, ".claude/hooks"); import harness_lib as H, pathlib; print(H.record_answer(pathlib.Path(".").resolve(), sys.argv[1], sys.argv[2]))' "$1" "$2"; }
expect "fixture: store answer recorded for G-T201-2" True "$(rec G-T201-2 B)"
expect "fixture: store answer recorded for G-T201-4" True "$(rec G-T201-4 B)"
python3 -B -c 'import sys; sys.path.insert(0, ".claude/hooks"); import harness_lib as H, pathlib; m=pathlib.Path(".").resolve(); print(H.gate_state(m,"G-T201-1"), H.gate_state(m,"G-T201-2"))' > "$T/gstate.out" 2>&1
expect "fixture: store says G-T201-1 open, G-T201-2 answered" "open answered" "$(cat "$T/gstate.out")"
GL="$(bash scripts/gates.sh 2>&1)"
expect "T-017 gates.sh: card says approved but store has no answer -> listed as open" yes "$(yn 'printf "%s\n" "$GL" | grep -q "^G-T201-1 "')"
expect "T-017 gates.sh: answered in store, card still open -> not listed as open (or flagged 答案不一致)" yes \
  "$(yn '! printf "%s\n" "$GL" | grep -q "^G-T201-2 " || printf "%s\n" "$GL" | grep "^G-T201-2 " | grep -qF "答案不一致"')"
expect "T-017 gates.sh: truly open gate listed" yes "$(yn 'printf "%s\n" "$GL" | grep -q "^G-T201-3 "')"
expect "T-017 gates.sh: answered in store and card -> not listed" no "$(yn 'printf "%s\n" "$GL" | grep -q "^G-T201-4 "')"
expect "T-017 gates.sh: footer points at the new answer channels (harness_lib.py answer / 看板 / Telegram)" yes \
  "$(yn 'printf "%s\n" "$GL" | grep -qF "answer" && printf "%s\n" "$GL" | grep -qF "Telegram"')"
unset XDG_STATE_HOME
cd "$T"

# ================================================================ T-022（S-003#10，F-1）：发出去的内容变了，版本号必须变
# pkg/plugin/RELEASED.json = {"version": 发布的版本, "files": {相对路径: sha256}}（构建输出里每个普通文件），由 build.sh --write-released 写。
# v2（第 2 轮，见任务卡 §9）：不写死 0.2.1；版本门 = 已提交的 plugins/harness 清单 == RELEASED.files 且 RELEASED.version == VERSION
#   ——发出去的任何改动都必须「升 VERSION + 重建 plugins/harness + --write-released」一起提交。
TOP="$(cd "$SRC/.." && pwd)"
REL="$SRC/plugin/RELEASED.json"
VER="$(tr -d '[:space:]' < "$SRC/plugin/VERSION")"
pv() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1" 2>/dev/null || echo none; }
vge() {  # vge <a> <b> -> yes 当 a >= b（按数字逐段比较）
  python3 -c 'import sys
n = lambda v: tuple(int(x) for x in v.strip().split("."))
try: print("yes" if n(sys.argv[1]) >= n(sys.argv[2]) else "no")
except ValueError: print("bad")' "$1" "$2"
}
expect "T-022 VERSION is semver x.y.z" yes "$(yn 'printf "%s" "$VER" | grep -qxE "[0-9]+\.[0-9]+\.[0-9]+"')"
expect "T-022 VERSION >= 0.2.1" yes "$(vge "$VER" 0.2.1)"
expect "T-022 built plugin.json version = VERSION" "$VER" "$(pv "$OUT/.claude-plugin/plugin.json")"
expect "T-022 published plugins/harness plugin.json version = VERSION" "$VER" "$(pv "$TOP/plugins/harness/.claude-plugin/plugin.json")"
expect "T-022 pkg/plugin/RELEASED.json exists" yes "$(yn '[ -f "$REL" ]')"
# relgate <插件目录> <VERSION> <RELEASED.json> -> ok | version-not-recorded | changed-without-release | bad-released
relgate() {
  python3 - "$1" "$2" "$3" <<'PY2'
import hashlib, json, os, sys
root, ver, rel = sys.argv[1], sys.argv[2].strip(), sys.argv[3]
try:
    r = json.load(open(rel, encoding="utf-8"))
    rv, rf = str(r["version"]).strip(), r["files"]
    assert isinstance(rf, dict) and rf
except Exception:
    print("bad-released"); sys.exit()
man = {}
for d, _dirs, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f)
        if os.path.isfile(p) and not os.path.islink(p):
            man[os.path.relpath(p, root).replace(os.sep, "/")] = hashlib.sha256(open(p, "rb").read()).hexdigest()
if rv != ver:
    print("version-not-recorded")
elif man != rf:
    print("changed-without-release")
else:
    print("ok")
PY2
}
mkrel() {  # mkrel <插件目录> <版本> <输出 json>：模拟 --write-released
  python3 - "$1" "$2" "$3" <<'PY2'
import hashlib, json, os, sys
root = sys.argv[1]
files = {os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/"): hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest()
         for d, _ds, fs in os.walk(root) for f in fs}
json.dump({"version": sys.argv[2], "files": files}, open(sys.argv[3], "w"))
PY2
}
expect "T-022 version gate v2: RELEASED.json version = VERSION" "$VER" "$(pv "$REL")"
expect "T-022 version gate v2: committed plugins/harness == RELEASED.json manifest, version recorded" ok "$(relgate "$TOP/plugins/harness" "$VER" "$REL")"
expect "T-022 version gate v2: fresh build == RELEASED.json manifest" ok "$(relgate "$OUT" "$VER" "$REL")"
# 门自身（夹具：「已发布」9.8.7 = 当前构建）
mkrel "$OUT" 9.8.7 "$T/rel-987.json"
cp -R "$OUT" "$T/tampered" && printf '\n# changed\n' >> "$T/tampered/hooks/harness_lib.py"
expect "T-022 gate self-test: nothing changed -> ok" ok "$(relgate "$OUT" 9.8.7 "$T/rel-987.json")"
expect "T-022 gate self-test: content changed, version same, not re-released -> FAIL" changed-without-release "$(relgate "$T/tampered" 9.8.7 "$T/rel-987.json")"
expect "T-022 gate self-test: content changed after bump, without --write-released -> FAIL" version-not-recorded "$(relgate "$T/tampered" 9.8.8 "$T/rel-987.json")"
expect "T-022 gate self-test: version bumped only (nothing re-released) -> FAIL" version-not-recorded "$(relgate "$OUT" 9.8.8 "$T/rel-987.json")"
mkrel "$T/tampered" 9.8.8 "$T/rel-988.json"
expect "T-022 gate self-test: bump + --write-released -> ok" ok "$(relgate "$T/tampered" 9.8.8 "$T/rel-988.json")"
printf '\n# changed again\n' >> "$T/tampered/hooks/harness_lib.py"
expect "T-022 gate self-test: content changed again after release, without bump -> FAIL" changed-without-release "$(relgate "$T/tampered" 9.8.8 "$T/rel-988.json")"
rm -f "$T/tampered/README.md"
expect "T-022 gate self-test: a file removed -> FAIL" changed-without-release "$(relgate "$T/tampered" 9.8.8 "$T/rel-988.json")"
# build.sh --write-released（在 pkg 的副本里跑，不改源码）
cp -R "$SRC" "$T/pkgcopy" && rm -f "$T/pkgcopy/plugin/RELEASED.json"
bash "$T/pkgcopy/plugin/build.sh" "$T/relout" --write-released > "$T/wr.out" 2>&1
expect "T-022 build.sh --write-released: exit 0" 0 "$?"
expect "T-022 build.sh --write-released: writes plugin/RELEASED.json matching the build and VERSION" ok \
  "$(relgate "$T/relout" "$(tr -d '[:space:]' < "$T/pkgcopy/plugin/VERSION")" "$T/pkgcopy/plugin/RELEASED.json")"
expect "T-022 README records the 0.2.1 changes" yes "$(yn 'grep -qF "0.2.1" "$SRC/README.md"')"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
