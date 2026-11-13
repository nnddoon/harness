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
#   每批结束后：卡住的任务跑 /replan、更新 .harness/STATUS.md。教训在任务合进 main 后由 sync-merged 从主干任务卡同步。
#
# 用法：scripts/harness-loop.sh [--max-tasks N] [--parallel N] [--until HH:MM] [--integration] [--review-budget MIN] [--no-groom] [--no-replan] [--dry-run]
# 环境变量：
#   HARNESS_PERMISSION_MODE  传给 claude 的 --permission-mode（默认 acceptEdits；可改为 auto，如果你的账号支持）
#   HARNESS_MAX_TURNS        传给 claude 的 --max-turns（可选）
#   HARNESS_CLAUDE           claude 可执行文件（默认 claude）
#   每次启动 Claude 都经 harness_lib.py launch --strict：沙箱必须可用，凭证从环境里清掉（S-002）
#   改到控制路径（CONTROL_PATHS）的分支不合并、不推送、不作基线：任务转 blocked 并开门卡 G-Txxx-ctl（T-009）
#   整合验证在 srt 沙箱里、无凭证地跑，工作目录是合并结果的一次性 git archive 导出（没有 git 目录）；没装 srt 时不整合
#   控制面的每次 git 调用都关掉 hooks / fsmonitor（合并另关 LFS 过滤器）：worktree 里的东西 agent 碰过
#   Claude 用 strict 目标运行（不推送、不开 PR）：任务进 review 且控制路径检查通过后，由调度器从主仓库按 SHA 推任务分支、
#   开 PR、把 PR 号记到合并门卡 G-Txxx-merge（答案库）；门卡 Issue 由 gate-sync 在控制面发布（T-011）
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

