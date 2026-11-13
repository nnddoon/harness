---
id: T-010
title: 答案库与门卡语义
status: ready
priority: P0
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-010-answers-store
worktree: .claude/worktrees/T-010
session: auto
depends_on: [T-008]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/gate_github.py, pkg/.claude/hooks/harness_lib.py, pkg/cli/serve_cmd.py, pkg/cli/answers.py, pkg/.claude/skills/human-gate/SKILL.md, pkg/.claude/rules/human-gates.md, pkg/.harness/gates/_TEMPLATE.md, pkg/tests/test_answers.sh, pkg/tests/test_serve_answer.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-010 答案库与门卡语义

## 1. 背景与目标
门卡答案只认仓库外的答案库，「哪个选项算批准」由控制面决定。修掉 v0.1 的三个漏洞（旧 PR 冒充批准、伪造 Issue 标记、接续提示伪造答复）。

## 2. 范围
**做：**
- `pkg/cli/answers.py`：唯一写入入口 `record(gid, letter, note, via)`，存 `$XDG_STATE_HOME/harness/<仓库>/answers/`；同一门卡只认第一次
- 终端、看板、GitHub 同步改走它；门卡 `answer:` 与 decisions.md 由控制面写镜像
- 门卡语义：批准项固定 A；then 只允许 ready；pr 只认控制面为该任务开的 PR；门卡号↔Issue 号在发布时记入库，不再解析正文；渲染时去掉正文里的 `<!--`
- resume_pending 移入库；自动决定由控制面检查 auto-decide.txt 后写入
- 迁移 v0.1 已有答案；human-gate skill 与规则改为 Claude 只开卡、不写答案
- 启动器的 unlock：T-008 在 strict 下让 unlock 一律不生效；改为从答案库读取已批准的 unlock 门卡后放开对应路径（harness_lib.strict_settings）

**不做（明确排除）：**
- 不实现对话与 Telegram 通道（T-015、T-016）
- 不改发布时机（T-011）

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 库放哪里 | 仓库外状态目录，所有 worktree 读同一份 | 挑错 F#3 |
| 旧答案 | 迁移，迁移后不报不一致 | 挑错 F#7 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | apply_answer、sync_once、PR 门卡路径、pending_resumes、看板 POST /answer | gate_github.py:236-285,317-415,302-314；serve_cmd.py:424-466 |
| 对外契约 | decisions.md 行格式不变，新增 via 字段值 | - |
| 受影响测试 | test_serve_answer 49 项需改为断言库 | pkg/tests/test_serve_answer.sh |
| 风险 | high | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：三个漏洞各写一个失败测试；Claude 改卡里 answer/approve_options/then/pr 不改变结果；迁移测试 — 结果：
- [ ] 2. 实现 answers.py 并接入三个现有通道 — 结果：
- [ ] 3. 门卡语义收紧与迁移 — 结果：
- [ ] 4. skill/规则改写；完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 用旧的已合并 PR 号、伪造 Issue 标记、把拒绝项写进 approve_options、then: done，都不会批准或改任务状态（S-002#9） — 证据：
- [ ] A2. Claude 改门卡 answer:/status: 不触发接续，看板标「答案不一致」（S-002#9） — 证据：
- [ ] A3. 终端、看板、GitHub 三个通道写同一库，decisions.md 记 via，重复答复只认第一次（S-002#8） — 证据：
- [ ] A4. 自动决定只由控制面写入（S-002#10） — 证据：
- [ ] A5. 迁移 v0.1 门卡后看板无不一致（S-002#19） — 证据：
- [ ] A6. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A7. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- decisions.md 行格式保持兼容
- 不删除现有门卡文件

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
