#!/usr/bin/env bash
# T-015 验收：对话内选项卡（S-002 #13）。按任务卡「接口约定」与「接口约定 v2」。
# chat_answer.py：UserPromptSubmit（消息恰好是「G-x-n: L [备注]」）与 PostToolUse(AskUserQuestion) 经 record_answer 写库，via 对话。
# 无人值守 / strict / 非交互 / 嵌套时不生效；快照与门卡不符、选项卡与快照不符、有后续效果的 A、预填答案 → 不记录；
# 每个结果都有 systemMessage 给人看；结构不认识时不写、不报错。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-chat.XXXXXX")"; T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
unset HARNESS_UNATTENDED HARNESS_STRICT HARNESS_MODE HARNESS_GH_TOKEN HARNESS_SERVE_TOKEN HARNESS_NESTED
export CLAUDE_CODE_ENTRYPOINT=cli   # 交互会话（测试本身可能跑在 claude -p / SDK 里）
export CLAUDECODE=1                 # Claude Code 总会给 hook 设上它：不能当作「嵌套」
export XDG_STATE_HOME="$T/state" HARNESS_GATE_PUSH_ASSETS=0
mkdir -p "$T/state" "$T/bin"
printf '#!/usr/bin/env bash\n"$@"\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"   # 假 claude：只把参数当子进程跑（不 exec）

# ---------------------------------------------------------------- fixture repo
R="$T/repo"; mkdir -p "$R" && cd "$R" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" . && rm -f .harness/gates/G-*.md
rm -rf .claude/worktrees .harness/logs
printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
git add -A && git commit -qm fixture
HK="$R/.claude/hooks"
AD="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.answers_dir(Path(sys.argv[2])))' "$HK" "$R" 2>/dev/null)"
[ -n "$AD" ] || AD="$T/no-answers-dir"

gate() {  # gate <id> [kind] [额外 frontmatter 行...]  —— status: open，选项 A/B，标题「选哪个？」
  local id="$1" kind="${2:-ui}"; shift; [ $# -gt 0 ] && shift
  { printf -- '---\nid: %s\ntask: T-201\nkind: %s\nstatus: open\nurgency: normal\nrecommended: A\ndecided_by: human\nreview_minutes: 3\nanswer:\n' "$id" "$kind"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n\n# %s 选哪个？\n\n## 选项\n- **A（推荐）**：甲方案\n- **B**：乙方案\n' "$id"
  } > "$R/.harness/gates/$id.md"
}
st() {  # st <gid> <field> -> 值 | none | ERR
  python3 -B - "$HK" "$R" "$1" "$2" <<'PY' 2>/dev/null || echo ERR
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import harness_lib as H
a = H.read_answer(Path(sys.argv[2]), sys.argv[3])
print("none" if a is None else a.get(sys.argv[4], ""))
PY
}
RP() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.record_pr(Path(sys.argv[2]), sys.argv[3], int(sys.argv[4])))' "$HK" "$R" "$1" "$2" 2>/dev/null || echo ERR; }
has() { [ -e "$AD/$1" ] && echo yes || echo no; }
lib() { (cd "$R" && python3 -B .claude/hooks/harness_lib.py "$@" 2>&1); }
librc() { (cd "$R" && python3 -B .claude/hooks/harness_lib.py "$@" >/dev/null 2>&1); echo $?; }

