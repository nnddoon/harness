---
name: task-run
description: 按任务卡执行一个 ready/claimed/in_progress 的任务：逐步修改、记录过程、跑验证、交给 verifier 独立验收、需要时开人工门。用户说「开始做 T-xxx」「执行任务卡」「继续这个任务」时使用。
argument-hint: <任务号，例如 T-013；省略则从分支名推断>
---

# /harness:task-run：执行任务卡

任务：$ARGUMENTS

## 当前状态（自动注入）
!`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py context run`

## 规则
- 任务卡是唯一事实来源。开始前完整读一遍任务卡和它的 `context_files`；压缩/恢复后也先重读。
- 只改 `allowed_paths`。hook 会拦截越界和冻结路径——被拦截时**不要绕过**（不要换工具、不要用 shell 写文件），按 `.claude/rules/harness-guardrails.md` 第 1 节处理。
- 不删除、不跳过、不弱化已有测试。

## 步骤

1. **开工**：任务卡 `status` 改为 `in_progress`，「当前进展」写上开始时间。
   **先取基线**：跑一次 CLAUDE.md 里的快速验证（测试 + lint），把结果一行写进「当前进展」，例如「基线：测试 212 过 / 3 失败（`auth.spec.ts` 本来就失败）」。之后判断「是不是我弄坏的」只和基线比，别为既有失败花时间，也别被它们误导（这些既有失败写进「8. 发现的问题」）。若 `depends_on` 中有任务不是 `done`（= 已合并进 main），停下并告诉用户：要么等它合并，要么经用户同意把本 worktree 基于那条任务分支（`HARNESS_BASE=<分支> scripts/new-task.sh`）。

2. **先测试，后实现**（`test_owner: tester` 时，这是默认）：
   - 调用 `tester` 子代理，按验收 A 写测试，确认新测试是红的。
   - 你（或 `builder` 子代理）负责实现。**hook 不让实现方改测试文件**：觉得测试写错了，把理由写进「7. 当前进展」，再叫 tester 来改。

3. **逐步执行「修改过程」**：每一步：
   - 改代码 → 跑该步相关的快速验证 → 勾选并在「结果」写证据（提交号 / 命令 + 关键输出）。
   - 小步提交：`T-xxx: <动词> <内容>`。
   - 计划要变：划掉旧步骤写原因，加新步骤；若导致范围扩大 >3 个文件或跨模块 → `/harness:human-gate ambiguity`。
   - **每次修复前先在「11. 尝试日志」写一行假设**，修完写结果。同一个问题最多试 5 次（hook 在连续 3 次失败时会提醒你）。到上限就把状态改为 `blocked`，在「卡住的点」写清楚试过什么，交给 `/harness:replan` 处理。
   - 同一个错误第二次出现 → 在「12. 教训」写一行可执行的规则。
   - 改完一个文件后，快检 hook 会跑 lint 和类型检查，没过就先修好它再继续。
   - 权限请求被用户拒绝 → **不要原样再试，也不要换个写法绕过去**。在「7. 当前进展」写下你原本想做什么、为什么，然后换一个不需要那个权限的方案，或者开一张门卡问用户。

4. **完整验证**：跑 CLAUDE.md「验证命令」中的测试、lint、类型检查、构建；把结果写进验收 A 的证据。

5. **人工验收预检（验收 B 有内容时）**：按 `.claude/rules/human-gates.md` 第 1 节先做完机器预检（截图、指标、样本），再用 `/harness:human-gate` 生成门卡。门卡打开期间继续做不依赖它的工作。

6. **对抗审查**（在 verifier 之前；`risk: medium/high` 必做，low 建议做 1 个）：
   - 跑 `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py critics <risk> verify` 得到挑错角度（每行一个）。
   - **同时**开对应数量的 `critic` 子代理，每个只给一个角度 + 任务卡路径 + `git diff <base>...HEAD` + 验证命令。不要把你的实现思路告诉它们。
   - 把全部输出交给 `judge` 子代理核实。只修 VALID 的；UNSURE 的开门卡或写进第 8 节；INVALID 不改。
   - 在第 13 节记一行。修了东西就重跑第 4 步。不要用自己这个会话判断自己的产出——这正是要另开会话的原因。
7. **独立验收**：调用 `verifier` 子代理，只给它：任务卡路径、`git diff origin/main...HEAD`（或相对 base 分支）、验证命令。`risk: high` 时同时调用 `security-auditor`。
   - 结论写入任务卡第 10 节。
   - FAIL → 按它的问题清单修复，回到第 4 步（最多 3 轮，仍失败则 `blocked` 并说明）。

8. **结束本阶段**：
   - 验收 A 全过 + verifier PASS + 无 open 门卡 → `status: review`，然后执行 `/harness:task-close`。
   - 有 open 门卡且其余工作已完成 → `status: waiting_human`，「当前进展」写清楚等哪张门卡、拿到答复后做什么，然后停下并简短告诉用户去看哪张门卡。
