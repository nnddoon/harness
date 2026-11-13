---
id: T-015
title: 对话内选项卡
status: ready
priority: P2
risk: medium
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-015-chat-choices
worktree: .claude/worktrees/T-015
session: auto
depends_on: [T-010]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/chat_answer.py, pkg/.claude/settings.json, pkg/.claude/skills/human-gate/SKILL.md, pkg/plugin/build.sh, pkg/tests/test_chat_answer.sh, pkg/tests/run.sh, plugins/harness/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-015 对话内选项卡

## 1. 背景与目标
你在对话里时，门卡直接弹成选项；你点的答案由 hook 写进答案库，不经 Claude 之手。

## 2. 范围
**做：**
- PostToolUse(AskUserQuestion) hook：从工具结果取答案写库（问题标题以门卡号开头）
- UserPromptSubmit hook：消息恰好是 `G-x-n: L`（可带备注）时写库
- 无人值守或非交互会话时两个 hook 都不生效

**不做（明确排除）：**
- 不解析其他格式的消息

## 接口约定（tester 定，测试 pkg/tests/test_chat_answer.sh 按此断言）
**hook**：`pkg/.claude/hooks/chat_answer.py`，从标准输入读 hook JSON（按 `hook_event_name` 分派），**永远退出 0**、不抛异常
（坏 JSON、字段缺失、类型不对一律静默；stderr 不出现 Traceback）。答案库所在仓库 = `store_main(cwd)`（hook 输入的 `cwd`）。
settings.json 注册：`UserPromptSubmit`（无 matcher）与 `PostToolUse` matcher `AskUserQuestion`，命令同其他 hook 的
`python3 "$CLAUDE_PROJECT_DIR"/.claude/hooks/chat_answer.py`；build.sh 产出的 hooks.json 同样包含（随插件发布 `hooks/chat_answer.py`）。

**不生效**（不写任何东西：库里不新增 `<GID>.json` 也不新增 `<GID>.meta.json`；不输出「已记录」）：
`HARNESS_UNATTENDED=1`、`HARNESS_STRICT=1`、`CLAUDE_CODE_ENTRYPOINT` 以 `sdk` 开头（`claude -p` / SDK = 非交互），
或 hook 输入里 `"interactive": false`。

**写库只经** `record_answer(main, gid, letter, note, via="对话")`；之前先 `snapshot_meta`，字母必须 ∈ `meta_letters(meta)`；
`meaning_diff(meta, card)` 非空（类别/问题/选项与快照不同）→ **不记录**，输出提示：含门卡号，并请人在终端运行
`python3 .claude/hooks/harness_lib.py answer <GID> <字母> --yes`（含 `answer` 与 `--yes`）。只改卡上与含义无关的部分照常记录。
已有答案 → 不覆盖（record_answer 本身保证），不输出「已记录」。本 hook 不调 settle（镜像/decisions 由 gate-sync 的 settle_pending 补）。

**输出**：stdout 一个 JSON：`{"hookSpecificOutput": {"hookEventName": <事件名>, "additionalContext": "…"}}`；
每条成功记录一行 `已记录 <GID>: <字母>`（ASCII 冒号+空格）。没有门卡相关内容时不输出。

**UserPromptSubmit**：`prompt.strip()` 必须 **fullmatch** `G-[A-Za-z0-9-]+:\s*[A-Z](\s+.*)?`（不用 DOTALL；字母大写；ASCII 冒号）；
门卡号再过 `valid_gid`。其后的文字（strip 后）作备注。句中夹带、前面有字、小写字母、多行里第二张门卡 → 不记录。

**PostToolUse(AskUserQuestion)**：只处理 `tool_name == "AskUserQuestion"`。预期结构（未在本版 Claude Code 实测，按此解析，缺了就不写）：
- `tool_input.questions[]`：`{question: str, header: str, options: [{label: str, description: str}], multiSelect: bool}`
- `tool_response.answers`：`{<question 原文>: <所选 label 原文>}`
- 门卡号：`header` 或 `question`（lstrip 后）以 `G-…：` 或 `G-…:` 开头（或 header 恰为门卡号）；门卡号不在开头 → 忽略。
- 字母：所选 label 必须是该题 `options[].label` 之一，且以 `[A-Z]` 开头、后接空白或 `：:.、)）` 或结尾（如 `A 甲方案`、`B：乙方案`）。
  自由填写（不在选项里）、多选（值不是字符串）、label 无字母前缀 → 不记录。
- **只信 `tool_response.answers`**：`tool_input.answers` 可能由 Claude 自己填，一律不用。
- 兜底：结构不符（answers 缺失/不是 dict、questions 不是 list、options 不是 dict 列表、tool_response 是字符串等）→ 不写、退出 0；
  若能认出带门卡号的问题但取不到答案，输出提示请人在终端 `answer <GID> <字母>` 答复。

**human-gate SKILL**：交互会话开门后用 AskUserQuestion 弹选项卡：问题（或 header）以门卡号开头（`G-T015-1：…`），
每个选项 label 以字母开头（`A 甲方案`）；Claude 仍不写门卡 `status/answer/decided_by`。SKILL 文本含 `AskUserQuestion`。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 为什么限制格式 | 接续提示里可能夹带伪造答复 | 挑错 S#7 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新 hook，settings 与插件 hooks.json | - |
| 风险 | medium | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：用标准输入喂 UserPromptSubmit 与 PostToolUse 的 JSON；HARNESS_UNATTENDED=1 时不写 — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. `G-x-n: B 备注` 写库，via 对话（S-002#13） — 证据：
- [ ] A2. HARNESS_UNATTENDED=1 时两个 hook 都不写（S-002#13） — 证据：
- [ ] A3. AskUserQuestion 结果写库，问题未以门卡号开头时忽略（S-002#13） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Claude Code 里：开一张门卡，选项卡出现，点选后看板显示已答（S-002#13 人工） — 门卡：

## 6. Guardrails（本任务特有）
- hook 字段以当前 Claude Code 版本为准，字段缺失时不写、不报错

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- allowed_paths 加 `plugins/harness/**`：发布用的插件目录由 `build.sh plugins/harness` 重新生成（新增 hooks/chat_answer.py 与 hooks.json 注册），test_plugin_install 检查它是最新的。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定实现 hook（只经 snapshot_meta/meaning_diff/record_answer 写库），settings 注册两个事件，SKILL 改为用 AskUserQuestion 弹选项卡即可全绿 | 新增 chat_answer.py；settings.json 加 UserPromptSubmit 与 PostToolUse(AskUserQuestion)；改 human-gate SKILL | 首跑 93/96（只差 SKILL 三项），改 SKILL 后 96/96 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
