---
id: T-018
title: strict 加固：钥匙串、验证入口、连接器、locked_paths
status: ready
priority: P0
risk: high
size: M
source: human
spec: S-003
test_owner: tester
branch: task/T-018-strict-hardening
worktree: .claude/worktrees/T-018
session: auto
depends_on: []
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s002-field-test.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/tests/test_launch.sh, pkg/cli/doctor_cmd.py, pkg/scripts/harness-loop.sh, pkg/tests/test_strict_hardening.sh, pkg/tests/fake/**, plugins/harness/**, pkg/scripts/test-harness.sh]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-018 strict 加固：钥匙串、验证入口、连接器、locked_paths

## 1. 背景与目标
真机验收发现 strict 有四个洞：macOS 钥匙串里的 GitHub 凭证在沙箱内可读（F-2）、package.json 能改掉验证（F-3）、claude.ai 连接器可用（F-4）、任务 locked_paths 只靠 hook（F-10）。补上它们。

## 2. 范围
**做：**
- macOS strict 启动前检查钥匙串里无需授权可读的 GitHub 凭证（只查存在：`security find-generic-password -s gh:github.com`、`security find-internet-password -s github.com`，不带 -w），有则拒绝并给修复办法；HARNESS_ALLOW_KEYCHAIN=1 放行并标记；doctor 报告
- 从 verify.sh / quick-check.sh 推出验证入口清单文件，加进 CONTROL_PATHS 等价清单（沙箱 denyWrite + control-diff）
- strict 启动器：ENABLE_CLAUDEAI_MCP_SERVERS=false、--strict-mcp-config、permissions.deny 加连接器前缀
- --task 时把任务卡 locked_paths 加进 denyWrite 与 Edit/Write deny；control-diff 拒绝改了本任务 locked_paths 的分支

**不做（明确排除）：**
- 不改 Claude Code 沙箱实现
- 不处理任务自锁（T-021）

**接口约定（tester 按此写测试，builder 按此实现；测试：`pkg/tests/test_strict_hardening.sh`，调度器部分在 `pkg/scripts/test-harness.sh`「strict hardening (T-018)」一节）**

*钥匙串（F-2，A1）*
- `keychain_items(env=None) -> list[str]`：只在 `detect_platform() == "macos"`（`HARNESS_PLATFORM` 覆盖）时检查，其他平台直接 `[]`、**不调用**任何命令。依次运行 `${HARNESS_SECURITY:-security}`（按 PATH 解析）的两条命令，参数**恰好**是：
  `find-generic-password -s gh:github.com` → 命中记 `"gh:github.com"`；`find-internet-password -s github.com` → 命中记 `"github.com"`。
  绝不带 `-w` / `-g` / `-a` 等任何读取内容的参数；stdout/stderr 一律丢弃（不回显、不写日志）；超时 10 秒。退出码 0 = 存在；其他退出码、命令不存在（OSError）、超时 = 不存在。返回顺序固定 `["gh:github.com", "github.com"]` 的子集。
- `keychain_problem(env=None) -> str`：无命中返回 `""`；否则一行中文说明，必须包含：命中的项名（`gh:github.com` / `github.com`）；命中 gh 时含 `gh auth login --insecure-storage`（先 `gh auth logout`）；命中 github.com 时含 `git config --global --unset credential.helper`（并提到 osxkeychain）；以及「或设 `HARNESS_ALLOW_KEYCHAIN=1` 明确放行」。
- strict 启动（`launch --strict` 或 `HARNESS_UNATTENDED=1`）：在 `sandbox_problem` 之后检查。有命中且环境 `HARNESS_ALLOW_KEYCHAIN` 不等于字面 `1` → 退出码 3，stderr 为 `✗ strict 模式无法启动 Claude：<keychain_problem>`，不执行 claude。`HARNESS_ALLOW_KEYCHAIN=1` → 照常启动，stderr 打印一行警告，含 `HARNESS_ALLOW_KEYCHAIN=1` 与命中项名。standard 模式与 `--print-settings` 不检查（不调用 security）。
- `harness_lib.py sandbox-check`：先看 `sandbox_problem`，再看钥匙串。钥匙串有命中且未放行 → 打印 keychain_problem、退出 3；放行 → 打印上面的警告行（含 `HARNESS_ALLOW_KEYCHAIN=1`）、退出 0；都没有 → 打印 `ok`、退出 0。`sandbox_problem()` 本身不变（doctor「沙箱依赖」仍只报沙箱）。
- `harness-loop.sh`：沙箱检查失败照旧退出 3、不启动任何 claude；检查通过但输出不是 `ok`（钥匙串放行警告）→ 把这行原样打印到调度器输出（夜间模式另写进晨报）。
- `harness doctor`：仅 macos 时在「## 沙箱依赖」之后加一段「## 钥匙串」：无命中 → `ok`；有命中 → keychain_problem 那一行；若 `HARNESS_ALLOW_KEYCHAIN=1` → 另加一行含 `HARNESS_ALLOW_KEYCHAIN=1` 与 `已放行`。doctor 退出码仍为 0；非 macos 不出现这一段。

*验证入口文件（F-3，A2）*
- `verify_entry_paths(root) -> list[str]`：读 `root/.harness/verify.sh` 与 `root/.harness/quick-check.sh`（不存在就跳过），忽略去掉前导空白后以 `#` 开头的行，按下表（正则、`\b` 词边界）推出入口文件，返回**去重、排序**的相对路径字符串列表（不管文件存不存在）：
  | 命中 | 入口文件 |
  |---|---|
  | `\b(npm\|npx\|pnpm\|yarn\|bun)\b` | `package.json` |
  | `\bmake\b` | `Makefile`、`makefile`、`GNUmakefile` |
  | `\b(pytest\|tox\|nox)\b`，或 `\bpython[0-9.]*\s+-m\b` | `pyproject.toml`、`setup.cfg`、`tox.ini`、`noxfile.py`、`pytest.ini`、`conftest.py`（仓库根） |
  | `\bcargo\b` | `Cargo.toml` |
  | `\bgo\s+[a-z]` | `go.mod` |
  都不命中 → `[]`。
- strict 配置（task 角色，工作目录与主仓库各一份，入口清单取两处 `verify_entry_paths` 的并集）：每个入口文件都进 `permissions.deny` 的 `Edit(//<abs>)` / `Write(//<abs>)`；沙箱 `denyWrite` 只放**已存在**的入口文件（不存在的不放：沙箱会放 0 字节占位文件，空的 `pytest.ini` / `package.json` 会改变或弄坏工具行为；新建由 control-diff 拦）。已批准 unlock（`unlocked_paths`）对入口文件的放行规则与 CONTROL_PATHS 相同。verify.sh 不引用的清单文件（例如只有 `exit 0` 时的 package.json）不加。
- `control_diff`：入口清单 = base 与 branch 两个提交里的 verify.sh / quick-check.sh 推出的并集（分支删掉 `npm test` 也拦不掉 package.json）；diff 里出现入口文件（大小写 / Unicode 归一后精确比较）即命中，与控制路径一起排序输出。

*连接器（F-4，A3）*
- strict（task 与 plan 角色）：传给 claude 的环境设 `ENABLE_CLAUDEAI_MCP_SERVERS=false`（覆盖调用方原值）；argv = `[claude, "--settings", <文件>, *其余参数, "--strict-mcp-config"]`——追加在用户参数**末尾**，若其余参数里有 `--`，插在第一个 `--` 之前（现有假 claude 都按 `$2` 取提示词，不能插在前面）；`permissions.deny` 含 `mcp__claude_ai_*` 与 `mcp__claude_ai_Gmail`（常量 `CONNECTOR_DENY`，可再加其他已知 `mcp__claude_ai_<名>` 项）。`--print-settings` 的输出同样含这些 deny。standard 模式不加 flag、不改该环境变量。

*locked_paths 硬边界（F-10，A4）*
- `launch --strict --task <TID>`（task 角色）：locked_paths = 主仓库任务卡与工作目录任务卡（`.harness/tasks/<TID>-*.md`，各取排序后第一个）frontmatter `locked_paths` 的**并集**（Claude 改自己的卡只能多锁、不能解锁）。每项为相对工作目录的 glob（绝对路径或含 `..` 的项忽略）：
  - `permissions.deny` 加 `Edit(//<工作目录>/<glob>)`、`Write(//<工作目录>/<glob>)`（glob 原样）；
  - 沙箱 `denyWrite`：`X/**` → `//<工作目录>/X`（目录形式）；不含通配符 → `//<工作目录>/<路径>`（不存在也放，同控制路径；占位文件照旧写进 exclude）；其他通配 → 展开为工作目录里现有的匹配文件逐个列出（不把整个上级目录锁掉）。
  - 没有 `--task`、卡片找不到、或 `--role plan` → 不加。
- `control_diff(root, base, branch, task="")`：`task` 非空时，locked_paths = base 提交里的卡、branch 提交里的卡、主仓库工作区的卡三者 `locked_paths` 的并集；diff 文件名匹配任一 glob（同 `matches_any`，归一后比较）即命中。分支把自己卡上的 locked_paths 删掉也照样命中。
- CLI：`harness_lib.py control-diff [<base>] <branch> [--root DIR] [--task T-xxx]`；`--task` 缺值或不是 `T-\d{3,}` → 退出码 2。
- `harness-loop.sh`：`finish()` 与 `integrate()` 里的 control-diff 都带 `--task "$TID"`；命中照旧走 `ctl_block`（blocked + `G-<TID>-ctl` 门卡列出命中文件）。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 钥匙串怎么挡 | 沙箱只能放行 Mach 服务不能单独拒绝，所以改为不让凭证留在钥匙串里 | S-003 §2，claudeissues #40209/#45476 |
| 连接器开关 | claude CLI 有 ENABLE_CLAUDEAI_MCP_SERVERS 与 --strict-mcp-config | 本机 claude 2.1.323 --help / 二进制字符串 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | strict_settings / launch_argv / control_diff / doctor | harness_lib.py strict launcher 段 |
| 风险 | high：安全边界 | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester 写失败测试（假 security 命令、假 claude 记录 argv/env） — 结果：新增 pkg/tests/test_strict_hardening.sh 158 项（对 HEAD 111 项失败）、pkg/tests/fake/security；test-harness.sh「strict hardening (T-018)」15 项（11 项失败）；test_launch.sh A1 argv 断言按 §9 改（1 项失败）；其余套件全过，未提交
- [x] 2. 实现 — 结果：harness_lib 加 keychain_items/keychain_problem/keychain_check、verify_entry_paths、task_locked_paths、CONNECTOR_DENY；strict_settings/launch_argv/control_diff(task=)/control-diff --task/sandbox-check 按接口约定；doctor 加「## 钥匙串」；harness-loop 打印放行警告（夜间写晨报）、finish/integrate 带 --task；plugins/harness 重新生成。test_strict_hardening 158/158、test-harness 321/321、其余套件全过
- [ ] 3. 对抗审查 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. HARNESS_PLATFORM=macos 且假 security 报告存在 gh:github.com → strict 退出 3 且提示 --insecure-storage；HARNESS_ALLOW_KEYCHAIN=1 放行；检查命令不带 -w（S-003#1） — 证据：
- [ ] A2. verify.sh 含 npm run test 时 package.json 进 denyWrite 与 control-diff；Makefile / pyproject 同理（S-003#2） — 证据：
- [ ] A3. strict 启动 env 含 ENABLE_CLAUDEAI_MCP_SERVERS=false，argv 含 --strict-mcp-config，deny 含 mcp__claude_ai_ 前缀（S-003#3） — 证据：
- [ ] A4. 任务卡 locked_paths 进 denyWrite 与 Edit/Write deny；改 locked_paths 的分支 control-diff 命中（S-003#7） — 证据：
- [ ] A5. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A6. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Mac 上：钥匙串有 gh 凭证时 strict 拒绝；`gh auth login --insecure-storage` 后能启动且沙箱内 security 读不到 — 门卡：

## 6. Guardrails（本任务特有）
- 检查钥匙串时绝不读取凭证内容

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- builder：`pkg/.claude/hooks/gate_github.py` 的两处 `control_diff(main, "main", …)`（推送 / 开 PR 前）没带 `task=`，只查控制路径与入口文件、不查 locked_paths；该文件不在本任务 allowed_paths，未改

## 9. 范围变更 / 依赖变更
- tester（2026-11-14）：`--strict-mcp-config`（S-003#3）改变了 strict argv，`pkg/tests/test_launch.sh` 的「A1: claude args passed through after settings」由 `-p|hello` 改为 `-p|hello|--strict-mcp-config`（需求变化，断言仍是精确比较，未放宽）。为此把 `pkg/tests/test_launch.sh` 加进 allowed_paths（只改这一条断言）。
- tester：`pkg/scripts/test-harness.sh` 全局加 `HARNESS_SECURITY=<假 security，恒 exit 44>`，免得在真 Mac 上跑自测时读到真实钥匙串导致 macos 用例被拒（测试夹具，不改断言）。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定一次实现：钥匙串检查放在 launch_argv（sandbox_problem 之后，write 之前），入口文件 / locked_paths 加进 strict_settings 的 deny 与 denyWrite，control_diff 从 base/branch 提交读 verify.sh 与任务卡 | harness_lib.py、doctor_cmd.py、harness-loop.sh | 首跑 153/158（doctor 段缺失），补 doctor 后全绿 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