hook() {  # hook <stdin-json>：以孤儿进程运行 chat_answer.py（父进程链上没有真实 claude）；$WRAP 可在前面套假 claude
  printf '%s' "$1" > "$T/in"; rm -f "$T/rc"
  ( OUTER=$BASHPID
    ( while kill -0 "$OUTER" 2>/dev/null; do sleep 0.01; done   # 等外层退出、本进程被收养
      cd "$R" && ${WRAP:-} python3 -B "$HK/chat_answer.py" < "$T/in" > "$T/out" 2> "$T/err"; echo $? > "$T/rc.tmp"; mv "$T/rc.tmp" "$T/rc" ) & )
  for _ in $(seq 1 600); do [ -f "$T/rc" ] && break; sleep 0.02; done
}
rc() { cat "$T/rc" 2>/dev/null || echo none; }
tb() { grep -c 'Traceback' "$T/err"; }
jget() {  # jget <expr>：从 stdout JSON 取值（不是 JSON / 没有 -> 空）
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]) or "")
except Exception:
    pass' "$T/out" "$1"
}
ctx() { jget 'd["hookSpecificOutput"]["additionalContext"]'; }
sysm() { jget 'd["systemMessage"]'; }
evname() { jget 'd["hookSpecificOutput"]["hookEventName"]'; }
recorded() { ctx | grep -c "已记录 $1"; }        # recorded "G-x: A" -> 1/0
srecorded() { sysm | grep -c "已记录 $1"; }
smsg() { local s; s="$(sysm)"; for w in "$@"; do case "$s" in *"$w"*) ;; *) echo no; return;; esac; done; echo yes; }  # smsg <词>... -> yes/no
upj() {  # upj <prompt> [extra-json-fields]
  python3 -c 'import json,sys; d={"session_id":"s1","transcript_path":"/dev/null","cwd":sys.argv[1],"permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":sys.argv[2]}; d.update(json.loads(sys.argv[3])); print(json.dumps(d, ensure_ascii=False))' "$R" "$1" "${2:-{\}}"
}
ups() { hook "$(upj "$@")"; }
aq() {  # aq <tool_input-json> <tool_response-json> [tool_name]：PostToolUse 负载
  python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","transcript_path":"/dev/null","cwd":sys.argv[1],"permission_mode":"default","hook_event_name":"PostToolUse","tool_name":sys.argv[4],"tool_input":json.loads(sys.argv[2]),"tool_response":json.loads(sys.argv[3])}, ensure_ascii=False))' "$R" "$1" "$2" "${3:-AskUserQuestion}"
}
post() { hook "$(aq "$@")"; }
OPTS='[{"label":"A 甲方案","description":"推荐"},{"label":"B 乙方案","description":"另一个"}]'
q1() {  # q1 <question> [header|__none__] [options-json] -> tool_input 单题
  python3 -c 'import json,sys
q = {"question": sys.argv[1], "options": json.loads(sys.argv[3]), "multiSelect": False}
if sys.argv[2] != "__none__": q["header"] = sys.argv[2]
print(json.dumps({"questions": [q]}, ensure_ascii=False))' "$1" "${2-__none__}" "${3:-$OPTS}"
}
ans() { python3 -c 'import json,sys; print(json.dumps({"answers":{sys.argv[1]:sys.argv[2]}}, ensure_ascii=False))' "$1" "$2"; }
pick() {  # pick <gid> <label> [header|__none__] [options-json]：规范的门卡选项卡（question = "<gid>：选哪个？"）
  local q="$1：选哪个？"; post "$(q1 "$q" "${3-$1}" "${4:-$OPTS}")" "$(ans "$q" "$2")"
}

# ---------------------------------------------------------------- 0. 注册与打包
expect "hook file exists" yes "$([ -f "$SRC/.claude/hooks/chat_answer.py" ] && echo yes || echo no)"
expect "settings: UserPromptSubmit runs chat_answer.py" yes "$(python3 - "$SRC/.claude/settings.json" <<'PY' 2>/dev/null || echo ERR
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
print("yes" if any("chat_answer.py" in x.get("command", "") for m in h.get("UserPromptSubmit", []) for x in m.get("hooks", [])) else "no")
PY
)"
expect "settings: PostToolUse matcher AskUserQuestion runs chat_answer.py" yes "$(python3 - "$SRC/.claude/settings.json" <<'PY' 2>/dev/null || echo ERR
import json, re, sys
h = json.load(open(sys.argv[1]))["hooks"]
ok = any(re.fullmatch(m.get("matcher", ""), "AskUserQuestion") and any("chat_answer.py" in x.get("command", "") for x in m.get("hooks", []))
         for m in h.get("PostToolUse", []) if m.get("matcher"))
