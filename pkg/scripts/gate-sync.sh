#!/usr/bin/env bash
# GitHub 决策收件箱：把你在 GitHub（或邮件回复）里的答复写回门卡并接续任务。
#   scripts/gate-sync.sh                 同步一次（只写回，告诉你哪些任务可以继续）
#   scripts/gate-sync.sh --resume        同步并在后台自动接续已解除阻塞的任务（claude -p /goal）
#   scripts/gate-sync.sh --watch 300     每 300 秒同步一次（前台常驻）
#   scripts/gate-sync.sh setup           检查 gh、建标签、提示要打开的通知设置
#   scripts/gate-sync.sh publish <门卡>  手动把某张门卡发布成 Issue
#   scripts/gate-sync.sh install-cron    安装每 5 分钟一次的 crontab（带 --resume），${HARNESS_CRON_DAYS:-30} 天后到期
#   定时任务行尾带 `# harness repo=<主仓库> expires=<日期>`；过了到期日，下一次运行把自己从 crontab 删掉、
#   在 .harness/reports/expired-cron.txt 留一行，不再同步。crontab 经 ${HARNESS_CRONTAB:-crontab}；HARNESS_NOW 覆盖「现在」（UTC）。
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MAIN="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
PY="${HARNESS_PYTHON:-python3}"
CRONTAB="${HARNESS_CRONTAB:-crontab}"
TAG="# harness repo=$MAIN "   # 本仓库的行；结尾的空格让 /x/r 不匹配 /x/r-other
valid_now() { [ -z "${HARNESS_NOW:-}" ] || [[ "$HARNESS_NOW" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
day() {  # day N —— 今天 + N 天（UTC，YYYY-MM-DD）；失败时不输出、返回非 0
  $PY -B -c 'import os, sys, time, datetime as d
t = float(os.environ.get("HARNESS_NOW") or time.time())
print(d.datetime.fromtimestamp(t, d.timezone.utc).date() + d.timedelta(days=int(sys.argv[1])))' "${1:-0}" 2>/dev/null
}
cron_list() { $CRONTAB -l 2>/dev/null || true; }   # 还没有 crontab → 空表
cron_others() {  # crontab 去掉本仓库的 harness 行和本仓库的旧格式行（T-013 之前写的、没有 # harness 标记）
  cron_list | TAG="$TAG" OLD="cd \"$MAIN\" " awk '!(index($0, ENVIRON["TAG"]) ||
    (!index($0, "# harness") && index($0, ENVIRON["OLD"]) && index($0, "scripts/gate-sync.sh --resume")))'
}
cron_locked() {  # cron_locked CMD… —— 在 crontab.lock 上 flock 后执行（有 flock 时），避免并发读-改-写互相覆盖
  local d="${XDG_STATE_HOME:-$HOME/.local/state}/harness"
  if command -v flock >/dev/null 2>&1 && mkdir -p "$d" 2>/dev/null; then
    ( flock -w 30 9 || true; "$@" ) 9>>"$d/crontab.lock"
  else "$@"; fi
}
cron_replace() { { cron_others; [ -z "${1:-}" ] || printf '%s\n' "$1"; } | $CRONTAB -; }   # cron_replace [新行]
check_expiry() {  # 本仓库的定时任务过了到期日：删掉自己、留提示、退出 0（不同步）
  local line exp today
  line="$(cron_list | grep -F -- "$TAG" | head -n1)"; [ -n "$line" ] || return 0
  exp="$(printf '%s\n' "$line" | sed -n 's/.* expires=\([0-9][0-9-]*\).*/\1/p')"
  [[ "$exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0   # 看不懂的到期日：不动它，照常同步
  if valid_now; then today="$(day 0)"
  else echo "⚠ HARNESS_NOW 不是数字（$HARNESS_NOW），到期检查按当前时间算" >&2; today="$(HARNESS_NOW= day 0)"; fi
  [[ "$today" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  [[ "$exp" < "$today" ]] || return 0
  cron_locked cron_replace
  mkdir -p "$MAIN/.harness/reports"
  echo "$today 定时任务已到期（expires=$exp），已从 crontab 移除；还要的话重跑 scripts/gate-sync.sh install-cron" \
    >> "$MAIN/.harness/reports/expired-cron.txt"
  echo "■ 定时任务已到期（expires=$exp），已移除，本次不同步"
  exit 0
}
lib_dir() { if [ -f "$1/.claude/hooks/gate_github.py" ]; then echo .claude/hooks; else echo .harness/lib; fi; }   # 插件模式：库在 .harness/lib

case "${1:-}" in
  setup|publish)
    cd "$ROOT" && exec $PY -B "$(lib_dir "$ROOT")/gate_github.py" "$@" ;;
  install-cron)
    valid_now || { echo "✗ HARNESS_NOW 要是数字（Unix 秒），现在是：$HARNESS_NOW" >&2; exit 2; }
    DAYS="${HARNESS_CRON_DAYS:-30}"
    [[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$((10#$DAYS))" -gt 0 ] || { echo "✗ HARNESS_CRON_DAYS 要是正整数（天数），现在是：$DAYS" >&2; exit 2; }
    EXP="$(day "$((10#$DAYS))")"
    [[ "$EXP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "✗ 算不出到期日（HARNESS_CRON_DAYS=$DAYS 太大？）" >&2; exit 2; }
    mkdir -p "$MAIN/.harness/logs"
    LINE="*/5 * * * * cd \"$MAIN\" && PATH=\"$PATH\" scripts/gate-sync.sh --resume --quiet >> .harness/logs/gate-sync.log 2>&1 ${TAG}expires=$EXP"
    cron_locked cron_replace "$LINE" || { echo "✗ 写 crontab 失败" >&2; exit 1; }
    echo "✓ 已安装：$LINE"
    echo "  移除：harness down（只删本仓库带 # harness 标记的行）"
    echo "  （Windows 原生不支持 cron：用「任务计划程序」每 5 分钟运行 bash scripts/gate-sync.sh --resume，或在 WSL 里装 cron）"
    ;;
  *)
    check_expiry
    cd "$MAIN" && exec $PY -B "$(lib_dir "$MAIN")/gate_github.py" sync "$@" ;;
esac
