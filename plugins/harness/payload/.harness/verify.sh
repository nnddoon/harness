#!/usr/bin/env bash
# 完整验证（全部测试 + lint + 类型 + 构建）。夜间模式每次往整合分支合并后都会跑它，红了就撤回那个任务。
# ← 安装时改成你的项目命令（与 CLAUDE.md「验证命令」一致）。未配置时直接失败，避免把没验证的东西合进去。
echo "verify.sh 未配置：请编辑 .harness/verify.sh" >&2
exit 3
# 例：
# set -e
# pnpm test && pnpm lint && pnpm typecheck && pnpm build
