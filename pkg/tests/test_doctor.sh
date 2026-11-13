#!/usr/bin/env bash
# T-013 验收：harness doctor / down、定时任务到期（S-002 #16 #17）。按任务卡「接口约定」。
# 假 crontab（HARNESS_CRONTAB）把表存在文件里；PATH 上的 crontab 是陷阱，被调用就记下来——绝不碰你真实的 crontab。
# HARNESS_NOW 固定「现在」；测试用的 sleep 进程都脱离本脚本（由 init 回收），结束时一律清掉。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-doctor.XXXXXX")"; T="$(cd "$T" && pwd -P)"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
yn() { if "$@"; then echo yes; else echo no; fi; }
# sec FILE 标题 —— doctor 输出里某段的正文（标题行之后、下一个 ## 之前）
sec() { awk -v h="## $2" '$0==h{p=1;next} /^## /{p=0} p' "$1" 2>/dev/null; }
# alive PID —— 进程存在且不是僵尸
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  if [ -r "/proc/$1/stat" ]; then [ "$(sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f1)" != Z ]; fi
}
# gone PID —— 最多等 3 秒看进程是否结束
gone() { local i; for i in $(seq 30); do alive "$1" || return 0; sleep 0.1; done; return 1; }
# detached_sleep —— 启动一个不是本脚本子进程的 sleep 300，打印其 pid
detached_sleep() { sh -c 'sleep 300 >/dev/null 2>&1 </dev/null & echo $!'; }   # 调用方把 pid 加进 PIDS（$(...) 是子 shell）
endswith() { case "$1" in *"$2") return 0;; *) return 1;; esac; }

unset HARNESS_NOW HARNESS_CRON_DAYS HARNESS_UNATTENDED HARNESS_MODE HARNESS_PYTHON HARNESS_GH_TOKEN
export TZ=UTC XDG_STATE_HOME="$T/state" HARNESS_PLATFORM=macos HARNESS_GATE_CHANNEL=off
REALPY="$(command -v python3)"
HARNESS=("$REALPY" "$SRC/bin/harness")
D0101=1767225600; D0110=1768003200; D0131NOON=$((1769817600 + 43200)); D0201=1769904000

# ---------------------------------------------------------------- 假 crontab / 陷阱 / 假 python
BIN="$T/bin"; TRAPB="$T/trapbin"; mkdir -p "$BIN" "$TRAPB"
CRON="$T/crontab.txt"; export FAKE_CRON_FILE="$CRON"
cat > "$BIN/fake-crontab" <<'SH'
#!/bin/sh
F="${FAKE_CRON_FILE:?}"
case "${1:-}" in
  -l) [ -f "$F" ] || { echo "no crontab for user" >&2; exit 1; }; cat "$F" ;;
  -)  cat > "$F.tmp" && mv "$F.tmp" "$F" ;;
  *)  echo "fake crontab: unsupported: $*" >&2; exit 2 ;;
