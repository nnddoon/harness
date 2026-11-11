# Agentic Loop Harness for Claude Code

把「对齐需求 → 执行 → 验收 → 人工确认 → 交接 → 下一个任务 / 自动扩展任务」做成一套**可复制进任意仓库**的 Claude Code 配置。
目标：你只需要在**人工门（Human Gate）**出现时做判断，其余切换、交接、认领、开分支/worktree 都由 harness 驱动。

---

## 1. 整体状态机

```
            ┌──────────────────────────────────────────────────────────────┐
            │                                                              │
  人工需求 ──▶ ① ALIGN 对齐 ──(人工确认任务卡)──▶ ② RUN 执行 ──▶ ③ VERIFY 独立验收
  (/task-align)   产出任务卡                   (/task-run + /goal)   (verifier 子代理)
                                                    │                     │
                                                    │ 需要人判断           │ PASS
                                                    ▼                     ▼
                                            ④ HUMAN GATE ◀──────── 需要合并/部署/感官测试？
                                            (/human-gate 生成确认卡,     │ 否
                                             不阻塞其他独立任务)          ▼
                                                                    ⑤ CLOSE 收尾 (/task-close)
                                                                     · 写交接包 + 冻结路径(locks)
                                                                     · 问：本对话继续 / 开新对话 / 停
                                                                          │
                                                 ┌────────────────────────┴───────────┐
                                                 ▼                                    ▼
                                      backlog 还有 ready 任务                  backlog 已清空
                                       → 认领下一张 → ① 或 ②               → ⑥ GROOM 审核对话
                                                                          (/backlog-groom，独立会话)
                                                                          从 功能/测试/安全/部署/
                                                                          性能/可观测/UX 延伸新任务
                                                                          → 提议区 → 人工批准 → ①
            └──────────────────────────────────────────────────────────────┘
```

三个原则：
1. **任务卡是唯一事实来源**：需求、范围、修改过程、验收、guardrail、交接全部写在 `.harness/tasks/T-xxx.md`，对话可以丢，任务卡不能丢。
2. **执行者不给自己打分**：验收由 `verifier` 子代理（只看任务卡 + diff + 测试结果，没看过实现过程）完成；`/goal` 的完成条件也由独立的小模型判断。
3. **确定性规则用 hook，判断性规则用 prompt**：不准动的路径、不准跑的命令写进 hook（模型绕不过去）；「什么时候该问人」写进规则和 skill。

---

## 2. 目录结构

