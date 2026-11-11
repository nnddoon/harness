#!/usr/bin/env bash
# 认领一张任务卡：在主仓库登记 claimed → 建分支 + worktree → 打印新对话启动块。
# 用法：scripts/new-task.sh T-013 [--print-only]
#   环境变量：HARNESS_NO_COMMIT=1  不自动提交 .harness/ 的登记改动
#             HARNESS_BASE=<ref>   worktree 基于哪个提交（默认主仓库当前 HEAD）
set -euo pipefail

TID="${1:?用法: scripts/new-task.sh T-xxx}"
PRINT_ONLY="${2:-}"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
LIB="python3 .claude/hooks/harness_lib.py"

if [ "$(git rev-parse --absolute-git-dir)" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
  echo "✗ 请在主仓库（控制塔）运行，而不是在 worktree 里。" >&2; exit 1
fi

CARD="$(ls .harness/tasks/${TID}*.md 2>/dev/null | head -n1 || true)"
[ -n "$CARD" ] || { echo "✗ 找不到任务卡 .harness/tasks/${TID}*.md，先 /task-align" >&2; exit 1; }

fm() { python3 -B - "$CARD" "$1" <<'PY'
import sys; sys.path.insert(0, ".claude/hooks"); import harness_lib as H
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

  $LIB set-status "$TID" claimed --owner "$(whoami)@$(hostname -s 2>/dev/null || echo host)" >/dev/null
  if [ -z "${HARNESS_NO_COMMIT:-}" ] && [ -n "$(git status --porcelain -- .harness)" ]; then
    git add .harness
    git commit -q -m "harness: claim ${TID}" -- .harness
  fi

  # 夜间模式：worktree 从整合分支开出，先把主干上的任务卡/backlog 同步进整合分支
  if [ -n "${HARNESS_INTEG_WT:-}" ] && [ -d "$HARNESS_INTEG_WT" ]; then
    git -C "$HARNESS_INTEG_WT" merge -q --no-edit main >/dev/null 2>&1 || git -C "$HARNESS_INTEG_WT" merge --abort >/dev/null 2>&1
  fi
  if [ -d "$WT" ]; then
    echo "• worktree 已存在：$WT（复用）"
  elif git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git worktree add -q "$WT" "$BRANCH"
  else
    git worktree add -q -b "$BRANCH" "$WT" "$BASE"
  fi

  # 复制 .worktreeinclude 中列出的被 gitignore 的文件（如 .env），与 claude --worktree 行为一致
  if [ -f .worktreeinclude ]; then
    while IFS= read -r pat; do
      case "$pat" in ""|\#*) continue;; esac
      for f in $pat; do
        [ -e "$f" ] && git check-ignore -q "$f" && mkdir -p "$WT/$(dirname "$f")" && cp -R "$f" "$WT/$f"
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
