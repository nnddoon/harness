---
id: T-025
title: 0.2.2：Python 与 Vue 的 lint / 类型检查配置算验证入口
status: claimed
priority: P0
risk: medium
size: S
source: human
spec: S-003
test_owner: tester
branch: task/T-025-lint-type-configs
worktree: .claude/worktrees/T-025
session: auto
depends_on: [T-023]
context_files: [docs/feedback/s003-review-r1.md, docs/feedback/r1-hotfix-scope.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/tests/test_lint_configs.sh, pkg/plugin/RELEASED.json, pkg/README.md, plugins/harness/**, docs/feedback/r1-hotfix-scope.md]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-025 0.2.2：Python 与 Vue 的 lint / 类型检查配置算验证入口

## 1. 背景与目标
项目文档 `R-1-hotfix-scope.md`（存档为 `docs/feedback/r1-hotfix-scope.md`）在 v0.2.1 上实测：用户的项目以 Python 和 Vue 为主，verify.sh 里的 lint / 类型检查 / 格式检查读的配置都没锁（`tsconfig*.json`、`eslint.config.*`、`.prettierrc*`、`mypy.ini`、`ruff.toml`、`.flake8`、`.coveragerc`；`uv run`、`poetry run` 前缀也没剥）。T-023 只补了 JS 测试运行器。T-024 的范围检查会从结果一侧兜底，但 strict 的 denyWrite 与 doctor 仍靠这张入口表；Mac 复测第 5 项也按这张表验收。

## 2. 范围
**做：**
- 在 T-023 的 `_JsScan` 运行器表里加：eslint（`eslint.config.*`、`.eslintrc*`、`.eslintignore`）、prettier（`.prettierrc*`、`prettier.config.*`、`.prettierignore`）、tsc / vue-tsc（`tsconfig*.json`，含 `tsconfig.app.json`、`tsconfig.vitest.json` 等）、vite（`vite.config.*`）、stylelint（`.stylelintrc*`、`stylelint.config.*`）。保守分支 JS_ALL 同步扩充。
- Python：verify 层与 package.json script 里都识别 ruff（`ruff.toml`、`.ruff.toml`，pyproject 已锁）、mypy（`mypy.ini`、`.mypy.ini`）、flake8（`.flake8`）、coverage / pytest-cov（`.coveragerc`）、pylint（`.pylintrc`、`pylintrc`）、black / isort（pyproject 已锁）。
- 前缀剥离：`uv run X`、`poetry run X`、`pipenv run X`、`hatch run X`、`pdm run X`、`python -m X` 先剥前缀再按 X 识别（现有 `python -m` 规则保留）。
- lock 文件不算验证入口（依赖门管）。
- doctor 表外运行器提示不变。

**不做（明确排除）：**
- 不读 tsconfig 的 `references` / `extends` 指向的文件（`tsconfig*.json` glob 已覆盖同目录；跨目录 → S-004）。
- 不改 T-024 范围检查。

## 3. 需求对齐与影响分析
| 问题 | 结论 | 来源 |
|---|---|---|
| 放进 0.2.2 | 是，用户的主要技术栈 | 项目文档 R-1-hotfix-scope.md；用户 2026-11-15 决定 R-1 做 0.2.2 热修 |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 文档表里每个「未锁」文件：任务分支只改它 → control-diff 命中，strict denyWrite 有它（Vue 脚手架、pytest+ruff+mypy、uv/make 三组） — 证据：
- [ ] A2. 对照组：只改源码或测试文件不命中 — 证据：
- [ ] A3. `uv run` / `poetry run` / `python -m` 前缀剥离后识别 — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 证据：

**B. 人工验收（→ 人工门）**
- （无；Mac 复测第 5 项覆盖真机）

## 6. Guardrails（本任务特有）
- 宁可多锁；不确定走保守分支（沿用 T-023）。

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）

## 9. 范围变更 / 依赖变更

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|

## 12. 教训

## 13. 对抗审查
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