```
CLAUDE.md                         # 项目宪法：短、只放每次都必须知道的
.claude/
  settings.json                   # hooks + 权限 deny 列表
  rules/
    harness-guardrails.md         # 全局 guardrail（改什么、不改什么、git 规范）
    human-gates.md                # 什么时候必须找人、怎么找人
  skills/
    task-align/SKILL.md           # /task-align  需求 → 任务卡（含修改过程/验收/guardrail）
    task-run/SKILL.md             # /task-run T-012  按任务卡执行
    task-close/SKILL.md           # /task-close  验收后收尾、交接、问下一步怎么走
    handoff/SKILL.md              # /handoff  生成交接包 + 新对话启动提示词
    human-gate/SKILL.md           # /human-gate  生成人工确认卡（设计/UI/感官/合并…）
    backlog-groom/SKILL.md        # /backlog-groom  任务清空后的审核扩展
    tower/SKILL.md                # /tower  控制塔：现读全局状态、建议并执行下一步（无状态，随时可重开）
    spec/SKILL.md                 # /spec  大需求：spec → 任务图 → 一次确认
    replan/SKILL.md               # /replan  卡住的任务：拆分 / 换路线 / 需要你（不删任务）
  agents/
    verifier.md                   # 独立验收
    security-auditor.md           # 安全/资安审计（groom 和高风险任务用）
    backlog-reviewer.md           # 从现有代码延伸任务
    impact-analyst.md             # 影响分析（只读，附证据）→ 推出 allowed/locked paths 与 guardrails
    tester.md                     # 先写测试（只能改测试）
    critic.md                     # 对抗审查：从一个角度尽力证明产出是错的（haiku，只读）
    judge.md                      # 对抗审查：核实挑错、只留成立的
    builder.md                    # 实现到绿（不能改测试）
  hooks/
    session_start.py              # 启动/恢复/压缩后：注入当前任务卡摘要、locks、待处理人工门
    protect_paths.py              # PreToolUse(Edit|Write)：禁止改 locks 和任务范围外的路径
    guard_bash.py                 # PreToolUse(Bash)：拦截 merge/push main/force/部署/危险删除
    stop_gate.py                  # Stop：任务卡验收没勾完又没在等人 → 不许停
    decision_guard.py             # Stop：回复里「待你决定」每项要引用门卡或带类别；ui/sensory 要写怎么验
    gate_github.py                # PostToolUse：新门卡 → GitHub Issue；sync：答复写回、关 Issue、接续任务、接收手机提的需求
    error_streak.py               # PostToolUse/Failure：同一调用连续失败 3 次 → 让 Claude 停止原样重试、升级处理
    quick_check.py                # PostToolUse：改完文件立刻跑 .harness/quick-check.sh，失败回给 Claude
    permission_allow.py           # PermissionRequest：自动放行只读命令、你列的项目命令、allowed_paths 内的编辑
    harness_lib.py                # 共用 + CLI：board / decide / pick-batch / set-status / sync-merged / goal
.harness/
  backlog.md                      # 任务池（人工区 / AI 提议区 / 已完成）
  locks.txt                       # 冻结路径（交接后不允许后续任务改动）
  decisions.md                    # 决策记录（ADR 简版），人工门的答复也记这里
  tasks/_TEMPLATE.md              # 任务卡模板
  handoffs/_TEMPLATE.md           # 交接包模板
  gates/_TEMPLATE.md              # 人工确认卡模板
  verify.sh / quick-check.sh      # 完整验证 / 单文件快检（你配置）
  allow-commands.txt              # 自动放行的项目命令（你配置）
  test-paths.txt                  # 哪些路径算测试
  STATUS.md                       # 自动生成的全局状态页（给同事看）
  sources.md                      # 原始数据来源（日志、Issue、崩溃、反馈），groom 按它找问题
  auto-decide.txt                 # 信任阶梯：已放权给 Claude 的门卡类别（只有你能改，可不存在）
  reports/                        # 晨报
scripts/
  new-task.sh                     # 认领任务：建分支 + worktree + 打印启动命令/提示词
  harness-loop.sh                 # 调度器：挑 ready 任务（--parallel N 并行）→ headless /goal → 同步 → 下一批
  gates.sh                        # 汇总所有待你处理的人工门（附 GitHub Issue 号）
  gate-sync.sh                    # GitHub 决策收件箱：同步答复 / --resume 自动接续 / setup / install-cron
  test-harness.sh                 # 自测：建临时仓库，把所有 hook / 脚本场景跑一遍（改 harness 后先跑它）
  demo/run-demo.sh                # 演示：用替身 Claude/GitHub 跑一遍「想法 → 合并」全流程，输出每步结果
```

---

## 3. 安装

```bash
# 在你的项目根目录
cp -r /path/to/agentic-harness/{CLAUDE.md,.claude,.harness,scripts} .
cat /path/to/agentic-harness/.gitattributes >> .gitattributes   # 决策/教训/冻结清单用 union 合并，避免并行任务冲突
chmod +x scripts/*.sh .claude/hooks/*.py
echo ".claude/worktrees/" >> .gitignore
echo ".claude/settings.local.json" >> .gitignore
echo ".harness/logs/" >> .gitignore
echo "__pycache__/" >> .gitignore
# 如果已有 CLAUDE.md：把本包 CLAUDE.md 的内容合并进去，保留你原来的技术栈说明
git add -A && git commit -m "chore: add agentic loop harness"
```

然后填 4 个地方（验收全靠它们）：
1. `CLAUDE.md` 的「项目速览」和「验证命令」；
2. `.harness/verify.sh`：完整验证（全部测试 + lint + 类型 + 构建），夜间模式每次合并后跑；
3. `.harness/quick-check.sh`：单文件快检（lint + 类型，几秒内）；
4. `.harness/allow-commands.txt`：不用再问你的项目命令（测试、lint、build）。
这几个文件被冻结，Claude 改不了，只能你改。

依赖：`git`、`python3`（hooks 用，无第三方包）、可选 `gh`（PR）。

装完先跑一次 `scripts/test-harness.sh`，全部 PASS 再开始用；以后改 hook 也先跑它。

---

