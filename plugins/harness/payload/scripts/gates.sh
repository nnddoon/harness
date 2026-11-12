#!/usr/bin/env bash
# 汇总所有 worktree 中 status: open 的人工门卡。
# 用法：scripts/gates.sh [--all]   (--all 同时显示已答复的)
set -uo pipefail
SHOW_ALL="${1:-}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
count=0; seen=" "

paths="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
[ -n "$paths" ] || paths="$ROOT"
# worktrees first (newest state of a gate), main checkout last; each gate id shown once
paths="$(printf '%s\n' "$paths" | awk '{a[NR]=$0} END{for(i=NR;i>0;i--)print a[i]}')"

while IFS= read -r wt; do
  for g in "$wt"/.harness/gates/G-*.md; do
    [ -f "$g" ] || continue
    id="$(sed -n 's/^id:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$g" | head -n1)"
    case "$seen" in *" $id "*) continue;; esac
    seen="$seen$id "
    st="$(sed -n 's/^status:[[:space:]]*\([a-z_]*\).*/\1/p' "$g" | head -n1)"
    [ "$st" = "open" ] || [ "$SHOW_ALL" = "--all" ] || continue
    issue="$(sed -n 's/^issue:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$g" | head -n1)"
    kind="$(sed -n 's/^kind:[[:space:]]*\([a-z_]*\).*/\1/p' "$g" | head -n1)"
    rec="$(sed -n 's/^recommended:[[:space:]]*\([^#]*\).*/\1/p' "$g" | head -n1 | sed 's/[[:space:]]*$//')"
    title="$(grep -m1 '^# ' "$g" | sed 's/^# //')"
    printf '%-12s [%-12s] %-8s 推荐:%-3s %s%s\n    %s\n' "$id" "$kind" "$st" "${rec:--}" "$title" "${issue:+  (GitHub ${issue/pr-/PR #})}" "$g"
    count=$((count+1))
  done
done <<< "$paths"

if [ "$count" -eq 0 ]; then
  echo "没有待处理的人工门。"
else
  echo
  echo "答复方式：在 GitHub Issue 勾一个选项 / 回复通知邮件（第一行写选项字母）；"
  echo "          或在控制塔会话里输入  /human-gate <门卡号>: <选项> <备注>。合并类门卡 = 去 PR 点 Merge。"
fi
