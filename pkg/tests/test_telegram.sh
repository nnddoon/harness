#!/usr/bin/env bash
# T-016 验收：Telegram 收件箱（S-002 #14 #8）。按任务卡「接口约定」：
#   harness inbox setup  [--repo DIR]   终端里 getpass 输入 bot token → config_dir()/telegram.json（0600，{token, paired_user_id, chat_id, api}），
#                                       打印一次性 6 位配对码（10 分钟有效；「现在」取 HARNESS_NOW，同 T-013）
#   harness inbox run --once [--repo]   一个轮询周期：getUpdates（timeout = HARNESS_TELEGRAM_POLL，≤ 20）→ 处理 /pair 与按钮 → 给未发过的开放门卡发消息
#   harness inbox start|stop|status     后台 bot；pid 文件 state_dir(main)/run/inbox-<pid>.pid，内容 "<pid> <starttime>"（T-013 格式），命令行含 harness
# 消息正文只取门卡的 meta 快照；按钮 callback_data = "<GID>|<字母>"；irreversible/external/unlock（快照的 kind）要再点 "<GID>|<字母>|ok"；
# 答复走 record_answer(via=Telegram)（并 settle：镜像、decisions.md、接续）；已答 → answerCallbackQuery「已经答过了」。
# 只认已配对的 user id；陌生人的消息与回调一律不理（不回复）；自由文本除 /pair 外不理。token 不出现在任何输出、日志、仓库里。
# 假 Telegram 服务器：pkg/tests/fake/telegram.py（HARNESS_TELEGRAM_API 指向它）。
# 接口约定 v2（第 2 轮）：
#  1. 正文带含义行（同 GitHub 通道）：审批类「选 A = 批准，其他 = 拒绝」；then: ready →「批准后变为 ready：<任务>」；解锁路径「批准后放开：…」。
#     审批类的按钮文字：A →「A 批准」，其他字母 →「<字母> 拒绝」。
#  2. 二次确认按「效果」判定：点 A 时，快照有任何效果（then / then_tasks / then_policy / then_rules、解锁路径、控制面记过 PR，
#     或 kind ∈ irreversible/external/unlock/design）就要再点 "<GID>|A|ok"；没点过第一次的 "|ok" 无效；按钮必须来自那条消息（message_id 对得上）。
#  3. editMessageText / answerCallbackQuery 出错：捕获、记日志，本周期继续（后面的更新照常处理、新门卡照常发，run --once 退出 0）；
#     先在 inbox.json 里把该条标 closed 再改消息；后台 bot 出错后的等待也不超过 HARNESS_TELEGRAM_POLL。
#  4. 关掉的条目（卡消失过）对应的门卡再出现 → 重新发；点关掉的旧消息无效。
#  5. 配对试错按 from.id 计（每人 5 次，陌生人猜不废掉你的码）；群聊里的 /pair 不理；过期的码在下个周期清掉
#     （telegram.json 只剩 token / paired_user_id / chat_id / api）。
#  6. 一个 token 只跑一个 bot：锁/pid 在 config_dir；另一个仓库再 start → 拒绝并说出在跑的那个（pid）。多仓库共用一个 bot 不在本期范围。
#  7. setup 把 config_dir 与答案库所在的状态目录加进仓库 .claude/settings.json 的 permissions.deny（Read(...)，经 init 的 merge 逻辑，不重复）。
#  8. 并发 start → 只有一个 bot。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-telegram.XXXXXX")"; T="$(cd "$T" && pwd -P)"
FT="$T/faketg"; mkdir -p "$FT"
FTPID=""
cleanup() {
  for f in "$T"/state/harness/*/run/inbox-*.pid; do [ -f "$f" ] && kill "$(cut -d' ' -f1 "$f")" 2>/dev/null; done
  for pid in $(bots); do kill "$pid" 2>/dev/null; done
  [ -n "$FTPID" ] && kill "$FTPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
to() { if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"; else "$@"; fi; }
notty() { if command -v setsid >/dev/null 2>&1; then setsid -w "$@"; else "$@"; fi; }   # 没有控制终端：getpass 读 stdin（只接外部命令）
alive() { kill -0 "$1" 2>/dev/null || return 1; [ ! -r "/proc/$1/stat" ] || [ "$(sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f1)" != Z ]; }
gone() { local i; for i in $(seq 50); do alive "$1" || return 0; sleep 0.1; done; return 1; }
# bots —— 本测试起的 bot 进程（命令行含 "inbox run" 且指向 $T 下的仓库）
bots() { for c in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$c" 2>/dev/null | grep -q "inbox run.*$T/repo" && { c="${c#/proc/}"; echo "${c%/cmdline}"; }; done; }
starttime() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }

unset HARNESS_TELEGRAM_TOKEN HARNESS_NOW HARNESS_UNATTENDED HARNESS_MODE HARNESS_GH_TOKEN HARNESS_SERVE_TOKEN HARNESS_TELEGRAM_POLL
BOTID=7000000001; SECRET="AAHfakeTOKENsecret_x9QzLmNoPqRsTuVwXyZ012"; TOKEN="$BOTID:$SECRET"
export TZ=UTC XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" HARNESS_GATE_CHANNEL=off HARNESS_GATE_PUSH_ASSETS=0
export HARNESS_TELEGRAM_POLL=1
PY="$(command -v python3)"
OUTALL="$T/outputs.log"; : > "$OUTALL"
ME=1001; STRANGER=2002
T0=1767225600

# ---------------------------------------------------------------- 假 crontab（harness down 会读写 crontab：绝不碰真的）
mkdir -p "$T/bin"
printf '#!/bin/sh\nF="%s/crontab.txt"\ncase "${1:-}" in -l) [ -f "$F" ] && cat "$F" || exit 1;; -) cat > "$F";; esac\n' "$T" > "$T/bin/fake-crontab"
chmod +x "$T/bin/fake-crontab"; export HARNESS_CRONTAB="$T/bin/fake-crontab"

# ---------------------------------------------------------------- 假 Telegram 服务器
echo '[]' > "$FT/queue.json"
FAKETG_TOKEN="$TOKEN" "$PY" "$SRC/tests/fake/telegram.py" "$FT" > "$FT/server.out" 2>&1 & FTPID=$!
for _ in $(seq 50); do [ -s "$FT/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$FT/port" 2>/dev/null)"
export HARNESS_TELEGRAM_API="$API"
REQ="$FT/requests.jsonl"; : > "$REQ"
UID_N=0
upd() {  # upd msg <from> <chat> <text> [聊天类型] | upd cb <id> <from> <chat> <message_id> <data> —— 加进 getUpdates 队列
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
# rq '<python>' —— 对请求日志 R（列表，每项 {method, params, auth, message_id}）求值并打印
rq() { "$PY" - "$REQ" "$1" <<'PY' 2>/dev/null || echo ERR
import json, sys
R = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
def p(e, k, d=""): return (e.get("params") or {}).get(k, d)
def btns(e):
    m = p(e, "reply_markup", {}) or {}
    return [b.get("callback_data", "") for row in (m.get("inline_keyboard") or []) for b in row] if isinstance(m, dict) else []
def sends(g): return [e for e in R if e["method"] == "sendMessage" and g in str(p(e, "text"))]
exec("print(" + sys.argv[2] + ")")
PY
}
nsent() { rq "len(sends('$1'))"; }
mid_of() { rq "(sends('$1') or [{}])[0].get('message_id')"; }
acq() { rq "next((str(p(e,'text')) for e in R if e['method']=='answerCallbackQuery' and str(p(e,'callback_query_id'))=='$1'), 'none')"; }
nlines() { wc -l < "$REQ" | tr -d ' '; }

# ---------------------------------------------------------------- 夹具仓库
R="$T/repo"; mkdir -p "$R" && cd "$R" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" . && rm -f .harness/gates/G-*.md
rm -rf .claude/worktrees .harness/logs
printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
HK="$R/.claude/hooks"
task() {  # task <T-xxx> <status> [unlock 列表]
  sed -e "s/T-000/$1/g" -e "s/^status: proposed /status: $2 /" -e "s/^title: .*/title: demo $1/" \
      -e "s#^unlock: \[\]#unlock: [${3:-}]#" "$R/.harness/tasks/_TEMPLATE.md" > "$R/.harness/tasks/$1-x.md"
}
gate() {  # gate <dir> <id> <kind> <标题> <A 文字> <B 文字> [额外 frontmatter 行...]
  local d="$1" id="$2" kind="$3" title="$4" a="$5" b="$6"; shift 6
  { printf -- '---\nid: %s\ntask: %s\nkind: %s\nstatus: open\nurgency: normal\nrecommended: A\ndecided_by: human\nreview_minutes: 3\nanswer:\n' "$id" "T-${id:3:3}" "$kind"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n\n# %s %s\n\n## 选项\n- **A（推荐）**：%s\n- **B**：%s\n' "$id" "$title" "$a" "$b"
  } > "$d/.harness/gates/$id.md"
}
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
fm() { "$PY" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_lib as H, pathlib; print(H.read_frontmatter(pathlib.Path(sys.argv[2])).get(sys.argv[3], ""))' "$HK" "$1" "$2" 2>/dev/null; }
SD="$("$PY" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.state_dir(Path(sys.argv[2]).resolve()))' "$HK" "$R")"
CFG="$T/config/harness/telegram.json"
cfg() { "$PY" -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$CFG" "$1" 2>/dev/null || echo ERR; }
cfgkeys() { "$PY" -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$CFG" 2>/dev/null || echo ERR; }
closed() { "$PY" -c 'import json,sys; print(json.dumps(bool(json.load(open(sys.argv[1]))["sent"][sys.argv[2]].get("closed"))))' "$SD/inbox.json" "$1" 2>/dev/null || echo ERR; }
# btntext <GID> <data> —— 这张门卡第一条消息里某个按钮的文字
btntext() { rq "next((b.get('text','') for row in ((sends('$1') or [{}])[0].get('params',{}).get('reply_markup') or {}).get('inline_keyboard',[]) for b in row if b.get('callback_data')=='$2'), 'none')"; }
okoffered() { rq "any('$1|A|ok' in btns(e) for e in R if e['method'] in ('sendMessage','editMessageText'))" | sed 's/True/yes/;s/False/no/'; }
# denies <path> —— 仓库 .claude/settings.json 的 permissions.deny 里有 Read(...) 规则盖住这个路径（//绝对、~/、或绝对路径写法都算）
denies() {
  "$PY" - "$R/.claude/settings.json" "$1" <<'EOF' 2>/dev/null || echo ERR
import json, os, sys
deny = json.load(open(sys.argv[1]))["permissions"]["deny"]
path, ok = sys.argv[2], False
for d in deny:
    if not (d.startswith("Read(") and d.endswith(")")):
        continue
    p = d[5:-1]
    p = p[1:] if p.startswith("//") else os.path.expanduser(p) if p.startswith("~/") else p
    if p.endswith("/**"):
        base = p[:-3].rstrip("/")
        ok = ok or path == base or path.startswith(base + "/")
print("yes" if ok else "no")
EOF
}
HARNESS=("$PY" "$SRC/bin/harness")
inbox() { "${HARNESS[@]}" inbox "$@" --repo "$R"; }
cycle() {  # cycle [n]：跑 n 次 run --once（默认 1），输出进 $OUTALL；RC = 最后一次退出码
  local i; for i in $(seq "${1:-1}"); do to "${HARNESS[@]}" inbox run --once --repo "$R" >> "$OUTALL" 2>&1 < /dev/null; RC=$?; done
}
setup() {  # setup [HARNESS_NOW] —— 往 getpass 喂 token；打印配对码（输出里唯一的 6 位数）；退出码在 $T/setup.rc
  (printf '%s\n' "$TOKEN" | HARNESS_NOW="${1:-}" notty timeout 60 "${HARNESS[@]}" inbox setup --repo "$R") > "$T/setup.out" 2>&1; echo $? > "$T/setup.rc"
  cat "$T/setup.out" >> "$OUTALL"
  grep -oE '(^|[^0-9])[0-9]{6}([^0-9]|$)' "$T/setup.out" | grep -oE '[0-9]{6}' | head -1
}

task T-101 waiting_human; task T-102 in_progress; task T-103 in_progress; task T-104 waiting_human
task T-105 waiting_human 'scripts/**'; task T-106 in_progress; task T-107 in_progress; task T-108 in_progress
task T-109 proposed; task T-110 in_progress; task T-111 in_progress; task T-112 in_progress; task T-113 in_progress
git add -A && git commit -qm fixture
gate "$R" G-T101-1 design '用哪个数据库？' 'Postgres 主库' 'SQLite 单文件'

# ================================================================ setup + 配对（S-002 #14：只认终端显示的一次性码）
C1="$(setup "$T0")"
expect "setup: exit 0" 0 "$(cat "$T/setup.rc")"
expect "setup: prints a 6-digit pairing code" yes "$([ -n "$C1" ] && echo yes || echo no)"
expect "setup: config file written" yes "$([ -f "$CFG" ] && echo yes || echo no)"
expect "setup: config file mode 600" 600 "$(stat -c %a "$CFG" 2>/dev/null || stat -f %Lp "$CFG" 2>/dev/null || echo none)"
expect "setup: token stored in config" "$TOKEN" "$(cfg token)"
expect "setup: not paired yet" "" "$(cfg paired_user_id)"
expect "setup: output does not contain the token" no "$(grep -qF "$SECRET" "$T/setup.out" && echo yes || echo no)"
expect "setup: config is outside the repo" no "$(case "$CFG" in "$R"/*) echo yes;; *) echo no;; esac)"
expect "setup v2: settings.json denies Read of config_dir (telegram.json)" yes "$(denies "$CFG")"
expect "setup v2: settings.json denies Read of the state dir (answers store)" yes "$(denies "$SD/answers/G-T101-1.json")"
expect "setup v2: existing deny rules kept" yes "$("$PY" -c 'import json,sys; print("yes" if "Read(./.env)" in json.load(open(sys.argv[1]))["permissions"]["deny"] else "no")' "$R/.claude/settings.json" 2>/dev/null || echo ERR)"
NDENY="$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["permissions"]["deny"]))' "$R/.claude/settings.json" 2>/dev/null)"
WRONG="$(printf '%06d' $(( (10#${C1:-0} + 1) % 1000000 )))"
upd msg "$ME" "$ME" "/pair $WRONG"
HARNESS_NOW=$((T0 + 10)) cycle
expect "pair: run --once exit 0" 0 "$RC"
expect "pair: wrong code -> not paired" "" "$(cfg paired_user_id)"
expect "pair: open gate not sent before pairing" 0 "$(nsent G-T101-1)"

C2="$(setup $((T0 + 100)))"
expect "setup again: deny rules not duplicated" "$NDENY" "$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["permissions"]["deny"]))' "$R/.claude/settings.json" 2>/dev/null)"
HARNESS_NOW=$((T0 + 100 + 601)) cycle
expect "pair v2: expired code cleaned up by the next cycle (no pairing state left)" "api chat_id paired_user_id token" "$(cfgkeys)"
upd msg "$ME" "$ME" "/pair $C2"
HARNESS_NOW=$((T0 + 100 + 602)) cycle
expect "pair: expired code (10 min + 1 s) -> not paired" "" "$(cfg paired_user_id)"
expect "pair: chat_id not saved before pairing" "" "$(cfg chat_id)"

C3="$(setup $((T0 + 1000)))"
expect "setup again: new code" yes "$([ -n "$C3" ] && echo yes || echo no)"
W3="$(printf '%06d' $(( (10#${C3:-0} + 7) % 1000000 )))"
for _ in 1 2 3 4 5; do upd msg 3003 3003 "/pair $W3"; done
upd msg 3003 3003 "/pair $C3"                               # 第 6 次：已经超过这个人的 5 次
upd msg "$ME" -5005 "/pair $C3" group                        # 群聊里的 /pair 不理
HARNESS_NOW=$((T0 + 1020)) cycle
expect "pair v2: 6th try (right code) after 5 wrong ones from that user -> not paired" "" "$(cfg paired_user_id)"
expect "pair v2: /pair in a group chat ignored" "" "$(cfg chat_id)"
expect "pair v2: no reply to the guesser or the group" 0 "$(rq "len([e for e in R if str(p(e,'chat_id')) in ('3003', '-5005')])")"
upd msg "$ME" "$ME" "/pair $C3"
HARNESS_NOW=$((T0 + 1030)) cycle
expect "pair: right code within 10 min -> paired user id saved" "$ME" "$(cfg paired_user_id)"
expect "pair: chat id saved" "$ME" "$(cfg chat_id)"
expect "pair: config still mode 600 after pairing" 600 "$(stat -c %a "$CFG" 2>/dev/null || stat -f %Lp "$CFG" 2>/dev/null || echo none)"
expect "pair v2: another user's wrong guesses did not burn your code" "$ME" "$(cfg paired_user_id)"
expect "pair v2: pairing state cleaned after pairing" "api chat_id paired_user_id token" "$(cfgkeys)"
upd msg "$STRANGER" "$STRANGER" "/pair $C3"
HARNESS_NOW=$((T0 + 1040)) cycle
expect "pair: code is one-time (stranger reusing it does not re-pair)" "$ME" "$(cfg paired_user_id)"
expect "pair: stranger got no reply" 0 "$(rq "len([e for e in R if str(p(e,'chat_id'))=='$STRANGER'])")"

# ================================================================ 推送（S-002 #14：两个周期内发出；按钮只含门卡号与选项）
cycle 2
expect "send: new gate sent within two cycles (exactly once)" 1 "$(nsent G-T101-1)"
expect "send: sent to the paired chat" "$ME" "$(rq "sends('G-T101-1')[0]['params'].get('chat_id')")"
expect "send: text has the title" yes "$(rq "'用哪个数据库' in sends('G-T101-1')[0]['params']['text']" | sed 's/True/yes/;s/False/no/')"
expect "send: text has the options" yes "$(rq "all(x in sends('G-T101-1')[0]['params']['text'] for x in ('Postgres 主库', 'SQLite 单文件'))" | sed 's/True/yes/;s/False/no/')"
expect "send: text has the kind" yes "$(rq "'design' in sends('G-T101-1')[0]['params']['text']" | sed 's/True/yes/;s/False/no/')"
expect "send: buttons are <GID>|<LETTER>" "G-T101-1|A G-T101-1|B" "$(rq "' '.join(sorted(btns(sends('G-T101-1')[0])))")"
M1="$(mid_of G-T101-1)"
expect "send: message id recorded in state_dir/inbox.json" yes "$(grep -q "G-T101-1" "$SD/inbox.json" 2>/dev/null && grep -qw "$M1" "$SD/inbox.json" && echo yes || echo no)"
cycle
expect "send: not re-sent on the next cycle" 1 "$(nsent G-T101-1)"
expect "poll: getUpdates timeout = HARNESS_TELEGRAM_POLL (1)" 1 "$(rq "[e for e in R if e['method']=='getUpdates'][-1]['params'].get('timeout')")"
HARNESS_TELEGRAM_POLL=3 cycle
expect "poll: HARNESS_TELEGRAM_POLL=3 -> timeout 3" 3 "$(rq "[e for e in R if e['method']=='getUpdates'][-1]['params'].get('timeout')")"
HARNESS_TELEGRAM_POLL=60 cycle
expect "poll: HARNESS_TELEGRAM_POLL=60 -> timeout capped at <= 20" yes "$(rq "0 < int([e for e in R if e['method']=='getUpdates'][-1]['params'].get('timeout')) <= 20" | sed 's/True/yes/;s/False/no/')"
expect "poll: every getUpdates long-polls with timeout <= 20" yes "$(rq "len([e for e in R if e['method']=='getUpdates']) > 0 and all(0 < int(p(e,'timeout',0)) <= 20 for e in R if e['method']=='getUpdates')" | sed 's/True/yes/;s/False/no/')"

# 跨 worktree：任务自己的 worktree 里的门卡发；放在别的任务 worktree 里的同名卡不发（T-010 的门卡解析）
git worktree add -q -b task/T-102-x .claude/worktrees/T-102
WT="$R/.claude/worktrees/T-102"
gate "$WT" G-T102-1 design '缓存放哪？' 'Redis' '内存'
gate "$WT" G-T103-1 design '伪造的门卡' '甲' '乙'
cycle 2
expect "worktree: gate in the task's own worktree sent" 1 "$(nsent G-T102-1)"
expect "worktree: planted card in another task's worktree not sent" 0 "$(nsent G-T103-1)"

# 正文只取 meta 快照：先快照，再改卡（类别、标题、选项）
gate "$R" G-T104-1 irreversible '删除旧表吗？' '删除旧表 legacy_orders' '保留旧表'
(cd "$R" && "$PY" -B .claude/hooks/harness_lib.py show G-T104-1 > /dev/null 2>&1)
sed -i.bak -e 's/^kind: .*/kind: design/' -e 's/删除旧表吗？/随便问问/' -e 's/删除旧表 legacy_orders/什么都不做/' "$R/.harness/gates/G-T104-1.md" && rm -f "$R/.harness/gates/G-T104-1.md.bak"
gate "$R" G-T105-1 unlock '解锁脚本目录？' '解锁' '不解锁'
cycle 2
TX4="$(rq "sends('G-T104-1')[0]['params']['text']")"
expect "meta: relabeled gate still sent once" 1 "$(nsent G-T104-1)"
expect "meta: message shows the snapshot kind (irreversible)" yes "$(case "$TX4" in *irreversible*) echo yes;; *) echo no;; esac)"
expect "meta: message shows the snapshot option text" yes "$(case "$TX4" in *legacy_orders*) echo yes;; *) echo no;; esac)"
expect "meta: message does not show the edited option" no "$(case "$TX4" in *什么都不做*) echo yes;; *) echo no;; esac)"
expect "meta: message does not show the edited title" no "$(case "$TX4" in *随便问问*) echo yes;; *) echo no;; esac)"
expect "meta: unlock gate shows the unlock paths" yes "$(rq "'scripts/**' in sends('G-T105-1')[0]['params']['text']" | sed 's/True/yes/;s/False/no/')"
M4="$(mid_of G-T104-1)"; M5="$(mid_of G-T105-1)"
TX1="$(rq "sends('G-T101-1')[0]['params']['text']")"; TX5="$(rq "sends('G-T105-1')[0]['params']['text']")"
expect "meaning v2: approval kind shows 选 A = 批准，其他 = 拒绝 (from the snapshot kind)" yes "$(case "$TX4" in *"选 A = 批准，其他 = 拒绝"*) echo yes;; *) echo no;; esac)"
expect "meaning v2: unlock shows 批准后放开 with the paths" yes "$(case "$TX5" in *批准后放开*'scripts/**'*) echo yes;; *) echo no;; esac)"
expect "meaning v2: unlock (approval kind) shows 选 A = 批准，其他 = 拒绝" yes "$(case "$TX5" in *"选 A = 批准，其他 = 拒绝"*) echo yes;; *) echo no;; esac)"
expect "meaning v2: design gate has no approval line" no "$(case "$TX1" in *"选 A = 批准"*) echo yes;; *) echo no;; esac)"
expect "buttons v2: approval kind A labelled 'A 批准'" yes "$(case "$(btntext G-T104-1 'G-T104-1|A')" in *"A 批准"*) echo yes;; *) echo no;; esac)"
expect "buttons v2: approval kind B labelled 'B 拒绝'" yes "$(case "$(btntext G-T104-1 'G-T104-1|B')" in *"B 拒绝"*) echo yes;; *) echo no;; esac)"
expect "buttons v2: unlock A labelled 'A 批准'" yes "$(case "$(btntext G-T105-1 'G-T105-1|A')" in *"A 批准"*) echo yes;; *) echo no;; esac)"

# ================================================================ 陌生人与自由文本（S-002 #14：只接受已配对的 user id）
N0="$(nlines)"
upd msg "$STRANGER" "$STRANGER" "G-T101-1: A"
upd cb cbS1 "$STRANGER" "$STRANGER" "$M1" "G-T101-1|A"
upd cb cbS2 "$STRANGER" "$ME" "$M1" "G-T101-1|A"            # 同一个聊天里，但不是已配对的人
upd cb cbS3 "$STRANGER" "$ME" "$M4" "G-T104-1|A|ok"
upd msg "$ME" "$ME" "G-T101-1: A"                           # 自由文本不是答复
upd msg "$ME" "$ME" "A"
cycle
expect "stranger: run exit 0" 0 "$RC"
expect "stranger: callbacks/messages record nothing" "none none" "$(st G-T101-1 letter) $(st G-T104-1 letter)"
expect "stranger: no reply to the stranger's chat" 0 "$(rq "len([e for e in R if str(p(e,'chat_id'))=='$STRANGER'])")"
expect "stranger: callbacks not answered" "none none none" "$(acq cbS1) $(acq cbS2) $(acq cbS3)"
expect "stranger/free text: nothing but polling happened" 0 "$(rq "len([e for e in R[$N0:] if e['method']!='getUpdates'])")"

# ================================================================ 按钮回调（S-002 #14 #8）
upd cb cb1 "$ME" "$ME" "$M1" "G-T101-1|B"
cycle
expect "tap: normal kind recorded at once" B "$(st G-T101-1 letter)"
expect "tap: via Telegram" Telegram "$(st G-T101-1 via)"
expect "tap: B is not an approval" false "$(st G-T101-1 approved)"
expect "tap: message edited to show the result" yes "$(rq "any(e['method']=='editMessageText' and str(p(e,'message_id'))=='$M1' and 'B' in str(p(e,'text')) for e in R)" | sed 's/True/yes/;s/False/no/')"
expect "tap: callback answered" yes "$([ "$(acq cb1)" != none ] && echo yes || echo no)"
expect "tap: settled -> card mirror status answered" answered "$(fm "$R/.harness/gates/G-T101-1.md" status)"
expect "tap: settled -> decisions.md logs via Telegram" 1 "$(grep -F 'G-T101-1' "$R/.harness/decisions.md" | grep -c 'Telegram')"
expect "tap: settled -> waiting task resumes (in_progress)" in_progress "$(fm "$R/.harness/tasks/T-101-x.md" status)"

upd cb cb2 "$ME" "$ME" "$M1" "G-T101-1|A"
cycle
expect "double tap: 已经答过了" yes "$(case "$(acq cb2)" in *已经答过了*) echo yes;; *) echo no;; esac)"
expect "double tap: first answer kept" B "$(st G-T101-1 letter)"

gate "$R" G-T106-1 design '日志格式？' 'JSON' '文本'
cycle 2
M6="$(mid_of G-T106-1)"
(cd "$R" && "$PY" -B .claude/hooks/harness_lib.py answer G-T106-1 A --yes > /dev/null 2>&1)
upd cb cb6 "$ME" "$ME" "$M6" "G-T106-1|B"
cycle
expect "answered elsewhere first: 已经答过了" yes "$(case "$(acq cb6)" in *已经答过了*) echo yes;; *) echo no;; esac)"
expect "answered elsewhere first: terminal answer kept" "A 终端" "$(st G-T106-1 letter) $(st G-T106-1 via)"

gate "$R" G-T107-1 design '端口？' '8080' '9090'
cycle 2
M7="$(mid_of G-T107-1)"
upd cb cb7 "$ME" "$ME" "$M7" "G-T107-1|Z"
upd cb cb8 "$ME" "$ME" "$M7" "../../evil|A"
upd cb cb9 "$ME" "$ME" "$M7" "G-T107-1"
cycle
expect "bad data: run exit 0" 0 "$RC"
expect "bad data: letter not in the snapshot options -> nothing recorded" none "$(st G-T107-1 letter)"
expect "bad data: no file outside the store" 0 "$(find "$T" -name 'evil*' 2>/dev/null | wc -l | tr -d ' ')"

# 不可逆类（以快照的 kind 判定）二次确认
upd cb cb10 "$ME" "$ME" "$M4" "G-T104-1|A"
cycle
expect "irreversible: first tap records nothing" none "$(st G-T104-1 letter)"
expect "irreversible: a confirm button <GID>|A|ok is offered" yes "$(rq "any('G-T104-1|A|ok' in btns(e) for e in R if e['method'] in ('sendMessage','editMessageText'))" | sed 's/True/yes/;s/False/no/')"
upd cb cb11 "$ME" "$ME" "$M4" "G-T104-1|A|ok"
cycle
expect "irreversible: confirm records A" A "$(st G-T104-1 letter)"
expect "irreversible: via Telegram, approved" "Telegram true" "$(st G-T104-1 via) $(st G-T104-1 approved)"
expect "irreversible: kind recorded from the snapshot" irreversible "$(st G-T104-1 kind)"
upd cb cb12 "$ME" "$ME" "$M5" "G-T105-1|A"
cycle
expect "unlock: first tap records nothing" none "$(st G-T105-1 letter)"
upd cb cb13 "$ME" "$ME" "$M5" "G-T105-1|A|ok"
cycle
expect "unlock: confirm records A via Telegram" "A Telegram" "$(st G-T105-1 letter) $(st G-T105-1 via)"
# ---------------------------------------------------------------- v2：二次确认按效果判定（S-002 #14「以动作判定」）
gate "$R" G-T109-1 ui '确认任务卡？' '确认' '再改改' 'then: ready' 'then_tasks: [T-109]'
gate "$R" G-T110-1 ui '按钮颜色？' '蓝' '绿'
gate "$R" G-T110-2 ui '合并截图 PR？' '合并' '不合并'
gate "$R" G-T111-1 design '分层方式？' '按领域' '按技术'
"$PY" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; H.record_pr(Path(sys.argv[2]), "G-T110-2", 7)' "$HK" "$R"
cycle 2
TX9="$(rq "sends('G-T109-1')[0]['params']['text']")"
expect "meaning v2: then: ready shows 批准后变为 ready with then_tasks" yes "$(case "$TX9" in *"批准后变为 ready"*T-109*) echo yes;; *) echo no;; esac)"
M9="$(mid_of G-T109-1)"; M10="$(mid_of G-T110-1)"; M12="$(mid_of G-T110-2)"; M11="$(mid_of G-T111-1)"
upd cb cb20 "$ME" "$ME" "$M7" "G-T110-1|A"                  # 按钮不是那条消息上的（message_id 对不上）
upd cb cb21 "$ME" "$ME" "$M11" "G-T111-1|A|ok"              # 没点过第一次就伪造「确认」
upd cb cb22 "$ME" "$ME" "$M9" "G-T109-1|A|ok"
cycle
expect "v2: tap with a mismatched message_id records nothing" none "$(st G-T110-1 letter)"
expect "v2: forged |ok without a first tap records nothing" "none none" "$(st G-T111-1 letter) $(st G-T109-1 letter)"
upd cb cb23 "$ME" "$ME" "$M10" "G-T110-1|A"
upd cb cb24 "$ME" "$ME" "$M9" "G-T109-1|A"
upd cb cb25 "$ME" "$ME" "$M12" "G-T110-2|A"
upd cb cb26 "$ME" "$ME" "$M11" "G-T111-1|A"
cycle
expect "effect v2: ui gate without effects: A recorded at once" "A Telegram" "$(st G-T110-1 letter) $(st G-T110-1 via)"
expect "effect v2: then: ready gate: first A tap records nothing" none "$(st G-T109-1 letter)"
expect "effect v2: gate with a recorded PR: first A tap records nothing" none "$(st G-T110-2 letter)"
expect "effect v2: design gate: first A tap records nothing" none "$(st G-T111-1 letter)"
expect "effect v2: confirm offered for then/PR/design gates" "yes yes yes" "$(okoffered G-T109-1) $(okoffered G-T110-2) $(okoffered G-T111-1)"
upd cb cb27 "$ME" "$ME" "$M9" "G-T109-1|A|ok"
upd cb cb28 "$ME" "$ME" "$M12" "G-T110-2|A|ok"
upd cb cb29 "$ME" "$ME" "$M11" "G-T111-1|A|ok"
cycle
expect "effect v2: confirms record A" "A A A" "$(st G-T109-1 letter) $(st G-T110-2 letter) $(st G-T111-1 letter)"
expect "effect v2: then: ready applied after a confirmed Telegram approval" ready "$(fm "$R/.harness/tasks/T-109-x.md" status)"

# ---------------------------------------------------------------- v2：改消息 / 回调应答出错时本周期照常继续
gate "$R" G-T112-1 design '出错一？' '甲' '乙'
gate "$R" G-T112-2 design '出错二？' '甲' '乙'
cycle 2
M13="$(mid_of G-T112-1)"; M14="$(mid_of G-T112-2)"
printf 'editMessageText\nanswerCallbackQuery\n' > "$FT/fail_methods"
gate "$R" G-T113-1 design '出错时也发吗？' '发' '不发'
upd cb cb30 "$ME" "$ME" "$M13" "G-T112-1|B"
upd cb cb31 "$ME" "$ME" "$M14" "G-T112-2|B"
to "${HARNESS[@]}" inbox run --once --repo "$R" > "$T/err.out" 2>&1 < /dev/null; RC=$?; cat "$T/err.out" >> "$OUTALL"
rm -f "$FT/fail_methods"
expect "api error v2: run --once exits 0" 0 "$RC"
expect "api error v2: both taps recorded although edit/answer failed" "B B" "$(st G-T112-1 letter) $(st G-T112-2 letter)"
expect "api error v2: new gate still sent in the same cycle" 1 "$(nsent G-T113-1)"
expect "api error v2: entry marked closed although the edit failed" "true true" "$(closed G-T112-1) $(closed G-T112-2)"
expect "api error v2: error logged" yes "$([ -s "$T/err.out" ] && echo yes || echo no)"

# ---------------------------------------------------------------- v2：卡消失后又出现 → 重发；点关掉的旧消息无效
gate "$R" G-T110-3 ui '要不要暗色？' '要' '不要'
cycle 2
M15="$(mid_of G-T110-3)"
mv "$R/.harness/gates/G-T110-3.md" "$T/G-T110-3.md.away"
cycle
expect "reappear v2: vanished gate's entry closed" true "$(closed G-T110-3)"
mv "$T/G-T110-3.md.away" "$R/.harness/gates/G-T110-3.md"
upd cb cb32 "$ME" "$ME" "$M15" "G-T110-3|B"
cycle 2
expect "reappear v2: tap on the closed old message records nothing" none "$(st G-T110-3 letter)"
expect "reappear v2: gate re-sent after it reappeared" 2 "$(nsent G-T110-3)"
M16="$(rq "(sends('G-T110-3') or [{}])[-1].get('message_id')")"
upd cb cb33 "$ME" "$ME" "$M16" "G-T110-3|B"
cycle
expect "reappear v2: tap on the new message records" "B Telegram" "$(st G-T110-3 letter) $(st G-T110-3 via)"

expect "buttons: every callback_data is <GID>|<LETTER>[|ok] and <= 64 bytes" yes "$(rq "any(btns(e) for e in R) and all(__import__('re').fullmatch(r'G-[A-Za-z0-9-]+\|[A-Z](\|ok)?', d) and len(d.encode()) <= 64 for e in R if e['method'] in ('sendMessage','editMessageText') for d in btns(e))" | sed 's/True/yes/;s/False/no/')"

# ================================================================ token 不外泄（S-002 #14）
touch "$FT/fail"; cycle; rm -f "$FT/fail"
expect "401 from the API: error output does not contain the token" no "$(grep -qF "$SECRET" "$OUTALL" && echo yes || echo no)"
HARNESS_TELEGRAM_API="http://127.0.0.1:1" cycle
expect "API unreachable: error output does not contain the token" no "$(grep -qF "$SECRET" "$OUTALL" && echo yes || echo no)"

# ================================================================ start / status / stop（pid 文件复用 T-013 格式）
RUN="$SD/run"
to "${HARNESS[@]}" inbox start --repo "$R" > "$T/start.out" 2>&1 < /dev/null; RC=$?; cat "$T/start.out" >> "$OUTALL"
expect "start: exit 0" 0 "$RC"
sleep 0.5
PF="$(ls "$RUN"/inbox-*.pid 2>/dev/null | head -1)"
BP=""; [ -n "$PF" ] && { BP="$(basename "$PF" .pid)"; BP="${BP#inbox-}"; }
expect "start: pid file run/inbox-<pid>.pid" yes "$([ -n "$PF" ] && echo yes || echo no)"
expect "start: pid file content '<pid> <starttime>'" yes "$([ -n "$BP" ] && [ "$(cat "$PF")" = "$BP $(starttime "$BP")" ] && echo yes || echo no)"
expect "start: bot alive" yes "$(yn alive "${BP:-999999999}")"
expect "start: cmdline contains harness" yes "$(tr '\0' ' ' < "/proc/$BP/cmdline" 2>/dev/null | grep -q harness && echo yes || echo no)"
expect "start: token not on the bot's command line" no "$(tr '\0' ' ' < "/proc/$BP/cmdline" 2>/dev/null | grep -qF "$SECRET" && echo yes || echo no)"
to "${HARNESS[@]}" inbox status --repo "$R" > "$T/status.out" 2>&1 < /dev/null; cat "$T/status.out" >> "$OUTALL"
expect "status: shows the running pid" yes "$([ -n "$BP" ] && grep -qw -- "$BP" "$T/status.out" && echo yes || echo no)"
gate "$R" G-T108-1 design '背景进程能发吗？' '能' '不能'
for _ in $(seq 100); do [ "$(nsent G-T108-1)" = 1 ] && break; sleep 0.1; done
expect "start: background bot sends a new gate" 1 "$(nsent G-T108-1)"
R2="$T/repo2"; mkdir -p "$R2" && git -C "$R2" init -q -b main && git -C "$R2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
SD2="$("$PY" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.state_dir(Path(sys.argv[2]).resolve()))' "$HK" "$R2")"
to "${HARNESS[@]}" inbox start --repo "$R2" > "$T/start2.out" 2>&1 < /dev/null; RC=$?; cat "$T/start2.out" >> "$OUTALL"
expect "one bot per token v2: start from another repo refused (non-zero)" yes "$([ "$RC" -ne 0 ] && echo yes || echo no)"
expect "one bot per token v2: refusal names the running bot's pid" yes "$([ -n "$BP" ] && grep -qw -- "$BP" "$T/start2.out" && echo yes || echo no)"
expect "one bot per token v2: no bot started for repo2" "0 1" "$(ls "$SD2"/run/inbox-*.pid 2>/dev/null | wc -l | tr -d ' ') $(bots | wc -l | tr -d ' ')"
expect "one bot per token v2: first bot still alive" yes "$(yn alive "${BP:-999999999}")"
expect "one bot per token v2: bot pid/lock recorded in config_dir" yes "$([ -n "$BP" ] && grep -rlw -- "$BP" "$T/config/harness" 2>/dev/null | grep -vqxF "$CFG" && echo yes || echo no)"
# 退避不超过 HARNESS_TELEGRAM_POLL（=1）：API 连续出错 5 秒，恢复后很快接上
N1="$(nlines)"
touch "$FT/fail"; sleep 5; rm -f "$FT/fail"
gate "$R" G-T113-2 design '恢复后多快？' '快' '慢'
for _ in $(seq 30); do [ "$(nsent G-T113-2)" = 1 ] && break; sleep 0.1; done
expect "backoff v2: bot resumes within ~POLL after 5 s of API errors" 1 "$(nsent G-T113-2)"
expect "backoff v2: polls kept coming while failing (max gap <= POLL + 1.5 s)" yes "$(rq "(lambda ts: len(ts) >= 3 and max(b - a for a, b in zip(ts, ts[1:])) <= 2.5)([e['t'] for e in R[$N1:] if e['method'] == 'getUpdates'])" | sed 's/True/yes/;s/False/no/')"
to "${HARNESS[@]}" inbox start --repo "$R" >> "$OUTALL" 2>&1 < /dev/null
expect "start twice: still one bot" 1 "$(ls "$RUN"/inbox-*.pid 2>/dev/null | wc -l | tr -d ' ')"
to "${HARNESS[@]}" inbox stop --repo "$R" > "$T/stop.out" 2>&1 < /dev/null; RC=$?; cat "$T/stop.out" >> "$OUTALL"
expect "stop: exit 0" 0 "$RC"
expect "stop: bot stopped" yes "$([ -n "$BP" ] && gone "$BP" && echo yes || echo no)"
expect "stop: pid file removed" "yes 0" "$([ -n "$PF" ] && echo yes || echo no) $(ls "$RUN"/inbox-*.pid 2>/dev/null | wc -l | tr -d ' ')"
to "${HARNESS[@]}" inbox status --repo "$R" > "$T/status2.out" 2>&1 < /dev/null; cat "$T/status2.out" >> "$OUTALL"
expect "status after stop: pid not shown" "yes no" "$([ -n "$BP" ] && echo yes || echo no) $(grep -qw -- "${BP:-x}" "$T/status2.out" && echo yes || echo no)"
to "${HARNESS[@]}" inbox start --repo "$R" >> "$OUTALL" 2>&1 < /dev/null; sleep 0.5
PF2="$(ls "$RUN"/inbox-*.pid 2>/dev/null | head -1)"; BP2="$(cut -d' ' -f1 "$PF2" 2>/dev/null)"
to "${HARNESS[@]}" down --repo "$R" >> "$OUTALL" 2>&1 < /dev/null
expect "harness down stops the bot (T-013 pid format)" yes "$([ -n "$BP2" ] && gone "$BP2" && echo yes || echo no)"
expect "harness down removes the bot's pid file" "yes 0" "$([ -n "$PF2" ] && echo yes || echo no) $(ls "$RUN"/inbox-*.pid 2>/dev/null | wc -l | tr -d ' ')"
# v2：并发 start → 只有一个 bot
CP=""; for _ in 1 2 3 4; do (to "${HARNESS[@]}" inbox start --repo "$R" >> "$T/cc.out" 2>&1 < /dev/null) & CP="$CP $!"; done; wait $CP
cat "$T/cc.out" >> "$OUTALL" 2>/dev/null; sleep 1
expect "concurrent start v2: exactly one bot process" 1 "$(bots | wc -l | tr -d ' ')"
expect "concurrent start v2: exactly one pid file" 1 "$(ls "$RUN"/inbox-*.pid 2>/dev/null | wc -l | tr -d ' ')"
to "${HARNESS[@]}" inbox stop --repo "$R" >> "$OUTALL" 2>&1 < /dev/null
for pid in $(bots); do kill "$pid" 2>/dev/null; done

# ================================================================ token 不出现在仓库、日志、状态目录、任何输出里
expect "token: absent from all command outputs" no "$(grep -qF "$SECRET" "$OUTALL" && echo yes || echo no)"
LEAK="$(grep -rlF "$SECRET" "$T" 2>/dev/null | grep -vxF "$CFG" | head -3 | tr '\n' ' ')"
expect "token: absent from every file but telegram.json (repo, state, logs, fake API log)" "" "$LEAK"
expect "token: not committed or tracked in the repo" no "$(git -C "$R" grep -qF "$SECRET" 2>/dev/null && echo yes || echo no)"

echo "$((N - FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
