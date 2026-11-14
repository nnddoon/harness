#!/usr/bin/env bash
# T-022 验收：S-003#11 小问题（F-6、F-7、F-13、F-14、F-15、doctor/down 与 serve）。按任务卡「接口约定」。
#   F-6  show 与终端 answer 用 meaning_diff 判断「快照后改过」：控制面回写 issue/worktree/session/status/answer/decided_by 不提示；改选项文字仍提示。
#   F-7  init 发现 npm 默认的 `exit 1` 测试脚本时提示 verify.sh 会一直失败。
#   F-13 审计打码 [?&]t=… 的值。
#   F-14 有有效配对码时，私聊里错误 / 旧的 /pair 回一句「配对码无效或已用过」；群聊、没有有效码时一律不回。
#   F-15 回调先 answerCallbackQuery 再写库；每个周期处理完后统一去掉已答门卡消息的按钮（失败下个周期重试，成功后不再重复）。
#   serve 写 run/serve-<pid>.pid；doctor 列出、down 停掉；down 移除定时任务后表空了就 crontab -r，不留空表。
# 外部一律用假的：假 Telegram（tests/fake/telegram.py）、假 crontab（HARNESS_CRONTAB；PATH 上的 crontab 是陷阱）。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-small.XXXXXX")"; T="$(cd "$T" && pwd -P)"
FT="$T/faketg"; mkdir -p "$FT"
FTPID=""; PIDS=""
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  [ -n "$FTPID" ] && kill "$FTPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
yn() { if eval "$1"; then echo yes; else echo no; fi; }
to() { if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"; else "$@"; fi; }
notty() { if command -v setsid >/dev/null 2>&1; then setsid -w "$@"; else "$@"; fi; }
alive() { kill -0 "$1" 2>/dev/null || return 1; [ ! -r "/proc/$1/stat" ] || [ "$(sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f1)" != Z ]; }
gone() { local i; for i in $(seq 50); do alive "$1" || return 0; sleep 0.1; done; return 1; }
sec() { awk -v h="## $2" '$0==h{p=1;next} /^## /{p=0} p' "$1" 2>/dev/null; }

unset HARNESS_TELEGRAM_TOKEN HARNESS_NOW HARNESS_UNATTENDED HARNESS_MODE HARNESS_GH_TOKEN HARNESS_SERVE_TOKEN HARNESS_GUARD HARNESS_STRICT
unset HARNESS_GATE_APPROVERS HARNESS_PYTHON HARNESS_CRON_DAYS
export TZ=UTC XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" HARNESS_GATE_CHANNEL=off HARNESS_GATE_PUSH_ASSETS=0
export HARNESS_TELEGRAM_POLL=1 HARNESS_PLATFORM=linux
export HOME="$T/home"; mkdir -p "$HOME/.claude"
PY="$(command -v python3)"
HARNESS=("$PY" "$SRC/bin/harness")

# ---------------------------------------------------------------- 假 crontab（记下每次调用）+ 陷阱
BIN="$T/bin"; TRAPB="$T/trapbin"; mkdir -p "$BIN" "$TRAPB"
CRON="$T/crontab.txt"; CLOG="$T/crontab.calls"; : > "$CLOG"
cat > "$BIN/fake-crontab" <<SH
#!/bin/sh
F="$CRON"; L="$CLOG"
case "\${1:-}" in
  -l) [ -f "\$F" ] || { echo "no crontab for user" >&2; exit 1; }; cat "\$F" ;;
  -)  cat > "\$F.tmp" && mv "\$F.tmp" "\$F"; echo "write \$(grep -c '[^[:space:]]' "\$F")" >> "\$L" ;;
  -r) [ -f "\$F" ] || { echo "no crontab for user" >&2; exit 1; }; rm -f "\$F"; echo "remove" >> "\$L" ;;
  *)  echo "fake crontab: unsupported: \$*" >&2; exit 2 ;;
esac
SH
printf '#!/bin/sh\necho "$*" >> "%s/real-crontab-called"\nexit 1\n' "$T" > "$TRAPB/crontab"
chmod +x "$BIN/fake-crontab" "$TRAPB/crontab"
export HARNESS_CRONTAB="$BIN/fake-crontab" PATH="$TRAPB:$PATH"

