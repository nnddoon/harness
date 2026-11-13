#!/usr/bin/env bash
# 无人值守循环（在主仓库根目录运行）：
#   挑 ready 任务 → new-task.sh 建 worktree → headless `claude -p "/goal ..."` → 同步状态 → 下一张
#   backlog 清空 → 跑一次 /backlog-groom（审核模式，只写 .harness/，只自动批准 auto_ok: yes）
#   遇到 waiting_human / blocked → 记录并跳过，继续独立任务；结束时汇总人工门。
#
#   --parallel N：一次最多派 N 个任务同时跑；只有 allowed_paths 互不重叠、也不和进行中任务重叠的才会一起派。
#   --until HH:MM | +分钟：到点后不再派发新批次（已在跑的跑完），然后写晨报 .harness/reports/morning-日期.md。
#   --integration：夜间模式。通过验收的任务按批次顺序合进 integration/<日期> 分支，每次合并后跑 .harness/verify.sh，
#                  红了就撤回那次合并（整合分支回到合并前）、把任务重开；下游任务从整合分支开工，不必等你合并。早上你只看一个整合 PR。
#   --review-budget 分钟：按你的审阅能力限流。待你看的（开着的门卡 + 做完未合并的任务）估计超过这么多分钟，
#                  就不再开新任务——做出来却没人看，只是浪费。默认取 HARNESS_REVIEW_BUDGET，0 = 不限。
#   每批结束后：同步教训到 .claude/rules/lessons.md、卡住的任务跑 /replan、更新 .harness/STATUS.md。
#
# 用法：scripts/harness-loop.sh [--max-tasks N] [--parallel N] [--until HH:MM] [--integration] [--review-budget MIN] [--no-groom] [--no-replan] [--dry-run]
# 环境变量：
#   HARNESS_PERMISSION_MODE  传给 claude 的 --permission-mode（默认 acceptEdits；可改为 auto，如果你的账号支持）
#   HARNESS_MAX_TURNS        传给 claude 的 --max-turns（可选）
#   HARNESS_CLAUDE           claude 可执行文件（默认 claude）
#   每次启动 Claude 都经 harness_lib.py launch --strict：沙箱必须可用，凭证从环境里清掉（S-002）
set -uo pipefail

MAX_TASKS=3; PARALLEL=1; GROOM=1; DRY=0; UNTIL=""; INTEG=0; REPLAN=1; BUDGET="${HARNESS_REVIEW_BUDGET:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --max-tasks) MAX_TASKS="$2"; shift 2;;
    --parallel)  PARALLEL="$2"; shift 2;;
    --no-groom)  GROOM=0; shift;;
    --no-replan) REPLAN=0; shift;;
    --until)     UNTIL="$2"; shift 2;;
    --integration) INTEG=1; shift;;
    --review-budget) BUDGET="$2"; shift 2;;
    --dry-run)   DRY=1; shift;;
    *) echo "未知参数 $1" >&2; exit 2;;
  esac
done

ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
HOOKS=.claude/hooks; [ -f "$HOOKS/harness_lib.py" ] || HOOKS=.harness/lib   # 插件模式：库在 .harness/lib
LIB="python3 $HOOKS/harness_lib.py"
# pid 文件「<pid> <starttime>」：harness doctor 看得到、harness down 停得掉；退出（含 SIGTERM）时删除。
# 仓库里的 harness_lib 可能是旧版（没有 state_dir）：那就按同一公式自己算
MAIN="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
RUNDIR="$(python3 -B - "$ROOT/$HOOKS" "$MAIN" 2>/dev/null <<'PY'
import hashlib, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1]); main = Path(sys.argv[2])
try:
    import harness_lib as h; d = h.state_dir(main)
except Exception:
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    d = base / "harness" / f"{main.name}-{hashlib.sha1(str(main.resolve()).encode()).hexdigest()[:8]}"
print(d / "run")
PY
)"
PIDF=""
if [ -n "$RUNDIR" ] && mkdir -p "$RUNDIR"; then
  PIDF="$RUNDIR/loop-$$.pid"; STT="$(sed 's/.*) //' "/proc/$$/stat" 2>/dev/null | cut -d' ' -f20)"
  echo "$$${STT:+ $STT}" > "$PIDF"
