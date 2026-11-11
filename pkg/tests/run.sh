#!/usr/bin/env bash
# 跑 pkg/tests/test_*.sh，全部通过才返回 0。每个测试文件最后一行打印 "<通过>/<总数> passed"。
cd "$(dirname "$0")" || exit 1
fail=0; any=0
for t in test_*.sh; do
  [ -f "$t" ] || continue
  any=1
  out="$(bash "$t" 2>&1)"; rc=$?
  echo "$t: $(printf '%s\n' "$out" | tail -1)"
  [ $rc -eq 0 ] || { fail=1; printf '%s\n' "$out" | grep -E '^FAIL' | head -20; }
done
[ $any -eq 1 ] || echo "(还没有产品测试)"
exit $fail