# ---------------------------------------------------------------- 夹具仓库
R="$T/repo"; mkdir -p "$R" && cd "$R" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" . && rm -f .harness/gates/G-*.md
rm -rf .claude/worktrees .harness/logs .harness/reports .harness/STATUS.md
printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
HK="$R/.claude/hooks"
task() {  # task <T-xxx> <status>
  sed -e "s/T-000/$1/g" -e "s/^status: proposed /status: $2 /" -e "s/^title: .*/title: demo $1/" \
      "$R/.harness/tasks/_TEMPLATE.md" > "$R/.harness/tasks/$1-x.md"
}
gate() {  # gate <id> <kind> [标题] [A 文字] [B 文字]  —— status: open，选项 A/B
  local id="$1" kind="$2" title="${3:-选哪个？}" a="${4:-甲方案}" b="${5:-乙方案}"
  printf -- '---\nid: %s\ntask: %s\nkind: %s\nstatus: open\nurgency: normal\nrecommended: A\ndecided_by: human\nreview_minutes: 3\nanswer:\n---\n\n# %s %s\n\n## 选项\n- **A（推荐）**：%s\n- **B**：%s\n' \
    "$id" "T-${id:3:3}" "$kind" "$id" "$title" "$a" "$b" > "$R/.harness/gates/$id.md"
}
lib() { (cd "$R" && "$PY" -B .claude/hooks/harness_lib.py "$@" 2>&1); }
librc() { (cd "$R" && "$PY" -B .claude/hooks/harness_lib.py "$@" >/dev/null 2>&1); echo $?; }
st() {  # st <gid> <field> -> 答案库里的值 | none
  "$PY" -B - "$HK" "$R" "$1" "$2" <<'PY' 2>/dev/null || echo ERR
import json, sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import harness_lib as H
a = H.read_answer(Path(sys.argv[2]), sys.argv[3])
v = "none" if a is None else a.get(sys.argv[4], "")
print(json.dumps(v) if isinstance(v, bool) else v)
PY
}
writeback() {  # writeback <card> <key> <value> [<key> <value>...] —— 控制面回写 frontmatter（H.ensure_frontmatter_field）
  "$PY" -B - "$HK" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import harness_lib as H
card, kv = Path(sys.argv[2]), sys.argv[3:]
for k, v in zip(kv[0::2], kv[1::2]):
    H.ensure_frontmatter_field(card, k, v)
PY
}
for t in T-301 T-302 T-303 T-304 T-401 T-402 T-403 T-404 T-405 T-406; do task "$t" waiting_human; done
git add -A && git commit -qm fixture
SD="$("$PY" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.state_dir(H.store_main(Path(sys.argv[2]).resolve())))' "$HK" "$R")"

# ================================================================ F-6：控制面回写不算「快照后改过」；改选项文字仍算
gate G-T301-1 ui
lib show G-T301-1 >/dev/null                       # 第一次见：冻结快照
C1="$R/.harness/gates/G-T301-1.md"
writeback "$C1" issue 1 worktree "$R/.claude/worktrees/T-301" session sess-301
expect "F-6 show: after control-plane write-back of issue/worktree/session -> no 快照后改过" no "$(yn 'lib show G-T301-1 | grep -qF 快照后改过')"
writeback "$C1" status answered answer B decided_by human
expect "F-6 show: after write-back of status/answer/decided_by -> no 快照后改过" no "$(yn 'lib show G-T301-1 | grep -qF 快照后改过')"
expect "F-6 show: still shows the snapshot options" yes "$(yn 'lib show G-T301-1 | grep -qF 乙方案')"

gate G-T302-1 design
lib show G-T302-1 >/dev/null
C2="$R/.harness/gates/G-T302-1.md"
writeback "$C2" issue 7 worktree "$R/.claude/worktrees/T-302" session sess-302 status open answer '' decided_by human
AO="$(lib answer G-T302-1 A)"; ARC="$(librc show G-T302-1)"
expect "F-6 answer: after control-plane write-back -> no 快照后改过" no "$(yn 'printf "%s\n" "$AO" | grep -qF 快照后改过')"
expect "F-6 answer: after control-plane write-back -> recorded (A)" A "$(st G-T302-1 letter)"
expect "F-6 answer: after control-plane write-back -> no 'not recorded' refusal" no "$(yn 'printf "%s\n" "$AO" | grep -qF 没有记录')"
expect "F-6 show: after settle mirrored status/answer/decided_by -> no 快照后改过" no "$(yn 'lib show G-T302-1 | grep -qF 快照后改过')"
expect "F-6 show: exit 0" 0 "$ARC"

