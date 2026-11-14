---
id: T-018
title: strict 加固：钥匙串、验证入口、连接器、locked_paths
status: ready
priority: P0
risk: high
size: M
source: human
spec: S-003
test_owner: tester
branch: task/T-018-strict-hardening
worktree: .claude/worktrees/T-018
session: auto
depends_on: []
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s002-field-test.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/cli/doctor_cmd.py, pkg/scripts/harness-loop.sh, pkg/tests/test_strict_hardening.sh, pkg/tests/fake/**, plugins/harness/**, pkg/scripts/test-harness.sh]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-018 strict 加固：钥匙串、验证入口、连接器、locked_paths

## 1. 背景与目标
真机验收发现 strict 有四个洞：macOS 钥匙串里的 GitHub 凭证在沙箱内可读（F-2）、package.json 能改掉验证（F-3）、claude.ai 连接器可用（F-4）、任务 locked_paths 只靠 hook（F-10）。补上它们。

## 2. 范围
**做：**
- macOS strict 启动前检查钥匙串里无需授权可读的 GitHub 凭证（只查存在：`security find-generic-password -s gh:github.com`、`security find-internet-password -s github.com`，不带 -w），有则拒绝并给修复办法；HARNESS_ALLOW_KEYCHAIN=1 放行并标记；doctor 报告
- 从 verify.sh / quick-check.sh 推出验证入口清单文件，加进 CONTROL_PATHS 等价清单（沙箱 denyWrite + control-diff）
- strict 启动器：ENABLE_CLAUDEAI_MCP_SERVERS=false、--strict-mcp-config、permissions.deny 加连接器前缀
- --task 时把任务卡 locked_paths 加进 denyWrite 与 Edit/Write deny；control-diff 拒绝改了本任务 locked_paths 的分支

**不做（明确排除）：**
- 不改 Claude Code 沙箱实现
- 不处理任务自锁（T-021）

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 钥匙串怎么挡 | 沙箱只能放行 Mach 服务不能单独拒绝，所以改为不让凭证留在钥匙串里 | S-003 §2，claudeissues #40209/#45476 |
| 连接器开关 | claude CLI 有 ENABLE_CLAUDEAI_MCP_SERVERS 与 --strict-mcp-config | 本机 claude 2.1.323 --help / 二进制字符串 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | strict_settings / launch_argv / control_diff / doctor | harness_lib.py strict launcher 段 |
| 风险 | high：安全边界 | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester 写失败测试（假 security 命令、假 claude 记录 argv/env） — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 对抗审查 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. HARNESS_PLATFORM=macos 且假 security 报告存在 gh:github.com → strict 退出 3 且提示 --insecure-storage；HARNESS_ALLOW_KEYCHAIN=1 放行；检查命令不带 -w（S-003#1） — 证据：
- [ ] A2. verify.sh 含 npm run test 时 package.json 进 denyWrite 与 control-diff；Makefile / pyproject 同理（S-003#2） — 证据：
- [ ] A3. strict 启动 env 含 ENABLE_CLAUDEAI_MCP_SERVERS=false，argv 含 --strict-mcp-config，deny 含 mcp__claude_ai_ 前缀（S-003#3） — 证据：
- [ ] A4. 任务卡 locked_paths 进 denyWrite 与 Edit/Write deny；改 locked_paths 的分支 control-diff 命中（S-003#7） — 证据：
- [ ] A5. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A6. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Mac 上：钥匙串有 gh 凭证时 strict 拒绝；`gh auth login --insecure-storage` 后能启动且沙箱内 security 读不到 — 门卡：

## 6. Guardrails（本任务特有）
- 检查钥匙串时绝不读取凭证内容

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