## 4. 日常用法

### 4.1 有新需求（人工给的）

```text
/task-align 给播放器加一个倍速切换，0.5x–2x，记住用户上次的选择
```
Claude 会：读代码 → 最多问 3 个关键问题 → 写出任务卡 `T-013`（目标、范围、修改步骤、验收、guardrail、人工门、建议分支/worktree）→ 让你确认。
你回「OK」或改几行后，任务卡状态变 `ready`。

### 4.2 执行

**小任务，就在当前对话：**
```text
/task-run T-013
```
**大任务 / 想放着让它跑：**
```bash
scripts/new-task.sh T-013          # 建 task/T-013-xxx 分支 + .claude/worktrees/T-013 + 打印启动命令
cd .claude/worktrees/T-013 && claude
> /goal 按 /task-run 流程完成 T-013；完成条件：任务卡所有验收项已勾选且附证据、verifier 结论 PASS；或任务卡 status 变为 waiting_human/blocked；或超过 40 轮
```

### 4.3 收尾与切换（你原来手动做的部分）

任务验收通过后 Claude 会自动调用 `/task-close`，它会：
1. 把交接包写进 `.harness/handoffs/T-013.md`（改了什么、为什么、怎么验证、遗留问题、**下游不许动的东西**）。
2. 把需要冻结的路径追加进 `.harness/locks.txt`（之后任何任务改它都会被 hook 拦下，除非任务卡显式 `unlock`）。
3. 用选择题问你下一步，并给出推荐：

| 选项 | 什么时候推荐 |
|---|---|
| 在本对话继续下一张 | 下一张和本张同模块、上下文用量 < 50%、同分支能完成 |
| 开新对话（给你启动命令 + 交接提示词） | 换模块/换分支、上下文已重、下一张是大任务、需要干净视角 |
| 先停，等人工门 | 下一张依赖本张合并或人工确认 |

选「开新对话」时它会输出一段**可直接粘贴**的启动块：`cd` 到哪个 worktree、开哪个分支、第一句话说什么、要读哪些交接文件、哪些路径不许动。

### 4.4 任务清空 → 自动扩展

backlog 没有 `ready` 任务时，`/task-close` 会建议开一个**审核对话**（不要在执行对话里做，避免「自己审自己」）：
```bash
HARNESS_MODE=groom claude   # 在主仓库根目录；审核模式下 hook 只允许写 .harness/，不会动业务代码
> /backlog-groom
```
它会并行调用 `backlog-reviewer` 和 `security-auditor` 两个子代理，从 **功能完整性 / 测试 / 安全与资安 / 依赖与密钥 / 部署与 CI / 性能 / 可观测性 / UX 与无障碍 / 文档** 九个维度找缺口，写进 backlog 的「AI 提议区」，每条带 优先级、风险、规模、是否可自动批准。
- `auto_ok: yes`（低风险：补测试、补文档、lint 修复、依赖小版本升级）→ 直接进 `ready`。
- 其余 → 生成一张人工门卡，你批一下（一次批一批）。

### 4.5 无人值守（调度器）

```bash
scripts/harness-loop.sh --parallel 2 --max-tasks 4
```
`--parallel N`：一批最多派 N 个任务同时跑，只有 `allowed_paths` 互不重叠、也不和进行中任务重叠的才放进同一批；没写允许路径的任务只会单独跑。
循环：挑 `ready` 且依赖已完成的任务 → `new-task.sh` → 在 worktree 里 `claude -p "/goal …"` → 读任务卡最终状态 → 下一张；backlog 清空时跑一次 groom（只自动批准 `auto_ok` 的）；遇到人工门就**记录并跳过依赖它的任务**，继续跑独立的。结束时打印 `scripts/gates.sh` 汇总给你。

### 4.6 处理人工门

```bash
scripts/gates.sh             # 列出所有 status: open 的确认卡
```
每张卡都写好了：要你判断什么、怎么在 5 分钟内检查（命令/URL/文件）、机器已经预检了什么、选项 A/B/C 和推荐、不回答时的默认行为。你在任意对话里回一句：
```text
G-T013-2: B，按钮颜色再深一点
```
Claude 会把答复记进 `decisions.md`，关闭门卡，解除相关任务的阻塞。

