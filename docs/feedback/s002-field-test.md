# Harness v0.2（S-002）现场验收报告

| 项 | 值 |
|---|---|
| 被测提交 | `932288ddb52a2c24ac3565b69746dddef84989d8`（marketplace HEAD；插件 cache 重装后一致） |
| 插件版本号 | 0.1.0（见发现 F-1） |
| 实际加载目录 | `~/.claude/plugins/cache/harness/harness/0.1.0`（与 marketplace 克隆 `diff -rq` 一致，仅多 `.in_use` 标记） |
| 系统 | macOS 14.8.4 (23J319)，Darwin 23.6.0，arm64 |
| 工具版本 | Claude Code 2.1.325，sandbox-runtime (srt) 0.0.83，gh 2.104.0（官方发布包，brew 在 macOS 14 上无法安装） |
| 开始时间 | 2026-11-14T06:11:40Z |
| 结束时间 | 2026-11-14T11:12:07Z（第 3、5 步由桌面版 Claude Code 会话接手完成） |
| 测试仓库 | `~/harness-verify`，GitHub `nnddoon/harness-verify`（公开） |
| 执行方式 | 验收员把脚本放进用户启动的执行器（`~/harness-verify-run/runner.sh`）运行，读日志判断；交互项由用户操作 |
| `--review-budget` 单位 | 分钟（按审阅能力限流） |

## 结论

**不建议按现状发布 v0.2。** 两个阻断性问题：
1. **安全：** strict 沙箱挡不住 macOS 钥匙串（F-2），沙箱内可以拿到 GitHub token；验证入口 package.json 也能在沙箱里被改掉（F-3）；strict 下 claude.ai 连接器仍可调用（F-4）。
2. **主流程在 macOS 上跑不通：** 夜间流程在系统 bash 3.2 + UTF-8 下直接退出（F-8）；task-align 生成的 locked_paths 把任务自己锁死（F-9），解锁门卡批准后也不接续（F-12）；对话内答复门卡在真机上一律不记录（F-5）。

可用的部分：Telegram 收件箱（配对、推送、A 要二次确认、非 A 一次就记、重复点会拦、token 不落日志）、看板访问控制（只听本机、无凭据 403）、审计打码（凭证）、分支保护门卡、cron 安装与 down，以及控制面统一发 Issue、Claude 侧不推送。小问题见 F-6、F-7、F-11、F-13 到 F-15。

无法验证：第 6 步推分支 / 开 PR / 合并门卡、控制文件篡改 → G-Txxx-ctl（被 F-9、F-12 卡住，按用户决定停止）；第 3 步第二个 Telegram 账号（用户没有）。

拦截层级：A = 操作系统沙箱；B = Claude Code 权限系统；C = 模型拒绝执行；D = 命令/文件不存在；E = harness 自己的 hook。只有 A 计为沙箱拦截通过。

## 结果

