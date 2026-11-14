# S-003 现场验收修复（v0.2.1）

> 状态：已确认开工（用户 2026-11-14 选「写成 S-003 并直接开工」）。来源：`docs/feedback/s002-field-test.md`（macOS 14 / Claude Code 2.1.325 真机验收，15 个发现）。

## 1. 目标
修掉真机验收发现的阻断项，让 v0.2 能在 macOS 上把夜间流程完整跑通、strict 模式名副其实，对话选项卡能记录答复；顺手修掉小问题并把版本号升到 0.2.1，让已安装用户能收到更新。

## 2. 非目标
- 不重新设计沙箱：Claude Code 的 macOS 沙箱只能「放行」Mach 服务、不能单独拒绝（`allowMachLookup` 是放行名单），钥匙串问题用「不让凭证留在钥匙串里」解决，不改沙箱实现。
- 不做控制面独立系统账号（仍是 S-002 的残余风险）。
- 不支持原生 Windows。

## 3. 验收
1. macOS strict：启动前检查登录钥匙串里有没有不需要授权就能读的 GitHub 凭证（gh 的 `gh:github.com`、git osxkeychain 的 github.com 互联网密码；只检查存在，不读内容）。有则拒绝 strict 启动，给一句话修复办法（`gh auth login --insecure-storage` 等）；`HARNESS_ALLOW_KEYCHAIN=1` 可明确放行并在晨报 / doctor 标红。doctor 同样报告。（F-2）
2. 完整验证依赖的入口文件是控制路径：verify.sh / quick-check.sh 里引用的 `npm run` / `make` / `pytest` 等对应的清单文件（package.json、Makefile、pyproject.toml、setup.cfg、tox.ini、noxfile.py、Cargo.toml、go.mod 等，按 verify.sh 实际内容推出）进入沙箱 denyWrite 与 control-diff；改依赖仍走 unlock。（F-3）
3. strict 下 Claude 用不到任何 MCP / claude.ai 连接器：启动器设 `ENABLE_CLAUDEAI_MCP_SERVERS=false`、加 `--strict-mcp-config`，并在 permissions.deny 里加 `mcp__claude_ai_*` 形式的已知前缀。（F-4）
4. 对话选项卡真机可用：预填判定改在 PreToolUse（此时 `tool_input` 只该有 questions，出现 answers 即拒绝这次调用）；PostToolUse 读取 `tool_input.answers`（真机格式：问题文本 → 选项 label）。有后果的 A 仍不从对话记录，并给出正确理由。Other 自由输入不记录、提示原因。（F-5）
5. 所有 shell 脚本在 macOS bash 3.2 + UTF-8 locale 下可运行：`$VAR` 后紧跟非 ASCII 字符一律改 `${VAR}`；加 lint 测试（扫描 pkg/scripts 与 payload）；脚本开头不依赖 bash 4 特性。（F-8）
6. 任务不会锁死自己：task-align 生成的 locked_paths 不含 `.harness/**`；protect_paths 与 control-diff 永远允许任务写自己的 `.harness/tasks/T-xxx*`、`.harness/handoffs/T-xxx*`、`.harness/gates/G-Txxx-*`。（F-9）
7. locked_paths 是硬边界：strict 启动器把任务卡的 locked_paths 加进沙箱 denyWrite 与 Edit/Write deny；control-diff 也拒绝改了本任务 locked_paths 的分支。（F-10）
8. 解锁门卡批准后任务接续：unlock 门卡必须带 `paths:`（否则控制面拒绝快照并提示）；控制面记录批准后，按快照里的任务把 blocked 任务转回 ready 并进入下一次接续；调度器会重新派发因 unlock 被 blocked、且门卡已批准的任务。（F-12）
9. 调度器只派发 ready 任务（pick-batch 过滤 proposed）；`backlog-status` 无参数时打印用法。（F-11）
10. 插件版本号：`pkg/plugin/VERSION` 升到 0.2.1，build.sh 写入 plugin.json；测试断言插件内容变化时版本号必须变化（与上次发布的清单比对）。（F-1）
11. 小问题：show 不再因控制面回写的字段（issue/worktree/session/status/answer/decided_by）误报「快照后改过」（F-6）；init 发现 npm 默认的 `exit 1` 测试脚本时提示（F-7）；审计打码 `[?&]t=…`（F-13）；配对码错误 / 已用时回一句提示（F-14）；Telegram 回调立即 answerCallbackQuery、记录后统一去掉所有已答消息的按钮（F-15）；guard_bash 不把 heredoc 新建门卡误判成写答案；doctor 显示在跑的 serve；down 不留下空 crontab。

所有任务：现有测试全部通过（读各套件计数），自测数量不下降。

**人工复测（在你的 Mac 上）：** 钥匙串检查与 `--insecure-storage` 后 strict 能启动；连接器不可用；对话选项卡选 B 记录、选 A（有后果）被拒；夜间流程在系统 bash 下跑通到开 PR 与合并门卡；控制文件篡改 → G-Txxx-ctl。

## 4. 任务图
| 任务 | 依赖 | 风险 | 验收 |
|---|---|---|---|
| T-018 strict 加固：钥匙串、验证入口、连接器、locked_paths 硬边界 | - | high | #1 #2 #3 #7 |
| T-019 对话选项卡真机格式 | - | medium | #4 |
| T-020 bash 3.2 兼容与调度小修 | - | medium | #5 #9 |
| T-021 任务生命周期：不自锁、解锁后接续 | T-018 | high | #6 #8 |
| T-022 小问题与版本号 | T-018 T-019 T-020 T-021 | low | #10 #11 |