合并永远由你来做（GitHub 上点合并，或批准门卡后在会话里确认 hook 弹出的提示）。合并后运行
`python3 .claude/hooks/harness_lib.py sync-merged`（`harness-loop.sh` 每次启动会自动跑），把对应任务从 `review` 标为 `done`——**依赖它的任务只有在 `done` 之后才会被认领**，因为新 worktree 从 main 分出（夜间整合模式例外：下游从整合分支开工，见 4.10）。

---

### 4.7 GitHub 决策收件箱（推荐：手机勾选即可接续）

每张人工门卡一打开，hook 就把它开成**私有仓库里的一个 GitHub Issue**，选项变成勾选框：

```
[G-T013-2][ui] 倍速选择器用下拉还是分段按钮？           labels: gate  kind:ui  task:T-013
## 怎么检查 …   ## 机器已预检 …   ## 素材（截图直接显示，音频/视频给链接）
## 选项
- [ ] A（推荐）：分段按钮 — 一眼看到所有倍速
- [ ] B：下拉 — 省空间
```

你在 **GitHub 网页/手机 App 勾一项**，或**直接回复通知邮件**（第一行写 `B 颜色再深一点`）。
`scripts/gate-sync.sh` 读到后：检查是你本人（不是你的账号不算）→ 写回门卡和 `decisions.md` → 在 Issue 留回执并关闭 → 任务从 `waiting_human` 回到 `in_progress` → 加 `--resume` 时在该 worktree 后台接着跑 `/goal`。

- **合并类门卡**不另开 Issue：门卡填 `pr: <号>`，PR 本身就是门，**合并=批准、关闭=拒绝**。
- 在会话里当场答复的门卡，下次同步会自动关掉对应 Issue。
- 记录在三处且互相关联：Issue（含讨论）、门卡、`decisions.md`；所有 Issue 可用 `label:gate` 搜索。

**一次性设置：**
```bash
gh auth login                       # 用你的 GitHub 账号
scripts/gate-sync.sh setup          # 建标签、确认答复账号
scripts/gate-sync.sh install-cron   # 每 5 分钟同步并自动接续（电脑开着时）
```
然后在 GitHub：Settings → Notifications → Customize email updates → 勾选 **Include your own updates**（Issue 由你自己账号开，GitHub 默认不寄自己的动态）。邮件 CC 带 `your_activity@noreply.github.com`，可以拿来建邮件过滤器，把所有决策归到一个标签。
想要 **GitHub 手机 App 推送**：另开一个机器人账号加为仓库协作者，用它的 token 设 `HARNESS_GH_TOKEN`（推送不通知自己的动作，所以要由别的账号开 Issue；答复仍只认你的账号）。

- **紧急度**：门卡写 `urgency: high` 时 Issue 标题加 🔴、加 `urgency:high` 标签，可以在 GitHub 或邮箱里只对它设提醒；`low` 的可以攒着批。
- **从手机提新需求**：开一个 Issue 加标签 `harness:request`。`gate-sync.sh --resume` 会在主仓库以审核模式跑 `/task-align`，对齐问题和「确认任务卡」都以门卡 Issue 回给你；确认（门卡 `then: ready`）后任务变 `ready`，`harness-loop.sh` 接手。只接受允许名单里账号开的需求。

不想用 GitHub：`HARNESS_GATE_CHANNEL=off`，门卡只留在本地，用 `scripts/gates.sh` 查看。

### 4.8 规划套件：/spec 与影响分析

按需求大小选：**bug** → `/task-align`（轻量影响分析：调用方 + 复现测试）；**功能** → `/task-align`（完整影响分析）；**新专案 / 大改** → `/spec`（目标、非目标、场景、架构、契约、风险、验收、分批 → 拆成任务图，一张门卡一次确认，`then_tasks` 让确认后的任务全部变 ready）。
影响分析由只读的 `impact-analyst` 子代理做，每个结论附证据（命令或 文件:行）；任务卡的 `allowed_paths` / `locked_paths` / guardrails / risk / size 都从它推出，不凭感觉填。规划在 plan 模式或 `HARNESS_MODE=groom` 下跑：只能写 `.harness/` 和 `docs/specs/`。

### 4.9 执行套件：先测后码、快检、依赖门

