# S-002 硬边界与决定收件箱

> 状态：已确认（D-005 全部确认；D-006 strict 只在无人值守时强制；D-007 允许使用 srt）。文档版：https://claude.ai/artifact/Tu9XM5TzMpmmUoB8FojV85
> 第 2 版：吸收两轮挑错（安全绕过 10 条、可行性 9 条，成立 18 条）。

## 1. 目标
把最关键的护栏从「我们的 hook 在拦」变成「Claude 物理上做不到」，并让你在对话里或手机上点一下就能答门卡。
完成后，无人值守时 Claude：拿不到任何凭证；改不了控制文件和答案；它写的代码不会在沙箱外、带着你的凭证运行；
它写的门卡改变不了「哪个选项算批准」。

为什么现在：OpenAI 公布的常驻 agent 做法（可信/不可信分开、沙箱、独立身份、全量日志）对准我们的头号残余风险；
Claude Code 原生沙箱已可用（macOS / Linux / WSL2）。挑错还找到 v0.1 现有的 3 个可被利用的漏洞（见 §7），本 spec 第 1 批修掉。

## 2. 非目标
- 不换底座（不迁到 OpenClaw / Codex），只在设计上保持与 agent 无关。
- 不做原生 App；通知先只做 Telegram（留接口）。不做云端托管、多用户、TLS 拦截与凭证代理。
- 不把控制面拆成独立系统账号（理想做法，留到以后；本期靠沙箱 + 权限规则，残余风险见 §7）。
- 不做「模型审每个动作」：原生 auto 模式 + 沙箱自动放行已覆盖；放进 backlog 提议区，触发条件「第 3 批后 standard 模式每天弹窗 > 5 次」。
- 原生 Windows / WSL1 不提供硬边界，只给明确提示。

## 3. 场景
1. 夜间：所有 Claude 启动（任务、接续、groom、replan）都经同一个启动器，用 strict 配置；沙箱不可用就拒绝启动。规划类运行只能写 .harness/ 的任务卡、门卡与 backlog。
2. 收工：调度器检查任务分支，改到控制文件（无已批准的 unlock）就拒绝合并、推送、作为下游基线；完整验证在同样的沙箱里、无凭证地跑。推分支、开 PR、开门卡 Issue 都由调度器做。
3. 白天对话：开门卡时对话里弹出选项；你点 A，由 hook 写进答案库。
4. 出门：新门卡推到 Telegram，按钮点了就算；不可逆类二次确认。
5. 收尾与追查：`harness doctor` / `harness down`；看板「审计」页。

## 4. 架构
**控制面**（你的账号、沙箱外）：启动器、调度器、gate-sync、看板、Telegram bot、hooks。持有凭证；唯一写答案库、
decisions.md、审计日志的一方；**从不在沙箱外执行 worktree 里的文件**。

**执行面**（沙箱里的 Claude）：只写自己的 worktree 和自己分支的 git 对象；网络只到按技术栈生成的白名单；
Bash 读不到凭证（沙箱 denyRead），Read/WebFetch 也读不到（权限 deny）。

关键设计：
- **strict 配置不进仓库**：生成到 `$XDG_STATE_HOME/harness/<仓库>/strict-settings.json`，启动器用 `claude --settings` 传入。
  Claude 改不了它，已安装的仓库也不用升级。键：`sandbox.enabled`、`failIfUnavailable`、`allowUnsandboxedCommands: false`、
  `filesystem.denyRead`（gh / git / ssh / 云凭证、harness 状态目录）、`filesystem.denyWrite`（控制路径、`.git/hooks`、`.git/config`、`.git/info`）、
  `network.allowedDomains`（按技术栈）、`network.deniedDomains`（粘贴站、webhook.site、api.telegram.org）、
  `permissions.deny`（同一批路径的 Read/Edit/Write，以及 WebFetch、WebSearch）。
- **控制路径**（一处定义）：`.claude/**`、`CLAUDE.md`、`scripts/**`、`.github/**`、`.gitattributes`、`.gitignore`、`.worktreeinclude`、
  `.harness/{verify.sh,quick-check.sh,allow-commands.txt,locks.txt,auto-decide.txt,decisions.md,backlog.md}`、`.harness/lib/**`。
- **答案库在仓库外**：`$XDG_STATE_HOME/harness/<仓库>/answers/`。门卡里的 `answer:`、decisions.md 都是控制面写的镜像。
- **门卡含义由控制面决定**：批准项固定为 A；`then` 只允许 ready；`pr:` 只认控制面为该任务开的 PR；需要二次确认与否看动作，不看卡上写的 kind；
  门卡号 ↔ Issue 号在发布时记进答案库，不从 Issue 正文解析。

## 5. 验收
1. strict 模式下沙箱不可用（缺 bubblewrap/socat、WSL1、原生 Windows）时，任何 Claude 启动都拒绝，并打印一句话修复办法。
2. 所有启动点（任务、`gate-sync --resume`、groom、replan、看板接续）都经同一个启动器；规划类运行（`--role plan`）在 strict 下只能写 .harness/ 的任务卡、门卡与 backlog。
3. 启动器传给 Claude 的环境里没有 `GH_TOKEN`、`GITHUB_TOKEN`、`HARNESS_GH_TOKEN`、`HARNESS_SERVE_TOKEN`、`HARNESS_TELEGRAM_TOKEN`（以及 `*_TOKEN`、`*_SECRET`、`*_KEY` 通配）。
4. 生成的 strict 配置包含 §4 列出的全部键；控制路径的 Read/Edit/Write 规则和沙箱 denyWrite 来自同一份清单（测试断言二者一致）。
5. 网络白名单由技术栈推出（npm / pip / go / cargo 各自的源），只有该栈需要时才含 github.com；api.telegram.org、webhook.site、粘贴站始终拒绝。
6. 调度器对任务分支做控制路径检查：`git diff --name-only <base>...<分支>` 命中控制路径且无已批准 unlock 时，拒绝合并、推送、作为下游基线，任务转 blocked 并开门卡说明。
7. 控制面不在沙箱外执行 worktree 文件：整合验证经沙箱运行器执行、环境无凭证；strict 模式下 quick-check hook 不执行项目命令（改为提示 Claude 在沙箱里跑）。
8. 答案库在仓库外；终端、看板、GitHub、对话、Telegram 写同一个库，decisions.md 由控制面写并记 `via <通道>`；同一张门卡只认第一次答复。
9. Claude 改门卡的 `answer:` / `status:` / `approve_options` / `then` / `pr:` 不改变结果：用旧的已合并 PR 号、伪造 Issue 正文里的门卡标记、把拒绝项写进批准项，都不会批准（每种一个测试）。
10. 「已放权」类门卡的自动决定由控制面写入（检查 auto-decide.txt 后），Claude 自己写 `decided_by: auto` 无效。
11. strict 模式下 Claude 及其 hooks 对 GitHub 的写调用为 0（假 gh / 假远端的日志断言）；推分支、开 PR、开门卡 Issue、推素材由调度器在任务结束后完成。
12. 推送前拒绝改了 `.github/**` 的分支（除非已批准 unlock）；setup 建议把 Actions 的 workflow 权限设为只读。
13. 对话通道：交互会话开门卡时弹出选项卡，答案取自 AskUserQuestion 的工具结果，由 hook 写库；你发出的消息恰好是 `G-x-n: L`（可带备注）时由 UserPromptSubmit hook 写库。`HARNESS_UNATTENDED=1` 或非交互会话时两个 hook 都不生效。
14. Telegram：token 只存在控制面配置（`$XDG_CONFIG_HOME/harness/telegram.json`，权限 600），Claude 的 Read 被拒；配对只认终端显示的一次性码；只接受已配对的 user id；轮询间隔 ≤ 20 秒（可配），新门卡在两个轮询周期内发出；按钮只携带门卡号与选项；不可逆类（以动作判定）二次确认；`HARNESS_TELEGRAM_API` 可指向假服务器做测试。
15. 审计：每次工具调用、护栏判定、门卡答复追加到 `$XDG_STATE_HOME/harness/<仓库>/audit/<日期>.jsonl`；打码规则：`ghp_`、`gho_`、`github_pat_`、Telegram 机器人 token 形式、`sk-`、`AKIA`、`xox[bp]-`、`Bearer `、PEM 私钥头，以及控制面配置里出现的实际 token 原文；看板「审计」页只在带令牌时可见。
16. `harness doctor` 列出：harness 装的定时任务（带 `# harness expires=<日期>` 标记）、`$XDG_STATE_HOME/harness/run/*.pid` 里仍存活的调度器与 bot、7 天没动的 worktree、3 天没答的门卡、沙箱依赖是否齐全；`harness down` 停掉这些进程、移除定时任务，重复执行无害。
17. 定时任务每次运行先检查到期日（默认安装后 30 天），过期则移除自己并在下次晨报与 doctor 里提示。
18. setup 检查能否开分支保护（公开仓库，或私有仓库 + Pro/Team）：能开就开门卡问你；不能开时说明原因，并说明 strict 模式已在本机挡住。
19. v0.1 已有的门卡、答案迁移进答案库，迁移后看板不出现「答案不一致」；human-gate skill 不再让 Claude 写答案。
20. 教程、README、规则文件与插件打包同步更新；插件构建测试断言新命令随插件发布。

