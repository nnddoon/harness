#!/usr/bin/env bash
# 改完一个文件立刻跑：Python 编译检查、bash 语法检查。
case "$1" in
  *.py|*/bin/harness) python3 -B -m py_compile "$1" ;;
  *.sh) bash -n "$1" ;;
esac