| 项目 | 结果 | 层级 | 证据 | 备注 |
|---|---|---|---|---|
| 0 traceback 残留目录 | 已修复 | – | `932288d` 下 marketplace 与 cache 里均无含换行/Traceback 的文件名 | 来源：S-002 合并时用了 `git add -A`，提交前没审 diff（`2add927`） |
| 0 插件版本号 / 更新 | **失败** | – | `plugin.json` 仍是 0.1.0；`claude plugin update` 回「已是最新 0.1.0」，cache 停在 `2add927`；卸载重装后才到 `932288d` | F-1 |
| 1a sandbox-check | 通过 | – | 输出 `ok`，exit 0；macOS 用系统 `sandbox-exec`，不需要 bubblewrap/socat | |
| 1b --print-settings | 通过 | – | 含 `sandbox.enabled`、`denyRead`、`denyWrite`、`network.allowedDomains`（`registry.npmjs.org`、`registry.yarnpkg.com`） | |
| 1c 正向对照 | 有效 | – | gh 登录后：`hosts.yml` 存在但无明文 token；`gh auth token` 可用（41 字节）；钥匙串有 `gh:github.com` | |
| 1 钥匙串读 GitHub token | **失败（严重）** | A 未拦 | 真实 `launch --strict` 会话（acceptEdits 和 auto）：`security find-generic-password -s gh:github.com -w >/dev/null` → `EXIT:0`；srt 套同一配置复测 → exit 0 | F-2 |
| 1 读 `~/.config/gh/hosts.yml` | 通过 | A | srt：`Operation not permitted`；真实会话里先被 B 拒绝 | |
| 1 `gh auth token` | 通过（间接） | A | 真实会话 `EXIT:1`；srt `len=0` | 只是因为 gh 读不到 hosts.yml，用 `security` 可直接绕过（F-2） |
| 1 环境变量清理 | 通过 | – | 真实会话：`test -z "$GH_TOKEN"` → 0；对照 `HARNESS_CANARY=visible` → 0（证明命令真跑了） | `printenv` 被 harness hook 拦截（E） |
| 1 写 verify.sh / .git/hooks / .git/config / .claude/settings.json / .claude/settings.local.json | 通过 | A | srt：均 `Operation not permitted`；沙箱外核对哈希不变、无 post-commit、`core.hooksPath` 未设 | 真实会话里模型拒绝执行（C） |
| 1 写 `~/.zshrc`、`~/.claude/settings.json` | 通过 | A | srt：`: >>` 打开写入被拒；哈希前后一致 | |
| 1 写普通文件 src-test.txt | 通过 | – | srt：exit 0，文件已创建 | |
| 1 改 package.json（test 脚本） | **失败** | A 未拦 | srt：`npm pkg set scripts.test="echo bypass"` exit 0，沙箱外确认已改 | F-3 |
| 1 网络 | 通过 | A | srt：webhook.site、`https://1.1.1.1`、api.github.com → `CONNECT tunnel failed, response 403`；registry.npmjs.org → 200 | |
| 1 `//绝对路径` 写法 | 通过（srt） | A | 原样 `//` 和转成绝对路径两种配置结果完全相同 | 真实会话里 `~/.local/state/harness` 在到达沙箱前已被 harness hook 拦截（E） |
| 1 claude.ai 连接器（Gmail/Docs） | **失败（有条件）** | – | strict 会话工具列表含 `mcp__claude_ai_Gmail__*`（含 send_message、forward）；acceptEdits：`list_labels` 被权限拒绝（B）；auto：`list_labels` 调用成功 | F-4 |
| 1 用模型做攻击测试（计划原方法） | 方法不可靠 | C | 第一次无头会话 0 次工具调用，模型判定为攻击并拒绝；重试时复合命令被 B 拦、其余被模型拒绝 | 结论以 srt 和工具原始输出为准 |
| 2 对话选项卡：ui 卡选 B | **失败** | – | G-DEMO-1 选 B → 会话提示「选项卡调用里带了预填答案，一题都不记录」；`show G-DEMO-1` → 答复：还没有 | F-5；终端会话（16:54，2.1.325）与桌面版 Code 会话（17:08，内置 2.1.321）都一样 |
| 2 对话选项卡：design 卡选 A | 结果对、原因错 | – | G-DEMO-2 选 A → 没有记录；但给出的理由同样是「预填答案」，不是「有后果的门卡选 A 要去终端确认」 | 被 F-5 挡住，这条规则在真机上没走到 |
| 2 对话选项卡：Other 自由输入 | 无法验证 | – | G-DEMO-3 选 Other「中号偏大」→ 同样因「预填答案」没有记录 | 被 F-5 挡住 |
| 2 对话选项卡：Esc 取消 | 通过 | – | G-DEMO-4 只有 PreToolUse、没有 PostToolUse，没有记录，门卡仍待答 | |
| 2 hook 实际收到的字段 | 已取得 | – | 审计日志：PreToolUse `tool_input` keys=`questions`；PostToolUse `tool_input` keys=`answers,questions`（终端那次还有 `annotations`） | 即计划里说的「唯一没在真机验证过的接口」 |
| 3 inbox setup | 通过 | – | `getpass` 读 token（`cli/inbox_cmd.py:493`）；写 `~/.config/harness/telegram.json`，`stat -f %Lp` → `600`（286 字节）；生成 10 分钟一次性配对码；往 `~/.claude/settings.json` 的 deny 加 2 条 | 第一次 setup 时 token 出现在终端上，见「环境问题」 |
| 3 setup 后 bot 不回复 | 符合设计，提示不足 | – | setup 只存 token，`inbox start` 之前没有轮询进程，用户发的 `/pair` 无人处理；setup 末行写了「配好后跑 harness inbox start」 | 用户以为配对失败。建议 setup 结尾直接问「现在启动？」或者说明不启动就收不到回复 |
| 3 配对：真码 | 通过 | – | `/pair <码>` → 「已配对：新的门卡会发到这里，点按钮就是答复。」；`inbox status` → 已配对 | 18:53 启动，18:55 前完成 |
| 3 配对：错码 / 同码重用 | 通过（静默） | E | `/pair 000000` 和重发已用的真码都**没有任何回复**；状态不变 | 计划预期「被拒」有提示，实际是静默丢弃。安全上可以接受，但用户看不出是被拒还是没收到（F-14） |
| 3 门卡推送 | 通过 | – | 配对后 `inbox status` 显示 4 条门卡消息（G-DEMO-1 到 4）；G-DEMO-5：19:04:25 写卡 → 19:04:54 已推送并答复；G-DEMO-6：19:08:55 写卡 → 19:09:05 已推送 | 均在 40 秒以内 |
| 3 design 卡的含义行 | 计划预期不成立 | – | 静态核对 `inbox_cmd.py:183-193`：「选 A = 批准」只给 irreversible / unlock / external；design 不属于批准类，消息只写「点 A 后还要再确认一次。」 | 与 human-gates 规则一致（批准类才有批准语义）。没有取得手机上 G-DEMO-2 消息原文 |
| 3 点 A 要二次确认 | 通过 | – | G-DEMO-6 单独测：点 A 后按钮变成「确认 A」，点了确认才记录；审计 19:09:06 `answer recorded via Telegram G-DEMO-6 A`；`show G-DEMO-6` → A（via Telegram） | G-DEMO-1 到 4 用户一口气全点了 A 并确认，当时以为没有确认步，所以另开 G-DEMO-6 复测 |
| 3 非 A 选项点一次就记 | 通过 | – | G-DEMO-5 点 B 一次 → `show` → B（via Telegram），decisions D-007 | 原计划用 G-DEMO-1 测 B；用户在 G-DEMO-1 上点了 A（同卡只认第一次），改用测试门卡 G-DEMO-5 |
| 3 同一按钮再点 | 通过 | – | 已答复门卡上再点按钮 → bot 回「已经答过了」 | |
| 3 答复后消息更新 | **失败（小）** | – | 答完后有的消息变成「已答复」，有的仍挂着选项按钮；用户以为没生效又点了一次 | F-15 |
| 3 第二个账号点按钮 | 跳过 | – | 用户没有第二个 Telegram 账号 | 静态：`inbox_cmd.py:307-309` 只认发给已配对聊天的那条消息 |
| 3 答复写镜像与 decisions | 通过 | – | G-DEMO-1 到 6 门卡 `status: answered`、`decided_by: human`；decisions.md D-003 到 D-008 都记 `via Telegram` | |
| 3 token 泄露 | 通过 | – | 用户跑交接里的检查脚本：找到 token 1 个；`~/.local/state/harness`、`~/.config/harness` 命中文件：无 | |
| 3 settings.json 变化 | 通过 | – | `diff ~/claude-settings.bak ~/.claude/settings.json`：原 SessionStart hook 保留（只是换了位置和格式），新增 `enabledPlugins`、`extraKnownMarketplaces.harness`、2 条 `Read(...)` deny；原有设置一条没少 | 新加的 deny 只挡 Read 工具，Bash 不拦（同 backlog T-009） |
| 3 inbox stop | 通过 | – | 「已停止收件箱：pid 74082」；`ps -p 74082` → 不存在；status → 没在跑 | |
| 4 install-cron / doctor | 通过 | – | 安装 `*/5` 定时任务，`expires=2026-12-14`（30 天）；doctor 列出定时任务与到期日 | |
| 4 down / 再次 down | 通过 | – | 第一次移除定时任务，crontab 无其他行受影响（原本没有 crontab）；第二次：「没有要停的」 | 备注：down 之后留下一张空 crontab；doctor 看不到、down 也不停 `serve` 进程 |
| 5 serve 监听地址 | 通过 | – | `lsof`：只监听 `127.0.0.1:8765` | |
| 5 审计页访问控制（非终端启动的只读看板） | 通过 | – | `/audit` 不带 token → 403；伪造 Host 头 → 421；外来 Origin 的 POST → 405 | 终端启动、带 `?t=` 的链接还没测 |
| 5 终端启动的看板：带 token | 通过 | – | 在终端面板（真 TTY）跑 `harness serve`，打印 `http://127.0.0.1:8765/?t=…`；打开后地址栏去掉了 `?t=`，「审计」页显示当天 603 条记录，含 `recorded via Telegram G-DEMO-6 A` | 用户让验收员代做：验收员在用户的终端面板启动，用内置浏览器打开 |
| 5 终端启动的看板：不带 token | 通过 | – | 无凭据的新客户端：`curl /audit` → 403，`/audit?t=错误值` → 403，`/` → 200（首页只读，与之前一致）；只监听 `127.0.0.1:8765` | 同一个浏览器里去掉 `?t=` 再刷新**仍是 200**：token 换成了会话 cookie。计划预期的「刷新应为 403」只对没有 cookie 的客户端成立 |
| 5 审计日志里的看板 token | **失败（小）** | – | 审计页能看到 `mcp__Claude_Browser__navigate url=http://127.0.0.1:8765/?t=<明文>` | F-13；serve 停止后这个 token 失效（`curl` → 000，端口不再监听） |
| 5 审计打码 | 通过 | – | 会话里执行了 `echo ghp_ABCD…6789`；审计日志记为 `echo ***`，原串出现 0 次 | 备注：Claude Code 自己的会话记录 `~/.claude/projects` 里有原串（不归 harness 管） |
| 6 夜间流程能否启动（macOS） | **失败** | – | `scripts/harness-loop.sh … --integration` 立刻退出：`line 129: IBR�: unbound variable`；macOS `/bin/bash` 3.2.57 在任何 UTF-8 locale 下都复现，只有 `LC_ALL=C` 或没有 locale 才正常 | F-8；后面的测试都加了 `LC_ALL=C` 绕过 |
| 6 任务执行（T-002） | **失败（流程）** | – | README 已做完，A1–A4 通过（`4045281`）；但任务卡 `locked_paths` 含 `.harness/**`，会话写不了自己的任务卡和交接文件，最后自开解锁门卡 G-T002-1 并转 blocked。单个任务会话花费 2.69 美元、67 轮 | F-9、F-10 |
| 6 blocked 任务不推送 | 通过 | – | 远端只有 `main`；`task/T-002-readme` 只在本地（`4045281`、`ce92b47`） | |
| 6 门卡 Issue 由控制面发 | 通过 | – | Issue #1–#4 在派发时由 gate-sync 发出（09:29:46Z 起）；审计日志里 Claude 侧没有任何 `gh` 命令 | |
| 6 Claude 侧无 push / gh 写操作 | 通过 | – | 17:29 之后的审计日志：0 条 `git push` / `gh pr|issue|api`；groom 会话试图写答案库被拒（「答案库只由控制面写」） | |
| 6 解锁门卡批准后任务接续 | **失败** | – | 用户决定 A，`answer G-T002-1 A` → `approved`，但没有「T-002 解除阻塞」提示；`gate-sync --resume` 后第二轮夜间流程没有接续 T-002，仍是 blocked | F-12；这一轮又白跑了一次 backlog-groom |
| 6 推分支、开 PR、合并门卡 | 无法验证 | – | T-002 被 F-9 和 F-12 卡住，产品自身的流程走不到 review | 需要人工改任务卡才能继续，见「未完成」 |
| 6 控制文件篡改 → G-Txxx-ctl | 无法验证 | – | 要另开一个任务并走到 review；按用户决定，第 6 步到此为止 | 静态核对：`harness-loop.sh` 写明改到 CONTROL_PATHS 的分支不合并、不推送、开 G-Txxx-ctl；注意 F-3（package.json 不在控制路径里） |
| 6 调度：派发 proposed 任务 | **失败（小）** | – | groom 之后调度器派发了 T-006、T-007，认领时报「状态是 proposed，只有 ready/claimed 可以认领」 | F-11 |
| 7 分支保护：判断 | 通过 | – | 公开仓库：`init --dry-run` 输出「分支保护可以开：会开门卡」，`--yes` 生成 `G-SETUP-bp`（预检：只读查询 404、写调用 0 次） | 无头 `/harness:setup` 卡在 Bash 审批（B），因此直接跑技能里的两条 init 命令；技能说明写「两条 `gh api -X PUT`」，门卡实际只有一条 |
| 7 分支保护：生效 | 通过 | – | 用户在对话中批准 A，`answer G-SETUP-bp A` 记录（via 终端），由验收员执行门卡命令；`gh api …/protection` → `pr_required:true, approvals:0, force_push:false, deletions:false, enforce_admins:true`；直接 `git push origin main` → `protected branch hook declined` | `show` 提示「卡片在快照后改过」，但这期间没人手动改过卡片（重跑 `init --yes` 重写了卡片？），待确认 |

