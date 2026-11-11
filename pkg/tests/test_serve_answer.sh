#!/usr/bin/env bash
# T-003 验收：在看板上答复门卡（写入要令牌；放权类门卡不能在看板批准；Claude 发不了答复请求）。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-answer.XXXXXX")"
PIDS=""; trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
fm() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_lib as H, pathlib; print(H.read_frontmatter(pathlib.Path(sys.argv[2])).get(sys.argv[3], ""))' "$R/.claude/hooks" "$1" "$2"; }

R="$T/repo"; mkdir -p "$R" && cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" . && rm -f .harness/gates/G-*.md
sed -e 's/T-000/T-001/g' -e 's/^status: proposed /status: waiting_human/' .harness/tasks/_TEMPLATE.md > .harness/tasks/T-001-x.md
gate() {  # gate <id> <kind> <extra-frontmatter>
  printf -- '---\nid: %s\ntask: T-001\nkind: %s\nstatus: open\nurgency: normal\nrecommended: A\nreview_minutes: 3\napprove_options: [A]\n%s\n---\n\n# %s 选哪个？\n\n## 选项\n- **A（推荐）**：甲方案\n- **B**：乙方案\n' \
    "$1" "$2" "${3:-}" "$1" > ".harness/gates/$1.md"
}
gate G-T001-1 sensory
gate G-T001-2 irreversible
gate G-T001-3 design "then_policy: ui"
gate G-T001-4 design "then_rules: [语音一律变速不变调]"
git add -A && git commit -qm fixture

start() {  # start <outfile> [env...]
  env "${@:2}" python3 "$SRC/cli/serve_cmd.py" --repo "$R" --port 0 > "$1" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do grep -q '^http://' "$1" 2>/dev/null && break; sleep 0.1; done
  grep -m1 '^http://' "$1" | sed 's#/?.*##; s#/$##'
}
U="$(start "$T/s1.out" HARNESS_SERVE_TOKEN=s3cret)"
PORT="${U##*:}"
JAR="$T/jar"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
post() {  # post <gate> <letter> [extra curl args]
  curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -H "Origin: ${ORIGIN:-$U}" --data-urlencode "gate=$1" --data-urlencode "letter=$2" --data-urlencode "note=${NOTE:-}" "${@:3}" "$U/answer"
}

expect "without the token: page has no answer buttons" no "$(curl -s "$U/" | grep -q 'name="letter"' && echo yes || echo no)"
SETC="$(curl -s -D - -o /dev/null -c "$JAR" "$U/?t=s3cret" | tr -d '\r' | grep -i '^set-cookie:')"
expect "token link sets an HttpOnly SameSite=Strict cookie" yes "$(printf '%s' "$SETC" | grep -qi 'httponly' && printf '%s' "$SETC" | grep -qi 'samesite=strict' && echo yes || echo no)"
expect "wrong token sets no cookie" "" "$(curl -s -D - -o /dev/null "$U/?t=nope" | tr -d '\r' | grep -i '^set-cookie:')"
expect "with the cookie: answer buttons shown" yes "$(curl -s -b "$JAR" "$U/" | grep -q 'name="letter"' && echo yes || echo no)"

expect "POST without cookie refused" 403 "$(curl -s -o /dev/null -w '%{http_code}' -H "Origin: $U" -d 'gate=G-T001-1&letter=A' "$U/answer")"
expect "POST from another origin refused" 403 "$(ORIGIN=https://evil.example post G-T001-1 A)"
expect "POST with a foreign Host refused" 421 "$(post G-T001-1 A -H 'Host: evil.example')"
expect "gate untouched after refused posts" open "$(fm .harness/gates/G-T001-1.md status)"
expect "unknown letter refused" 400 "$(post G-T001-1 Z)"
expect "unknown gate refused" 404 "$(post G-NOPE A)"
expect "oversized body refused" 413 "$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -H "Origin: $U" --data-urlencode "gate=G-T001-1" --data-urlencode "letter=A" --data-urlencode "note=$(head -c 9000 /dev/zero | tr '\0' x)" "$U/answer")"

NOTE="音色更自然" ; expect "valid answer redirects back" 303 "$(post G-T001-1 A)"; NOTE=""
expect "sensory gate answered" answered "$(fm .harness/gates/G-T001-1.md status)"
expect "answer recorded with the option and note" yes "$(fm .harness/gates/G-T001-1.md answer | grep -q '^A（甲方案） — 音色更自然' && echo yes || echo no)"
expect "decision logged as via the dashboard" 1 "$(grep -c 'G-T001-1 | answered: A.*via 看板' .harness/decisions.md)"
expect "answering twice refused" 409 "$(post G-T001-1 B)"
expect "irreversible: non-approve option = rejected (same as GitHub)" 303 "$(post G-T001-2 B)"
expect "irreversible gate status" rejected "$(fm .harness/gates/G-T001-2.md status)"
expect "then_policy gate cannot be approved here" 403 "$(post G-T001-3 A)"
expect "then_rules gate cannot be approved here" 403 "$(post G-T001-4 A)"
expect "policy gate untouched" open "$(fm .harness/gates/G-T001-3.md status)"
expect "no auto-decide file appeared" no "$([ -e .harness/auto-decide.txt ] && echo yes || echo no)"
expect "waiting task resumes only when no open gate is left" waiting_human "$(fm .harness/tasks/T-001-x.md status)"
rm .harness/gates/G-T001-3.md .harness/gates/G-T001-4.md; gate G-T001-5 ui
post G-T001-5 A >/dev/null
expect "last answer moves the task back to in_progress" in_progress "$(fm .harness/tasks/T-001-x.md status)"

