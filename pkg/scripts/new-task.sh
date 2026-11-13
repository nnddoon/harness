#!/usr/bin/env bash
# 认领一张任务卡：在主仓库登记 claimed → 建分支 + worktree → 打印新对话启动块。
# 用法：scripts/new-task.sh T-013 [--print-only]
#   环境变量：HARNESS_NO_COMMIT=1  不自动提交 .harness/ 的登记改动
#             HARNESS_BASE=<ref>   worktree 基于哪个提交（默认主仓库当前 HEAD）
set -euo pipefail

TID="${1:?用法: scripts/new-task.sh T-xxx}"
PRINT_ONLY="${2:-}"
# 控制面的 git 一律关掉 hooks / fsmonitor；检出另关 LFS 过滤器（T-009）
GIT=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false)
MGIT=("${GIT[@]}" -c filter.lfs.process= -c filter.lfs.smudge= -c filter.lfs.clean=)
ROOT="$("${GIT[@]}" rev-parse --show-toplevel)"
cd "$ROOT"
HOOKS=.claude/hooks; [ -f "$HOOKS/harness_lib.py" ] || HOOKS=.harness/lib   # 插件模式：库在 .harness/lib
export HOOKS
LIB="python3 $HOOKS/harness_lib.py"

if [ "$("${GIT[@]}" rev-parse --absolute-git-dir)" != "$("${GIT[@]}" rev-parse --path-format=absolute --git-common-dir)" ]; then
  echo "✗ 请在主仓库（控制塔）运行，而不是在 worktree 里。" >&2; exit 1
fi

CARD="$(ls .harness/tasks/${TID}*.md 2>/dev/null | head -n1 || true)"
[ -n "$CARD" ] || { echo "✗ 找不到任务卡 .harness/tasks/${TID}*.md，先 /task-align" >&2; exit 1; }

fm() { python3 -B - "$CARD" "$1" <<'PY'
import os, sys; sys.path.insert(0, os.environ.get("HOOKS", ".claude/hooks")); import harness_lib as H
from pathlib import Path
v = H.read_frontmatter(Path(sys.argv[1])).get(sys.argv[2], "")
print(",".join(v) if isinstance(v, list) else v)
PY
}

STATUS="$(fm status)"
SLUG="$(basename "$CARD" .md | sed "s/^${TID}-\{0,1\}//")"; SLUG="${SLUG:-task}"
BRANCH="$(fm branch)"; case "$BRANCH" in ""|*T-000*|*-slug) BRANCH="task/${TID}-${SLUG}";; esac
WT="$(fm worktree)";   case "$WT" in ""|*T-000*) WT=".claude/worktrees/${TID}";; esac
CTX="$(fm context_files)"
LOCKED="$(fm locked_paths)"
BASE="${HARNESS_BASE:-HEAD}"

