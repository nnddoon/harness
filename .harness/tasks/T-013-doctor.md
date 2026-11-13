---
id: T-013
title: doctor / down / 定时任务到期
status: claimed
priority: P2
risk: low
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-013-doctor
worktree: .claude/worktrees/T-013
session: auto
depends_on: [T-008]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/cli/doctor_cmd.py, pkg/bin/harness, pkg/scripts/gate-sync.sh, pkg/scripts/harness-loop.sh, pkg/tests/test_doctor.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-013 doctor / down / 定时任务到期

## 1. 背景与目标
随时看得到 harness 在你电脑上跑着什么，并能一键停掉；定时任务不会在项目结束后永远跑下去。

## 2. 范围
**做：**
- `harness doctor`：定时任务（含到期日）、存活的调度器与 bot（pid 目录）、旧 worktree、久未答的门卡、沙箱依赖
- `harness down`：停进程、移除定时任务，幂等
- install-cron 写 `# harness expires=<日期>`，每次运行先检查到期

**不做（明确排除）：**
- 不删除 worktree（只列出）

**接口约定（tester 按此写测试，builder 按此实现；测试：`pkg/tests/test_doctor.sh`）**
- 时间：`HARNESS_NOW`（Unix 秒）覆盖「现在」，所有日期按 UTC 算（测试设 `TZ=UTC`）。
- crontab 一律以 `${HARNESS_CRONTAB:-crontab}` 调用（`-l` 读、`-` 从 stdin 写）；`crontab -l` 失败（还没有 crontab）当作空表。只增删带 `# harness` 标记的行，其余行原样保留。
- 「本仓库的行」= 含 `# harness repo=<主仓库绝对路径> `（路径精确匹配，`/x/r` 不匹配 `/x/r-other`）的行；主仓库 = `git rev-parse --git-common-dir` 的上一级。
- `gate-sync.sh install-cron`：写 `*/5 * * * * cd "<MAIN>" && … scripts/gate-sync.sh --resume --quiet >> … 2>&1 # harness repo=<MAIN> expires=YYYY-MM-DD`（行尾就是这段标记；到期日 = 今天 + `${HARNESS_CRON_DAYS:-30}` 天）。重装只替换本仓库的行（恰好一行），不动别的仓库的 harness 行和非 harness 行。
- `gate-sync.sh` 每次同步运行（非 setup/publish/install-cron）先查到期：本仓库的行 `expires` < 今天 → 从 crontab 删掉这一行、向 `<MAIN>/.harness/reports/expired-cron.txt` 追加一行（含「已到期」和到期日）、退出 0，**不**同步（不调用 gate_github.py）。今天 = 到期日当天仍正常同步；没有本仓库的行（手动运行）照常同步。
- `harness-loop.sh`：启动时写 `state_dir(主仓库)/run/loop-<$$>.pid`（内容 = 调度器 pid），退出（含 SIGTERM）时由 trap 删除；写晨报时，若 `.harness/reports/expired-cron.txt` 存在，把其内容附在晨报 `morning-*.md` 末尾。
- pid 文件：`state_dir(主仓库)/run/*.pid`，内容是一个正整数 pid；内容不是 >1 的整数的文件视为无效（报告、不 kill）。存活 = `os.kill(pid, 0)` 成功。
- `harness doctor [--repo DIR]`（`pkg/cli/doctor_cmd.py`；DIR 可以是主仓库或其 worktree，默认 cwd）：按顺序打印 5 段，段标题行恰为 `## 定时任务`、`## 在跑的进程`、`## 久未动的 worktree`、`## 久未答的门卡`、`## 沙箱依赖`；每项一行；空段打印 `（无）`。退出码恒为 0。
  - 定时任务：crontab 里所有含 `# harness` 的行（任何仓库），每行带 `expires=YYYY-MM-DD`，已过期的行加 `已过期`；`expired-cron.txt` 存在时把它的内容也列在本段（行含「已到期」）。
  - 在跑的进程：存活的 pid 每个一行（含 pid 与文件名）；已死的 pid 文件报告一行含 `已退出` 并删除该文件。
  - 久未动的 worktree：链接 worktree（不含主仓库）中「最后提交时间与目录 mtime 的较大者」距今 > 7 天的，每个一行（含路径与天数）。只列不删。
  - 久未答的门卡：主仓库 `.harness/gates/G-*.md` 中 `status: open` 且 `created:` 距今 > 3 天的，每张一行（含门卡 id）。
  - 沙箱依赖：`sandbox_problem(detect_platform())`，为空则 `ok`。
- `harness down [--repo DIR]`（由 `pkg/bin/harness` 分派到 `doctor_cmd.py` 里的实现）：对 run/*.pid 中存活的 pid 发 SIGTERM（只发给这些 pid，绝不碰其他进程；无效内容跳过），删除全部 pid 文件，从 crontab 删掉本仓库的 harness 行；打印做了什么；没有任何可停的东西时打印 `没有要停的`。幂等，退出码 0（没有 crontab 也是 0）。
- `harness --help` 列出 doctor 与 down。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 什么算在跑 | `$XDG_STATE_HOME/harness/run/*.pid` 里存活的进程 | 挑错 F#8 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新命令；gate-sync install-cron；调度器写 pid | gate-sync.sh:18-24 |
| 风险 | low | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：假 crontab + HARNESS_NOW 测到期；down 两次无害 — 结果：
- [x] 2. 实现 — 结果：doctor_cmd.py（doctor/down）、bin/harness 分派 down + help、gate-sync install-cron 标记与到期、harness-loop pid 文件 + 晨报附到期提示；test_doctor.sh 74/74
- [ ] 3. 完整验证 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. doctor 输出五类信息（S-002#16） — 证据：
- [ ] A2. down 停掉 pid 进程、移除定时任务，第二次执行退出码 0（S-002#16） — 证据：
- [ ] A3. HARNESS_NOW 超过到期日时定时任务移除自己，晨报与 doctor 提示（S-002#17） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 只动带 harness 标记的定时任务

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 旧版 install-cron 写的行没有 `# harness` 标记：新版重装不会删它（按约定只动带标记的行），升级用户可能出现两条同步任务；需要一次性迁移提示或 doctor 里提示无标记的 gate-sync 行

## 9. 范围变更 / 依赖变更
- 

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定直接实现：crontab 经 HARNESS_CRONTAB、标记 `# harness repo=<MAIN> `（尾空格防前缀误配）、日期用 python 按 HARNESS_NOW/UTC 算；loop 用 EXIT+TERM trap 删 pid | 四个文件 | test_doctor.sh 74/74 通过 |
| 2 | 在本仓库手动跑 doctor 报 AttributeError：_lib 优先加载仓库里的旧 harness_lib（无 state_dir）；改为优先包自带的库（同 launch_cmd） | doctor_cmd._lib 顺序 | 手动 doctor 正常、退出 0；测试仍 74/74 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
