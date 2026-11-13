#!/usr/bin/env bash
# 汇总所有 worktree 中待答的人工门卡。是否待答以答案库为准（harness_lib.gate_state），不看卡上的 status:。
# 用法：scripts/gates.sh [--all]   (--all 同时显示已答复的)
set -uo pipefail
SHOW_ALL="${1:-}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOKS="$ROOT/.claude/hooks"; [ -f "$HOOKS/harness_lib.py" ] || HOOKS="$ROOT/.harness/lib"   # 插件模式：库在 .harness/lib
count=0; seen=" "

# 答案库里的状态：open | answered | unknown（库读不了）。库位置随 XDG_STATE_HOME（harness_lib.state_dir）。
gstate() {
  python3 -B - "$HOOKS" "$ROOT" "$1" <<'PY' 2>/dev/null || echo unknown
import sys
sys.path.insert(0, sys.argv[1])
import harness_lib as H
from pathlib import Path
main = H.main_checkout(sys.argv[2]) or Path(sys.argv[2])
print(H.gate_state(main, sys.argv[3]))
PY
}

paths="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
[ -n "$paths" ] || paths="$ROOT"
# worktrees first (newest state of a gate), main checkout last; each gate id shown once
paths="$(printf '%s\n' "$paths" | awk '{a[NR]=$0} END{for(i=NR;i>0;i--)print a[i]}')"

while IFS= read -r wt; do
  for g in "$wt"/.harness/gates/G-*.md; do
    [ -f "$g" ] || continue
    id="$(sed -n 's/^id:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$g" | head -n1)"
    [ -n "$id" ] || continue
    case "$seen" in *" $id "*) continue;; esac
    seen="$seen$id "
    st="$(gstate "$id")"
    [ "$st" = "answered" ] && [ "$SHOW_ALL" != "--all" ] && continue
    card_st="$(sed -n 's/^status:[[:space:]]*\([a-z_]*\).*/\1/p' "$g" | head -n1)"
    flag=""
    if [ "$st" = "answered" ] && [ "$card_st" = "open" ]; then flag="  答案不一致：库里已答，卡上仍是 open"
    elif [ "$st" = "open" ] && [ -n "$card_st" ] && [ "$card_st" != "open" ]; then flag="  答案不一致：卡上写 $card_st，库里没有答案"
    elif [ "$st" = "unknown" ]; then flag="  答案库读不了，状态未知"
    fi
    issue="$(sed -n 's/^issue:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$g" | head -n1)"
    kind="$(sed -n 's/^kind:[[:space:]]*\([a-z_]*\).*/\1/p' "$g" | head -n1)"
    rec="$(sed -n 's/^recommended:[[:space:]]*\([^#]*\).*/\1/p' "$g" | head -n1 | sed 's/[[:space:]]*$//')"
    title="$(grep -m1 '^# ' "$g" | sed 's/^# //')"
    printf '%-12s [%-12s] %-8s 推荐:%-3s %s%s%s\n    %s\n' "$id" "$kind" "$st" "${rec:--}" "$title" "${issue:+  (GitHub ${issue/pr-/PR #})}" "$flag" "$g"
    count=$((count+1))
  done
done <<< "$paths"

if [ "$count" -eq 0 ]; then
  echo "没有待处理的人工门。"
else
  echo
  echo "答复方式（只认第一次，由控制面记进答案库）："
  echo "  终端      python3 ${HOOKS#"$ROOT"/}/harness_lib.py answer <门卡号> <选项> [备注]   （先看 show <门卡号>）"
  echo "  看板      harness serve → 门卡页点选项"
  echo "  GitHub    在 Issue 勾一个选项 / 回复通知邮件（第一行写选项字母）；合并类门卡 = 去 PR 点 Merge"
  echo "  对话      在会话里选 Claude 弹出的选项卡"
  echo "  Telegram  harness inbox setup 后点手机上的按钮"
fi
