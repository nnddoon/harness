---
id: T-016
title: Telegram 收件箱
status: ready
priority: P2
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-016-telegram
worktree: .claude/worktrees/T-016
session: auto
depends_on: [T-010, T-013]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [plugins/harness/**, pkg/cli/init_cmd.py, pkg/cli/inbox_cmd.py, pkg/bin/harness, pkg/cli/answers.py, pkg/plugin/build.sh, pkg/tests/test_telegram.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-016 Telegram 收件箱

## 1. 背景与目标
门卡推到你的 Telegram，点按钮就算答复；bot 跑在控制面，token 不进仓库、不进 Claude 的环境。

## 2. 范围
**做：**
- `harness inbox setup`（在你终端输入 token、显示一次性配对码）/ `start` / `stop`
- 长轮询（≤ 20 秒）；新门卡发带按钮的消息；回调写答案库并接续任务
- 不可逆类（按动作判定）二次确认；只接受已配对 user id；按钮数据只含门卡号和选项
- `HARNESS_TELEGRAM_API` 指向假服务器做测试；标准库 urllib

**不做（明确排除）：**
- 不接受自由文本指令
- 不做 LINE / Discord（留接口）

## 接口约定（tester 写，与 pkg/tests/test_telegram.sh 头注释一致）
```
T-016 验收：Telegram 收件箱（S-002 #14 #8）。按任务卡「接口约定」：
  harness inbox setup  [--repo DIR]   终端里 getpass 输入 bot token → config_dir()/telegram.json（0600，{token, paired_user_id, chat_id, api}），
                                      打印一次性 6 位配对码（10 分钟有效；「现在」取 HARNESS_NOW，同 T-013）
  harness inbox run --once [--repo]   一个轮询周期：getUpdates（timeout = HARNESS_TELEGRAM_POLL，≤ 20）→ 处理 /pair 与按钮 → 给未发过的开放门卡发消息
  harness inbox start|stop|status     后台 bot；pid 文件 state_dir(main)/run/inbox-<pid>.pid，内容 "<pid> <starttime>"（T-013 格式），命令行含 harness
消息正文只取门卡的 meta 快照；按钮 callback_data = "<GID>|<字母>"；irreversible/external/unlock（快照的 kind）要再点 "<GID>|<字母>|ok"；
答复走 record_answer(via=Telegram)（并 settle：镜像、decisions.md、接续）；已答 → answerCallbackQuery「已经答过了」。
只认已配对的 user id；陌生人的消息与回调一律不理（不回复）；自由文本除 /pair 外不理。token 不出现在任何输出、日志、仓库里。
假 Telegram 服务器：pkg/tests/fake/telegram.py（HARNESS_TELEGRAM_API 指向它）。
接口约定 v2（第 2 轮）：
 1. 正文带含义行（同 GitHub 通道）：审批类「选 A = 批准，其他 = 拒绝」；then: ready →「批准后变为 ready：<任务>」；解锁路径「批准后放开：…」。
    审批类的按钮文字：A →「A 批准」，其他字母 →「<字母> 拒绝」。
 2. 二次确认按「效果」判定：点 A 时，快照有任何效果（then / then_tasks / then_policy / then_rules、解锁路径、控制面记过 PR，
    或 kind ∈ irreversible/external/unlock/design）就要再点 "<GID>|A|ok"；没点过第一次的 "|ok" 无效；按钮必须来自那条消息（message_id 对得上）。
 3. editMessageText / answerCallbackQuery 出错：捕获、记日志，本周期继续（后面的更新照常处理、新门卡照常发，run --once 退出 0）；
    先在 inbox.json 里把该条标 closed 再改消息；后台 bot 出错后的等待也不超过 HARNESS_TELEGRAM_POLL。
 4. 关掉的条目（卡消失过）对应的门卡再出现 → 重新发；点关掉的旧消息无效。
 5. 配对试错按 from.id 计（每人 5 次，陌生人猜不废掉你的码）；群聊里的 /pair 不理；过期的码在下个周期清掉
    （telegram.json 只剩 token / paired_user_id / chat_id / api）。
 6. 一个 token 只跑一个 bot：锁/pid 在 config_dir；另一个仓库再 start → 拒绝并说出在跑的那个（pid）。多仓库共用一个 bot 不在本期范围。
 7. setup 把 config_dir 与答案库所在的状态目录加进仓库 .claude/settings.json 的 permissions.deny（Read(...)，经 init 的 merge 逻辑，不重复）。
 8. 并发 start → 只有一个 bot。
```

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 为什么不用官方 Telegram channel | 它把消息交给 Claude，由 Claude 写答案；且要求会话一直开着 | 本对话分析 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新命令与 pid 管理（复用 T-013） | - |
| 对外契约 | 新配置文件 $XDG_CONFIG_HOME/harness/telegram.json | - |
| 依赖变更 | 无 | - |
| 风险 | high：外部输入通道 | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：假 Telegram 服务器（http.server）测配对、推送、按钮、二次确认、陌生 user id 被忽略 — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 完整验证 + 对抗审查（5 个挑错） — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 配对只认一次性码；陌生 user id 的消息与回调被忽略（S-002#14） — 证据：
- [ ] A2. 新门卡在两个轮询周期内发出（S-002#14） — 证据：
- [ ] A3. 按钮回调写库 via Telegram，并触发接续（S-002#14、S-002#8） — 证据：
- [ ] A4. 不可逆类需二次确认（S-002#14） — 证据：
- [ ] A5. 配置文件权限 600；token 不出现在仓库与日志（S-002#14） — 证据：
- [ ] A6. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A7. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的手机上：真机配对、收到门卡、点按后任务接续（S-002#14 人工） — 门卡：

## 6. Guardrails（本任务特有）
- 网络请求只发往 HARNESS_TELEGRAM_API（默认 api.telegram.org）

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- builder：allowed_paths 加 `plugins/harness/**`——打包产物（build.sh 生成，test_plugin_install 检查它是最新的），只是重新生成，不手改。
- 未改 harness_lib / doctor_cmd：复用 record_answer（经 answer_gate，含 settle 镜像与接续）、gate_state、snapshot_meta/read_meta、open_gates、state_dir、config_dir、_write_private、scrub_env，以及 doctor_cmd 的 pid 文件读写 / 进程核验。`pkg/cli/answers.py` 不需要，未建。
- 第 2 轮：allowed_paths 加 `pkg/cli/init_cmd.py`——把 merge_permissions 的合并部分抽成 `merge_deny(root, want, notes)`（行为不变），inbox setup 复用它写 permissions.deny（接口约定 v2 #7）。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按测试头注释实现 inbox setup/run/start/stop/status：配置 600、配对码只存 sha256（10 分钟、≤5 次试错、私聊）、按钮须与已发消息的 message_id 绑定、approval 类须先点再点 `\|ok`（服务端记住待确认字母）、错误信息去 token | 新建 pkg/cli/inbox_cmd.py，pkg/bin/harness 帮助加一行 | test_telegram 87/87 一次通过 |
| 2 | 接口约定 v2：含义行与「A 批准 / B 拒绝」按钮；A 按效果（then*、paths、PR、irreversible/external/unlock/design）二次确认、无首点的 \|ok 无效；edit/answer 出错 soft 继续且先标 closed；关掉的条目再出现重发、旧消息失效；配对试错按 from.id、群聊忽略、过期码下周期清掉；config_dir/inbox-bot.pid + start 锁（一个 token 一个 bot、并发 start 只起一个）；setup 合并 deny；退避 ≤ POLL | inbox_cmd.py 改写相关函数；init_cmd 抽 merge_deny | test_telegram 132/132 一次通过 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