if [ "$PRINT_ONLY" != "--print-only" ]; then
  case "$STATUS" in
    ready|claimed) ;;
    *) echo "✗ ${TID} 状态是 '${STATUS}'，只有 ready/claimed 可以认领（先 /task-align 并确认）。" >&2; exit 1;;
  esac

  # 基线（HARNESS_BASE，默认 HEAD）只要不是默认分支，就查它有没有改到控制路径（T-009）：
  # 在登记、建 worktree 之前查；查不了也当命中。建好 worktree 之后再核对一次（见下）
  CTLLIB=(python3 -B "$ROOT/$HOOKS/harness_lib.py")
  DEF="$("${CTLLIB[@]}" default-branch --root "$ROOT" 2>&1)" || { echo "${DEF:-✗ 找不到默认分支}，不认领 ${TID}" >&2; exit 1; }
  BASE_SHA="$("${GIT[@]}" rev-parse --verify --quiet "${BASE}^{commit}" 2>/dev/null || true)"
  [ -n "$BASE_SHA" ] || { echo "✗ 基线 ${BASE} 不是有效的提交" >&2; exit 1; }
  DEF_SHA="$("${GIT[@]}" rev-parse --verify --quiet "refs/heads/${DEF}^{commit}" 2>/dev/null || true)"
  if [ "$BASE_SHA" != "$DEF_SHA" ]; then
    if ! HIT="$("${CTLLIB[@]}" control-diff "$DEF" "$BASE_SHA" --root "$ROOT" 2>&1)"; then
      echo "✗ 基线 ${BASE} 改到控制路径：${HIT//$'\n'/, }" >&2; exit 1
    fi
  fi
  # 夜间模式要往整合 worktree 合并 main：它的公共 git 目录必须是本仓库的 .git
  if [ -n "${HARNESS_INTEG_WT:-}" ] && [ -d "$HARNESS_INTEG_WT" ]; then
    ICD="$("${GIT[@]}" -C "$HARNESS_INTEG_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$ICD" ] || [ "$(cd "$ICD" 2>/dev/null && pwd -P)" != "$(cd "$ROOT/.git" && pwd -P)" ]; then
      echo "✗ 整合 worktree $HARNESS_INTEG_WT 的 git 目录不是本仓库的 .git，拒绝使用" >&2; exit 1
    fi
  fi

  $LIB set-status "$TID" claimed --owner "$(whoami)@$(hostname -s 2>/dev/null || echo host)" >/dev/null
  if [ -z "${HARNESS_NO_COMMIT:-}" ] && [ -n "$("${GIT[@]}" status --porcelain -- .harness)" ]; then
    "${GIT[@]}" add .harness
    "${GIT[@]}" commit -q -m "harness: claim ${TID}" -- .harness
  fi

  # 夜间模式：worktree 从整合分支开出，先把主干上的任务卡/backlog 同步进整合分支
  if [ -n "${HARNESS_INTEG_WT:-}" ] && [ -d "$HARNESS_INTEG_WT" ]; then
    GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" -C "$HARNESS_INTEG_WT" merge -q --no-edit main >/dev/null 2>&1 \
      || GIT_LFS_SKIP_SMUDGE=1 "${MGIT[@]}" -C "$HARNESS_INTEG_WT" merge --abort >/dev/null 2>&1
  fi
  CREATED=0
  if [ -d "$WT" ]; then
    echo "• worktree 已存在：$WT（复用）"
  elif "${GIT[@]}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    "${GIT[@]}" worktree add -q "$WT" "$BRANCH"; CREATED=1
  else
    "${GIT[@]}" worktree add -q -b "$BRANCH" "$WT" "$BASE"; CREATED=1   # 期间只多了控制面自己的登记提交 / 合并 main
  fi
  # 建好之后再核对（基线可能在检查之后被换掉，分支也可能早就存在）：分支没改到控制路径，
  # 且这次新建的 worktree 的分支 tip 是检查过的基线或其后代（复用的 worktree 是之前开工的，基线已前进，不比）；
  # 否则删掉这次建的 worktree（不删分支）
  TIP="$("${GIT[@]}" rev-parse --verify --quiet "refs/heads/${BRANCH}^{commit}" 2>/dev/null || true)"
  WHY=""
  if [ -z "$TIP" ]; then WHY="找不到分支 ${BRANCH}"
  elif ! HIT="$("${CTLLIB[@]}" control-diff "$DEF" "$TIP" --root "$ROOT" 2>&1)"; then WHY="分支 ${BRANCH} 改到控制路径：${HIT//$'\n'/, }"
  elif [ "$CREATED" -eq 1 ] && ! "${GIT[@]}" merge-base --is-ancestor "$BASE_SHA" "$TIP" 2>/dev/null; then WHY="分支 ${BRANCH} 不是基线 ${BASE} 的后代"
  fi
  if [ -n "$WHY" ]; then
    [ "$CREATED" -eq 1 ] && "${GIT[@]}" worktree remove --force "$WT" >/dev/null 2>&1
    $LIB set-status "$TID" blocked --backlog-only >/dev/null 2>&1 || true
    echo "✗ ${WHY}，不在它上面开工" >&2; exit 1
  fi

  # 复制 .worktreeinclude 中列出的被 gitignore 的文件（如 .env），与 claude --worktree 行为一致
  if [ -f .worktreeinclude ]; then
    while IFS= read -r pat; do
      case "$pat" in ""|\#*) continue;; esac
      for f in $pat; do
        [ -e "$f" ] && "${GIT[@]}" check-ignore -q "$f" && mkdir -p "$WT/$(dirname "$f")" && cp -R "$f" "$WT/$f"
      done
    done < .worktreeinclude
  fi
  grep -qxF '.claude/worktrees/' .gitignore 2>/dev/null || echo "⚠ 建议把 .claude/worktrees/ 加入 .gitignore"
fi

ABS_WT="$(cd "$WT" 2>/dev/null && pwd || echo "$ROOT/$WT")"
cat <<EOF

✓ ${TID} 已认领
  分支：${BRANCH}
  目录：${ABS_WT}

──────── 新对话启动块（复制粘贴）────────
cd "${ABS_WT}" && claude

你在执行 ${TID}（$(fm title)）。先完整读 ${CARD}${CTX:+ 以及 ${CTX//,/、}}。
不许修改：.harness/locks.txt 中的路径${LOCKED:+、${LOCKED//,/、}}。完成标准见任务卡第 5 节。
读完用 3 行复述 目标 / 范围 / 验收，然后执行 /task-run ${TID}。

── 想让它自己跑到底（推荐配合 auto 模式）：──
/goal 按 /task-run 流程完成 ${TID} 并执行 /task-close；完成条件：任务卡 status 为 review、交接包 .harness/handoffs/${TID}.md 已写、verifier 结论 PASS；或 status 为 waiting_human/blocked 且「7. 当前进展」写明原因；或已超过 40 轮
──────────────────────────────────────────
EOF