- **tester / builder 分工**：`tester` 子代理按验收先写测试（红），实现方（主会话或 `builder`）把它做绿；hook 不让实现方改测试、不让 tester 改源码。小修可在任务卡写 `test_owner: any`。测试路径见 `.harness/test-paths.txt`。
- **改完即检**：每次 Edit/Write 后跑 `.harness/quick-check.sh <文件>`（你配置 lint + 类型），失败立刻回给 Claude。
- **尝试日志**：每次修复前在任务卡第 11 节写假设，同一问题最多 5 次，之后 blocked 交给 `/replan`（拆分 / 换路线 / 需要你；不删任务、不降验收）。
- **教训**：同一错误第二次出现，写进任务卡第 12 节，调度器同步到 `.claude/rules/lessons.md`，之后所有会话自动读到。
- **新依赖要你批**：依赖清单文件和 `npm add` / `pip install <包>` / `go get` 等被拦下，走 unlock 门卡。

### 4.10 夜间模式

```bash
scripts/harness-loop.sh --parallel 3 --until 06:00 --integration     # 或 --until +360（跑 6 小时）
```
通过验收的任务按批次顺序合进 `integration/<日期>`，每次合并后跑 `.harness/verify.sh`；红了就撤回那次合并（整合分支回到合并前，重试时第一次的好改动不会丢）并重开任务（最多 2 次，之后 blocked）。下游任务从整合分支开工，不用等你合并。每批结束：同步教训、卡住的跑 `/replan`、更新 `STATUS.md`。到点后写 `.harness/reports/morning-日期.md`（≤ 20 行：状态、已整合 + 证据、重开与卡住的原因、先看的 3 个 diff、新教训），有远端时开一个整合 PR（请用 Merge commit 合并，任务才会自动标记 done）。

### 4.11 权限：不用一直按「允许」

危险操作已经由 PreToolUse hook 硬拦（拒绝时会告诉 Claude 下一步），所以执行阶段可以放宽：
- **执行**：`claude --permission-mode auto`（后台有安全检查）；想默认就把 `"permissions": {"defaultMode": "auto"}` 写进 **`~/.claude/settings.json`**（写在项目的 `.claude/settings.json` 里不生效）。夜间模式用 `HARNESS_PERMISSION_MODE=auto`。
- **没有 auto 模式时**：`permission_allow.py` 会自动放行只读命令、`.harness/allow-commands.txt` 里你列的项目命令、以及任务 `allowed_paths` 内的编辑——把测试/lint/build 命令写进去即可。
- **规划**：plan 模式（只读）。
- **你拒绝时**：在输入框说一句原因或替代做法；Claude 这边的规则是「被拒绝就停下、记进任务卡、换方案或开门卡」，不会原样重试。

### 4.12 记录与协作

| 想知道 | 看哪里 |
|---|---|
| 全局谁在做什么、卡在哪、等谁、接下来哪几批 | `.harness/STATUS.md`（每次同步/每批自动重写并提交） |
| 某个任务的 todo、进展、试过什么、为什么这么做 | 任务卡 `.harness/tasks/T-xxx.md`（第 4、7、11 节） |
| 交付了什么、下游不能动什么 | 交接包 `.harness/handoffs/T-xxx.md` |
| 某个决定是谁、何时、为什么做的 | `.harness/decisions.md` + 对应门卡 / GitHub Issue |
| 大需求的来龙去脉 | `docs/specs/S-xxx.md`（任务卡 `spec:` 字段回指） |
| 昨晚发生了什么 | `.harness/reports/morning-日期.md` |
| 一次运行的完整过程 | `.harness/logs/T-xxx-*.jsonl` |

### 4.13 对抗式审查：另开会话专门挑错

同一个会话判断自己的产出不可靠，所以验收前另开几个 `critic` 子代理（默认用便宜的 haiku），**每个只从一个角度尽力证明它是错的**，再由 `judge` 子代理亲自核实证据、只留成立的，交回实现方修。数量按风险：

| 阶段 | low | medium | high |
|---|---|---|---|
| 验收前（`/task-run` 第 6 步） | 1（建议） | 3（必做） | 5（必做） |
| 确认任务卡 / spec 前 | 0 | 2 | 3 |

角度由 `harness_lib.py critics <risk> verify|spec` 给出（测试测的是不是需求、边界、漏改的调用方、安全与数据、契约）。结果记在任务卡「13. 对抗审查」；risk medium/high 没记录就进 review，Stop hook 会拦下，verifier 也会判 FAIL。门卡「机器已预检」里写上「N 个挑错，K 条成立已处理」，你判断时更有底。`HARNESS_CRITICS=off` 关闭。