## 发现

- **F-1 版本号没升，用户收不到修复。** S-002 仍是 0.1.0。`claude plugin update` 按版本号判断，回「已是最新」，cache 停在含残留目录的 `2add927`，只有卸载重装才能拿到 `932288d`。建议每次合并都升 `plugin.json` 的 version。
- **F-2 strict 沙箱挡不住 macOS 钥匙串（严重）。** denyRead 只管文件路径，`security` 走 securityd 的系统服务通信。沙箱里的代码能拿到 GitHub token。网络白名单挡住了直接外传，但 token 可以写进仓库文件，随调度器的 push 离开本机。建议在 macOS 的 strict 配置里拒绝钥匙串访问（例如在 sandbox-runtime 层禁止访问 `com.apple.SecurityServer` 等服务），或者夜间流程改用钥匙串之外、只给控制面用的凭证。修复后用本报告的 srt 复测命令回归。
- **F-3 验证可被绕过。** `verify.sh` 执行的是 `npm run test`，但 `package.json` 既不在 denyWrite 里，也不在 `locks.txt` 里。沙箱里改 test 脚本即可让验证恒过。建议把 verify.sh 实际依赖的入口（package.json 的 scripts 字段，以及其他技术栈的对应文件）纳入控制文件检查。
- **F-4 strict 没禁用 claude.ai 连接器。** 网络沙箱管不到连接器（它们在服务端执行）。夜间流程默认的 acceptEdits 下会被权限拒绝，但 `harness-loop.sh` 写明可以切到 auto，切过去后连接器可以直接调用，发信、转发都在列表里。建议 strict 下加 `--strict-mcp-config`，或在 deny 里加 `mcp__claude_ai_*`。

- **F-5 对话内答复在真机上永远记不上（T-015 失败）。** `hooks/chat_answer.py` 的 `on_ask` 在 PostToolUse 时，只要 `tool_input` 里有 `answers` 就判定为「预填」、整张拒收。而 Claude Code（2.1.321 和 2.1.325 都是）作答后会把用户的答案写回 PostToolUse 的 `tool_input.answers`。结果是真人作答一律被当成预填。建议改为在 PreToolUse 判定预填（那时 `tool_input` 只有 `questions`，出现 `answers` 才是 Claude 预填；PreToolUse 可以直接拒绝这次调用），或者按 tool_use_id 把 PreToolUse 看到的输入记下来，到 PostToolUse 再比对。
- **F-6（小）`show` 误报「卡片在快照后改过」。** G-SETUP-bp、G-DEMO-1 都出现了，但这期间没人手动改过卡片。看起来是控制面自己往卡片里回写了 `issue:`、`worktree:`、`session:` 等字段，触发了提示。
- **F-7（小）新建的 npm 仓库 verify.sh 恒失败。** `npm init -y` 生成的 test 脚本是 `exit 1`，`init` 照样生成 `npm run test` 作为完整验证，也不提示。为了跑第 6 步，验收员在测试仓库里把 test 脚本改成了 `echo … && exit 0`（提交 `bdc6c14`，属于测试夹具，不是产品改动）。

- **F-8 macOS 上夜间流程起不来（严重）。** `harness-loop.sh` 用 `#!/usr/bin/env bash`，在 Mac 上就是系统自带的 bash 3.2。在 UTF-8 locale 下，bash 3.2 会把紧跟在 `$VAR` 后的全角字符字节当成变量名的一部分，例如第 129 行 `$IBR（`，再加上 `set -u`，脚本直接退出。同样的写法在 harness-loop.sh、gate-sync.sh、gates.sh、new-task.sh 里还有十几处（`grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' scripts/*.sh`）。建议统一改成 `${VAR}`，并在 CI 里加一个 macOS bash 3.2 + UTF-8 locale 的冒烟测试。
- **F-9 task-align 让任务锁死自己。** 任务卡写着「不做：…`.harness/**`」，生成的 `locked_paths` 也就包含 `.harness/**`。`protect_paths.py` 于是拒绝任务写自己的任务卡、交接文件和门卡，一个只改 README 的任务也会被 blocked。建议 `locked_paths` 永远排除任务自己的 `.harness/tasks/T-xxx*`、`.harness/handoffs/T-xxx*`、`.harness/gates/G-Txxx-*`，或者 task-align 不要把 `.harness/**` 写进 locked_paths（全局 locks.txt 已经保护了具体的控制文件）。
- **F-10 locked_paths 只拦 Edit/Write 工具，Bash 能绕过。** T-002 会话被拦后改用 `python3 -c "…set_frontmatter_field…"` 和 heredoc 直接写进了被锁的文件并提交。replan 会话也指出这和 guardrails 第 7 条「被拒绝后不要换个命令绕过去」相冲突。locked_paths 不在沙箱的 denyWrite 里，所以 OS 层也不拦。建议要么把任务的 locked_paths 也加进 strict 的 denyWrite，要么在控制面的 control-diff 里检查任务分支有没有改动 locked_paths。
- **F-11（小）调度器派发 proposed 任务。** groom 之后，pick-batch 选了 T-006、T-007，认领时才失败。
- **F-12 解锁门卡批准后任务不接续。** G-T002-1 是会话用 Bash 绕过 hook 手写的，`paths:` 为空。控制面答复后没有和 T-002 关联起来解除阻塞，调度器也不会重新派发 blocked 任务。结果是：任务自己开的解锁门卡，批准了也没用。建议控制面校验 unlock 门卡必须带 `paths`，或者答复后按 `task:` 字段解除阻塞。
- **F-13（小）审计打码漏了看板 token。** 打码规则管 `ghp_…` 这类凭证，但 `serve` 的 `?t=` 会话 token 照原样写进审计日志（例如浏览器工具的 `url=` 字段）。token 只在本次 serve 进程有效、只监听 127.0.0.1，影响有限；但审计页本身就是用这个 token 保护的。建议打码规则加上 `[?&]t=[^&\s]+`。
- **F-14（小）配对失败没有提示。** 错误码、已用过的码都静默丢弃，用户分不清是被拒还是 bot 没在跑（这次两种情况都碰上了）。建议对「当前有有效配对码、但码不对」回一句「配对码无效或已用过」。
- **F-15（小）答复后消息没有统一更新。** 一次答多张卡时，有的消息变成「已答复」，有的还挂着选项按钮，用户以为没生效又点了一次（第二次正确回了「已经答过了」）。另外按钮点下去要等一个长轮询周期（≤20 秒）才有反应，期间没有任何反馈；建议收到回调立刻 `answerCallbackQuery`，并在记录后统一编辑掉按钮。
- 另：`guard_bash` 把「用 heredoc 新建门卡文件」误判成「写答案」并拒绝；`harness_lib.py backlog-status` 不带参数时会抛 IndexError，没有用法提示。

## 环境恢复（11:12Z 后）
- crontab：验收前没有；`crontab -r` 删掉 down 留下的空表，`crontab -l` → `no crontab for linxiutong`。
- `harness down` → 「没有要停的」；serve、inbox 都已停止。`pgrep -fl harness` 只剩用户自己的 `~/harness-verify-run/runner.sh`，由用户在它的标签页 Ctrl-C。
- `~/.claude/settings.json`：用户选择保留 harness 加的项（插件启用、marketplace、2 条 Read deny）。
- git 全局 credential 配置：`git config --global --get-regexp credential` 没有输出，不需要清理。
- 用户选择保留：GitHub 测试仓库、`~/harness-verify`、`~/harness-verify-run`、`*.bak-verify` 备份、全局 sandbox-runtime。
- `gh auth logout`：用户已执行（「Logged out of github.com account nnddoon」）；`security find-generic-password -s gh:github.com` → exit 44（钥匙串里已没有），`gh auth status` → exit 1。
- 用户自己做：在 BotFather 删除 @nnddoonbot（token 一并作废）。
- 失败项暂不开成 `nnddoon/harness` 的 Issue，用户先看报告。

## 环境问题（不计入结果）
本机通过本地代理（`127.0.0.1:1082`，DNS 走 198.18.x.x 透明代理）访问 API。06:31–06:58Z 期间 claude 调用正常；从约 07:50Z 起，`claude -p` 持续 `ECONNRESET`，显式设 `HTTPS_PROXY` 也一样，而 curl 访问 api.anthropic.com 正常（405）。判断是代理线路上游断开长连接。桌面端正常，是因为它走 macOS 系统代理；命令行 `claude`（Node）不读系统代理，只走透明代理。同一时段对比测试：显式设 `HTTPS_PROXY=http://127.0.0.1:1082` 时 3 次里成功 2 次，不设时 0 次。此后所有脚本都显式设代理。补充：桌面版内置的 Claude Code（2.1.321）环境里也是 `HTTPS_PROXY=http://127.0.0.1:1082`；17:22–17:27 的对比测试中，2.1.321 和 2.1.325 都是先断后通，和版本无关，是线路时断时续。

**Telegram bot token 外露（第 3 步）。** 第一次 `inbox setup` 时，token 出现在桌面版终端面板的提示符下一行；随后用户又在 shell 提示符下粘贴了一次（`zsh: command not found`），所以它也进了 `~/.zsh_history`。验收员读终端面板时也读到了它，所以它也进了本次对话记录（`~/.claude/projects`）。harness 用的是 `getpass`，第二、三次 setup 在提示出现后才粘贴，就没有回显，所以判断是提示出现前就粘贴了，不算产品问题。已建议用户在 BotFather `/revoke` 并删掉那行历史；用户有没有作废：未确认。