print("yes" if ok else "no")
PY
)"
P="$T/plugin"; bash "$SRC/plugin/build.sh" "$P" > "$T/build.out" 2>&1
expect "plugin: hooks/chat_answer.py shipped" yes "$([ -f "$P/hooks/chat_answer.py" ] && echo yes || echo no)"
expect "plugin: hooks.json UserPromptSubmit + PostToolUse(AskUserQuestion) reference chat_answer.py" 2 "$(python3 - "$P/hooks/hooks.json" <<'PY' 2>/dev/null || echo ERR
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
n = sum(1 for ev in ("UserPromptSubmit", "PostToolUse") for m in h.get(ev, []) for x in m.get("hooks", [])
        if "chat_answer.py" in x.get("command", "") and "CLAUDE_PLUGIN_ROOT" in x.get("command", ""))
print(n)
PY
)"
SK="$SRC/.claude/skills/human-gate/SKILL.md"
expect "skill: tells Claude to use AskUserQuestion" yes "$(grep -q 'AskUserQuestion' "$SK" && echo yes || echo no)"
expect "skill: AskUserQuestion with the gate id first and lettered labels" yes "$(grep 'AskUserQuestion' "$SK" | grep -q 'G-T' && grep -qE 'label.*(字母|A )|(字母|A ).*label' "$SK" && echo yes || echo no)"
expect "skill: no longer tells the human that a chat reply must be re-given elsewhere" 0 "$(grep -c '请他用上面任一方式答复' "$SK")"

# ---------------------------------------------------------------- 1. UserPromptSubmit：恰好是 G-x-n: L（A1）
gate G-T201-1; ups "G-T201-1: B"
expect "prompt exact: exit 0" 0 "$(rc)"
expect "prompt exact: stored B" B "$(st G-T201-1 letter)"
expect "prompt exact: via 对话" 对话 "$(st G-T201-1 via)"
expect "prompt exact: additionalContext 已记录 G-T201-1: B" 1 "$(recorded 'G-T201-1: B')"
expect "v2 prompt exact: systemMessage 已记录 G-T201-1: B" 1 "$(srecorded 'G-T201-1: B')"
expect "prompt exact: hookEventName UserPromptSubmit" UserPromptSubmit "$(evname)"
gate G-T201-2; ups "G-T201-2: A 可以，先做这个"
expect "prompt with note (A on an effect-free ui gate): stored A" A "$(st G-T201-2 letter)"
expect "prompt with note: note kept" "可以，先做这个" "$(st G-T201-2 note)"
expect "prompt with note: via 对话" 对话 "$(st G-T201-2 via)"
gate G-T201-3; ups "$(printf '  G-T201-3:B  \n')"
expect "prompt with surrounding whitespace / no space after colon: stored" B "$(st G-T201-3 letter)"

gate G-T201-4; gate G-T201-5
ups "好的 G-T201-4: A"
expect "prompt with text before: not recorded" none "$(st G-T201-4 letter)"
expect "... exit 0" 0 "$(rc)"
expect "... no 已记录" 0 "$(ctx | grep -c '已记录')"
ups "我觉得 G-T201-4: A 比较好"
expect "embedded in a sentence: not recorded" none "$(st G-T201-4 letter)"
ups "$(printf '继续任务\nG-T201-4: A')"
expect "on a later line: not recorded" none "$(st G-T201-4 letter)"
ups "$(printf 'G-T201-4: A\nG-T201-5: A')"
expect "second gate on a second line: not recorded" none "$(st G-T201-5 letter)"
ups "G-T201-5: a"
expect "lowercase letter: not recorded" none "$(st G-T201-5 letter)"
ups "G-T201-5: Z"
expect "letter not among the options: not recorded" none "$(st G-T201-5 letter)"
expect "... exit 0" 0 "$(rc)"
ups "G-T299-1: A"
expect "unknown gate: exit 0" 0 "$(rc)"
expect "unknown gate: nothing stored" none "$(st G-T299-1 letter)"
ups "G-../../evil: A"
expect "path-like gate id: exit 0 and nothing written" "0 0" "$(rc) $(find "$T" -name 'evil*' 2>/dev/null | wc -l | tr -d ' ')"
ups "继续做 T-201"
expect "ordinary prompt: exit 0, no output" "0 " "$(rc) $(cat "$T/out")"

