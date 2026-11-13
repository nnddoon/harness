#!/usr/bin/env bash
# T-015 验收：对话内选项卡（S-002 #13）。按任务卡「接口约定」。
# chat_answer.py：UserPromptSubmit（消息恰好是「G-x-n: L [备注]」）与 PostToolUse(AskUserQuestion) 经 record_answer 写库，via 对话。
# 无人值守 / strict / 非交互时不生效；快照与门卡不符不记录；结构不认识时不写、不报错。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-chat.XXXXXX")"; T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
unset HARNESS_UNATTENDED HARNESS_STRICT HARNESS_MODE HARNESS_GH_TOKEN HARNESS_SERVE_TOKEN
export CLAUDE_CODE_ENTRYPOINT=cli   # 交互会话（测试本身可能跑在 claude -p / SDK 里）
export XDG_STATE_HOME="$T/state" HARNESS_GATE_PUSH_ASSETS=0
mkdir -p "$T/state"

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

gate() {  # gate <id> [kind]  —— status: open，选项 A/B
  { printf -- '---\nid: %s\ntask: T-201\nkind: %s\nstatus: open\nurgency: normal\nrecommended: A\ndecided_by: human\nreview_minutes: 3\nanswer:\n---\n\n' "$1" "${2:-design}"
    printf -- '# %s 选哪个？\n\n## 选项\n- **A（推荐）**：甲方案\n- **B**：乙方案\n' "$1"
  } > "$R/.harness/gates/$1.md"
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
has() { [ -e "$AD/$1" ] && echo yes || echo no; }
lib() { (cd "$R" && python3 -B .claude/hooks/harness_lib.py "$@" 2>&1); }

hook() {  # hook <stdin-json>：运行 chat_answer.py；stdout -> $T/out，stderr -> $T/err，退出码 -> $T/rc
  printf '%s' "$1" | (cd "$R" && python3 -B "$HK/chat_answer.py") > "$T/out" 2> "$T/err"; echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
tb() { grep -c 'Traceback' "$T/err"; }
ctx() {  # stdout JSON 的 hookSpecificOutput.additionalContext（不是 JSON / 没有 -> 空）
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d["hookSpecificOutput"]["additionalContext"])
except Exception:
    pass' "$T/out"
}
evname() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["hookEventName"])
except Exception: print("")' "$T/out"; }
recorded() { ctx | grep -c "已记录 $1"; }   # recorded "G-x: A" -> 1/0
upj() {  # upj <prompt> [extra-json-fields]
  python3 -c 'import json,sys; d={"session_id":"s1","transcript_path":"/dev/null","cwd":sys.argv[1],"permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":sys.argv[2]}; d.update(json.loads(sys.argv[3])); print(json.dumps(d, ensure_ascii=False))' "$R" "$1" "${2:-{\}}"
}
ups() { hook "$(upj "$@")"; }
aq() {  # aq <tool_input-json> <tool_response-json> [tool_name]：PostToolUse 负载
  python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","transcript_path":"/dev/null","cwd":sys.argv[1],"permission_mode":"default","hook_event_name":"PostToolUse","tool_name":sys.argv[4],"tool_input":json.loads(sys.argv[2]),"tool_response":json.loads(sys.argv[3])}, ensure_ascii=False))' "$R" "$1" "$2" "${3:-AskUserQuestion}"
}
post() { hook "$(aq "$@")"; }
OPTS='[{"label":"A 甲方案","description":"推荐"},{"label":"B 乙方案","description":"另一个"}]'
q1() {  # q1 <header> <question> [options-json] -> tool_input 单题
  python3 -c 'import json,sys; print(json.dumps({"questions":[{"question":sys.argv[2],"header":sys.argv[1],"options":json.loads(sys.argv[3]),"multiSelect":False}]}, ensure_ascii=False))' "$1" "$2" "${3:-$OPTS}"
}
ans() {  # ans <question> <label> -> tool_response {questions, answers}
  python3 -c 'import json,sys; print(json.dumps({"answers":{sys.argv[1]:sys.argv[2]}}, ensure_ascii=False))' "$1" "$2"
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
expect "prompt exact: hookEventName UserPromptSubmit" UserPromptSubmit "$(evname)"
gate G-T201-2; ups "G-T201-2: A 可以，先做这个"
expect "prompt with note: stored A" A "$(st G-T201-2 letter)"
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
gate G-T201-6; lib answer G-T201-6 B >/dev/null
ups "G-T201-6: A"
expect "terminal then chat: terminal answer kept" "B 终端" "$(st G-T201-6 letter) $(st G-T201-6 via)"

# ---------------------------------------------------------------- 2. 不生效（A2）
gate G-T202-1
HARNESS_UNATTENDED=1 ups "G-T202-1: A"
expect "UNATTENDED prompt: exit 0" 0 "$(rc)"
expect "UNATTENDED prompt: nothing stored" none "$(st G-T202-1 letter)"
expect "UNATTENDED prompt: no snapshot written either" no "$(has G-T202-1.meta.json)"
expect "UNATTENDED prompt: no 已记录" 0 "$(ctx | grep -c '已记录')"
HARNESS_STRICT=1 ups "G-T202-1: A"
expect "STRICT prompt: nothing stored" none "$(st G-T202-1 letter)"
expect "STRICT prompt: no snapshot written" no "$(has G-T202-1.meta.json)"
CLAUDE_CODE_ENTRYPOINT=sdk-cli ups "G-T202-1: A"
expect "non-interactive (claude -p / SDK entrypoint) prompt: nothing stored" none "$(st G-T202-1 letter)"
ups "G-T202-1: A" '{"interactive": false}'
expect "hook input interactive:false prompt: nothing stored" none "$(st G-T202-1 letter)"
expect "... exit 0" 0 "$(rc)"
HARNESS_UNATTENDED=1 post "$(q1 G-T202-1 '选哪个？')" "$(ans '选哪个？' 'A 甲方案')"
expect "UNATTENDED AskUserQuestion: exit 0" 0 "$(rc)"
expect "UNATTENDED AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
expect "UNATTENDED AskUserQuestion: no snapshot written" no "$(has G-T202-1.meta.json)"
HARNESS_STRICT=1 post "$(q1 G-T202-1 '选哪个？')" "$(ans '选哪个？' 'A 甲方案')"
expect "STRICT AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
CLAUDE_CODE_ENTRYPOINT=sdk-py post "$(q1 G-T202-1 '选哪个？')" "$(ans '选哪个？' 'A 甲方案')"
expect "non-interactive AskUserQuestion: nothing stored" none "$(st G-T202-1 letter)"
ups "G-T202-1: A"
expect "control: the same prompt in an interactive session records" A "$(st G-T202-1 letter)"

# ---------------------------------------------------------------- 3. 快照与门卡不符
gate G-T203-1; lib show G-T203-1 >/dev/null
sed -i.bak 's/^- \*\*B\*\*：乙方案/- **B**：删库跑路/' .harness/gates/G-T203-1.md && rm -f .harness/gates/G-T203-1.md.bak
ups "G-T203-1: B"
expect "snapshot mismatch prompt: exit 0" 0 "$(rc)"
expect "snapshot mismatch prompt: not recorded" none "$(st G-T203-1 letter)"
expect "snapshot mismatch prompt: notice names the gate" yes "$(ctx | grep -q 'G-T203-1' && echo yes || echo no)"
expect "snapshot mismatch prompt: notice points to terminal answer --yes" yes "$(ctx | grep -q 'answer' && ctx | grep -q -- '--yes' && echo yes || echo no)"
expect "snapshot mismatch prompt: no 已记录" 0 "$(ctx | grep -c '已记录')"
gate G-T203-2; lib show G-T203-2 >/dev/null
sed -i.bak 's/^kind: design/kind: irreversible/' .harness/gates/G-T203-2.md && rm -f .harness/gates/G-T203-2.md.bak
post "$(q1 G-T203-2 '选哪个？')" "$(ans '选哪个？' 'A 甲方案')"
expect "snapshot mismatch AskUserQuestion (kind changed): not recorded" none "$(st G-T203-2 letter)"
expect "snapshot mismatch AskUserQuestion: notice with --yes" yes "$(ctx | grep -q 'G-T203-2' && ctx | grep -q -- '--yes' && echo yes || echo no)"
gate G-T203-3; lib show G-T203-3 >/dev/null
printf '\n## 补充\n多写了一段说明。\n' >> .harness/gates/G-T203-3.md
ups "G-T203-3: B"
expect "card edited outside its meaning: still recorded" B "$(st G-T203-3 letter)"

# ---------------------------------------------------------------- 4. AskUserQuestion（A3）
gate G-T204-1; post "$(q1 G-T204-1 '选哪个？')" "$(ans '选哪个？' 'B 乙方案')"
expect "AUQ header = gate id: exit 0" 0 "$(rc)"
expect "AUQ header = gate id: stored B" B "$(st G-T204-1 letter)"
expect "AUQ: via 对话" 对话 "$(st G-T204-1 via)"
expect "AUQ: additionalContext 已记录 G-T204-1: B" 1 "$(recorded 'G-T204-1: B')"
expect "AUQ: hookEventName PostToolUse" PostToolUse "$(evname)"
gate G-T204-2; post "$(q1 门卡 'G-T204-2：先上哪个？')" "$(ans 'G-T204-2：先上哪个？' 'A 甲方案')"
expect "AUQ question starts with 'G-…：': stored A" A "$(st G-T204-2 letter)"
gate G-T204-3; post "$(q1 门卡 'G-T204-3: 先上哪个？')" "$(ans 'G-T204-3: 先上哪个？' 'B 乙方案')"
expect "AUQ question starts with 'G-…:': stored B" B "$(st G-T204-3 letter)"
gate G-T204-4; gate G-T204-5
TI="$(python3 -c 'import json,sys; o=json.loads(sys.argv[1]); print(json.dumps({"questions":[{"question":"G-T204-4：甲？","header":"门卡","options":o,"multiSelect":False},{"question":"G-T204-5：乙？","header":"门卡","options":o,"multiSelect":False}]}, ensure_ascii=False))' "$OPTS")"
post "$TI" '{"answers":{"G-T204-4：甲？":"A 甲方案","G-T204-5：乙？":"B 乙方案"}}'
expect "AUQ two gate questions: both recorded" "A B" "$(st G-T204-4 letter) $(st G-T204-5 letter)"
expect "AUQ two gate questions: two 已记录 lines" 2 "$(ctx | grep -c '已记录 G-T204-[45]: [AB]')"
gate G-T204-6; post "$(q1 门卡 '关于 G-T204-6：选哪个？')" "$(ans '关于 G-T204-6：选哪个？' 'A 甲方案')"
expect "AUQ gate id not at the start: ignored" none "$(st G-T204-6 letter)"
expect "... exit 0" 0 "$(rc)"
post "$(q1 偏好 '你喜欢哪个？')" "$(ans '你喜欢哪个？' 'A 甲方案')"
expect "AUQ without any gate id: exit 0, no output" "0 " "$(rc) $(cat "$T/out")"
gate G-T204-7; post "$(q1 G-T204-7 '选哪个？' '[{"label":"A：甲方案","description":""},{"label":"B：乙方案","description":""}]')" "$(ans '选哪个？' 'B：乙方案')"
expect "AUQ label 'B：…' maps to B" B "$(st G-T204-7 letter)"
gate G-T204-8; post "$(q1 G-T204-8 '选哪个？')" "$(ans '选哪个？' 'A 我自己写的答案')"
expect "AUQ free-text answer not among the options: not recorded" none "$(st G-T204-8 letter)"
post "$(q1 G-T204-8 '选哪个？' '[{"label":"甲方案","description":""},{"label":"乙方案","description":""}]')" "$(ans '选哪个？' '甲方案')"
expect "AUQ label without a letter: not recorded" none "$(st G-T204-8 letter)"
post "$(q1 G-T204-8 '选哪个？' '[{"label":"A 甲方案","description":""},{"label":"C 丙方案","description":""}]')" "$(ans '选哪个？' 'C 丙方案')"
expect "AUQ letter not in the snapshot's options: not recorded" none "$(st G-T204-8 letter)"
post "$(q1 G-T204-8 '选哪个？')" '{"answers":{"选哪个？":["A 甲方案","B 乙方案"]}}'
expect "AUQ multi-select (list value): not recorded" none "$(st G-T204-8 letter)"
expect "... exit 0" 0 "$(rc)"
post "$(q1 G-T204-8 '选哪个？')" "$(ans '选哪个？' 'A 甲方案')" Write
expect "same payload from another tool: ignored" none "$(st G-T204-8 letter)"
# 第二次不覆盖
post "$(q1 G-T204-1 '选哪个？')" "$(ans '选哪个？' 'A 甲方案')"
expect "AUQ second answer: first kept" "B 对话" "$(st G-T204-1 letter) $(st G-T204-1 via)"
expect "AUQ second answer: no 已记录" 0 "$(recorded 'G-T204-1: A')"
ups "G-T204-2: B"
expect "AUQ then prompt: AUQ answer kept" A "$(st G-T204-2 letter)"

# ---------------------------------------------------------------- 5. 结构不认识：不写、不报错
gate G-T205-1
TI1="$(q1 G-T205-1 '选哪个？')"
post "$TI1" '{"result":"ok"}'
expect "unknown shape (no answers): exit 0" 0 "$(rc)"
expect "unknown shape (no answers): not recorded" none "$(st G-T205-1 letter)"
expect "unknown shape (no answers): no traceback" 0 "$(tb)"
expect "unknown shape with a gate question: notice points to terminal answer" yes "$(ctx | grep -q 'G-T205-1' && ctx | grep -q 'answer' && echo yes || echo no)"
post "$TI1" '"User has answered your questions: \"选哪个？\"=\"A 甲方案\"."'
expect "tool_response is a string: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post "$TI1" '{"answers":[["选哪个？","A 甲方案"]]}'
expect "answers is a list: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post '{"questions":"G-T205-1：选哪个？"}' "$(ans 'G-T205-1：选哪个？' 'A 甲方案')"
expect "questions is a string: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post '{"questions":[{"question":"G-T205-1：选哪个？","options":["A 甲方案","B 乙方案"]}]}' "$(ans 'G-T205-1：选哪个？' 'A 甲方案')"
expect "options are strings: exit 0, no traceback" "0 0" "$(rc) $(tb)"
post '{"questions":[{"q":"G-T205-1：选哪个？","choices":[{"text":"A 甲方案"}]}]}' '{"selected":"A 甲方案"}'
expect "renamed fields: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post '{}' '{}'
expect "empty input/response: exit 0, no traceback" "0 0" "$(rc) $(tb)"
post '[1,2]' 'null'
expect "input/response of wrong JSON types: exit 0, no traceback" "0 0" "$(rc) $(tb)"
TIF="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["answers"]={"选哪个？":"A 甲方案"}; print(json.dumps(d, ensure_ascii=False))' "$TI1")"
post "$TIF" '{"result":"ok"}'
expect "answers only in tool_input (Claude-fillable): not recorded" none "$(st G-T205-1 letter)"
hook 'not json at all {'
expect "stdin not JSON: exit 0, no traceback" "0 0" "$(rc) $(tb)"
hook ''
expect "empty stdin: exit 0, no traceback" "0 0" "$(rc) $(tb)"
hook "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","cwd":sys.argv[1]}))' "$R")"
expect "UserPromptSubmit without prompt: exit 0, no traceback" "0 0" "$(rc) $(tb)"
hook "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","cwd":sys.argv[1],"prompt":["G-T205-1: A"]}))' "$R")"
expect "prompt not a string: exit 0, not recorded, no traceback" "0 none 0" "$(rc) $(st G-T205-1 letter) $(tb)"
post "$TI1" "$(ans '选哪个？' 'A 甲方案')"
expect "control: well-formed payload for the same gate records" A "$(st G-T205-1 letter)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