GIT=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false)
MGIT=("${GIT[@]}" -c filter.lfs.process= -c filter.lfs.smudge= -c filter.lfs.clean=)   # 合并 / 检出：另关 LFS（配 GIT_LFS_SKIP_SMUDGE=1）
ROOT="$("${GIT[@]}" rev-parse --show-toplevel)"; cd "$ROOT"
HOOKS=.claude/hooks; [ -f "$HOOKS/harness_lib.py" ] || HOOKS=.harness/lib   # 插件模式：库在 .harness/lib
LIB="python3 $HOOKS/harness_lib.py"
# pid 文件「<pid> <starttime>」：harness doctor 看得到、harness down 停得掉；退出（含 SIGTERM）时删除。
# 仓库里的 harness_lib 可能是旧版（没有 state_dir）：那就按同一公式自己算
MAIN="$(cd "$("${GIT[@]}" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
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
# 守门和沙箱用控制面自己的库（绝对路径），从不用 worktree 里的副本
CTL=(python3 -B "$ROOT/$HOOKS/harness_lib.py")
PERM="${HARNESS_PERMISSION_MODE:-acceptEdits}"
TURNS=(); [ -n "${HARNESS_MAX_TURNS:-}" ] && TURNS=(--max-turns "$HARNESS_MAX_TURNS")
LOGDIR="$ROOT/.harness/logs"; mkdir -p "$LOGDIR"
if [ "$DRY" -eq 0 ] && ! SBX="$($LIB sandbox-check 2>&1)"; then
  echo "✗ 无人值守需要 Claude Code 沙箱（strict 模式），这台机器现在用不了：$SBX" >&2; exit 3
fi
grep -qxF '.harness/logs/' .gitignore 2>/dev/null || echo '.harness/logs/' >> .gitignore
export HARNESS_UNATTENDED=1

SKIP=""; BLOCKED=""; groomed=0; ran=0; summary=()

"${GIT[@]}" pull -q --ff-only 2>/dev/null || true
MERGED="$($LIB sync-merged)"
[ -n "$MERGED" ] && echo "✓ 已合并、标记为 done：$MERGED"

commit_bookkeeping() {
  if [ -n "$("${GIT[@]}" status --porcelain -- .harness .claude/rules/lessons.md)" ]; then
    "${GIT[@]}" add .harness .claude/rules/lessons.md 2>/dev/null
    "${GIT[@]}" commit -q -m "harness: $1" -- .harness .claude/rules/lessons.md
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
integ_owned() {  # 整合 worktree 的公共 git 目录必须就是本仓库的 .git（在它里面跑任何别的 git 之前查）
  local cdir
  cdir="$("${GIT[@]}" -C "$IWT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || cdir=""
  if [ -z "$cdir" ] || [ "$(cd "$cdir" 2>/dev/null && pwd -P)" != "$(cd "$ROOT/.git" && pwd -P)" ]; then
    echo "✗ 整合 worktree $IWT 的 git 目录不是本仓库的 .git，拒绝使用" >&2; return 1
  fi
}
if [ "$INTEG" -eq 1 ]; then
  IBR="integration/$(date +%Y%m%d)"; IWT="$ROOT/.claude/worktrees/_integration"; ILOG="$LOGDIR/integration-$(date +%Y%m%d).jsonl"
  if [ ! -d "$IWT" ]; then
    if "${GIT[@]}" show-ref --verify --quiet "refs/heads/$IBR"; then GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" worktree add -q "$IWT" "$IBR"
    else GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" worktree add -q -b "$IBR" "$IWT" HEAD; fi
  fi
  integ_owned || exit 2
  [ -x .harness/verify.sh ] || { echo "✗ 夜间模式需要可执行的 .harness/verify.sh（完整验证命令）" >&2; exit 2; }
  export HARNESS_INTEGRATION="$IBR" HARNESS_BASE="$IBR" HARNESS_INTEG_WT="$IWT"
  echo "◆ 夜间模式：通过验收的任务合进 $IBR（$IWT）"
fi

ctl_block() {  # ctl_block <TID> <命中文件（每行一个）> <分支> —— 不合并、不推送、不作基线：blocked + 主仓库门卡
  local TID="$1" HIT="$2" BR="${3:-<任务分支>}" G f
  G=".harness/gates/G-${TID//-/}-ctl.md"
  $LIB set-status "$TID" blocked --backlog-only >/dev/null
  echo "  ✗ $TID 改到控制路径：${HIT//$'\n'/, }"
  mkdir -p .harness/gates
  {
    printf -- '---\nid: G-%s-ctl\ntask: %s\nkind: unlock\nstatus: open\ncreated: %s\nurgency: normal\n' "${TID//-/}" "$TID" "$(date +%Y-%m-%d)"
    printf -- 'recommended: B\ndecided_by: human\nreview_minutes: 5\ndefault_if_no_answer: 不合并、不推送；任务保持 blocked\n'
    printf -- 'blocks: [%s 整合]\nanswer:\napprove_options: [A]\nthen:\npr:\nissue:\n---\n\n' "$TID"
    printf -- '# G-%s-ctl %s 改到控制路径：批准这些改动吗？\n\n' "${TID//-/}" "$TID"
    printf -- '**为什么需要你：** 控制路径（hooks、脚本、验证命令、CI 等）决定 harness 怎么约束 Claude，机器不能自己放行。\n\n'
    printf -- '## 改到的控制路径\n'
    while IFS= read -r f; do [ -n "$f" ] && printf -- '- `%s`\n' "$(printf '%s' "$f" | tr -d '\000-\037`')"; done <<< "$HIT"
    printf -- '\n## 怎么检查\n```bash\ngit diff main...%s -- <上面的文件>\n```\n\n' "$(printf '%s' "$BR" | tr -d '\000-\037`')"
    printf -- '## 选项\n- **A**：批准这些改动 — 后果：你人工合并这个分支\n- **B（推荐）**：退回重做 — 后果：任务重开，不改控制路径\n\n'
    printf -- '**回复格式：** `G-%s-ctl: A` 或 `G-%s-ctl: B，<备注>`\n' "${TID//-/}" "${TID//-/}"
  } > "$G"
}

integrate() {  # integrate <TID> <worktree> <分支> <提交> —— 合进整合分支、跑完整验证、红则撤回并重开
  local TID="$1" WT="$2" BR="$3" SHA="$4" pre result commit lines n merged FIX HIT
  if ! FIX="$("${CTL[@]}" sandbox-run --check 2>&1)"; then  # 没有沙箱就不在沙箱外跑 agent 写的代码：不合并，保持 review
    echo "  ✗ 没有沙箱运行器 srt，不整合 $TID：$FIX"; return 2
  fi
  # 在整合 worktree 里跑 git 之前（中间不再调用外部程序）：它的公共 git 目录必须是本仓库的 .git
  integ_owned || { echo "  ✗ 不整合 $TID（整合 worktree 不可信）"; return 2; }
  GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" -C "$IWT" merge -q --no-edit main >/dev/null 2>&1 \
    || GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" -C "$IWT" merge --abort >/dev/null 2>&1
  pre="$("${GIT[@]}" -C "$IWT" rev-parse HEAD)"
  # 合并 finish() 查过的那个提交（不是分支名，免得中途被换掉）
  if ! GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" -C "$IWT" merge -q --no-ff --no-edit -m "Merge branch '$BR'" "$SHA" >/dev/null 2>&1; then
    GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" -C "$IWT" merge --abort >/dev/null 2>&1; result=conflict
  else
    merged="$("${GIT[@]}" -C "$IWT" rev-parse HEAD)"
    lines="$("${GIT[@]}" diff --shortstat "$pre" "$merged" | awk '{print $4+$6}')"
    if ! HIT="$("${CTL[@]}" control-diff "$pre" "$merged" --root "$ROOT" 2>&1)"; then  # 合并结果再查一次
      integ_reset "$pre"; ctl_block "$TID" "$HIT" "$BR"; return 1
    fi
    # 验证跑 agent 写的代码：srt 沙箱、无凭证、在合并结果的一次性导出里（没有 git 目录，跑完删除）
    if "${CTL[@]}" sandbox-run --root "$IWT" --export "$merged" -- bash .harness/verify.sh > "$LOGDIR/verify-$TID.log" 2>&1; then
      result=green; commit="$merged"
    else
      # 撤回这次合并：整合分支只有调度器在用、尚未推送，直接回到合并前，下次重新合并时第一次的改动不会丢
      result=red; integ_reset "$pre"
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

integ_reset() {  # integ_reset <commit> —— 先把 HEAD 指回整合分支（沙箱里能改 worktree 自己的 HEAD），再硬重置
  integ_owned || return 1
  "${GIT[@]}" -C "$IWT" symbolic-ref HEAD "refs/heads/$IBR" && GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" -C "$IWT" reset -q --hard "$1"
}

[ -n "$MERGED" ] && commit_bookkeeping "mark merged: $MERGED"

launch() {  # launch <TID> <worktree> <note>  —— 后台运行，结果写进 .harness/logs/.<TID>.*
  local TID="$1" WT="$2" NOTE="$3" GOAL LOG
  [ -z "$NOTE" ] && [ -f "$LOGDIR/.$TID.note" ] && { NOTE="$(cat "$LOGDIR/.$TID.note")"; rm -f "$LOGDIR/.$TID.note"; }
  GOAL="$($LIB goal "$TID" --strict ${NOTE:+--note "$NOTE"})"   # strict：Claude 不推送、不开 PR（T-011）
  LOG="$LOGDIR/${TID}-$(date +%Y%m%d-%H%M%S).jsonl"
  printf '%s\n' "$LOG" > "$LOGDIR/.$TID.log"; printf '%s\n' "$WT" > "$LOGDIR/.$TID.wt"; rm -f "$LOGDIR/.$TID.rc"
  ( cd "$WT" && "${LAUNCH[@]}" --task "$TID" --root "$WT" -- -p "$GOAL" --permission-mode "$PERM" ${TURNS[@]+"${TURNS[@]}"} \
      --output-format stream-json --verbose > "$LOG" 2>&1; echo $? > "$LOGDIR/.$TID.rc" ) &
}

publish_task() {  # publish_task <TID> <分支> <提交> —— 控制面（T-011）：从主仓库按 SHA 推任务分支、开 PR（每任务一次）、记合并门卡
  local TID="$1" BR="$2" SHA="$3" G N BODY TITLE CARD
  G="G-${TID//-/}-merge"
  if "${GIT[@]}" remote get-url origin >/dev/null 2>&1; then
    if ! "${GIT[@]}" push -q origin "$SHA:refs/heads/$BR" > "$LOGDIR/.$TID.push" 2>&1; then
      echo "  ✗ $TID 推送 $BR 失败，保持 review、不开 PR：$(head -n1 "$LOGDIR/.$TID.push" | tr -d '\000-\037')"
      rm -f "$LOGDIR/.$TID.push"; return 1
    fi
    rm -f "$LOGDIR/.$TID.push"
  else
    echo "  • 没有 origin，不推送 $BR"
  fi
  CARD="$(ls .harness/tasks/"$TID"-*.md 2>/dev/null | head -n1)"
  TITLE="$(sed -n 's/^title:[[:space:]]*//p' "$CARD" 2>/dev/null | head -n1 | tr -d '\000-\037')"
  BODY="$LOGDIR/.$TID.prbody"
  { echo "$TID：${TITLE:-$TID}（由 harness-loop 在控制面开出；合并门卡 $G）"; echo
    "${GIT[@]}" show "$SHA:.harness/handoffs/$TID.md" 2>/dev/null | head -c 60000; } > "$BODY"
  # 开 PR、核对 / 恢复已有映射、记到合并门卡：控制面自己的库，进程内调用（没有能写映射的 CLI）
  N="$(python3 -B - "$ROOT/$HOOKS" "$ROOT" "$TID" "$BR" "$TID: ${TITLE:-$TID}" "$BODY" 2>/dev/null <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import gate_github as G
n = G.open_task_pr(Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], open(sys.argv[6], encoding="utf-8").read())
print(n or "")
PY
)"
  if [ -n "$N" ]; then echo "  ↑ $TID 已推送 $BR，PR #$N（合并门卡 $G）"
  else echo "  ✗ $TID 开 PR 失败（也没有控制面自己开的 PR 可认），保持 review、不记录"; fi
  rm -f "$BODY"
}

finish() {  # finish <TID>  —— 在主进程里同步状态、记汇总
  local TID="$1" WT LOG rc ST NH BR="" SHA="" HIT
  WT="$(cat "$LOGDIR/.$TID.wt")"; LOG="$(cat "$LOGDIR/.$TID.log")"; rc="$(cat "$LOGDIR/.$TID.rc" 2>/dev/null || echo '?')"
  ST="$($LIB card-status "$TID" --root "$WT")"; ST="${ST:-unknown}"
  case "$ST" in review|done|waiting_human|blocked|in_progress) ;; *) ST=blocked;; esac
  $LIB set-status "$TID" "$ST" --backlog-only >/dev/null
  if [ "$ST" = "review" ] || [ "$ST" = "done" ]; then
    # 整合 / 推送 / 作下游基线之前：分支改到控制路径就拦下（失败也当命中）。
    # 分支取自主仓库任务卡、在主仓库解析成提交，只解析一次；不看 worktree 的 HEAD
    if ! BR="$($LIB task-branch "$TID" 2>"$LOGDIR/.$TID.brerr")"; then  # 只认 task/<TID>-…（主仓库卡也可能被改）
      $LIB set-status "$TID" blocked --backlog-only >/dev/null
      echo "  ✗ $TID $(head -n1 "$LOGDIR/.$TID.brerr" | tr -d '\000-\037')"; ST=blocked; BR=""
    else
      SHA="$("${GIT[@]}" rev-parse --verify --quiet "refs/heads/$BR^{commit}" 2>/dev/null)"
      if [ -z "$SHA" ]; then HIT="找不到 $TID 的任务分支 $BR"; false
      else HIT="$("${CTL[@]}" control-diff main "$SHA" --root "$ROOT" 2>&1)"; fi || { ctl_block "$TID" "$HIT" "$BR"; ST=blocked; }
    fi
    rm -f "$LOGDIR/.$TID.brerr"
  fi
  if [ "$INTEG" -eq 1 ] && [ "$ST" = "review" ]; then
    integrate "$TID" "$WT" "$BR" "$SHA"; ST="$($LIB backlog-status "$TID")"; [ "$ST" = "ready" ] && ST="reopened"
  elif [ "$ST" = "review" ] && [ -n "$SHA" ]; then
    publish_task "$TID" "$BR" "$SHA"   # 控制路径检查通过之后；命中 / blocked 的不推不开
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
  # 整合分支从主仓库推送：先在主仓库把它解析成提交、查控制路径，推的就是这个提交（不在整合 worktree 里跑 git）
  ISHA=""; [ -n "$IBR" ] && ISHA="$("${GIT[@]}" rev-parse --verify --quiet "refs/heads/$IBR^{commit}" 2>/dev/null)"
  if [ -n "$ISHA" ] && "${GIT[@]}" remote get-url origin >/dev/null 2>&1 && [ "$("${GIT[@]}" rev-list --count "main..$ISHA")" -gt 0 ] \
     && { IHIT="$("${CTL[@]}" control-diff "$ISHA" --root "$ROOT" 2>&1)" \
          || { echo "✗ 整合分支 $IBR 改到控制路径，不推送：${IHIT//$'\n'/, }" | tee -a "$MREP"; false; }; }; then
    "${GIT[@]}" push -q origin "$ISHA:refs/heads/$IBR" 2>/dev/null && \
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
