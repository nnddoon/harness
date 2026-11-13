---
id: T-016
title: Telegram 收件箱
status: proposed
priority: P2
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-016-telegram
worktree: .claude/worktrees/T-016
session: auto
depends_on: [T-010, T-013]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/cli/inbox_cmd.py, pkg/bin/harness, pkg/cli/answers.py, pkg/plugin/build.sh, pkg/tests/test_telegram.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-016 Telegram 收件箱

## 1. 背景与目标
门卡推到你的 Telegram，点按钮就算答复；bot 跑在控制面，token 不进仓库、不进 Claude 的环境。

## 2. 范围
**做：**
- `harness inbox setup`（在你终端输入 token、显示一次性配对码）/ `start` / `stop`
- 长轮询（≤ 20 秒）；新门卡发带按钮的消息；回调写答案库并接续任务
- 不可逆类（按动作判定）二次确认；只接受已配对 user id；按钮数据只含门卡号和选项
- `HARNESS_TELEGRAM_API` 指向假服务器做测试；标准库 urllib

**不做（明确排除）：**
- 不接受自由文本指令
- 不做 LINE / Discord（留接口）

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 为什么不用官方 Telegram channel | 它把消息交给 Claude，由 Claude 写答案；且要求会话一直开着 | 本对话分析 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新命令与 pid 管理（复用 T-013） | - |
| 对外契约 | 新配置文件 $XDG_CONFIG_HOME/harness/telegram.json | - |
| 依赖变更 | 无 | - |
| 风险 | high：外部输入通道 | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：假 Telegram 服务器（http.server）测配对、推送、按钮、二次确认、陌生 user id 被忽略 — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 完整验证 + 对抗审查（5 个挑错） — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 配对只认一次性码；陌生 user id 的消息与回调被忽略（S-002#14） — 证据：
- [ ] A2. 新门卡在两个轮询周期内发出（S-002#14） — 证据：
- [ ] A3. 按钮回调写库 via Telegram，并触发接续（S-002#14、S-002#8） — 证据：
- [ ] A4. 不可逆类需二次确认（S-002#14） — 证据：
- [ ] A5. 配置文件权限 600；token 不出现在仓库与日志（S-002#14） — 证据：
- [ ] A6. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A7. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的手机上：真机配对、收到门卡、点按后任务接续（S-002#14 人工） — 门卡：

## 6. Guardrails（本任务特有）
- 网络请求只发往 HARNESS_TELEGRAM_API（默认 api.telegram.org）

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
