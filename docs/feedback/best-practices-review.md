# 外部审查：对照 Claude Code best practices（2026-11-15，另一对话产出，原样存档）

我先读那篇 best practices 和你项目里的 harness 文档，然后逐项对照、给出可借鉴的原则和批评。

整体看，你的 harness 已经覆盖了这篇文档的大部分核心原则，有几处（证据分级、由控制面执行验收）比文档走得更远。主要问题有四类：停止条件不是硬上限；有几个只算偏好的规则被做成了 hook；有些地方还是 agent 给自己打分；R-1 这类防御靠列举输入，会一直补不完。

以下判断依据的是项目里的 9 份文档。我没看到源码。README 还是早期复制进仓库的版本，后来已经改成插件，所以有些点可能已经改过了。

---

## 一、可以直接借进来的（按收益排序）

1. **给无人值守运行加硬上限。** `harness-loop.sh` 调 `claude -p` 时加 `--max-turns` 和 `--max-budget-usd`。现在 `/goal` 里的「超过 40 轮」是另一个模型读对话后判断的，不能保证一定停。S-004 里还没定的「验证时间预算」可以直接用 `--max-budget-usd` 来做。
2. **无人值守用的权限模式。** `HARNESS_PERMISSION_MODE` 默认是 `acceptEdits`，它在 `-p` 下遇到要确认的命令会怎样，说得不清楚。文档推荐脚本用 `--permission-mode dontAsk` 加 `--allowedTools`：不在名单里的直接拒绝。`--allowedTools` 可以从 `allow-commands.txt` 生成，这也正好就是你第 9 节「拒绝并告诉它怎么继续」的做法。
3. **Stop hook 有个上限，要算进去。** 如果连续 8 次停止都被拦、中间没有任何工具调用，Claude Code 会强行结束这一轮（可以用 `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` 调）。`stop_gate` 和 `decision_guard` 共用这个上限。被强行放过时，会话看起来是正常结束的。所以调度器在会话结束后要再读一次任务卡：验收没勾完、又不是 `waiting_human`，就标成 `blocked`，原因写「stop 上限」。
4. **worktree 缺文件。** 新开的 worktree 是全新检出，里面没有 `.env`，也没有装好的依赖。用 `.worktreeinclude` 带上 `.env` 这类小文件，`node_modules` 用 `worktree.symlinkDirectories`。你主要写 Vue，不处理的话 `verify.sh` 在 worktree 里会先挂在依赖上。
5. **headless 运行要能复现（先验证再用）。** 文档建议脚本用 `--bare`，再用 `--settings`、`--mcp-config`、`--append-system-prompt` 把需要的东西显式传进去。这样运行不受机器上个人配置的影响，T-018 A3（连接器混进 strict 会话）也能从根上解决。但 `--bare` 会跳过插件和 hooks，`--settings` 里写的 hooks 在 bare 模式下会不会跑，文档没说清楚。要先在 test-harness 里测一下。
6. **lessons 和规则文件要定期删减。** `lessons.md` 和「你的原则」现在只增不减，而每一行都会进每个会话的上下文。groom 时跑一次 `/doctor prompt-audit`（会找出过时和互相矛盾的指令）；给 lessons 加 `paths:`，只在相关目录加载；再设个条数上限。
7. **能用内置功能的就别自己维护 hook。** `/fewer-permission-prompts` 和 `autoMode.environment` 能替掉 `permission_allow.py` 的一部分；`/verify` 可以给 UI 门卡做预检；`/usage` 能按子代理类型看花了多少，拿来衡量 critic 值不值。
8. **把分支保护当最后一道硬关。** setup 或 doctor 里检查 main 有没有保护规则，并且调度器用的 token 绕不过去。

## 二、值得借的原则，以及你现在做到哪

| 文档原则 | 你的现状 |
|---|---|
| 不能有例外的规则用 hook 或 deny；只是偏好的交给模型 | 方向对，但 `decision_guard` 和「禁止新建 SUMMARY 文件」是偏好（见三-3） |
| 给 agent 一个能跑出通过/失败的检查，并要求贴证据 | ✓ S-004 的证据分级比文档更进一步 |
| 换人审查有用，但交给子代理不会让答案更聪明 | ✓ verifier 用干净的上下文；critic 的部分见三-4 |
| 纠正两次还错，就清空重来，不要纠正第三次 | 你允许同一个问题试 5 次，偏多（见三-5） |
| 无人值守前的五问 | 完成标准、自检、能碰什么、结果交给谁：✓；什么让它停：✗（见一-1） |
| 需要强制执行的规则保持少量 | 现在约 10 个 hook、17 个开关，维护成本已经不低 |

## 三、批评

1. **R-1 的根源是在列举输入，不是只漏了几个配置文件。** 文档明确说，权限规则和 hook 匹配的是工具调用，不是意图：脚本自己去打开文件，规则抓不到。照现在的修法，要锁的运行器配置清单会一直变长（jest、vitest、ruff，接下来还有 tox、nox、pre-commit……）。建议改成检查结果：
   - a. control-diff 加一条：分支的改动只能落在「`allowed_paths` + 测试路径」里，范围外的任何文件都开 ctl 门卡。`jest.config.js` 不在任务范围内，自然会被拦下。没写 `allowed_paths` 的任务再退回现在的列举办法。
   - b. 加一条不变量：分支上收集到的测试数（`pytest --collect-only -q`、`vitest list`）不能比 base 少。这样不管改的是哪个配置，`testMatch: []` 都会被抓到。
   - c. 现在的列举表留着，只当作 strict denyWrite 的早期提醒。

   如果 0.2.2 还没定稿，我倾向做热修，但主体用 a 和 b。