### 4.14 审阅预算：不做超过你看得完的量

Claude 一晚能做很多，你一天只看得完一部分；做出来没人看就是浪费。`scripts/harness-loop.sh --review-budget 20`（或 `HARNESS_REVIEW_BUDGET=20`）：待你审阅的量——开着的门卡（按 `review_minutes`）加上做完未合并的任务（low 2 / medium 5 / high 10 分钟）——超过 20 分钟就不再开新任务。`harness_lib.py review-load` 查看当前的量，晨报和 STATUS.md 也会写。

### 4.15 信任阶梯：越用越少问你

每张门卡记下 Claude 的推荐（`recommended`）和你的选择（`answer`）。`harness_lib.py trust` 按类别统计一致率；同一类至少 8 次、一致率 ≥ 90%（`HARNESS_TRUST_MIN_N` / `HARNESS_TRUST_MIN_RATE`）就建议放权。放权**只能你本人做**：自己在终端跑 `harness_lib.py trust --apply ui`，或在 GitHub 上批准一张带 `then_policy: ui` 的门卡。Claude 跑这条命令会被 hook 拦下，`.harness/auto-decide.txt` 也被冻结。放权后这类门卡由 Claude 按推荐代决定（`decided_by: auto`），不打扰你，晨报列出供抽查。**合并、部署、新依赖、外部影响永远问你**，放不了权。

`/backlog-groom` 还会从 `decisions.md` 里找你**反复**做出的同类选择（至少 3 次），提炼成原则，开一张门卡问你要不要采纳（`then_rules`）；采纳后写进 `.claude/rules/lessons.md` 的「你的原则」，所有会话自动遵守。groom 也会读 `.harness/sources.md` 里你列的原始数据（错误日志、Issue、崩溃、用户反馈），让数据决定先修什么，而不是等你一条条转给它。

### 4.16 控制塔与「本对话还是新对话」

主控分两半：**调度器**是脚本（`harness-loop.sh` + `gate-sync.sh`），没有上下文，永远不需要交接；**控制塔**是一个无状态对话，在主仓库根目录 `claude` → `/tower`，每次从文件现读全局状态、给建议、执行你选的动作。控制塔变重了就关掉重开，不做「主控交接给主控」。

任务在哪个对话执行由规则决定（`python3 .claude/hooks/harness_lib.py decide T-xxx --after <刚完成的任务>`）：任务卡强制 > 无人值守一律新 > 非 S 级新 > 上下文 ≥ 50% 新 > 不是同一块代码新 > 否则 `/clear` 后本对话继续。`/task-align`、`/task-close`、`/tower` 都调用它，不再各自判断。

想看完整用户旅程：`scripts/demo/run-demo.sh`，或读《使用手册：从一个想法到上线》。

---

## 5. 人工门规范（摘要，完整版见 `.claude/rules/human-gates.md`）

| 类别 | 例子 | 机器先做到哪一步 | 人只判断什么 |
|---|---|---|---|
| 设计决策 | 架构取舍、数据模型、对外 API 形状 | 写 2–3 个方案 + 取舍表 + 推荐 | 选哪个 |
| UI/UX | 新页面、交互流程、视觉 | Playwright 截图（手机/平板/桌面）、a11y 扫描、录屏 | 好不好看、顺不顺手 |
| 感官 | 音频生成、TTS、视频推流、动画 | 可量化指标（响度 LUFS、削波、采样率、码率、帧率、丢帧、延迟）+ 样本文件 + A/B 对照 | 听/看起来对不对 |
| 不可逆 | 合并到主干、部署、数据迁移、删除数据、发版 | diff 摘要、回滚方案、dry-run 结果 | 批准 / 拒绝 |
| 外部影响 | 发消息/邮件、花钱、改权限、密钥 | 草稿 + 影响范围 | 批准 / 拒绝 |
| 需求歧义 | 任务卡里两种合理理解 | 列出两种理解及后果 | 选哪种 |

沟通规则：**批量问、选择题优先、给推荐和默认值、不阻塞独立工作、每张卡 5 分钟内可判断完**。

---

## 6. 环境变量开关

