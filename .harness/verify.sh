#!/usr/bin/env bash
# 完整验证：harness 自测 + 产品新增的测试 + 语法检查。
set -e
cd "$(git rev-parse --show-toplevel)"
for f in pkg/.claude/hooks/*.py pkg/cli/*.py pkg/bin/harness; do [ -f "$f" ] && python3 -m py_compile "$f"; done
for f in pkg/scripts/*.sh pkg/tests/*.sh; do [ -f "$f" ] && bash -n "$f"; done
bash pkg/scripts/test-harness.sh | tail -1
bash pkg/tests/run.sh