fi
trap '[ -z "$PIDF" ] || rm -f "$PIDF"' EXIT
stop_jobs() { local j; j="$(jobs -p)"; [ -z "$j" ] || kill -TERM $j 2>/dev/null; }   # 后台在跑的任务一起停（harness down 另外会停子孙进程）
trap 'stop_jobs; exit 143' TERM; trap 'stop_jobs; exit 130' INT; trap 'stop_jobs; exit 129' HUP
# 所有 Claude 启动都经启动器：无人值守一律 strict（沙箱 + 无凭证，S-002 / D-006）
LAUNCH=(python3 "$ROOT/$HOOKS/harness_lib.py" launch --strict)
PERM="${HARNESS_PERMISSION_MODE:-acceptEdits}"
TURNS=(); [ -n "${HARNESS_MAX_TURNS:-}" ] && TURNS=(--max-turns "$HARNESS_MAX_TURNS")
LOGDIR="$ROOT/.harness/logs"; mkdir -p "$LOGDIR"
if [ "$DRY" -eq 0 ] && ! SBX="$($LIB sandbox-check 2>&1)"; then
  echo "✗ 无人值守需要 Claude Code 沙箱（strict 模式），这台机器现在用不了：$SBX" >&2; exit 3
fi
grep -qxF '.harness/logs/' .gitignore 2>/dev/null || echo '.harness/logs/' >> .gitignore
export HARNESS_UNATTENDED=1

SKIP=""; BLOCKED=""; groomed=0; ran=0; summary=()

git pull -q --ff-only 2>/dev/null || true
MERGED="$($LIB sync-merged)"
[ -n "$MERGED" ] && echo "✓ 已合并、标记为 done：$MERGED"

commit_bookkeeping() {
  if [ -n "$(git status --porcelain -- .harness .claude/rules/lessons.md)" ]; then
    git add .harness .claude/rules/lessons.md 2>/dev/null
    git commit -q -m "harness: $1" -- .harness .claude/rules/lessons.md
  fi
}

DEADLINE=""
if [ -n "$UNTIL" ]; then
  DEADLINE="$(python3 - "$UNTIL" <<'PY'
import sys, datetime as d
now = d.datetime.now()
if sys.argv[1].startswith("+"):  # +MIN: run for MIN minutes from now
    print(int((now + d.timedelta(minutes=int(sys.argv[1][1:]))).timestamp())); raise SystemExit
h, m = map(int, sys.argv[1].split(":"))
t = now.replace(hour=h, minute=m, second=0, microsecond=0)
print(int((t if t > now else t + d.timedelta(days=1)).timestamp()))
PY
)"
fi
past_deadline() { [ -n "$DEADLINE" ] && [ "$(date +%s)" -ge "$DEADLINE" ]; }

IBR=""; IWT=""; ILOG=""
if [ "$INTEG" -eq 1 ]; then
  IBR="integration/$(date +%Y%m%d)"; IWT="$ROOT/.claude/worktrees/_integration"; ILOG="$LOGDIR/integration-$(date +%Y%m%d).jsonl"
  if [ ! -d "$IWT" ]; then
    if git show-ref --verify --quiet "refs/heads/$IBR"; then git worktree add -q "$IWT" "$IBR"
    else git worktree add -q -b "$IBR" "$IWT" HEAD; fi
  fi
  [ -x .harness/verify.sh ] || { echo "✗ 夜间模式需要可执行的 .harness/verify.sh（完整验证命令）" >&2; exit 2; }
  export HARNESS_INTEGRATION="$IBR" HARNESS_BASE="$IBR" HARNESS_INTEG_WT="$IWT"
  echo "◆ 夜间模式：通过验收的任务合进 $IBR（$IWT）"
fi

