#!/usr/bin/env bash
# 改完一个文件后立刻跑的快检（几秒内完成）：只检查这一个文件。退出码非 0 = 结果会回给 Claude。
# ← 安装时改成你的项目命令；保持空着 = 不做快检。
# 例（TypeScript）：
#   case "$1" in *.ts|*.tsx) npx eslint --max-warnings 0 "$1" && npx tsc --noEmit -p . ;; esac
# 例（Python）：
#   case "$1" in *.py) ruff check "$1" && mypy "$1" ;; esac
exit 0
