# harness（Claude Code 插件）v0.1.0

装上后，任何仓库都有这些护栏和工作流：路径与命令护栏、Stop 检查、改后快检、权限自动放行、GitHub 门卡收件箱；
skills：/harness:task-align、/harness:task-run、/harness:task-close、/harness:spec、/harness:human-gate、/harness:tower、/harness:replan、/harness:backlog-groom、/harness:handoff；
子代理：verifier、critic、judge、tester、builder、impact-analyst、security-auditor、backlog-reviewer。

## 一行安装
```bash
claude plugin marketplace add nnddoon/harness && claude plugin install harness@harness
```
然后在任何仓库里打开 Claude Code，输入 `/harness:setup`：识别技术栈、生成验证配置，把 `.harness/`（任务卡、门卡、配置）和 `scripts/` 放进仓库。

注意：
- 插件不能带权限设置：`/harness:setup` 会把「不读 .env / 密钥」的 deny 列表合并进项目的 `.claude/settings.json`。
- 装了插件就不要再把 hooks 装进仓库的 `${CLAUDE_PLUGIN_ROOT}/hooks/`，否则每个 hook 会跑两次；`/harness:setup` 发现时会提醒。
- `scripts/*.sh` 在插件模式下用 `.harness/lib/` 里的库副本；插件更新后重跑 `/harness:setup` 即可更新。

本机试装：`claude --plugin-dir <这个目录>`