integrate() {  # integrate <TID> <worktree> —— 合进整合分支、跑完整验证、红则撤回并重开
  local TID="$1" WT="$2" BR pre result commit lines n
  BR="$(git -C "$WT" branch --show-current)"; pre="$(git -C "$IWT" rev-parse HEAD)"
  git -C "$IWT" merge -q --no-edit main >/dev/null 2>&1 || git -C "$IWT" merge --abort >/dev/null 2>&1
  pre="$(git -C "$IWT" rev-parse HEAD)"
  if ! git -C "$IWT" merge -q --no-ff --no-edit "$BR" >/dev/null 2>&1; then
    git -C "$IWT" merge --abort >/dev/null 2>&1; result=conflict
  else
    lines="$(git -C "$IWT" diff --shortstat "$pre" HEAD | awk '{print $4+$6}')"
    if ( cd "$IWT" && bash .harness/verify.sh ) > "$LOGDIR/verify-$TID.log" 2>&1; then
      result=green; commit="$(git -C "$IWT" rev-parse HEAD)"
    else
      # 撤回这次合并：整合分支只有调度器在用、尚未推送，直接回到合并前，下次重新合并时第一次的改动不会丢
      result=red; git -C "$IWT" reset -q --hard "$pre"
    fi
  fi
  printf '{"task":"%s","branch":"%s","result":"%s","commit":"%s","lines":%s,"verify":"bash .harness/verify.sh"}\n' \
    "$TID" "$BR" "$result" "${commit:-}" "${lines:-0}" >> "$ILOG"
  if [ "$result" = green ]; then
    $LIB set-status "$TID" integrated --backlog-only >/dev/null; echo "  ✓ $TID 已合进 $IBR（验证通过）"; return 0
  fi
  n=$(( $(cat "$LOGDIR/.$TID.reopen" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$LOGDIR/.$TID.reopen"
  if [ "$n" -gt 2 ]; then
    $LIB set-status "$TID" blocked --backlog-only >/dev/null; echo "  ✗ $TID 整合失败第 $n 次（$result），标为 blocked"
  else
    printf '整合失败（%s）：先 git rebase %s，解决后重跑完整验证；验证日志 .harness/logs/verify-%s.log' "$result" "$IBR" "$TID" > "$LOGDIR/.$TID.note"
    $LIB set-status "$TID" ready --backlog-only >/dev/null; echo "  ↺ $TID 整合失败（$result），已撤回并重开"
  fi
  return 1
}

[ -n "$MERGED" ] && commit_bookkeeping "mark merged: $MERGED"

launch() {  # launch <TID> <worktree> <note>  —— 后台运行，结果写进 .harness/logs/.<TID>.*
  local TID="$1" WT="$2" NOTE="$3" GOAL LOG
  [ -z "$NOTE" ] && [ -f "$LOGDIR/.$TID.note" ] && { NOTE="$(cat "$LOGDIR/.$TID.note")"; rm -f "$LOGDIR/.$TID.note"; }
  GOAL="$($LIB goal "$TID" ${NOTE:+--note "$NOTE"})"
  LOG="$LOGDIR/${TID}-$(date +%Y%m%d-%H%M%S).jsonl"
  printf '%s\n' "$LOG" > "$LOGDIR/.$TID.log"; printf '%s\n' "$WT" > "$LOGDIR/.$TID.wt"; rm -f "$LOGDIR/.$TID.rc"
  ( cd "$WT" && "${LAUNCH[@]}" --task "$TID" --root "$WT" -- -p "$GOAL" --permission-mode "$PERM" ${TURNS[@]+"${TURNS[@]}"} \
      --output-format stream-json --verbose > "$LOG" 2>&1; echo $? > "$LOGDIR/.$TID.rc" ) &
}

finish() {  # finish <TID>  —— 在主进程里同步状态、记汇总
  local TID="$1" WT LOG rc ST NH
  WT="$(cat "$LOGDIR/.$TID.wt")"; LOG="$(cat "$LOGDIR/.$TID.log")"; rc="$(cat "$LOGDIR/.$TID.rc" 2>/dev/null || echo '?')"
  ST="$($LIB card-status "$TID" --root "$WT")"; ST="${ST:-unknown}"
  case "$ST" in review|done|waiting_human|blocked|in_progress) ;; *) ST=blocked;; esac
  $LIB set-status "$TID" "$ST" --backlog-only >/dev/null
  $LIB lessons "$TID" "$WT" >/dev/null 2>&1
  if [ "$INTEG" -eq 1 ] && [ "$ST" = "review" ]; then
    integrate "$TID" "$WT"; ST="$($LIB backlog-status "$TID")"; [ "$ST" = "ready" ] && ST="reopened"
  fi
  commit_bookkeeping "$TID -> $ST"
  NH="$(grep -ho 'NEEDS_HUMAN: [^"\\]*' "$LOG" | head -n3 | tr '\n' ' ')"
  summary+=("$TID  status=$ST  exit=$rc  ${NH}  log=${LOG#$ROOT/}")
  case "$ST" in review|done|reopened) ;; *) SKIP="$SKIP,$TID";; esac
  [ "$ST" = "blocked" ] && BLOCKED="$BLOCKED,$TID"
  rm -f "$LOGDIR/.$TID.log" "$LOGDIR/.$TID.wt" "$LOGDIR/.$TID.rc"
}