esac
SH
printf '#!/bin/sh\necho "$*" >> "%s/real-crontab-called"\nexit 1\n' "$T" > "$TRAPB/crontab"
chmod +x "$BIN/fake-crontab" "$TRAPB/crontab"
export HARNESS_CRONTAB="$BIN/fake-crontab"
export PATH="$TRAPB:$PATH"
SYNCLOG="$T/synced.log"; : > "$SYNCLOG"
cat > "$BIN/fakepy" <<SH
#!/bin/sh
for a in "\$@"; do case "\$a" in *gate_github.py) echo "\$*" >> "$SYNCLOG"; exit 0;; esac; done
exec "$REALPY" "\$@"
SH
chmod +x "$BIN/fakepy"
synced() { wc -l < "$SYNCLOG" | tr -d ' '; }
statedir() { "$REALPY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_lib as h; from pathlib import Path; print(h.state_dir(Path(sys.argv[2])))' "$SRC/.claude/hooks" "$1"; }

# ---------------------------------------------------------------- 夹具仓库
R="$T/repo"; OTHER="$T/repo-other"   # OTHER 与 R 共享前缀：匹配必须精确
mkdir -p "$R" && cd "$R" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p scripts .claude/hooks .harness/gates
cp "$SRC/scripts/gate-sync.sh" scripts/ && chmod +x scripts/gate-sync.sh
: > .claude/hooks/gate_github.py
printf '.claude/worktrees/\n.harness/logs/\n' > .gitignore
git add -A && git commit -qm init
git worktree add -q -b task/T-900-old .claude/worktrees/T-900
WT="$R/.claude/worktrees/T-900"
BACKUP='0 3 * * * /usr/bin/backup.sh'
OTHERLINE="*/5 * * * * cd \"$OTHER\" && scripts/gate-sync.sh --resume --quiet # harness repo=$OTHER expires=2020-01-01"
mine() { grep -F "# harness repo=$R expires=" "$CRON" 2>/dev/null; }
nmine() { mine | wc -l | tr -d ' '; }
cronhas() { grep -qxF -- "$1" "$CRON" 2>/dev/null && echo yes || echo no; }

# ================================================================ install-cron：标记 + 仓库 + 到期日
printf '%s\n%s\n' "$BACKUP" "$OTHERLINE" > "$CRON"
OUT="$(HARNESS_NOW=$D0101 scripts/gate-sync.sh install-cron 2>&1)"; RC=$?
expect "install-cron: exit 0" 0 "$RC"
expect "install-cron: exactly one line for this repo" 1 "$(nmine)"
expect "install-cron: line ends with '# harness repo=<repo> expires=<today+30>'" yes "$(yn endswith "$(mine)" "# harness repo=$R expires=2026-01-31")"
expect "install-cron: line runs gate-sync --resume" yes "$(mine | grep -qF 'scripts/gate-sync.sh --resume' && echo yes || echo no)"
expect "install-cron: line cds into the repo" yes "$(mine | grep -qF "cd \"$R\"" && echo yes || echo no)"
expect "install-cron: non-harness line kept" yes "$(cronhas "$BACKUP")"
expect "install-cron: other repo's harness line kept" yes "$(cronhas "$OTHERLINE")"
OUT="$(HARNESS_NOW=$D0101 HARNESS_CRON_DAYS=7 scripts/gate-sync.sh install-cron 2>&1)"; RC=$?
expect "install-cron: reinstall exit 0" 0 "$RC"
expect "install-cron: reinstall replaces (still one line)" 1 "$(nmine)"
expect "install-cron: HARNESS_CRON_DAYS=7 -> expires today+7" yes "$(yn endswith "$(mine)" "# harness repo=$R expires=2026-01-08")"
expect "install-cron: reinstall keeps non-harness line" yes "$(cronhas "$BACKUP")"
expect "install-cron: reinstall keeps other repo's line" yes "$(cronhas "$OTHERLINE")"

# ================================================================ 到期：移除自己、写提示、不同步
HARNESS_NOW=$D0101 scripts/gate-sync.sh install-cron >/dev/null 2>&1   # expires=2026-01-31
EXP="$R/.harness/reports/expired-cron.txt"
HARNESS_NOW=$D0131NOON HARNESS_PYTHON="$BIN/fakepy" scripts/gate-sync.sh --resume --quiet > "$T/s1.out" 2>&1; RC=$?
expect "expiry: on the expiry day exit 0" 0 "$RC"
expect "expiry: on the expiry day still syncs" 1 "$(synced)"
expect "expiry: on the expiry day the line stays" 1 "$(nmine)"
expect "expiry: on the expiry day no expired note" no "$([ -e "$EXP" ] && echo yes || echo no)"
HARNESS_NOW=$D0201 HARNESS_PYTHON="$BIN/fakepy" scripts/gate-sync.sh --resume --quiet > "$T/s2.out" 2>&1; RC=$?
expect "expiry: expired run exits 0" 0 "$RC"
expect "expiry: expired run does not sync" 1 "$(synced)"
expect "expiry: expired run removes its own line" 0 "$(nmine)"
expect "expiry: non-harness line kept" yes "$(cronhas "$BACKUP")"
expect "expiry: other repo's (also expired) line kept" yes "$(cronhas "$OTHERLINE")"
expect "expiry: note written to .harness/reports/expired-cron.txt" yes "$([ -s "$EXP" ] && echo yes || echo no)"
expect "expiry: note says 已到期" yes "$(has "$EXP" '已到期')"
expect "expiry: note has the expiry date" yes "$(has "$EXP" '2026-01-31')"
HARNESS_NOW=$D0201 HARNESS_PYTHON="$BIN/fakepy" scripts/gate-sync.sh --resume --quiet > "$T/s3.out" 2>&1; RC=$?
expect "expiry: without a harness line (manual run) it syncs" "0 2" "$RC $(synced)"
expect "expiry: note not duplicated by a run without a line" 1 "$(grep -c '已到期' "$EXP" 2>/dev/null)"