# 第二次答复不覆盖
ups "G-T201-1: A"
expect "second chat answer: first kept" "B 对话" "$(st G-T201-1 letter) $(st G-T201-1 via)"
expect "second chat answer: no 已记录" 0 "$(recorded 'G-T201-1: A')"
expect "second chat answer: exit 0" 0 "$(rc)"
expect "v2 second chat answer: systemMessage names the gate, no 已记录" "yes 0" "$(smsg G-T201-1) $(srecorded 'G-T201-1: A')"
gate G-T201-6; lib answer G-T201-6 B >/dev/null
ups "G-T201-6: A"
expect "terminal then chat: terminal answer kept" "B 终端" "$(st G-T201-6 letter) $(st G-T201-6 via)"

# ---------------------------------------------------------------- 2. 不生效（A2）
gate G-T202-1
HARNESS_UNATTENDED=1 ups "G-T202-1: A"
expect "UNATTENDED prompt: exit 0" 0 "$(rc)"
expect "UNATTENDED prompt: nothing stored" none "$(st G-T202-1 letter)"
expect "UNATTENDED prompt: no snapshot written either" no "$(has G-T202-1.meta.json)"
expect "UNATTENDED prompt: no output" "" "$(cat "$T/out")"
HARNESS_STRICT=1 ups "G-T202-1: A"
expect "STRICT prompt: nothing stored" none "$(st G-T202-1 letter)"
expect "STRICT prompt: no snapshot written" no "$(has G-T202-1.meta.json)"
CLAUDE_CODE_ENTRYPOINT=sdk-cli ups "G-T202-1: A"
expect "non-interactive (claude -p / SDK entrypoint) prompt: nothing stored" none "$(st G-T202-1 letter)"
ups "G-T202-1: A" '{"interactive": false}'
expect "hook input interactive:false prompt: nothing stored" none "$(st G-T202-1 letter)"
expect "... exit 0" 0 "$(rc)"
HARNESS_UNATTENDED=1 pick G-T202-1 'A 甲方案'
expect "UNATTENDED AskUserQuestion: exit 0" 0 "$(rc)"
expect "UNATTENDED AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
expect "UNATTENDED AskUserQuestion: no snapshot written" no "$(has G-T202-1.meta.json)"
HARNESS_STRICT=1 pick G-T202-1 'A 甲方案'
expect "STRICT AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
CLAUDE_CODE_ENTRYPOINT=sdk-py pick G-T202-1 'A 甲方案'
expect "non-interactive AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
# v2 (5) 嵌套
HARNESS_NESTED=1 ups "G-T202-1: A"
expect "v2 HARNESS_NESTED=1 prompt: nothing stored, no snapshot" "none no" "$(st G-T202-1 letter) $(has G-T202-1.meta.json)"
HARNESS_NESTED=1 pick G-T202-1 'A 甲方案'
expect "v2 HARNESS_NESTED=1 AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
WRAP="$T/bin/claude $T/bin/claude" ups "G-T202-1: A"
expect "v2 nested (two claude processes above the hook) prompt: exit 0" 0 "$(rc)"
expect "v2 nested prompt: nothing stored, no snapshot" "none no" "$(st G-T202-1 letter) $(has G-T202-1.meta.json)"
WRAP="$T/bin/claude $T/bin/claude" pick G-T202-1 'A 甲方案'
expect "v2 nested AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
WRAP="$T/bin/claude" ups "G-T202-1: A"
expect "v2 control: one claude above the hook (CLAUDECODE=1 set) records" A "$(st G-T202-1 letter)"