# 先接续：GitHub 上已答复、解除阻塞的任务（各自在自己的 worktree，可以一起跑）
if [ "$DRY" -eq 0 ]; then
  RES=()
  while IFS=$'\t' read -r tag RT RWT RNOTE; do
    [ "$tag" = "RESUME" ] || continue
    [ $((ran + ${#RES[@]})) -lt "$MAX_TASKS" ] || break
    echo "▶ 接续 $RT（$RNOTE）"
    $LIB set-status "$RT" in_progress --backlog-only >/dev/null; commit_bookkeeping "resume $RT"
    launch "$RT" "$RWT" "$RNOTE"; RES+=("$RT")
    if [ "${#RES[@]}" -ge "$PARALLEL" ]; then wait; for t in "${RES[@]}"; do finish "$t"; done; ran=$((ran + ${#RES[@]})); RES=(); fi
  done < <(python3 -B "$HOOKS/gate_github.py" sync --list-resumable --quiet 2>/dev/null)
  if [ "${#RES[@]}" -gt 0 ]; then wait; for t in "${RES[@]}"; do finish "$t"; done; ran=$((ran + ${#RES[@]})); fi
fi

after_batch() {  # 每批结束：卡住的任务 replan、更新 STATUS.md
  if [ "$REPLAN" -eq 1 ] && [ -n "$BLOCKED" ] && [ "$DRY" -eq 0 ]; then
    echo "▶ /replan ${BLOCKED#,}"
    HARNESS_MODE=groom "${LAUNCH[@]}" --role plan --root "$ROOT" -- -p "/replan ${BLOCKED#,}" --permission-mode "$PERM" ${TURNS[@]+"${TURNS[@]}"} \
      --output-format stream-json --verbose > "$LOGDIR/replan-$(date +%Y%m%d-%H%M%S).jsonl" 2>&1
    for t in $(echo "${BLOCKED#,}" | tr ',' ' '); do
      [ "$($LIB card-status "$t" 2>/dev/null)" = "ready" ] && SKIP="$(echo ",$SKIP," | sed "s/,$t,/,/g; s/^,//; s/,$//")"
    done
    BLOCKED=""
  fi
  $LIB status >/dev/null; commit_bookkeeping "status"
}

while [ "$ran" -lt "$MAX_TASKS" ]; do
  if past_deadline; then echo "■ 已到 $UNTIL，不再派发新批次。"; break; fi
  if [ "${BUDGET:-0}" -gt 0 ]; then
    read -r RMIN RITEMS <<< "$($LIB review-load)"
    if [ "${RMIN:-0}" -ge "$BUDGET" ]; then
      echo "■ 待你审阅约 ${RMIN} 分钟（${RITEMS} 项），已到审阅预算 ${BUDGET} 分钟，不再开新任务。先看完再继续。"
      summary+=("（因审阅预算暂停：待你看约 ${RMIN} 分钟）"); break
    fi
  fi
  N=$(( MAX_TASKS - ran < PARALLEL ? MAX_TASKS - ran : PARALLEL ))
  BATCH="$($LIB pick-batch "$N" --skip "${SKIP:-none}")"

  if [ -z "$BATCH" ]; then
    if [ "$GROOM" -eq 1 ] && [ "$groomed" -eq 0 ]; then
      echo "▶ backlog 没有可执行任务，运行 /backlog-groom（审核模式）"
      groomed=1
      if [ "$DRY" -eq 0 ]; then
        HARNESS_MODE=groom "${LAUNCH[@]}" --role plan --root "$ROOT" -- -p "/backlog-groom" --permission-mode "$PERM" ${TURNS[@]+"${TURNS[@]}"} \
          --output-format stream-json --verbose > "$LOGDIR/groom-$(date +%Y%m%d-%H%M%S).jsonl" 2>&1
        commit_bookkeeping "groom proposals"
      fi
      continue
    fi
    echo "■ 没有更多可执行任务。"; break
  fi

  echo "▶ [$((ran+1))-$((ran + $(echo $BATCH | wc -w)))/$MAX_TASKS] 派发：$BATCH"
  if [ "$DRY" -eq 1 ]; then
    for TID in $BATCH; do summary+=("$TID  (dry-run)"); SKIP="$SKIP,$TID"; ran=$((ran+1)); done
    continue
  fi
  LAUNCHED=()
  for TID in $BATCH; do
    OUT="$(scripts/new-task.sh "$TID")" || { echo "  ✗ 认领 $TID 失败"; SKIP="$SKIP,$TID"; continue; }
    WT="$(printf '%s\n' "$OUT" | sed -n 's/^  目录：//p' | head -n1)"
    $LIB set-status "$TID" in_progress --backlog-only >/dev/null; commit_bookkeeping "start $TID"
    launch "$TID" "$WT" ""; LAUNCHED+=("$TID")
  done
  [ "${#LAUNCHED[@]}" -gt 0 ] || continue
  wait
  for TID in $(printf '%s\n' "${LAUNCHED[@]}" | sort); do finish "$TID"; done
  ran=$((ran + ${#LAUNCHED[@]}))
  after_batch
done

if [ "$INTEG" -eq 1 ] || [ -n "$UNTIL" ]; then
  mkdir -p .harness/reports; MREP=".harness/reports/morning-$(date +%Y%m%d).md"
  $LIB morning ${ILOG:+--log "$ILOG"} ${IBR:+--branch "$IBR"} > "$MREP"
  EXPN=.harness/reports/expired-cron.txt   # gate-sync 的定时任务到期了：晨报里提一句
  [ -s "$EXPN" ] && { echo; echo "## 定时任务到期"; cat "$EXPN"; } >> "$MREP"
  if [ -n "$IBR" ] && git remote get-url origin >/dev/null 2>&1 && [ "$(git -C "$IWT" rev-list --count main..HEAD)" -gt 0 ]; then
    git -C "$IWT" push -q -u origin "$IBR" 2>/dev/null && \
      gh pr create --base main --head "$IBR" --title "夜间整合 $(date +%Y-%m-%d)" --body-file "$MREP" >/dev/null 2>&1 && \
      echo "整合 PR 已开（请用 Merge commit 方式合并，任务才会自动标记 done）" >> "$MREP"
  fi
  $LIB status >/dev/null; commit_bookkeeping "morning report"
  echo; echo "════════ 晨报（$MREP）════════"; cat "$MREP"
fi

echo; echo "════════ 本轮汇总 ════════"
for s in "${summary[@]:-}"; do [ -n "$s" ] && echo "  $s"; done
echo; echo "════════ 待你处理的人工门 ════════"
scripts/gates.sh
bash "$HOOKS/notify.sh" "harness-loop 完成：${ran} 个任务，查看 scripts/gates.sh" || true