# ================================================================ doctor
RUN="$(statedir "$R")/run"; mkdir -p "$RUN"
S1="$(detached_sleep)"; PIDS="$PIDS $S1"; echo "$S1" > "$RUN/bot-test.pid"
S2="$(detached_sleep)"; PIDS="$PIDS $S2"                     # 不在 run/ 里：谁也不许碰它
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"; echo "$DEAD" > "$RUN/loop-$DEAD.pid"
SETSID=(); BADPID=abc
if setsid -w true 2>/dev/null; then SETSID=(setsid -w); BADPID=0; fi   # pid 0 = 整个进程组：只在隔离的会话里测
echo "$BADPID" > "$RUN/bad.pid"
gate() { printf -- '---\nid: %s\ntask: %s\nkind: ui\nstatus: %s\ncreated: %s\n---\n# q\n' "$1" "$2" "$3" "$4" > ".harness/gates/$1.md"; }
gate G-T901-1 T-901 open 2026-01-02
gate G-T902-1 T-902 open 2026-01-08
gate G-T903-1 T-903 approved 2025-12-01
printf '%s\n%s\n%s\n' "$BACKUP" \
  "*/5 * * * * cd \"$R\" && scripts/gate-sync.sh --resume --quiet # harness repo=$R expires=2026-01-31" \
  "*/5 * * * * cd \"$OTHER\" && scripts/gate-sync.sh --resume --quiet # harness repo=$OTHER expires=2026-01-05" > "$CRON"

DA="$T/docA.out"
(cd /; HARNESS_NOW=$D0110 HARNESS_PLATFORM=wsl1 "${HARNESS[@]}" doctor --repo "$R" > "$DA" 2>"$T/docA.err"); RC=$?
expect "doctor: exit 0" 0 "$RC"
expect "doctor: five sections in order" "## 定时任务|## 在跑的进程|## 久未动的 worktree|## 久未答的门卡|## 沙箱依赖" \
  "$(grep '^## ' "$DA" 2>/dev/null | paste -sd'|' -)"