# ---------------------------------------------------------------- 3. 快照与门卡不符
gate G-T203-1; lib show G-T203-1 >/dev/null
sed -i.bak 's/^- \*\*B\*\*：乙方案/- **B**：删库跑路/' .harness/gates/G-T203-1.md && rm -f .harness/gates/G-T203-1.md.bak
ups "G-T203-1: B"
expect "snapshot mismatch prompt: exit 0" 0 "$(rc)"
expect "snapshot mismatch prompt: not recorded" none "$(st G-T203-1 letter)"
expect "snapshot mismatch prompt: notice names the gate" yes "$(ctx | grep -q 'G-T203-1' && echo yes || echo no)"
expect "snapshot mismatch prompt: notice points to terminal answer --yes" yes "$(ctx | grep -q 'answer' && ctx | grep -q -- '--yes' && echo yes || echo no)"
expect "snapshot mismatch prompt: no 已记录" 0 "$(ctx | grep -c '已记录')"
expect "v2 snapshot mismatch prompt: systemMessage with gate, answer, --yes" yes "$(smsg G-T203-1 answer --yes)"
gate G-T203-2; lib show G-T203-2 >/dev/null
sed -i.bak 's/^kind: ui/kind: sensory/' .harness/gates/G-T203-2.md && rm -f .harness/gates/G-T203-2.md.bak
pick G-T203-2 'B 乙方案'
expect "snapshot mismatch AskUserQuestion (kind changed): not recorded" none "$(st G-T203-2 letter)"
expect "snapshot mismatch AskUserQuestion: notice with --yes" yes "$(ctx | grep -q 'G-T203-2' && ctx | grep -q -- '--yes' && echo yes || echo no)"
expect "v2 snapshot mismatch AskUserQuestion: systemMessage with --yes" yes "$(smsg G-T203-2 --yes)"
gate G-T203-3; lib show G-T203-3 >/dev/null
printf '\n## 补充\n多写了一段说明。\n' >> .harness/gates/G-T203-3.md
ups "G-T203-3: B"
expect "card edited outside its meaning: still recorded" B "$(st G-T203-3 letter)"

# ---------------------------------------------------------------- 4. AskUserQuestion（A3）
gate G-T204-1; pick G-T204-1 'B 乙方案'
expect "AUQ canonical (header = gate id): exit 0" 0 "$(rc)"
expect "AUQ canonical: stored B" B "$(st G-T204-1 letter)"
expect "AUQ: via 对话" 对话 "$(st G-T204-1 via)"
expect "AUQ: additionalContext 已记录 G-T204-1: B" 1 "$(recorded 'G-T204-1: B')"
expect "v2 AUQ: systemMessage 已记录 G-T204-1: B" 1 "$(srecorded 'G-T204-1: B')"
expect "AUQ: hookEventName PostToolUse" PostToolUse "$(evname)"
gate G-T204-2; pick G-T204-2 'A 甲方案' ''
expect "AUQ empty header + 'G-…：' question: stored A" A "$(st G-T204-2 letter)"
gate G-T204-3; post "$(q1 'G-T204-3: 选哪个？')" "$(ans 'G-T204-3: 选哪个？' 'B 乙方案')"
expect "AUQ no header + 'G-…:' question: stored B" B "$(st G-T204-3 letter)"
gate G-T204-4; gate G-T204-5
TI="$(python3 -c 'import json,sys; o=json.loads(sys.argv[1]); print(json.dumps({"questions":[{"question":"G-T204-4：选哪个？","header":"G-T204-4","options":o,"multiSelect":False},{"question":"G-T204-5：选哪个？","header":"G-T204-5","options":o,"multiSelect":False}]}, ensure_ascii=False))' "$OPTS")"
post "$TI" '{"answers":{"G-T204-4：选哪个？":"A 甲方案","G-T204-5：选哪个？":"B 乙方案"}}'
expect "AUQ two gate questions: both recorded" "A B" "$(st G-T204-4 letter) $(st G-T204-5 letter)"
expect "AUQ two gate questions: two 已记录 lines" 2 "$(ctx | grep -c '已记录 G-T204-[45]: [AB]')"
gate G-T204-6; post "$(q1 '关于 G-T204-6：选哪个？' '')" "$(ans '关于 G-T204-6：选哪个？' 'A 甲方案')"
expect "AUQ gate id not at the start: ignored" none "$(st G-T204-6 letter)"
expect "... exit 0" 0 "$(rc)"
post "$(q1 '你喜欢哪个？' '偏好')" "$(ans '你喜欢哪个？' 'A 甲方案')"
expect "AUQ without any gate id: exit 0, no output" "0 " "$(rc) $(cat "$T/out")"
gate G-T204-8; pick G-T204-8 'A 我自己写的答案'
expect "AUQ free-text answer not among the options: not recorded" none "$(st G-T204-8 letter)"
pick G-T204-8 '甲方案' G-T204-8 '[{"label":"甲方案","description":""},{"label":"乙方案","description":""}]'
expect "AUQ label without a letter: not recorded" none "$(st G-T204-8 letter)"
pick G-T204-8 'C 丙方案' G-T204-8 '[{"label":"A 甲方案","description":""},{"label":"C 丙方案","description":""}]'
expect "AUQ letter not in the snapshot's options: not recorded" none "$(st G-T204-8 letter)"
post "$(q1 'G-T204-8：选哪个？' G-T204-8)" '{"answers":{"G-T204-8：选哪个？":["A 甲方案","B 乙方案"]}}'
expect "AUQ multi-select (list value): not recorded" none "$(st G-T204-8 letter)"
expect "... exit 0" 0 "$(rc)"
post "$(q1 'G-T204-8：选哪个？' G-T204-8)" "$(ans 'G-T204-8：选哪个？' 'A 甲方案')" Write
expect "same payload from another tool: ignored" none "$(st G-T204-8 letter)"
# 第二次不覆盖
pick G-T204-1 'A 甲方案'
expect "AUQ second answer: first kept" "B 对话" "$(st G-T204-1 letter) $(st G-T204-1 via)"
expect "AUQ second answer: no 已记录" 0 "$(recorded 'G-T204-1: A')"
expect "v2 AUQ second answer: systemMessage names the gate" yes "$(smsg G-T204-1)"
ups "G-T204-2: B"
expect "AUQ then prompt: AUQ answer kept" A "$(st G-T204-2 letter)"