gate G-T303-1 ui
lib show G-T303-1 >/dev/null
sed -i.bak 's/乙方案/丙方案（改过）/' "$R/.harness/gates/G-T303-1.md" && rm -f "$R/.harness/gates/G-T303-1.md.bak"
expect "F-6 show: option text changed -> 快照后改过" yes "$(yn 'lib show G-T303-1 | grep -qF 快照后改过')"
AO3="$(lib answer G-T303-1 A)"
expect "F-6 answer: option text changed -> 快照后改过" yes "$(yn 'printf "%s\n" "$AO3" | grep -qF 快照后改过')"
expect "F-6 answer: option text changed -> exit 3 without --yes" 3 "$(librc answer G-T303-1 A)"
expect "F-6 answer: option text changed -> not recorded" none "$(st G-T303-1 letter)"

gate G-T304-1 ui
lib show G-T304-1 >/dev/null
writeback "$R/.harness/gates/G-T304-1.md" issue 9
sed -i.bak 's/甲方案/甲方案（改过）/' "$R/.harness/gates/G-T304-1.md" && rm -f "$R/.harness/gates/G-T304-1.md.bak"
expect "F-6 show: write-back plus an option edit -> still 快照后改过" yes "$(yn 'lib show G-T304-1 | grep -qF 快照后改过')"
expect "F-6 answer: write-back plus an option edit -> still exit 3" 3 "$(librc answer G-T304-1 A)"

# ================================================================ F-7：npm init -y 的默认 test 脚本
NPMR="$T/npm-default"; mkdir -p "$NPMR" && (cd "$NPMR" && git init -q -b main)
if command -v npm >/dev/null 2>&1; then (cd "$NPMR" && to npm init -y >/dev/null 2>&1); fi
if ! grep -q '"test"' "$NPMR/package.json" 2>/dev/null; then   # 没有 npm：写入 npm init -y 的原样输出
  cat > "$NPMR/package.json" <<'JSON'
{
  "name": "npm-default",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1"
  },
  "keywords": [],
  "author": "",
  "license": "ISC"
}
JSON
fi
expect "F-7 fixture: package.json has npm's default 'exit 1' test script" yes \
  "$("$PY" -c 'import json,sys; print("yes" if json.load(open(sys.argv[1]))["scripts"]["test"].rstrip().endswith("exit 1") else "no")' "$NPMR/package.json" 2>/dev/null || echo no)"
DRY="$("${HARNESS[@]}" init --dry-run --target "$NPMR" 2>&1)"
warn7() { printf '%s\n' "$1" | grep -F 'exit 1' | grep -F 'verify.sh' | grep -qF '失败'; }
expect "F-7 init --dry-run: warns that the default 'exit 1' test makes verify.sh always fail" yes "$(yn 'warn7 "$DRY"')"
IO="$("${HARNESS[@]}" init --yes --target "$NPMR" 2>&1)"; IRC=$?
expect "F-7 init --yes: still installs (exit 0)" 0 "$IRC"
expect "F-7 init --yes: warns that the default 'exit 1' test makes verify.sh always fail" yes "$(yn 'warn7 "$IO"')"
expect "F-7 init --yes: verify.sh still generated with npm run test" yes "$(yn 'grep -qF "npm run test" "$NPMR/.harness/verify.sh"')"
OKR="$T/npm-real"; mkdir -p "$OKR" && (cd "$OKR" && git init -q -b main)
printf '{"name":"ok","scripts":{"test":"node -e \\"process.exit(0)\\""}}\n' > "$OKR/package.json"
OO="$("${HARNESS[@]}" init --yes --target "$OKR" 2>&1)"
expect "F-7 init: real test script -> no 'exit 1' warning" no "$(yn 'printf "%s\n" "$OO" | grep -qF "exit 1"')"
# v2（第 2 轮，见任务卡 §9）：只在 test 脚本恰好是 npm init 的默认值时提示；自己写的「… || exit 1」「exit 1」不提示
f7quiet() {  # f7quiet <名字> <test 脚本> -> yes 当 init 没打 F-7 警告
  local d="$T/npm-$1"; mkdir -p "$d" && (cd "$d" && git init -q -b main)
  "$PY" -c 'import json,sys; json.dump({"name": "x", "scripts": {"test": sys.argv[2]}}, open(sys.argv[1], "w"))' "$d/package.json" "$2"
  local o; o="$("${HARNESS[@]}" init --dry-run --target "$d" 2>&1)"
  if warn7 "$o"; then echo no; else echo yes; fi
}
expect "F-7 v2: 'jest || exit 1' -> no warning" yes "$(f7quiet jest 'jest || exit 1')"
expect "F-7 v2: bare 'exit 1' (not the npm default) -> no warning" yes "$(f7quiet bare 'exit 1')"
expect "F-7 v2: 'npm run lint && exit 1' -> no warning" yes "$(f7quiet lint 'npm run lint && exit 1')"
expect "F-7 v2: exact npm default (with surrounding spaces) -> warning" no "$(f7quiet dflt '  echo "Error: no test specified" && exit 1 ')"