expect "doctor cron: lists this repo's line with expiry" 1 "$(sec "$DA" 定时任务 | grep -cF "repo=$R expires=2026-01-31")"
expect "doctor cron: unexpired line not flagged" 0 "$(sec "$DA" 定时任务 | grep -F "repo=$R expires=2026-01-31" | grep -c '已过期')"
expect "doctor cron: other repo's expired line flagged 已过期" 1 "$(sec "$DA" 定时任务 | grep -F "repo=$OTHER expires=2026-01-05" | grep -c '已过期')"
expect "doctor cron: non-harness line not listed" 0 "$(sec "$DA" 定时任务 | grep -cF 'backup.sh')"
expect "doctor cron: shows the expired-cron note (已到期)" yes "$(sec "$DA" 定时任务 | grep -q '已到期' && echo yes || echo no)"
expect "doctor procs: alive pid listed with its file" 1 "$(sec "$DA" 在跑的进程 | grep -w -- "$S1" | grep -cF 'bot-test.pid')"
expect "doctor procs: unlisted process not mentioned" 0 "$(sec "$DA" 在跑的进程 | grep -cw -- "$S2")"
expect "doctor procs: stale pid file reported 已退出" 1 "$(sec "$DA" 在跑的进程 | grep -w -- "$DEAD" | grep -c '已退出')"
expect "doctor procs: stale pid file removed" no "$([ -e "$RUN/loop-$DEAD.pid" ] && echo yes || echo no)"
expect "doctor procs: alive pid file kept" yes "$([ -e "$RUN/bot-test.pid" ] && echo yes || echo no)"
expect "doctor: does not kill anything" "yes yes" "$(yn alive "$S1") $(yn alive "$S2")"
expect "doctor worktree: fresh worktree not listed" "（无）" "$(sec "$DA" '久未动的 worktree' | sed '/^[[:space:]]*$/d')"
expect "doctor gates: 8-day-old open gate listed" 1 "$(sec "$DA" 久未答的门卡 | grep -cF 'G-T901-1')"
expect "doctor gates: 2-day-old open gate not listed" 0 "$(sec "$DA" 久未答的门卡 | grep -cF 'G-T902-1')"
expect "doctor gates: answered gate not listed" 0 "$(sec "$DA" 久未答的门卡 | grep -cF 'G-T903-1')"
expect "doctor sandbox: wsl1 -> mentions WSL2" yes "$(sec "$DA" 沙箱依赖 | grep -qF 'WSL2' && echo yes || echo no)"

DB="$T/docB.out"; FUT=$(( $(date +%s) + 10*86400 ))
(cd "$WT" && HARNESS_NOW=$FUT HARNESS_PLATFORM=macos "${HARNESS[@]}" doctor > "$DB" 2>"$T/docB.err"); RC=$?
expect "doctor (from worktree, no --repo): exit 0" 0 "$RC"
expect "doctor worktree: 10-day-old worktree listed" 1 "$(sec "$DB" '久未动的 worktree' | grep -cF '.claude/worktrees/T-900')"
expect "doctor worktree: main checkout never listed" 1 "$(sec "$DB" '久未动的 worktree' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
expect "doctor worktree: only listed, not deleted" yes "$([ -d "$WT" ] && echo yes || echo no)"
expect "doctor (from worktree): uses the main repo's run dir" 1 "$(sec "$DB" 在跑的进程 | grep -cw -- "$S1")"
expect "doctor sandbox: macos -> ok" ok "$(sec "$DB" 沙箱依赖 | sed '/^[[:space:]]*$/d')"
DC="$T/docC.out"
(cd /; HARNESS_NOW=$(date +%s) "${HARNESS[@]}" doctor --repo "$R" > "$DC" 2>/dev/null); RC=$?
expect "doctor worktree: not listed when touched today" "0 （无）" "$RC $(sec "$DC" '久未动的 worktree' | sed '/^[[:space:]]*$/d')"

# ================================================================ down
(cd /; "${SETSID[@]}" "${HARNESS[@]}" down --repo "$R" > "$T/down1.out" 2>&1); RC=$?
expect "down: exit 0 (and survives a bogus '$BADPID' pid file)" 0 "$RC"
expect "down: listed process terminated" yes "$(yn gone "$S1")"
expect "down: process not in run/ left alone" yes "$(yn alive "$S2")"
expect "down: pid files removed" 0 "$(ls "$RUN"/*.pid 2>/dev/null | wc -l | tr -d ' ')"
expect "down: this repo's cron line removed" 0 "$(nmine)"
expect "down: non-harness cron line kept" yes "$(cronhas "$BACKUP")"
expect "down: other repo's harness line kept" 1 "$(grep -cF "# harness repo=$OTHER expires=" "$CRON" 2>/dev/null)"
expect "down: first run does not say 没有要停的" no "$(has "$T/down1.out" '没有要停的')"
(cd /; "${HARNESS[@]}" down --repo "$R" > "$T/down2.out" 2>&1); RC=$?
expect "down: second run exit 0" 0 "$RC"
expect "down: second run says 没有要停的" yes "$(has "$T/down2.out" '没有要停的')"
expect "down: second run still leaves others alone" yes "$(yn alive "$S2")"
rm -f "$CRON"
(cd /; "${HARNESS[@]}" down --repo "$R" > "$T/down3.out" 2>&1); RC=$?
expect "down: no crontab at all -> exit 0" 0 "$RC"
expect "down: never created a crontab when there was none to edit" no "$([ -s "$CRON" ] && echo yes || echo no)"