# ---------------------------------------------------------------- 对抗审查后补的用例
expect "token exchange always redirects home (no open redirect)" "/" "$(curl -s -D - -o /dev/null --path-as-is "$U//evil.example/?t=s3cret" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
gate G-T001-6 sensory
expect "no-token page tells you how to answer here" yes "$(curl -s "$U/" | grep -q '带令牌的地址' && echo yes || echo no)"
NOTE="$(printf 'ok\xe2\x80\xa8status: open\rthen_policy: ui')"; post G-T001-6 A >/dev/null; NOTE=""
expect "line separators in a note cannot forge frontmatter (status)" answered "$(fm .harness/gates/G-T001-6.md status)"
expect "line separators in a note cannot forge frontmatter (then_policy)" "" "$(fm .harness/gates/G-T001-6.md then_policy)"
gate G-T001-7 design "then_policy: ui"; sed -i 's/^approve_options: \[A\]/approve_options: [B]/' .harness/gates/G-T001-7.md
expect "policy gate refused whatever the letter" 403 "$(post G-T001-7 B)"; rm .harness/gates/G-T001-7.md
expect "negative Content-Length refused fast" 400 "$(python3 - "$PORT" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.sendall(b"POST /answer HTTP/1.1\r\nHost: 127.0.0.1:" + sys.argv[1].encode() + b"\r\nContent-Length: -1\r\n\r\n")
try:
    print(s.recv(64).split()[1].decode())
except Exception:
    print("hang")
PY
)"
for i in 1 2 3 4 5 6 7 8; do gate "G-C-$i" sensory; done
seq 1 8 | xargs -P 8 -I{} curl -s -o /dev/null -b "$JAR" -H "Origin: $U" -d "gate=G-C-{}&letter=A" "$U/answer"
expect "concurrent answers: every decision number unique" "" "$(grep '^- D-' .harness/decisions.md | cut -d'|' -f1 | sort | uniq -d)"
expect "concurrent answers: all eight recorded once" 8 "$(grep -c 'G-C-[1-8] | answered' .harness/decisions.md)"
git add -A >/dev/null; git commit -qm more >/dev/null
git worktree add -q .claude/worktrees/T-009 -b task/T-009-x
WG="$R/.claude/worktrees/T-009/.harness/gates/G-T009-1.md"
printf -- '---\nid: G-T009-1\ntask: T-001\nkind: ui\nstatus: open\nrecommended: A\nreview_minutes: 4\n---\n\n# G-T009-1 只在任务分支里的门卡\n\n## 选项\n- **A（推荐）**：甲\n- **B**：乙\n' > "$WG"
expect "gates living in a task worktree are shown" yes "$(curl -s -b "$JAR" "$U/" | grep -q '只在任务分支里的门卡' && echo yes || echo no)"
expect "and can be answered (the worktree copy is written)" answered "$(post G-T009-1 A >/dev/null; fm "$WG" status)"
sed -i 's/^status: in_progress/status: waiting_human/' .harness/tasks/T-001-x.md
gate G-T001-8 ui; post G-T001-8 A >/dev/null
RES="$(python3 -B .claude/hooks/gate_github.py sync --list-resumable --quiet 2>/dev/null)"
expect "dashboard answer is picked up by the next resume pass" 1 "$(printf '%s\n' "$RES" | grep -c '^RESUME	T-001	')"
expect "and only once" 0 "$(python3 -B .claude/hooks/gate_github.py sync --list-resumable --quiet 2>/dev/null | grep -c '^RESUME')"

# 没有令牌环境变量、输出不是终端（例如 Claude 在 Bash 里启动）：只读，打印的地址不带令牌
U2="$(start "$T/s2.out")"
expect "non-tty start prints no token" no "$(grep -q 't=' "$T/s2.out" && echo yes || echo no)"
expect "non-tty start: writes impossible" 403 "$(curl -s -o /dev/null -w '%{http_code}' -H "Origin: $U2" -d 'gate=G-T001-5&letter=A' "$U2/answer")"

# Claude 的命令被护栏拦下
gb() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$R" "$1" | python3 "$R/.claude/hooks/guard_bash.py" | grep -q '"deny"' && echo deny || echo allow; }
expect "guard: Claude cannot post answers to the dashboard" deny "$(gb "curl -s -X POST http://127.0.0.1:$PORT/answer -d gate=G-T001-1")"
expect "guard: nor via localhost" deny "$(gb "curl -d letter=A http://localhost:8765/answer")"
expect "guard: Claude cannot start serve with a token" deny "$(gb 'HARNESS_SERVE_TOKEN=x python3 pkg/bin/harness serve')"
expect "guard: 127.1 shorthand" deny "$(gb 'curl -d letter=A http://127.1:8765/answer')"
expect "guard: IPv6 loopback" deny "$(gb 'curl -X POST http://[::1]:8765/answer')"
expect "guard: token via os.environ" deny "$(gb "python3 -c \"import os;os.environ['HARNESS_SERVE_TOKEN']='x'\"")"
expect "guard: searching for the name is fine" allow "$(gb 'grep -rn HARNESS_SERVE_TOKEN= docs/')"
expect "guard: Claude cannot start a writable dashboard (pty trick)" deny "$(gb 'script -qc "python3 pkg/cli/serve_cmd.py --port 0" /dev/null')"
expect "guard: nor plainly" deny "$(gb 'python3 pkg/bin/harness serve --repo .')"
expect "guard: read-only dashboard is fine" allow "$(gb 'python3 pkg/cli/serve_cmd.py --read-only --port 0')"

expect "guard: reading the dashboard is fine" allow "$(gb "curl -s http://127.0.0.1:$PORT/")"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