# ================================================================ F-13：审计打码 ?t= / &t=
AUD="$SD/audit"
hookjson() {  # hookjson <tool> <tool_input json>
  "$PY" -B -c 'import json,sys; print(json.dumps({"session_id": "s-13", "transcript_path": "/tmp/t.jsonl", "cwd": sys.argv[3],
  "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))' "$1" "$2" "$R"
}
audit() { hookjson "$1" "$2" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" "$PY" -B "$R/.claude/hooks/audit_log.py") >/dev/null 2>&1; }
jarg() { "$PY" -c 'import json,sys; print(json.dumps({sys.argv[1]: sys.argv[2]}))' "$1" "$2"; }
leaked() { grep -rqF -- "$1" "$AUD" 2>/dev/null && echo yes || echo no; }
line() { grep -rhF -- "$1" "$AUD" 2>/dev/null | head -1; }
TK1="Zt$("$PY" -c 'import secrets; print(secrets.token_hex(12))')"
TK2="Qy$("$PY" -c 'import secrets; print(secrets.token_hex(12))')"
TK3="Wx$("$PY" -c 'import secrets; print(secrets.token_hex(12))')"
audit Bash "$(jarg command "curl -s http://127.0.0.1:8765/?t=$TK1 # mkT13a")"
expect "F-13 audit line written (Bash ?t=)" yes "$(yn '[ -n "$(line mkT13a)" ]')"
expect "F-13 mask ?t=<token> in a Bash command" no "$(leaked "$TK1")"
expect "F-13 ?t=: host still visible" yes "$(yn 'line mkT13a | grep -qF "127.0.0.1:8765"')"
audit mcp__Claude_Browser__navigate "$(jarg url "http://127.0.0.1:8765/audit/mkT13b?task=T-042&t=$TK2&day=2026-11-14")"
expect "F-13 audit line written (navigate url &t=)" yes "$(yn '[ -n "$(line mkT13b)" ]')"
expect "F-13 mask &t=<token> in a url field" no "$(leaked "$TK2")"
expect "F-13 &t=: other parameters kept (task=, day=)" yes "$(yn 'line mkT13b | grep -qF "task=T-042" && line mkT13b | grep -qF "day=2026-11-14"')"
audit Bash "$(jarg command "curl 'http://127.0.0.1:8765/?x=1&t=$TK3' mkT13c")"
expect "F-13 mask &t=<token> in a quoted Bash url" no "$(leaked "$TK3")"
audit Bash "$(jarg command "echo mkT13d http://h.example/?tab=1&type=plainvalue7")"
expect "F-13 no over-masking: ?tab= and &type= kept" yes "$(yn 'line mkT13d | grep -qF "tab=1" && line mkT13d | grep -qF "type=plainvalue7"')"

# ================================================================ F-14 / F-15：Telegram（假服务器）
BOTID=7000000001; SECRET="AAHfakeTOKENsecret_x9QzLmNoPqRsTuVwXyZ012"; TOKEN="$BOTID:$SECRET"
echo '[]' > "$FT/queue.json"
FAKETG_TOKEN="$TOKEN" "$PY" "$SRC/tests/fake/telegram.py" "$FT" > "$FT/server.out" 2>&1 & FTPID=$!
for _ in $(seq 50); do [ -s "$FT/port" ] && break; sleep 0.1; done
export HARNESS_TELEGRAM_API="http://127.0.0.1:$(cat "$FT/port" 2>/dev/null)"
REQ="$FT/requests.jsonl"; : > "$REQ"
ME=1001; T0=1767225600; UID_N=0
upd() {  # upd msg <from> <chat> <text> [聊天类型] | upd cb <id> <from> <chat> <message_id> <data>
  UID_N=$((UID_N+1))
  "$PY" - "$FT" "$UID_N" "$@" <<'PY'
import fcntl, json, os, sys
d, uid, kind = sys.argv[1], int(sys.argv[2]), sys.argv[3]
a = sys.argv[4:]
user = lambda i: {"id": int(i), "is_bot": False, "first_name": "u%s" % i}
chat = lambda i, t="private": {"id": int(i), "type": t}
if kind == "msg":
    u = {"update_id": uid, "message": {"message_id": 9000 + uid, "from": user(a[0]), "chat": chat(a[1], a[3] if len(a) > 3 else "private"), "date": 0, "text": a[2]}}
else:
    u = {"update_id": uid, "callback_query": {"id": a[0], "from": user(a[1]), "chat_instance": "ci",
         "message": {"message_id": int(a[3]) if a[3].isdigit() else 0, "from": {"id": 1, "is_bot": True, "first_name": "fake"}, "chat": chat(a[2]),
                     "date": 0, "text": "x"}, "data": a[4]}}
lk = open(os.path.join(d, "queue.lock"), "a"); fcntl.flock(lk, fcntl.LOCK_EX)
p = os.path.join(d, "queue.json")
q = json.load(open(p))
q.append(u)
json.dump(q, open(p + ".tmp", "w")); os.replace(p + ".tmp", p)
PY
}
rq() { "$PY" - "$REQ" "$1" <<'PY' 2>/dev/null || echo ERR
import json, sys
R = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
def p(e, k, d=""): return (e.get("params") or {}).get(k, d)
def btns(e):
    m = p(e, "reply_markup", {}) or {}
    return [b.get("callback_data", "") for row in (m.get("inline_keyboard") or []) for b in row] if isinstance(m, dict) else []
def sends(g): return [e for e in R if e["method"] == "sendMessage" and g in str(p(e, "text"))]
def to(c): return [e for e in R if e["method"] == "sendMessage" and str(p(e, "chat_id")) == str(c)]
def edits(mid, n=0): return [e for e in R[n:] if e["method"] == "editMessageText" and str(p(e, "message_id")) == str(mid)]
exec("print(" + sys.argv[2] + ")")
PY
}
nlines() { wc -l < "$REQ" | tr -d ' '; }
ninvalid() { rq "len([e for e in to('$1') if '配对码无效或已用过' in str(p(e,'text'))])"; }
nto() { rq "len(to('$1'))"; }
mid_of() { rq "(sends('$1') or [{}])[0].get('message_id')"; }
CFG="$T/config/harness/telegram.json"
cfg() { "$PY" -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$CFG" "$1" 2>/dev/null || echo ERR; }
cycle() { local i; for i in $(seq "${1:-1}"); do to "${HARNESS[@]}" inbox run --once --repo "$R" >> "$T/inbox.out" 2>&1 < /dev/null; RC=$?; done; }
setup() {  # setup <HARNESS_NOW> —— 打印配对码
  (printf '%s\n' "$TOKEN" | HARNESS_NOW="$1" notty timeout 60 "${HARNESS[@]}" inbox setup --repo "$R") > "$T/setup.out" 2>&1
  grep -oE '(^|[^0-9])[0-9]{6}([^0-9]|$)' "$T/setup.out" | grep -oE '[0-9]{6}' | head -1
}
other() { printf '%06d' $(( (10#${1:-0} + $2) % 1000000 )); }

# ---------------------------------------------------------------- F-14 配对码错误 / 已用过
P1="$(setup "$T0")"
expect "F-14 fixture: setup printed a pairing code" yes "$(yn '[ -n "$P1" ]')"
upd msg "$ME" "$ME" "/pair $(other "$P1" 1)"
upd msg "$ME" -5005 "/pair $(other "$P1" 2)" group
upd msg 3003 3003 "/pair 12345"
HARNESS_NOW=$((T0 + 10)) cycle
expect "F-14 run --once exit 0" 0 "$RC"
expect "F-14 wrong code in a private chat while a code is active -> exactly one 配对码无效或已用过" 1 "$(ninvalid "$ME")"
expect "F-14 ... and nothing else sent to that chat" 1 "$(nto "$ME")"
expect "F-14 wrong code -> not paired" "" "$(cfg paired_user_id)"
expect "F-14 /pair in a group chat -> no reply (never reveals a code exists)" 0 "$(nto -5005)"
expect "F-14 malformed /pair (not 6 digits) in a private chat while a code is active -> one 配对码无效或已用过" 1 "$(ninvalid 3003)"
P2="$(setup $((T0 + 100)))"
expect "F-14 fixture: second setup printed a different code" yes "$(yn '[ -n "$P2" ] && [ "$P2" != "$P1" ]')"
upd msg "$ME" "$ME" "/pair $P1"                                   # 上一次 setup 的旧码
HARNESS_NOW=$((T0 + 110)) cycle
expect "F-14 old code from an earlier setup -> 配对码无效或已用过 (one more reply)" 2 "$(ninvalid "$ME")"
expect "F-14 old code -> not paired" "" "$(cfg paired_user_id)"
upd msg "$ME" "$ME" "/pair $(other "$P2" 3)"
B14="$(ninvalid "$ME") $(nto "$ME")"
HARNESS_NOW=$((T0 + 100 + 601)) cycle                             # 码已过期：没有有效码 -> 不回
expect "F-14 no active code (expired) -> no reply, nothing sent to that chat" "$B14" "$(ninvalid "$ME") $(nto "$ME")"
P3="$(setup $((T0 + 1000)))"
upd msg "$ME" "$ME" "/pair $P3"
B14="$(ninvalid "$ME")"
HARNESS_NOW=$((T0 + 1010)) cycle
expect "F-14 right code -> paired" "$ME" "$(cfg paired_user_id)"
expect "F-14 right code -> no 配对码无效 reply" "$B14" "$(ninvalid "$ME")"
N14="$(nto "$ME")"
upd msg 4004 4004 "/pair $P3"                                     # 已用掉的码，没有有效码
upd msg "$ME" "$ME" "/pair $P3"
HARNESS_NOW=$((T0 + 1020)) cycle
expect "F-14 no active code (already used): stranger reusing the code gets no reply" 0 "$(nto 4004)"
expect "F-14 no active code (already used): paired user's /pair gets no reply" "$N14" "$(nto "$ME")"
expect "F-14 still paired with the first user" "$ME" "$(cfg paired_user_id)"

# ---------------------------------------------------------------- F-15 回调先应答；记录后统一去按钮
for g in G-T401-1 G-T402-1 G-T403-1 G-T404-1 G-T405-1 G-T406-1; do gate "$g" design; done
cycle 2
for g in G-T401-1 G-T402-1 G-T403-1 G-T404-1 G-T405-1 G-T406-1; do
  expect "F-15 fixture: $g sent once" 1 "$(rq "len(sends('$g'))")"
done
MA="$(mid_of G-T401-1)"; MB="$(mid_of G-T402-1)"; MC="$(mid_of G-T403-1)"
MD="$(mid_of G-T404-1)"; ME5="$(mid_of G-T405-1)"; MF="$(mid_of G-T406-1)"
first() { rq "next((e['method'] + ':' + str(p(e,'callback_query_id')) for e in R[$1:] if e['method'] != 'getUpdates'), 'none')"; }
lastbtns() { rq "(lambda x: 'none' if not x else ('none-buttons' if not btns(x[-1]) else 'buttons'))(edits('$1', $2))"; }

N0="$(nlines)"
upd cb cbA "$ME" "$ME" "$MA" "G-T401-1|B"
cycle
expect "F-15 B tap: the first API call for the callback is answerCallbackQuery (before any edit / record)" answerCallbackQuery:cbA "$(first "$N0")"
expect "F-15 B tap: the immediate answer has text" yes "$(rq "'yes' if any(e['method']=='answerCallbackQuery' and str(p(e,'callback_query_id'))=='cbA' and str(p(e,'text')).strip() for e in R) else 'no'")"
expect "F-15 B tap: recorded" B "$(st G-T401-1 letter)"
expect "F-15 B tap: message edited without buttons in the same cycle" none-buttons "$(lastbtns "$MA" "$N0")"

N0="$(nlines)"
upd cb cbB1 "$ME" "$ME" "$MB" "G-T402-1|A"
cycle
expect "F-15 A tap (confirm step): answerCallbackQuery first, before the confirm edit" answerCallbackQuery:cbB1 "$(first "$N0")"
N0="$(nlines)"
upd cb cbB2 "$ME" "$ME" "$MB" "G-T402-1|A|ok"
cycle
expect "F-15 A confirm: answerCallbackQuery first, before the record" answerCallbackQuery:cbB2 "$(first "$N0")"
expect "F-15 A confirm: recorded" A "$(st G-T402-1 letter)"
expect "F-15 A confirm: message ends without buttons" none-buttons "$(lastbtns "$MB" "$N0")"

# 同一周期：一张在 Telegram 点、一张在终端答 -> 本周期内两条消息都去掉按钮
lib answer G-T404-1 B >/dev/null
N0="$(nlines)"
upd cb cbC "$ME" "$ME" "$MC" "G-T403-1|B"
cycle
expect "F-15 same cycle: tapped gate's message loses its buttons" none-buttons "$(lastbtns "$MC" "$N0")"
expect "F-15 same cycle: gate answered in the terminal loses its buttons too" none-buttons "$(lastbtns "$MD" "$N0")"

# 改消息失败：下个周期重试；成功后不再重复
printf 'editMessageText\n' > "$FT/fail_methods"
lib answer G-T406-1 B >/dev/null
upd cb cbE "$ME" "$ME" "$ME5" "G-T405-1|B"
cycle
expect "F-15 edit failing: run --once still exit 0" 0 "$RC"
expect "F-15 edit failing: answer still recorded" B "$(st G-T405-1 letter)"
rm -f "$FT/fail_methods"
N1="$(nlines)"
cycle
expect "F-15 retry: tapped gate's message edited without buttons on the next cycle" none-buttons "$(lastbtns "$ME5" "$N1")"
expect "F-15 retry: terminal-answered gate's message edited without buttons on the next cycle" none-buttons "$(lastbtns "$MF" "$N1")"
N2="$(nlines)"
cycle
expect "F-15 retry: once the buttons are gone, no further edits" 0 "$(rq "len(edits('$ME5', $N2)) + len(edits('$MF', $N2)) + len(edits('$MA', $N2)) + len(edits('$MD', $N2))")"
# v2（第 2 轮，见任务卡 §9）：永久性失败（403 被拉黑、chat not found、除已接受的三种以外的 400）每条消息最多重试 3 次
#   （1 次 + 3 次重试 = 最多 4 次 editMessageText），之后标记完成、不再改，并在输出里记一行（含门卡号与「放弃」）。
#   假服务器的 fail_methods 回 400 "Bad Request: fake failure"（永久性）。
gate G-T407-1 design
cycle
MG="$(mid_of G-T407-1)"
expect "F-15 v2 fixture: G-T407-1 sent" yes "$(yn '[ -n "$MG" ] && [ "$MG" != None ]')"
printf 'editMessageText\n' > "$FT/fail_methods"
lib answer G-T407-1 B >/dev/null
N3="$(nlines)"; : > "$T/inbox-g7.out"
for _ in 1 2 3 4 5 6; do to "${HARNESS[@]}" inbox run --once --repo "$R" >> "$T/inbox-g7.out" 2>&1 < /dev/null; done
cat "$T/inbox-g7.out" >> "$T/inbox.out"
NG="$(rq "len(edits('$MG', $N3))")"
expect "F-15 v2 permanent failure: retried, but at most 1 + 3 edit attempts over 6 cycles" yes "$(yn '[ "$NG" -ge 2 ] && [ "$NG" -le 4 ]')"
N4="$(nlines)"
for _ in 1 2; do cycle; done
expect "F-15 v2 permanent failure: marked done, no further edits" 0 "$(rq "len(edits('$MG', $N4))")"
expect "F-15 v2 permanent failure: a log line names the gate and says 放弃" yes "$(yn 'grep -F G-T407-1 "$T/inbox-g7.out" | grep -qF 放弃')"
rm -f "$FT/fail_methods"
N5="$(nlines)"; cycle
expect "F-15 v2 permanent failure: stays done after the API recovers" 0 "$(rq "len(edits('$MG', $N5))")"
expect "F-15 token never in inbox output" no "$(yn 'grep -qF "$SECRET" "$T/inbox.out"')"

# ================================================================ serve：pid 文件、doctor 列出、down 停掉
RUN="$SD/run"
startserve() {  # -> pid（stdin 不是终端：只读看板）
  "${HARNESS[@]}" serve --repo "$R" --port 0 > "$T/serve.$1.out" 2>&1 < /dev/null &
  echo $!
}
waitpid() { local i; for i in $(seq 50); do [ -f "$RUN/serve-$1.pid" ] && return 0; sleep 0.1; done; return 1; }
S1="$(startserve 1)"; PIDS="$PIDS $S1"
expect "serve: writes run/serve-<pid>.pid" yes "$(yn 'waitpid "$S1"')"
expect "serve: pid file is '<pid> <starttime>' (T-013 format)" yes "$(yn 'grep -qE "^$S1( [0-9]+)?$" "$RUN/serve-$S1.pid" 2>/dev/null')"
(cd /; "${HARNESS[@]}" doctor --repo "$R" > "$T/doc.out" 2>&1)
expect "doctor: 在跑的进程 lists the running serve (pid + serve)" yes "$(yn 'sec "$T/doc.out" 在跑的进程 | grep -w -- "$S1" | grep -qF serve')"
expect "doctor: does not stop serve" yes "$(yn 'alive "$S1"')"
HAD1="$(yn '[ -e "$RUN/serve-$S1.pid" ]')"
(cd /; "${HARNESS[@]}" down --repo "$R" > "$T/down.out" 2>&1); DRC=$?
expect "down: exit 0" 0 "$DRC"
expect "down: serve stopped" yes "$(yn 'gone "$S1"')"
expect "down: serve pid file (present before) removed" "yes no" "$HAD1 $(yn '[ -e "$RUN/serve-$S1.pid" ]')"
expect "down: says 已停止" yes "$(yn 'grep -qF 已停止 "$T/down.out"')"
S2="$(startserve 2)"; PIDS="$PIDS $S2"
HAD2="$(yn 'waitpid "$S2"')"
kill -TERM "$S2" 2>/dev/null; gone "$S2"
expect "serve: SIGTERM -> removes its own pid file (present before)" "yes no" "$HAD2 $(yn 'sleep 0.3; [ -e "$RUN/serve-$S2.pid" ]')"

# ================================================================ down 不留空 crontab
MINE="*/5 * * * * cd \"$R\" && scripts/gate-sync.sh --resume --quiet # harness repo=$R expires=2099-01-01"
BACKUP='0 3 * * * /usr/bin/backup.sh'
printf '%s\n\n' "$MINE" > "$CRON"; : > "$CLOG"
(cd /; "${HARNESS[@]}" down --repo "$R" > "$T/down2.out" 2>&1); DRC=$?
expect "down cron: exit 0" 0 "$DRC"
expect "down cron: table that becomes empty is removed (crontab -r)" yes "$(yn 'grep -qx remove "$CLOG"')"
expect "down cron: no crontab left behind" no "$(yn '[ -e "$CRON" ]')"
expect "down cron: never writes an empty table" no "$(yn 'grep -qx "write 0" "$CLOG"')"
printf '%s\n%s\n' "$BACKUP" "$MINE" > "$CRON"; : > "$CLOG"
(cd /; "${HARNESS[@]}" down --repo "$R" > "$T/down3.out" 2>&1)
expect "down cron: other lines kept" yes "$(yn 'grep -qxF -- "$BACKUP" "$CRON"')"
expect "down cron: this repo's line removed" no "$(yn 'grep -qF "repo=$R " "$CRON"')"
expect "down cron: table not removed while other lines remain" no "$(yn 'grep -qx remove "$CLOG"')"
printf '# my notes\n%s\n' "$MINE" > "$CRON"; : > "$CLOG"
(cd /; "${HARNESS[@]}" down --repo "$R" > "$T/down4.out" 2>&1)
expect "down cron: a comment line counts as content (table kept)" "yes no" "$(yn 'grep -qxF "# my notes" "$CRON"') $(yn 'grep -qx remove "$CLOG"')"
expect "real crontab never invoked" no "$(yn '[ -e "$T/real-crontab-called" ]')"

echo "$((N - FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