| 变量 | 作用 |
|---|---|
| `HARNESS_GUARD=off` | 临时关闭路径/命令护栏（你自己手动改 harness 时用） |
| `HARNESS_STOP_GATE=off` | 关闭 Stop 护栏 |
| `HARNESS_MODE=groom` | 审核模式：只允许写 `.harness/` |
| `HARNESS_UNATTENDED=1` | 无人值守：不提问，人工门写卡后跳过 |
| `HARNESS_PERMISSION_MODE` | `harness-loop.sh` 传给 `claude -p` 的权限模式（默认 `acceptEdits`） |
| `HARNESS_BASE=<ref>` | `new-task.sh` 从指定分支/提交开 worktree（例如依赖一条未合并的任务分支） |
| `HARNESS_GATE_CHANNEL=off` | 不把门卡发布到 GitHub |
| `HARNESS_GH_TOKEN` | 开 Issue/留言用的 token（机器人账号，用于手机推送） |
| `HARNESS_GATE_APPROVERS=a,b` | 接受哪些 GitHub 账号的答复（默认：`gh` 登录的账号） |
| `HARNESS_GATE_PUSH_ASSETS=0` | 不自动提交推送门卡素材（截图/样本） |
| `HARNESS_ERROR_LIMIT=3` | 同一调用连续失败几次后升级（0 = 关闭） |
| `HARNESS_QUICK_CHECK=off` | 关闭改后快检 |
| `HARNESS_AUTO_ALLOW=off` | 关闭权限自动放行 |
| `HARNESS_CRITICS=off` | 关闭对抗式审查 |
| `HARNESS_REVIEW_BUDGET=分钟` | 审阅预算（0 = 不限），同 `--review-budget` |
| `HARNESS_TRUST_MIN_N=8` / `HARNESS_TRUST_MIN_RATE=0.9` | 信任阶梯建议放权的门槛 |

自定义部署命令拦截：在 `.harness/deploy-patterns.txt` 每行写一个正则。

## 7. 在哪里跑：VS Code 扩展 / 桌面端 / CLI / Windows

三者是同一个 Claude Code，共用 `CLAUDE.md`、`.claude/settings.json`（hooks、权限）、skills、subagents，harness 行为一致。差别：
- **VS Code 扩展**：命令只支持一部分（输入 `/` 查看），没有 `!` shell 快捷方式；缺的（例如 `/goal`）在 VS Code 内置终端跑 `claude`。
- **桌面端**：自带并行会话与 worktree（同样放在 `.claude/worktrees/`，worktree 名称取成 `T-013` 才能被 hook 识别为任务）、diff 留言、预览浏览器（UI 门预检很好用）。Windows 上不读 PowerShell profile，`git`/`gh`/`python` 要加进系统或用户 PATH 后重启。
- **无人值守**（`harness-loop.sh`、`gate-sync.sh --resume`）一律走 CLI，与用哪个客户端无关。

**Windows 注意**：hooks 用 `python3`、脚本用 bash。
- 推荐在 **WSL2** 里跑（VS Code 用 Remote-WSL 打开，桌面端选 WSL 会话），与 Linux 完全一致。
- 原生 Windows：装 Git for Windows（提供 Git Bash）和 Python 3；若 `python3` 是 Microsoft Store 空壳，把 `.claude/settings.json` 里的 `python3` 换成 `py -3`，并设 `HARNESS_PYTHON="py -3"`。cron 换成「任务计划程序」。
- 装完一定跑 `scripts/test-harness.sh`：`python3` 不可用时它会直接报错，避免护栏悄悄失效。

## 8. 对照 12-Factor Agents 与「agent team 一夜跑完」prompt

参考 [humanlayer/12-factor-agents](https://github.com/humanlayer/12-factor-agents) 检查后的对应关系：

| 原则 | 本 harness |
|---|---|
| 3 自己掌控上下文 / 13 预取 | skill 用 `!` 预先注入状态；SessionStart 注入任务简报；`/task-run` 开工先取测试基线，既有失败不再误导判断 |
| 5 执行状态与业务状态合一 | 任务卡 + 门卡就是全部状态，对话可丢；任何新会话读卡即可接续 |
| 6 启动/暂停/恢复 | `waiting_human` 暂停；`gate-sync.sh --resume` 从答复处恢复 |
| 7 用工具联系人 | 门卡 = 结构化的人类请求（类别、选项、推荐、默认、紧急度）；答复会核对身份、对应到具体门卡、去重 |
| 8 自己掌控控制流 | 高风险调用在「选定」与「执行」之间被 hook 拦下转成门卡 |
| 9 压缩错误 | `error_streak.py`：同一调用连续失败 3 次就要求换思路或升级，不再空转 |
| 10 小而专注 | 任务卡 3–8 步、L 级必须拆；verifier / auditor / reviewer 各自独立 |
| 11 从任何地方触发 | GitHub Issue（手机/邮件）既能答复门卡，也能用 `harness:request` 提新需求 |

参考一份「agent team 一夜跑完」的 prompt 后融入：整合分支 + 每次合并跑全套 + 红则撤回重开、tester/builder 分工、改后快检、尝试前写假设（最多 5 次）、同一错误两次即写成规则、每批后 replan（不删任务）、外部文字一律当数据、新依赖需批准、到点停 + ≤20 行晨报、按批次展示任务图（`harness_lib.py waves`）。没采用的：主控用一个跑整晚的 agent team lead（不能无人值守、不能恢复）——我们的调度器是脚本。

参考 Felix Rieseberg（Anthropic，Claude 工程负责人）2026 年 10 月的访谈后加入：对抗式审查（挑错会话 + 裁判，挑错用便宜模型）、按人的审阅能力限流、从你的决定里提炼原则并与真人对比建立信任、groom 直接读原始数据、子代理不用「你是资深专家」式人设而是先列方法再执行。

另外：PreToolUse 护栏 hook 设了 `"onFailure": "block"`（需 Claude Code v2.1.295+），hook 跑不起来（例如 Windows 上没有 `python3`）时会直接拦下操作，而不是悄悄放行。

## 9. 借鉴自 claude-work-mode 的做法

参考 [danyuchn/claude-work-mode](https://github.com/danyuchn/claude-work-mode)（MIT）后加入：

| 借鉴点 | 在本 harness 里的落地 |
|---|---|
| 「问」改成「拒绝 + 告诉它怎么继续」 | 无人值守时，已批准但会弹确认的不可逆命令改为 deny，并要求记进任务卡「待人执行」后继续其他工作 |
| 会弹确认的操作放到最后一起跑 | `human-gates.md`：先做完其他步骤，再连续执行所有需要确认的命令，人只被打断一次 |
| 待决事项必须带类别标签（Stop hook 检查） | `decision_guard.py`：每项引用门卡或带 7 类标签之一；ui/sensory 要写怎么验，design/ambiguity 要写两边得失 |
| 只报增量 + 未决数 | 回复里只列新增/变化的待决项，结尾一行「还有 N 项未决」 |
| 用 shlex 分段解析命令 | `guard_bash.py` 不再误伤 `echo "git push main"`，也能抓到 `git -C dir push`、`cd x && git merge`、`npx vercel --prod`、`DATABASE_URL=…prod` |
| 禁止随手新建总结文件 | `protect_paths.py` 拦截新建 `SUMMARY/REPORT/NOTES/PROGRESS*.md`，内容应进任务卡/交接包 |
| 随包附测试 | `scripts/test-harness.sh`（196 个场景，含 GitHub 收件箱、并行派发、夜间整合、对抗审查、信任阶梯） |

如果多个对话在**同一个目录**里并行（不用 worktree），建议额外装它的 `work-mode-gates` 插件，里面的 `git-safe-commit-gate` 能防止 `git add <文件>` / `git commit <路径>` 把别的会话没提交的改动一起提交。

## 10. 可以按需裁剪

- 只想要对齐 + 收尾：只拷 `CLAUDE.md`、`.harness/`、`task-align`、`task-close`、`handoff` 三个 skill，不装 hooks。
- 团队用 GitHub Issues 管任务：把 `backlog.md` 换成 `gh issue list --label ready`，`new-task.sh` 里的认领改成 `gh issue edit --add-assignee @me --add-label in-progress`（需要自己改 `harness_lib.py` 里的 `backlog_rows` / `set_backlog_status` 两个函数）。
- 并行：`harness-loop.sh --parallel N`；每张任务一个 worktree，**只有控制塔对话和脚本改 backlog**（单写者），worker 只改自己的任务卡。
- 多个独立仓库或领域：各跑各的调度器（并列），不要让一个主控再生出下级主控。