**人工验收（只能在你的电脑上做）：** 真实沙箱拦截（Linux/WSL2 与 macOS 各一次）；macOS 上沙箱内 `gh auth token` 失败（凭证在钥匙串）；
对话选项卡；Telegram 真机配对与点按；分支保护 API。其余全部自动化（假 claude、假 gh、假 crontab、假 Telegram 服务器、`HARNESS_PLATFORM` / `HARNESS_NOW` 覆盖）。

所有任务：现有测试全部通过，自测数量不下降。

## 6. 任务图
| 任务 | 批 | 依赖 | 风险 | 验收 |
|---|---|---|---|---|
| T-008 统一启动器与 strict 配置 | 1 | - | high | #1–#5 |
| T-009 控制路径守门与沙箱内验证 | 1 | T-008 | high | #6 #7 #12 |
| T-010 答案库与门卡语义 | 1 | T-008 | high | #8（终端/看板/GitHub）#9 #10 #19 |
| T-011 发布与推送移到控制面 | 1 | T-009 T-010 | high | #11 |
| T-012 审计日志与审计页 | 2 | T-008 T-010 | medium | #15 |
| T-013 doctor / down / 定时任务到期 | 2 | T-008 | low | #16 #17 |
| T-014 分支保护向导 | 2 | T-009 | medium | #18 |
| T-015 对话内选项卡 | 3 | T-010 | medium | #13 |
| T-016 Telegram 收件箱 | 3 | T-010 T-013 | high | #14 #8（收齐五通道） |
| T-017 文档、教程与打包 | 3 | T-011 T-015 T-016 | low | #20 |

## 7. 风险
- **v0.1 现有漏洞**（T-010 修）：①门卡 `pr:` 填一个旧的已合并 PR 就算批准；②Issue 正文里伪造另一张门卡的标记，你的答复被转到那张卡；③接续提示里夹带「G-x-n: A」可被当作答复。都需要一个不老实的 agent 才能利用。
- **同一系统账号**：Read/Edit/WebFetch 的拦截靠 Claude Code 自己执行权限规则；它若有缺陷，同账号下仍可能泄露。彻底解法是控制面用独立系统账号（非目标）。
- **沙箱运行器**：控制面在沙箱里跑验证用 Anthropic 的 sandbox-runtime（`srt`，npm 全局工具）；D-007 已允许，setup/doctor 负责检测与提示安装，不自动安装。
- **strict 让 Claude 不能自己推分支**：D-006 定为只在无人值守时强制，交互会话默认 standard、可用 `harness launch --strict` 手动开启。
- **白名单过窄会让依赖安装失败**：按技术栈生成，doctor 显示被拒的域名，加白名单只能你在终端改。
- **越做越重**：每批结束看三个指标再决定下一批；第 3 批可整体延后。
