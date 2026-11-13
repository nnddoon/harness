---
id: T-008
title: 统一启动器与 strict 配置
status: claimed
priority: P0
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-008-launcher-strict
worktree: .claude/worktrees/T-008
session: auto
depends_on: []
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/cli/launch_cmd.py, pkg/cli/strict_profile.py, pkg/bin/harness, pkg/scripts/harness-loop.sh, pkg/.claude/hooks/gate_github.py, pkg/cli/serve_cmd.py, pkg/tests/test_launch.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-008 统一启动器与 strict 配置

## 1. 背景与目标
所有 Claude 启动点经同一个启动器：生成仓库外的 strict 配置并用 `claude --settings` 传入，清掉环境里的凭证，沙箱不可用就拒绝启动。做完后无人值守的 Claude 读不到凭证、写不了控制路径、只能访问按技术栈推出的网络白名单。

## 2. 范围
**做：**
- 新增 `harness launch`（`pkg/cli/launch_cmd.py`）：生成 `$XDG_STATE_HOME/harness/<仓库>/strict-settings.json`，清理环境变量，检查沙箱依赖，再 exec claude
- `pkg/cli/strict_profile.py`：一处定义控制路径清单、凭证路径清单、按技术栈的网络白名单、拒绝域名
- 改 4 个启动点改走启动器：`harness-loop.sh` 的 launch / replan / groom，`gate_github.start_run`（gate-sync --resume 与看板接续）
- 规划类运行（groom、replan）的工作目录改为专用 worktree `.claude/worktrees/_plan`
- 平台检测：缺 bubblewrap/socat、WSL1、原生 Windows 时给一句话修复办法；`HARNESS_PLATFORM` 可覆盖，供测试

**不做（明确排除）：**
- 不改交互会话的默认行为（D-006：standard 仍是默认；提供 `harness launch --strict` 手动开启）
- 不实现控制路径的 diff 检查（T-009）
- 不动答案写入逻辑（T-010）

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| strict 在哪里生效 | 无人值守强制；交互可选（待 G-S002-1） | spec §4、风险段 |
| 配置放哪里 | 仓库外，用 --settings 传入；Claude 改不了、已装仓库不用升级 | 挑错 F-可行性#7 |
| 网络白名单 | 按技术栈推出，github.com 只在需要时加入 | 挑错 F-可行性#8 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | harness_lib（技术栈检测复用）、harness-loop.sh 三处 claude 调用、gate_github.start_run | harness-loop.sh:126,165,192；gate_github.py:451-471 |
| 调用方 | gate-sync.sh、看板 POST /answer 后的接续 | gate-sync.sh:4；serve_cmd.py |
| 受影响测试 | test-harness.sh 里调度器相关用例需改用假 claude | pkg/scripts/test-harness.sh |
| 对外契约 | 新增 `harness launch` 子命令；新增环境变量 HARNESS_PLATFORM | - |
| 依赖变更 | 无（只用标准库） | - |
| 风险 | high：安全边界核心，错一处就整套失效 | spec §7 |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester 写失败测试：假 claude 打印收到的 argv 与环境；断言 --settings 文件内容与清单一致、凭证变量被清掉、缺依赖时退出码非 0 — 结果：
- [ ] 2. 实现 strict_profile 与 launch_cmd — 结果：
- [ ] 3. 替换四个启动点，规划类运行改到专用 worktree — 结果：
- [ ] 4. 完整验证 + 对抗审查（5 个挑错） — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 假 claude 收到 `--settings <状态目录>/strict-settings.json`，文件含 sandbox.enabled、failIfUnavailable、allowUnsandboxedCommands=false 与 denyRead/denyWrite/allowedDomains/deniedDomains/permissions.deny（S-002#4） — 证据：
- [ ] A2. 环境里没有 GH_TOKEN、GITHUB_TOKEN、HARNESS_GH_TOKEN、HARNESS_SERVE_TOKEN、HARNESS_TELEGRAM_TOKEN 及 *_TOKEN/*_SECRET/*_KEY（S-002#3） — 证据：
- [ ] A3. PATH 里没有 bwrap/socat、或 HARNESS_PLATFORM=wsl1/windows 时拒绝启动，输出含修复办法（S-002#1） — 证据：
- [ ] A4. 四个启动点都调用启动器（grep 断言 harness-loop.sh 与 gate_github.py 不再直接调用 claude）；groom/replan 的 cwd 是 _plan worktree（S-002#2） — 证据：
- [ ] A5. npm、pip、go、cargo 四种技术栈各生成对应白名单；拒绝域名始终含 api.telegram.org、webhook.site（S-002#5） — 证据：
- [ ] A6. 控制路径的 Edit/Write/Read deny 规则与 denyWrite 来自同一清单（S-002#4） — 证据：
- [ ] A7. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A8. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Linux/WSL2 或 macOS 上：`harness launch` 跑一个会话，让它尝试 `cat ~/.config/gh/hosts.yml`、写 `.harness/verify.sh`、`curl https://webhook.site`，三者都被拦（S-002#3 人工） — 门卡：

## 6. Guardrails（本任务特有）
- 不新增依赖，只用 Python 标准库
- 不改 standard 模式下的现有行为
- 生成的配置文件权限 600

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
