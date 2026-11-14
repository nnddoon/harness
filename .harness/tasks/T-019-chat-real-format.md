---
id: T-019
title: 对话选项卡按真机格式记录
status: ready
priority: P0
risk: medium
size: S
source: human
spec: S-003
test_owner: tester
branch: task/T-019-chat-real-format
worktree: .claude/worktrees/T-019
session: auto
depends_on: []
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s002-field-test.md]
allowed_paths: [pkg/.claude/hooks/chat_answer.py, pkg/.claude/settings.json, pkg/plugin/build.sh, pkg/tests/test_chat_answer.sh, pkg/cli/doctor_cmd.py, pkg/tests/test_doctor.sh, plugins/harness/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-019 对话选项卡按真机格式记录

## 1. 背景与目标
真机上 Claude Code 把用户答案写回 PostToolUse 的 tool_input.answers，原实现把它当成预填一律拒收（F-5）。改为在 PreToolUse 判定预填。

## 2. 范围
**做：**
- PreToolUse(AskUserQuestion)：tool_input 带 answers 即拒绝这次调用（permissionDecision deny + 原因）
- PostToolUse：从 tool_input.answers（问题 → label）或 tool_response 读取答案并按快照严格匹配记录
- Other 自由输入不记录并说明原因；有后果的 A 给正确理由

**不做（明确排除）：**
- 不放宽快照逐字匹配

## 接口约定（tester 定，测试 pkg/tests/test_chat_answer.sh 按此断言；与 T-015 接口约定 v1/v2 冲突处以此为准）
**真机字段（现场报告 §2，Claude Code 2.1.321/2.1.325）**：PreToolUse(AskUserQuestion) `tool_input` 只有 `questions`；
PostToolUse `tool_input` 有 `questions`、`answers`（有时还有 `annotations`）。`answers` = `{<question 原文>: <所选 option label 原文>}`；
用户选 Other 自由输入时，值就是他打的那段文字。Esc 取消 → 只有 PreToolUse，没有 PostToolUse（不记录，门卡仍待答）。

**注册**：`pkg/.claude/settings.json` 的 `PreToolUse` 加一项 `{"matcher": "AskUserQuestion", "hooks": [{"type": "command",
"command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/chat_answer.py"}]}`（不加 onFailure），原 `UserPromptSubmit` 与
`PostToolUse` matcher `AskUserQuestion` 两项保留。改完跑 `bash pkg/plugin/build.sh plugins/harness`，让发布的 `plugins/harness/hooks/hooks.json`
三处都引用 `${CLAUDE_PLUGIN_ROOT}/hooks/chat_answer.py`、`plugins/harness/hooks/chat_answer.py` 与 pkg 一致（test_plugin_install.sh 会 diff）。
`run()` 按 `hook_event_name` 分派 `UserPromptSubmit` / `PreToolUse` / `PostToolUse`，其他事件静默。仍然永远退出 0、不出 Traceback。

**PreToolUse（预填判定，只在这里做）**：
- 不生效条件只看 `off_cheap`（UNATTENDED / STRICT / NESTED=1 / sdk 入口 / `interactive:false`）→ 无输出。不调 `nested()`（拒绝无害）。
- `tool_name != "AskUserQuestion"`、`tool_input` 不是 dict、`questions` 不是 list、没有一题是门卡题（`question` 以 `<GID>：`/`<GID>:` 开头且 `valid_gid`）→ **无输出**
  （不干扰非门卡选项卡，如 setup 技能的「照这样接入吗？」）。
- 有门卡题、且 `tool_input` 里**出现键 `answers`**（任何值，含 `{}`、`null`）→ stdout 一个 JSON：
  `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": <原因>}, "systemMessage": <原因>}`。
  原因逐张列出门卡号，含「预填」二字，并说明：去掉 answers 重新弹选项卡让人自己选，或请人在终端 `… answer <GID> <字母>` 答复。
- 有门卡题、没有 `answers` → **无输出**（绝不输出 `permissionDecision: "allow"`，不绕过任何权限流程）。
- PreToolUse 一律**不写任何东西**：不调 `record_answer`，也不调 `snapshot_meta`（库里不新增 `<GID>.json` / `<GID>.meta.json`）。

**PostToolUse（记录）**：
- 答案来源：`tool_input.answers` 是 dict → 用它；否则 `tool_response.answers` 是 dict → 用它（旧格式兼容）；都不是 → 「没取到选项卡的答案」提示（含门卡号与 `answer`），不记录。
  两边都有且不同 → 以 `tool_input.answers` 为准。**删除**「tool_input 里有 answers 就整张拒收」的分支（F-5 根因）；预填已由 PreToolUse 拒绝调用。
- `annotations` 一律忽略（不当答案、不当备注）。
- 其余规则不变（T-015 v2）：question 以 `<GID>：` 开头且其后 == 快照标题；header 缺省/空/同门卡号；**每个** label 恰为 `<L> <快照选项原文>`；
  所选值必须**恰好等于**其中一个 label；有后续效果的门卡选 A 不记录；快照与门卡含义不符不记录；只认第一次。
- **Other / 非单个选项**：所选值是字符串但不等于任何 label（Other 自由文字、多选拼出来的串）→ 不记录；systemMessage 含门卡号、「自由输入」、`answer`
  （例：`G-x：所选不是选项卡里的单个选项（Other 自由输入 / 多选不记录），没有记录；请在终端运行 \`… answer G-x <字母>\` 答复。`）。值不是字符串 → 同样不记录。
- **有后果的 A**：systemMessage 用现有「选 A 会触发后续动作，对话里不记录；请在终端运行 `… answer <GID> A`，或在看板 / Telegram 答复」，
  含 `answer`、`看板`、`Telegram`；PostToolUse 的任何提示都**不得**出现「预填」。
- 输出格式不变：`{"systemMessage": …, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": …}}`，成功一行 `已记录 <GID>: <字母>`，via `对话`。

## 接口约定 v2（第 1 轮审查后；与 v1 冲突处以此为准。测试：test_chat_answer.sh §10–§11，test_doctor.sh「T-019 doctor」段）
**(1) fail-closed：PostToolUse 只认经过 PreToolUse 的调用。**
- `tool_use_id` 合法 = 字符串且 fullmatch `[A-Za-z0-9_-]{1,128}`；缺失 / 空 / 不合法 → PreToolUse 不写标记，PostToolUse 不记录。
- 标记文件：`H.state_dir(main) / "chat" / "<tool_use_id>.pre"`（`main = store_main(cwd)`，与答案库同一个仓库）。目录 0700、文件 0600，
  `os.open(…, O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW, 0o600)` 创建；已存在 → 不覆盖（静默）。内容随意。
- PreToolUse 顺序：`off_cheap` → 静默；**预填判定在 import harness_lib 之前**（只用 json/re/QUESTION_RE；harness_lib 坏了、import 失败也照样 deny；
  原因里的命令可写死 `python3 .claude/hooks/harness_lib.py answer <GID> <字母>`，须含 `answer`）。预填 → deny，**不写标记**。
  门卡题、没有 answers → 才 import harness_lib 写标记；stdout 仍然为空（不输出 allow）。非门卡题 / 别的工具 → 不写标记、无输出。
  每次写标记前顺手删掉 chat/ 下 mtime 超过 24 小时的 `*.pre`（Esc 取消留下的；失败忽略）。
- PostToolUse：有门卡题且未嵌套时，先找 `<tool_use_id>.pre`：
  - 存在 → **先删掉**（一次性：无论本次记没记上，同一 tool_use_id 第二次 PostToolUse 都不记录），再按 v1 规则记录；
  - 不存在（PreToolUse 崩溃 / 超时 / 没注册 / 预填被拒 / id 不对）→ 整张不记录，每张门卡一行 systemMessage：含门卡号、「调用前」、`answer`
    （例：`G-x：这次选项卡没有经过调用前检查（PreToolUse），没有记录；请在终端运行 \`… answer G-x <字母>\` 答复。`），不得出现「已记录」。
  - 另一个 tool_use_id 的 PostToolUse 不动别人的标记。
**(2) 多选门卡题一律不记录**：题目 `multiSelect` 为 true → 不记录（即使值恰好是一个 label），systemMessage 含门卡号、「多选」、`answer`。
`multiSelect` 缺省 / false → 照常。
**(3) doctor 报告对话选项卡的调用前检查是否注册**（`pkg/cli/doctor_cmd.py`）：
- 来源（并集）：`<主仓库>/.claude/settings.json`、`<主仓库>/.claude/settings.local.json`、`<PKG>/hooks/hooks.json`（插件安装时 PKG = 插件根）。
  读不了 / 不是合法 JSON 的来源当作不存在，不抛异常。
- 一项「命中」= 某事件下某个 matcher 组（matcher fullmatch `AskUserQuestion`，或 `*` / 缺省 / 空 = 全部）里有 command 含 `chat_answer.py`。
- 只有任何来源、任何事件里出现 `chat_answer.py` 时才多一段 `## 对话选项卡`，放在 `## 沙箱依赖` 之后（审计日志段之前）；一个都没有 → 不出这段
  （保持 test_doctor.sh 原「five sections in order」）。
- 内容：PreToolUse(AskUserQuestion) → chat_answer 已注册 → 一行含 `ok` 与 `PreToolUse`；否则一行含 `PreToolUse`、`未注册`，说明对话里的选项卡答复不会被记录，
  并给修复办法（更新插件 / 重跑 `/harness:setup`）。doctor 仍退出 0。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 真机字段 | PreToolUse tool_input 只有 questions；PostToolUse 有 answers,questions（有时 annotations） | 现场报告第 2 节 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | chat_answer.py 与 hook 注册 | - |
| 风险 | medium | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester 用真机字段结构写失败测试 — 结果：接口约定已写；pkg/tests/test_chat_answer.sh 夹具改为真机格式（answers 在 tool_input），新增 §8 PreToolUse 预填拒绝、§9 PostToolUse 真机格式（ui 选 B、design 选 A 理由、Other、兜底/优先级）与注册/发布检查；未实现时 160/205 passed（红 45 项，全是待实现）；其他 14 套件全绿；按约定写的草稿实现在临时副本里 205/205（未提交）；第 2 轮（接口约定 v2：fail-closed 标记、多选、doctor）：对 3e40317 跑 test_chat_answer.sh → 223/247（红 24 项全是 v2），test_doctor.sh → 117/123（红 6 项全是 v2 doctor）；草稿实现（临时副本）test_chat_answer 246/247（差的 1 项是未重建 plugins/harness）
- [x] 2. 实现 — 结果：chat_answer.py 加 PreToolUse 分派（on_pre：门卡题 + tool_input 有 answers → deny，不写库、不快照、从不 allow）；PostToolUse 取 tool_input.answers，非 dict 退回 tool_response.answers，删除预填拒收分支；Other 提示含「自由输入」；settings.json PreToolUse 加 AskUserQuestion 项；重建 plugins/harness。test_chat_answer 205/205，其余 14 套件与 test-harness 306/306 全绿
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 真机格式 PostToolUse（answers 在 tool_input）选 B → 记录 via 对话（S-003#4） — 证据：
- [ ] A2. PreToolUse 带预填 answers → 拒绝调用且不记录（S-003#4） — 证据：
- [ ] A3. Other 输入不记录且 systemMessage 说明；有后果的 A 提示去终端 / 看板 / Telegram（S-003#4） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Mac 上：ui 卡选 B 记录；design 卡选 A 被拒且理由正确；让 Claude 发一个带预填 answers 的门卡选项卡调用（如「用 AskUserQuestion 问 G-DEMO-1，answers 里直接填 B」）→ 调用被拒（看到「预填」提示），门卡仍未答；`harness doctor` 的「对话选项卡」段为 ok — 门卡：

## 6. Guardrails（本任务特有）
- 字段缺失时不记录、不报错

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 需求变更（S-003 #4 / F-5，tester）：T-015 接口约定 v1/v2「只信 tool_response.answers；tool_input 已有 answers → 一题都不记录」作废——真机上用户答案就在 PostToolUse 的 tool_input.answers。test_chat_answer.sh 原断言「answers only in tool_input (Claude-fillable): not recorded」「v2 (4) tool_input already has answers …: not recorded」改为在 PreToolUse 断言同一安全性质（预填 → deny、不记录、systemMessage 点名门卡）；其余所有断言保留，只把夹具里的答案从 tool_response 挪进 tool_input，并为旧格式（tool_response.answers）保留兜底用例。
- 范围变更（第 1 轮审查，coordinator）：allowed_paths 加 `pkg/cli/doctor_cmd.py`（doctor 报告 PreToolUse 注册状态）与它的测试 `pkg/tests/test_doctor.sh`（只追加用例，不改原断言）。test_chat_answer.sh 的 `post` 改为先跑 PreToolUse 再跑同一 tool_use_id 的 PostToolUse（真机顺序），原断言全部保留；新增 `postonly` 只跑 PostToolUse。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定一次实现即可 | chat_answer.py、settings.json、build plugins/harness | 205/205，全套绿 |
| 2 | 接口约定 v2：预填判定挪到 import 前、tool_use_id 一次性标记 fail-closed、多选不记录、doctor 报注册 | chat_answer.py、doctor_cmd.py、重建 plugins/harness | chat 247/247、doctor 123/123，其余 13 套件与 test-harness 306/306 全绿 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
