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

## 接口约定 v2（第 2 轮；与 v1 冲突处以此为准）
**(1) 选项卡严格对照快照**（AskUserQuestion；不符 → 整题不记录）：
- 门卡号只从 `question` 开头取：`question` 以 `<GID>：` 或 `<GID>:` 开头（前面不许有字），其后文字 strip 后 **== meta `title`**（门卡 `# <GID> …` 标题去掉门卡号）。
- `header` 缺省、空串，或恰为同一个 `<GID>`；其他任何值（另一张门卡号、「门卡」等）→ 不记录。只有 header 带门卡号、question 不以门卡号开头 → 不当门卡题。
- **每个** option 的 `label` 必须恰为 `"<L> <meta 选项 L 的原文>"`（一个 ASCII 空格；`L` ∈ meta 字母）。`A：甲方案`、`A 甲方案（推荐）`、`A 不，先放着`（与快照原文不同）都不符；推荐写进 `description`。
- 所选值必须是这些 label 之一。
**(2) 有后续效果的门卡，对话里不记录 A**：meta `kind` ∉ {ui, sensory, ambiguity}（即 design / irreversible / external / unlock / 其他一切），
或 meta 有 `then` / `then_tasks` / `then_policy` / `then_rules` / `paths`，或库里有 `<GID>.pr.json`（`read_pr`）→ 字母 A 不记录（两个通道都一样），
提示请人在终端（`… answer <GID> A`）、看板或 Telegram 答复；门卡保持未答（之后终端照常可答）。非 A 字母照常记录；无效果门卡的 A 照常记录。
（meta 的 `then` 只认 ready：卡上 `then: done` 在快照里是空 → 不算效果。）
**(3) 每个结果都给人看**：stdout JSON 顶层加 `systemMessage`（与 `additionalContext` 同内容或摘要）：记录成功含 `已记录 <GID>: <L>`；
不记录（已答过、快照不符、有效果的 A、对照不符、预填答案、取不到答案）含门卡号；不符/有效果时含 `answer`，有效果时还含「看板」，快照不符时含 `--yes`。与门卡无关的输入仍不输出。
**(4) `tool_input` 里已有 `answers` 键** → 本次调用一题都不记录（提示含门卡号）。
⚠ 风险：若本版 Claude Code 把界面收集的答案经 updatedInput 放进 `tool_input.answers` 再交给 PostToolUse，此条会让选项卡通道永不记录；B1 人工验收要专门看这一点，届时改成「tool_response 与 tool_input 都有且一致」之类的规则。
**(5) 嵌套运行不生效**。实测（claude 2.1.42，UserPromptSubmit hook 打印环境）：
- `CLAUDECODE=1` 由 Claude Code 自己给 hook 设上（`env -u CLAUDECODE claude -p …` 的 hook 里仍是 1）→ **不能**用来判断嵌套，有它也照常生效。
- `claude -p` / 无 TTY 启动时 `CLAUDE_CODE_ENTRYPOINT` 被改写为 `sdk-cli`（父进程设成 `cli` 也一样）→ v1 的 sdk 判断已覆盖 Bash 工具里起的 `claude -p`。
- 剩下的是有 TTY 的嵌套交互会话：hook 沿父进程链（`ps -o ppid=,comm=,args= -p <pid>`，Linux / macOS 都有）向上数 Claude Code 进程，
  **≥ 2 个 → 不生效**。认定为 Claude Code 进程：`comm` 的 basename 是 `claude`，或 `args` 第 1 或第 2 个词的 basename 是 `claude`
  （原生安装 `claude …`；npm 安装 `node …/bin/claude …`；脚本 `bash …/claude …`）。ps 失败 → 按 1 个处理（不因此关掉通道）。
- 另认 `HARNESS_NESTED=1`（启动器 / 循环从 Claude 里再起 Claude 时设置；本任务不改启动器，记入 §8）。
- 测试：hook 以「孤儿进程」运行（父进程链上没有真实 claude），用 `$T/bin/claude`（只是 `"$@"` 的 bash 脚本）包一层 → 生效，包两层 → 不生效。

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
- （tester）启动器 / harness-loop 在 Claude 里再起 Claude 时应设 `HARNESS_NESTED=1`（chat_answer.py 已认这个标记；harness_lib.py launch 与 scripts/ 不在本任务 allowed_paths）。

## 9. 范围变更 / 依赖变更
- allowed_paths 加 `plugins/harness/**`：发布用的插件目录由 `build.sh plugins/harness` 重新生成（新增 hooks/chat_answer.py 与 hooks.json 注册），test_plugin_install 检查它是最新的。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定实现 hook（只经 snapshot_meta/meaning_diff/record_answer 写库），settings 注册两个事件，SKILL 改为用 AskUserQuestion 弹选项卡即可全绿 | 新增 chat_answer.py；settings.json 加 UserPromptSubmit 与 PostToolUse(AskUserQuestion)；改 human-gate SKILL | 首跑 93/96（只差 SKILL 三项），改 SKILL 后 96/96 |
| 2 | 第 2 轮（接口约定 v2）：AUQ 改为严格对照快照（question 前缀+标题、header、label 恰为「L 原文」）、有效果门卡的 A 不记录、tool_input 预填 answers 整次不记录、输出加 systemMessage、嵌套（HARNESS_NESTED / 父进程链 ≥2 个 claude）不生效；ps 走链只在认出门卡内容后才做 | 重写 chat_answer.py（复用 snapshot_meta/meta_option/meaning_diff/read_pr/record_answer）；SKILL 按 v2 写法更新 | 148/148 一次通过 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