2. **还有几处是 agent 给自己打分，和你的原则 2「执行者不给自己打分」冲突。**
   - `auto_ok` 是 groom 自己标的，标完直接变 `ready`。
   - risk 由 task-align 或 impact-analyst 判定，而 risk 又决定要几个 critic、要达到哪个证据档位、能不能自动合并，等于鼓励往低报。建议按路径算出风险下限：碰到控制文件、认证、迁移、依赖清单，至少算 medium 或 high。agent 只能往上调，不能往下调。
   - 信任阶梯：「至少 8 次、一致率 ≥90%」实际上就是 8 次全对（7/8 是 87.5%）。而且门卡先给你看「推荐」，你的选择会被它带着走，一致率会偏高。建议拿一部分门卡盲答（先选，再看推荐）；放权之后，晨报抽查时你推翻一次就自动收回。
3. **有偏好被做成了 Stop hook。** `decision_guard` 检查的是回复的格式。文档的说法是，只是偏好的 hook 应该删掉。它和 `stop_gate` 共用那 8 次上限，无人值守时还会把轮数花在改措辞上。建议改成规则或技能，或者只在交互模式下启用。「禁止新建 SUMMARY/REPORT/NOTES*.md」也会误伤用户项目里本来就合法的同名文件。
4. **critic 容易逼出过度修改。** 文档提醒：让审查者去找问题，它总能找到点什么；每条都修，就会多出不必要的抽象层，和测试不可能发生的情况的用例。高风险任务配 5 个「尽力证明它是错的」critic，这个风险不小。建议：
   - critic 的提示词写明「对照任务卡，只报影响正确性的问题，可以报 0 条」；
   - judge 认定「成立」的标准，和 state-scan 的证据等级对齐（至少读代码确认到行号）。

   另外，文档说 haiku 适合简单的活，对抗式的正确性审查不算简单。建议拿 `/usage` 的花费加上「N 个挑错、K 条成立」的命中率，用数据来决定。
5. **同一会话试 5 次太多。** 失败的尝试会一直留在上下文里反复被读到。既然任务卡是唯一事实来源，开新会话的代价很低：第 2 次失败后由调度器带上尝试日志开新会话，第 5 次再进 `/replan`。
6. **「上下文 ≥ 50% 就开新对话」这条前提已经过时。** 现在多数模型是 1M 的窗口，还会自动压缩，真正花钱的是缓存过期（订阅约 1 小时，API key 约 5 分钟）和带着无关的历史。人工门等了几个小时之后再续接原会话，缓存早就凉了，整段历史要全价重读。答复后一律开新会话、读任务卡接续，更便宜，也更符合你的原则 1。

## 四、有歧义或互相矛盾的地方

1. **自动合并。** README §4.6 和 §4.15 说合并永远由你来做、不能放权；S-004 的目标 1 和第 6 项却说「按证据档位自动合并」。合进的是 integration 还是 main，要写清楚。如果是 main，README 和信任阶梯里「永不放权」的清单都要跟着改。
2. **状态集合没有完整定义。** 现在出现过的有 proposed、ready、claimed、in_progress、waiting_human、blocked、review、done。夜间模式里「已整合、还没合进 main」其实也是一个状态（下游据此开工），但它没有名字。S-004 #2 的转移表要把它列出来。
3. **done 是事后推断出来的。** `sync-merged` 从 merge commit 推断任务完成了，所以要求「用 Merge commit 合并」。按你自己 state-scan 的分类，这就是 D 类（事后倒推）：一旦用 squash 或 rebase 合并，状态就丢了。建议按 PR 号和 PR 的合并事件来记录，不要看提交的形状。
4. **提议中的任务存在哪。** S-004 说任务卡是唯一来源，但 AI 提议区里的条目可能还没有任务卡。要么提议时就建卡，要么写明这是例外。
5. **`auto_ok` 和依赖门互相打架。** 「依赖小版本升级」被列为可以自动批准，但「新依赖要你批」的那道门会拦下 `npm add` 和 lock 文件的改动，这类任务会卡在 `blocked`。需要定一个谁优先。
6. **`/goal` 和 `stop_gate` 都在判断「完成没有」。** 一个是模型读对话，一个是脚本读文件。两者冲突时（goal 认为完成了，stop_gate 拦下）以谁为准？算进哪个上限？
7. **`gate-sync --resume` 指什么。** 是 `claude --resume` 续接原来的会话，还是在 worktree 里开一个新会话？这关系到第三节第 6 点的花费。
8. **无人值守时实际用哪个权限模式。** 默认是 `acceptEdits`，§4.11 推荐 auto，§9 又说无人值守时把会弹确认的命令改成 deny。三处说法不一致。
9. **agent 能不能自己关掉护栏。** 有 17 个环境变量开关。agent 能不能通过改 `.claude/settings.local.json`，或者在 Bash 里嵌套启动 `claude`，来关掉护栏？我看不到源码。如果 test-harness 里还没有这类用例，建议补上。

要不要我把这份整理成 `claude/best-practices-review.md` 存进项目，或者把一-1、三-1、三-2、四-1 这几条直接改写进 S-004 草稿？

Sources:
- [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices)