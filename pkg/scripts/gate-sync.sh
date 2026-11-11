#!/usr/bin/env bash
# GitHub 决策收件箱：把你在 GitHub（或邮件回复）里的答复写回门卡并接续任务。
#   scripts/gate-sync.sh                 同步一次（只写回，告诉你哪些任务可以继续）
#   scripts/gate-sync.sh --resume        同步并在后台自动接续已解除阻塞的任务（claude -p /goal）
#   scripts/gate-sync.sh --watch 300     每 300 秒同步一次（前台常驻）
#   scripts/gate-sync.sh setup           检查 gh、建标签、提示要打开的通知设置
#   scripts/gate-sync.sh publish <门卡>  手动把某张门卡发布成 Issue
#   scripts/gate-sync.sh install-cron    安装每 5 分钟一次的 crontab（带 --resume）
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MAIN="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
PY="${HARNESS_PYTHON:-python3}"

case "${1:-}" in
  setup|publish)
    cd "$ROOT" && exec $PY -B .claude/hooks/gate_github.py "$@" ;;
  install-cron)
    mkdir -p "$MAIN/.harness/logs"
    LINE="*/5 * * * * cd \"$MAIN\" && PATH=\"$PATH\" scripts/gate-sync.sh --resume --quiet >> .harness/logs/gate-sync.log 2>&1"
    ( crontab -l 2>/dev/null | grep -vF "scripts/gate-sync.sh --resume" ; echo "$LINE" ) | crontab -
    echo "✓ 已安装：$LINE"
    echo "  移除：crontab -l | grep -vF 'scripts/gate-sync.sh' | crontab -"
    echo "  （Windows 原生不支持 cron：用「任务计划程序」每 5 分钟运行 bash scripts/gate-sync.sh --resume，或在 WSL 里装 cron）"
    ;;
  *)
    cd "$MAIN" && exec $PY -B .claude/hooks/gate_github.py sync "$@" ;;
esac