# ---------------------------------------------------------------- 5. v2 (1) 选项卡严格对照快照
gate G-T206-1; post "$(q1 '你喜欢哪个？' G-T206-1)" "$(ans '你喜欢哪个？' 'B 乙方案')"
expect "v2 strict: header-only gate id on an unrelated question: not recorded" none "$(st G-T206-1 letter)"
expect "... exit 0" 0 "$(rc)"
gate G-T206-2; gate G-T206-3
post "$(q1 'G-T206-3：选哪个？' G-T206-2)" "$(ans 'G-T206-3：选哪个？' 'B 乙方案')"
expect "v2 strict: header id ≠ question id: neither gate recorded" "none none" "$(st G-T206-2 letter) $(st G-T206-3 letter)"
expect "v2 strict: header id ≠ question id: systemMessage names the question's gate" yes "$(smsg G-T206-3)"
pick G-T206-2 'B 乙方案' 门卡
expect "v2 strict: header neither empty nor the gate id: not recorded" none "$(st G-T206-2 letter)"
post "$(q1 'G-T206-2：要不要上线？' G-T206-2)" "$(ans 'G-T206-2：要不要上线？' 'B 乙方案')"
expect "v2 strict: question text ≠ snapshot title: not recorded" none "$(st G-T206-2 letter)"
expect "v2 strict: question mismatch: systemMessage names the gate" yes "$(smsg G-T206-2)"
pick G-T206-2 'A 不，先放着' G-T206-2 '[{"label":"A 不，先放着","description":""},{"label":"B 乙方案","description":""}]'
expect "v2 strict: label 'A 不，先放着' ≠ snapshot option text: not recorded" none "$(st G-T206-2 letter)"
expect "v2 strict: label mismatch: systemMessage names the gate" yes "$(smsg G-T206-2)"
pick G-T206-2 'B 乙方案' G-T206-2 '[{"label":"A 不，先放着","description":""},{"label":"B 乙方案","description":""}]'
expect "v2 strict: any option mismatching the snapshot spoils the question (even if B is picked)" none "$(st G-T206-2 letter)"
pick G-T206-2 'B：乙方案' G-T206-2 '[{"label":"A：甲方案","description":""},{"label":"B：乙方案","description":""}]'
expect "v2 strict: label 'B：乙方案' (not '<L> <text>'): not recorded" none "$(st G-T206-2 letter)"
pick G-T206-2 'B 乙方案' G-T206-2 '[{"label":"A 甲方案（推荐）","description":""},{"label":"B 乙方案","description":""}]'
expect "v2 strict: label with an extra '（推荐）': not recorded" none "$(st G-T206-2 letter)"
pick G-T206-2 'B 乙方案' G-T206-2 '[{"label":"B 甲方案","description":""},{"label":"B 乙方案","description":""}]'
expect "v2 strict: wrong letter for an option text: not recorded" none "$(st G-T206-2 letter)"
post "$(q1 ' G-T206-2：选哪个？' G-T206-2)" "$(ans ' G-T206-2：选哪个？' 'B 乙方案')"
expect "v2 strict: text before the gate id (even a space): not recorded" none "$(st G-T206-2 letter)"
pick G-T206-2 'B 乙方案' G-T206-2 '[{"label":"A 甲方案","description":"推荐：最省事"},{"label":"B 乙方案","description":"另一个"}]'
expect "v2 strict control: exact labels (recommendation in description) record" B "$(st G-T206-2 letter)"

# ---------------------------------------------------------------- 6. v2 (2) 有后续效果的门卡：对话里不记录 A
for k in design irreversible external unlock custom; do gate "G-T207-$k" "$k"; done
ups "G-T207-design: A"
expect "v2 effect: design + A (prompt): not recorded" none "$(st G-T207-design letter)"
expect "v2 effect: exit 0" 0 "$(rc)"
expect "v2 effect: systemMessage sends the human to terminal answer / 看板" yes "$(smsg G-T207-design answer 看板)"
expect "v2 effect: no 已记录" 0 "$(srecorded 'G-T207-design: A')"
pick G-T207-irreversible 'A 甲方案'
expect "v2 effect: irreversible + A (AskUserQuestion): not recorded" none "$(st G-T207-irreversible letter)"
expect "v2 effect: irreversible: systemMessage answer / 看板" yes "$(smsg G-T207-irreversible answer 看板)"
ups "G-T207-external: A"
expect "v2 effect: external + A: not recorded" none "$(st G-T207-external letter)"
pick G-T207-unlock 'A 甲方案'
expect "v2 effect: unlock + A: not recorded" none "$(st G-T207-unlock letter)"
ups "G-T207-custom: A"
expect "v2 effect: unknown kind + A: not recorded (only ui/sensory/ambiguity are effect-free)" none "$(st G-T207-custom letter)"
expect "v2 effect: refused gate stays open; terminal can still approve" "0 A 终端" "$(librc answer G-T207-design A) $(st G-T207-design letter) $(st G-T207-design via)"
ups "G-T207-external: B 先不发"
expect "v2 effect: external + B (not approving): recorded via 对话" "B 对话" "$(st G-T207-external letter) $(st G-T207-external via)"
pick G-T207-irreversible 'B 乙方案'
expect "v2 effect: irreversible + B via AskUserQuestion: recorded" B "$(st G-T207-irreversible letter)"
gate G-T207-1 ui "then: ready"; gate G-T207-2 ui "then_tasks: [T-201]"; gate G-T207-3 ui "then_policy: sensory"
gate G-T207-4 ui "then_rules: [不要再问 ui 门]"; gate G-T207-5 ui; RP G-T207-5 31 >/dev/null
for i in 1 2 3 4 5; do ups "G-T207-$i: A"; done
expect "v2 effect: ui + then: ready + A: not recorded" none "$(st G-T207-1 letter)"
expect "v2 effect: ui + then_tasks + A: not recorded" none "$(st G-T207-2 letter)"
expect "v2 effect: ui + then_policy + A: not recorded" none "$(st G-T207-3 letter)"
expect "v2 effect: ui + then_rules + A: not recorded" none "$(st G-T207-4 letter)"
expect "v2 effect: ui gate with a control-plane PR + A: not recorded" none "$(st G-T207-5 letter)"
expect "v2 effect: PR gate: systemMessage answer / 看板" yes "$(smsg G-T207-5 answer 看板)"
pick G-T207-1 'A 甲方案'
expect "v2 effect: ui + then + A via AskUserQuestion: not recorded" none "$(st G-T207-1 letter)"
ups "G-T207-1: B"
expect "v2 effect: ui + then + B: recorded" B "$(st G-T207-1 letter)"
gate G-T207-6 sensory; gate G-T207-7 ambiguity; gate G-T207-8 ui "then: done"
pick G-T207-6 'A 甲方案'; ups "G-T207-7: A"; ups "G-T207-8: A"
expect "v2 effect-free: sensory + A (AUQ) recorded" A "$(st G-T207-6 letter)"
expect "v2 effect-free: ambiguity + A (prompt) recorded" A "$(st G-T207-7 letter)"
expect "v2 effect-free: 'then: done' is not in the snapshot -> A recorded" A "$(st G-T207-8 letter)"

# ---------------------------------------------------------------- 7. 结构不认识 / 预填答案：不写、不报错
gate G-T205-1
TI1="$(q1 'G-T205-1：选哪个？' G-T205-1)"
post "$TI1" '{"result":"ok"}'
expect "unknown shape (no answers): exit 0" 0 "$(rc)"
expect "unknown shape (no answers): not recorded" none "$(st G-T205-1 letter)"
expect "unknown shape (no answers): no traceback" 0 "$(tb)"
expect "unknown shape with a gate question: notice points to terminal answer" yes "$(ctx | grep -q 'G-T205-1' && ctx | grep -q 'answer' && echo yes || echo no)"
expect "v2 unknown shape: systemMessage names the gate" yes "$(smsg G-T205-1)"
post "$TI1" '"User has answered your questions: \"G-T205-1：选哪个？\"=\"A 甲方案\"."'
expect "tool_response is a string: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post "$TI1" '{"answers":[["G-T205-1：选哪个？","A 甲方案"]]}'
expect "answers is a list: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post '{"questions":"G-T205-1：选哪个？"}' "$(ans 'G-T205-1：选哪个？' 'A 甲方案')"
expect "questions is a string: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post '{"questions":[{"question":"G-T205-1：选哪个？","options":["A 甲方案","B 乙方案"]}]}' "$(ans 'G-T205-1：选哪个？' 'A 甲方案')"
expect "options are strings: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post '{"questions":[{"q":"G-T205-1：选哪个？","choices":[{"text":"A 甲方案"}]}]}' '{"selected":"A 甲方案"}'
expect "renamed fields: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post '{}' '{}'
expect "empty input/response: exit 0, no traceback" "0 0" "$(rc) $(tb)"
post '[1,2]' 'null'
expect "input/response of wrong JSON types: exit 0, no traceback" "0 0" "$(rc) $(tb)"
TIF="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["answers"]={"G-T205-1：选哪个？":"A 甲方案"}; print(json.dumps(d, ensure_ascii=False))' "$TI1")"
post "$TIF" '{"result":"ok"}'
expect "answers only in tool_input (Claude-fillable): not recorded" none "$(st G-T205-1 letter)"
post "$TIF" "$(ans 'G-T205-1：选哪个？' 'A 甲方案')"
expect "v2 (4) tool_input already has answers (even with a matching tool_response): not recorded" none "$(st G-T205-1 letter)"
expect "v2 (4): exit 0" 0 "$(rc)"
expect "v2 (4): systemMessage names the gate" yes "$(smsg G-T205-1)"
hook 'not json at all {'
expect "stdin not JSON: exit 0, no traceback" "0 0" "$(rc) $(tb)"
hook ''
expect "empty stdin: exit 0, no traceback" "0 0" "$(rc) $(tb)"
hook "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","cwd":sys.argv[1]}))' "$R")"
expect "UserPromptSubmit without prompt: exit 0, no traceback" "0 0" "$(rc) $(tb)"
hook "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","cwd":sys.argv[1],"prompt":["G-T205-1: A"]}))' "$R")"
expect "prompt not a string: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
pick G-T205-1 'A 甲方案'
expect "control: well-formed payload for the same gate records" A "$(st G-T205-1 letter)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