# ================================================================ 调度器 pid 文件 + 晨报提示
L="$T/loop"; mkdir -p "$L" && cd "$L" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/CLAUDE.md" "$SRC/.claude" "$SRC/.harness" "$SRC/scripts" .
rm -rf .claude/worktrees .harness/logs
printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
git add -A && git commit -qm init
LRUN="$(statedir "$L")/run"
cat > scripts/gates.sh <<SH
#!/usr/bin/env bash
ls "$LRUN" > "$T/loop-during.txt" 2>/dev/null
cat "$LRUN"/loop-*.pid > "$T/loop-pidcontent.txt" 2>/dev/null
echo "\$PPID" > "$T/loop-ppid.txt"
[ -n "\${KILL_PARENT:-}" ] && kill -TERM "\$PPID"
exit 0
SH
chmod +x scripts/gates.sh
mkdir -p .harness/reports && echo "2026-02-01 定时任务已到期（expires=2026-01-31）TESTNOTE-7f3" > .harness/reports/expired-cron.txt
scripts/harness-loop.sh --dry-run --no-groom --no-replan --until +0 > "$T/loop.out" 2>&1; RC=$?
LP="$(cat "$T/loop-ppid.txt" 2>/dev/null)"
expect "loop: exit 0" 0 "$RC"
expect "loop: writes run/loop-<pid>.pid while running" yes "$([ -n "$LP" ] && grep -qxF "loop-$LP.pid" "$T/loop-during.txt" 2>/dev/null && echo yes || echo no)"
expect "loop: pid file holds the loop's pid" "${LP:-?}" "$(tr -d ' \n' < "$T/loop-pidcontent.txt" 2>/dev/null)"
expect "loop: pid file removed on exit" 0 "$(ls "$LRUN"/loop-*.pid 2>/dev/null | wc -l | tr -d ' ')"
expect "loop: morning report carries the expired-cron note" yes "$(cat .harness/reports/morning-*.md 2>/dev/null | grep -qF 'TESTNOTE-7f3' && echo yes || echo no)"
rm -f "$T/loop-during.txt" "$T/loop-ppid.txt"
KILL_PARENT=1 scripts/harness-loop.sh --dry-run --no-groom --no-replan > "$T/loop2.out" 2>&1
LP="$(cat "$T/loop-ppid.txt" 2>/dev/null)"
expect "loop (SIGTERM): pid file existed" yes "$([ -n "$LP" ] && grep -qxF "loop-$LP.pid" "$T/loop-during.txt" 2>/dev/null && echo yes || echo no)"
expect "loop (SIGTERM): pid file removed by trap" 0 "$(ls "$LRUN"/loop-*.pid 2>/dev/null | wc -l | tr -d ' ')"

# ================================================================ 其他
HELP="$("${HARNESS[@]}" --help 2>&1)"
expect "help lists doctor" yes "$(printf '%s' "$HELP" | grep -qE '^ *doctor' && echo yes || echo no)"
expect "help lists down" yes "$(printf '%s' "$HELP" | grep -qE '^ *down' && echo yes || echo no)"
expect "real crontab never invoked (HARNESS_CRONTAB used everywhere)" no "$([ -e "$T/real-crontab-called" ] && echo yes || echo no)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
