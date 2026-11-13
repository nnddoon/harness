---
id: T-011
title: 发布与推送移到控制面
status: ready
priority: P1
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-011-publish-outside
worktree: .claude/worktrees/T-011
session: auto
depends_on: [T-009, T-010]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/gate_github.py, pkg/.claude/hooks/harness_lib.py, pkg/scripts/harness-loop.sh, pkg/scripts/gate-sync.sh, pkg/.claude/skills/task-close/SKILL.md, pkg/.claude/settings.json, pkg/tests/test_publish.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-011 发布与推送移到控制面

## 1. 背景与目标
strict 模式下 Claude 和它的 hooks 不做任何 GitHub 写操作；推分支、开 PR、开门卡 Issue、推素材由调度器或 gate-sync 在控制面完成。

## 2. 范围
**做：**
- goal_prompt 与 task-close：strict 时只写交接包和合并门卡草稿，不推不开 PR
- 调度器 finish()：控制路径检查通过后推分支、开 PR、把 PR 号写入答案库
- 门卡 Issue 发布与素材推送从 PostToolUse hook 移到 gate-sync；standard 模式保留旧行为

**不做（明确排除）：**
- 不改 standard 模式下的交互流程

## 接口约定（tester 写，builder 按此实现；测试 pkg/tests/test_publish.sh）
- **strict 判定**：环境变量 `HARNESS_STRICT=1`（启动器 scrub_env 设置）。调度器（harness-loop）与 `gate_github.start_run` 启动的运行一律 strict。
- **goal_prompt**：`goal_prompt(tid, note="", strict=False)`；CLI `harness_lib.py goal <TID> [--note N] [--strict]`。
  strict 文本必须含「不推送」「不开 PR」和合并门卡草稿名 `G-<T无连字符>-merge`（如 `G-T050-merge`），仍含 `/task-close <TID>`；standard 输出与现在逐字相同。
  harness-loop 的 `launch()` 用 `--strict`；`gate_github.start_run` 传 `strict=True`。
- **task-close SKILL.md 第 4 步**：写明 `HARNESS_STRICT=1` 时只写交接包和合并门卡草稿 `.harness/gates/G-<T无连字符>-merge.md`（kind: irreversible，`pr:` 留空），不推送、不 `gh pr create`；否则保持现有流程（推送 + `gh pr create`）。
- **gate_github.py hook（PostToolUse）**：`HARNESS_STRICT=1` 时直接返回：不调用 gh（连只读也不调）、不 git commit/push 素材、不改门卡、不写答案库（auto_answer 也交给 gate-sync）、不输出。standard 行为不变；`publish` 子命令不变。
- **finish()（非整合模式，状态 review，task-branch + control-diff 通过之后）**：在主仓库 `git push origin <SHA>:refs/heads/<branch>`（SHA = finish 已解析并检查过的那个；没有 origin 就跳过）→ `gh pr create --base main --head <branch> …`（每任务一次）→ 从输出解析 PR 号 → `record_pr(main, "G-<T无连字符>-merge", n)`（合并门卡草稿不存在时调度器在主仓库写一张 kind irreversible）。push / pr create 失败：任务保持 review、不记 PR、打日志。control-diff 命中或 blocked：不推、不开 PR。整合模式维持现状（只推整合分支、开整合 PR）。
- **gate-sync（`gate_github.py sync`，含 harness-loop 开头那次）**：在控制面发布每张 open、尚未发布（无 issue 映射）的门卡：有 `read_pr` 的挂到 PR（pr comment，不开 Issue），合并门卡没有 PR 映射时不发布；其余 `issue create` + `record_issue`。素材若不在远端任务分支上，由控制面从主仓库按 SHA、先 control-diff 再推送。重复运行不重复发布。
- **测试替身**：`pkg/tests/fake/gh_publish.py`（有状态，calls.jsonl 记 argv / HARNESS_FAKE_CLAUDE / HARNESS_STRICT / 是否写调用；`pr create` 号从 101 起）；假远端 = 裸仓库 + `hooks/update` 记录每次 ref 更新；git 记录器记录每次 git 调用。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| hook 为什么也不行 | hook 在沙箱外、继承环境，可用 git 凭证助手 | 挑错 F#2 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | goal_prompt、task-close 第 4 步、finish()、整合 PR、publish/push_assets | harness_lib.py:160-166；task-close/SKILL.md:25；harness-loop.sh:215-226；gate_github.py:133-198 |
| 受影响测试 | gate 发布相关用例 | pkg/tests |
| 风险 | high | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester：假 gh / 假远端记录写调用，strict 下 Claude 侧为 0、调度器侧完成推送与 PR — 结果：pkg/tests/test_publish.sh 52 项，现状 13/52（红，39 项按预期失败）
- [ ] 2. 改 goal 与 task-close — 结果：
- [ ] 3. 调度器与 gate-sync 接管发布 — 结果：
- [ ] 4. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. strict 模式一次完整任务：Claude 及 hooks 对假 gh/假远端写调用 0 次；调度器推分支、开 PR、开门卡 Issue 各 1 次（S-002#11） — 证据：
- [ ] A2. standard 模式行为与现在一致（现有测试通过） — 证据：
- [ ] A3. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A4. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 不改 decisions.md 格式
- 不在 standard 模式下改变用户可见流程

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
