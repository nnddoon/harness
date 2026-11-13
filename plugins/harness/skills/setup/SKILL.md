---
name: setup
description: 把 harness 接入当前仓库（插件模式）：识别技术栈，生成验证配置，写入 .harness/ 和 scripts/。第一次在一个仓库里用 harness、或插件更新后，运行 /harness:setup。
disable-model-invocation: true
---

# /harness:setup — 把 harness 接入这个仓库

插件已经提供了护栏 hooks、skills 和子代理；这一步只在仓库里放「状态和脚本」：`.harness/`（任务卡、门卡、配置）、`scripts/`、`CLAUDE.md`、`.claude/rules/`，并把权限 deny 列表合并进 `.claude/settings.json`。

## 步骤

1. **先看计划，不写文件**：
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/bin/harness" init --plugin --dry-run --target .
   ```
   把输出用一两句话告诉用户：认出的技术栈、会生成的验证命令、以后不再询问的命令。
   - 没认出技术栈：告诉用户之后要自己编辑 `.harness/verify.sh`、`quick-check.sh`、`allow-commands.txt`。
   - 输出里提到「分支保护」的那一行（会开门卡 / 已开启 / 开不了 / 跳过检查）原样转告用户。
2. **确认一次**：用 AskUserQuestion 问「照这样接入吗？」，选项：接入（推荐）/ 先不要。用户没确认就停在这里。
3. **接入**：
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/bin/harness" init --plugin --yes --target .
   ```
   把输出里以「•」开头的提醒原样转告用户（例如仓库里已有旧的 hooks、settings.json 无法解析）。
   提到「分支保护」的那一行、以及「Actions 默认权限」那一行（有的话）也原样转告。开了门卡 `.harness/gates/G-SETUP-bp.md` 时：告诉用户批准后由他自己在终端执行门卡里的两条 `gh api -X PUT` 命令；你不要替他执行，也不要调用任何改 GitHub 设置的命令。
4. **提交**：问用户要不要现在提交；要的话 `git add -A && git commit -m "chore: add harness"`（在 main 上提交只改 harness 文件，是允许的）。
5. **下一步**：告诉用户三件事——
   - 提需求：`/harness:task-align <一句话需求>`；大需求或新项目：`/harness:spec`
   - 看全局：`/harness:tower`；本地看板：在自己的终端跑 `python3 "${CLAUDE_PLUGIN_ROOT}/bin/harness" serve`（要在看板上答复门卡，必须由用户在自己的终端启动）
   - 夜间跑：`scripts/harness-loop.sh --parallel 2 --integration --review-budget 20`

插件更新后重跑本命令即可：`.harness/lib/` 里的库会更新，你改过的配置不会被覆盖。
