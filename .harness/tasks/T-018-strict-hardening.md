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
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/gate_github.py, pkg/scripts/new-task.sh, pkg/tests/test_launch.sh, pkg/cli/doctor_cmd.py, pkg/scripts/harness-loop.sh, pkg/tests/test_strict_hardening.sh, pkg/tests/fake/**, plugins/harness/**, pkg/scripts/test-harness.sh]
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

**接口约定 v2（第 2 轮，tester；未写到的沿用上面 v1）**

*验证入口文件扩充（A2）*
- 入口表改为（仍按 `\b` 词边界、忽略注释行；返回值可以是路径**或 glob**，去重排序）：
  | 命中 | 入口 |
  |---|---|
  | `npm\|npx\|pnpm\|yarn\|bun` | `package.json`、`.npmrc`、`.yarnrc`、`.yarnrc.yml`、`.pnpmfile.cjs` |
  | `make` | `Makefile`、`makefile`、`GNUmakefile` |
  | `pytest\|tox\|nox`、`python[0-9.]* -m` | `pyproject.toml`、`setup.cfg`、`tox.ini`、`noxfile.py`、`pytest.ini`、`.pytest.ini`、`conftest.py`、`**/conftest.py` |
  | `python[0-9.]* -m X[.Y…]` | 另加 `X.py`、`X/**`（X = 模块名第一段，根目录下可遮蔽同名模块） |
  | `cargo` | `Cargo.toml`、`.cargo/config`、`.cargo/config.toml` |
  | `go <子命令>` | `go.mod`、`go.work` |
- 目录：`cd DIR`（行首或 `&&` / `;` / `||` 之后，DIR 为字面相对路径）对本行其后的命令和之后各行生效，直到下一个 `cd`；`cd` 的参数含 `$`、反引号或是绝对路径 → 回到仓库根。命令自带的 `-C DIR`（`make -C sub`、`go -C sub`）、`--prefix DIR` / `--prefix=DIR`（npm/pnpm）只对该命令生效。上表文件都加上 `DIR/` 前缀（规范化，不得含 `..`；越出仓库的忽略）。`pytest -c FILE` / `pytest -c=FILE` → 另加 `FILE`（相对当前 DIR）。
- 跟进脚本（只跟一层）：verify.sh / quick-check.sh 里以 `bash|sh|zsh [选项] PATH`、`source PATH`、`. PATH`、`./PATH`（字面路径，不含 `$`、`*`、反引号）调用的脚本：PATH（相对当前 DIR）本身是入口，且按同一规则解析它的内容（起始目录 = 调用处的 DIR）；它再调用的脚本不再跟进。带 `-n` 的 `bash -n PATH`（只做语法检查）不算调用。
- 沙箱 denyWrite：字面路径 → 存在才放；`X/**` → 目录 `X` 存在才放；其他 glob（如 `**/conftest.py`）→ 展开为现有匹配文件。Edit/Write deny：每个入口原样（glob 原样）。control-diff：入口按 glob 匹配（`matches_any`，归一后比较）。
- `harness doctor`：verify.sh / quick-check.sh（含跟进一层的脚本）里出现表外的运行器 `gradle gradlew mvn mvnw just deno rake bundle sbt bazel dotnet composer mix ant`（词边界）→ 多一段「## 验证入口」，每个运行器一行，含运行器名和「没有被保护」的提示（让人把它的配置文件加进 `.harness/locks.txt`）；没有表外运行器 → 不出现这一段。
- 未提交的入口文件：`harness_lib.py stray-entries --root <worktree>`：列出该 worktree 里**未跟踪或被忽略**（`git ls-files --others`，含 ignored）且匹配入口清单（worktree 与主仓库 verify 推出的并集）的文件，每行一个；有 → 退出 1，无 → 0，出错 → 2。`harness-loop.sh` 的 `finish()`：任务为 review/done 且 control-diff 通过后再跑它；命中 → backlog 置 blocked，输出一行含任务号、`未提交` 和文件名（不开 ctl 门卡）。

*连接器（A3）*
- strict 配置顶层加 `"disableClaudeAiConnectors": true`（task 与 plan、`--print-settings` 都有）；`--strict-mcp-config` 与 `ENABLE_CLAUDEAI_MCP_SERVERS=false` 保留。`CONNECTOR_DENY` 去掉无效的通配项 `mcp__claude_ai_*`（权限规则按服务器名精确匹配），保留具体名（含 `mcp__claude_ai_Gmail`）。

*钥匙串（A1）*
- 主机：`github.com` ∪ gh 的 hosts 配置（`$GH_CONFIG_DIR/hosts.yml`，否则 `${XDG_CONFIG_HOME:-~/.config}/gh/hosts.yml`）里顶格的主机名 ∪ 本仓库（launch 的 `--root` / doctor 的 `--repo` / sandbox-check 的 cwd）`origin` URL 的主机（`https://H/…`、`ssh://git@H/…`、`git@H:…`）。去重，github.com 在前，其余排序。
- 每个主机 H 依次查（参数恰好如此，仍不带 -w/-g）：`find-generic-password -s gh:H`、`find-internet-password -s H`、`find-generic-password -s git:https://H`（Git Credential Manager）；最后查 `find-generic-password -s Claude Code-credentials`（服务名含空格，作为一个参数）。
- 命中 GitHub 类项 → 拒绝（同 v1）；修复里：`gh:*` 提 `gh auth login --insecure-storage`（GHE 用 `--hostname H`）；互联网密码提 `git config --global --unset credential.helper`/osxkeychain；`git:https://*` 提 Git Credential Manager：`git config --global credential.credentialStore cache`（或 plaintext/gpg）并删除钥匙串项。消息里点名每个命中的服务名。
- `Claude Code-credentials` 命中 → **只警告不拒绝**：launcher stderr、`sandbox-check` 输出、doctor「## 钥匙串」都给一行，含 `Claude Code-credentials` 与 `CLAUDE_CODE_OAUTH_TOKEN`（建议无人值守用 `claude setup-token` 生成的 token、不留登录态在钥匙串）。只有它命中时 strict 照常启动（退出 0）。
- **失败即拒绝（spec 变更）**：只有退出码 44 = 不存在、0 = 存在；其他非零退出码、超时（`HARNESS_SECURITY_TIMEOUT` 秒，默认 10）、命令不存在/无法执行 → 拒绝 strict（退出 3），消息含 `无法检查钥匙串`、出错的服务名，以及退出码数字或 `超时` / `找不到`。`HARNESS_ALLOW_KEYCHAIN=1` 同样放行这种情况（并警告）。doctor「## 钥匙串」此时给出同一行（退出码仍 0）；`sandbox-check` 退出 3。

*控制路径检查的调用方都带任务号（A4）*
- `gate_github.py`：Claude 侧推资产（`_push_assets` 一类，分支 `task/T-xxx-…`）与 `push_assets_ctl` 的 `control_diff(main, "main", …)` 都传 `task=<从分支名取的 T-xxx>`；命中 locked_paths → 不推送。
- `new-task.sh`：建好/复用 worktree 后对分支 tip 的检查（第二次 control-diff）带 `--task "$TID"`；命中 → 删掉这次建的 worktree、blocked、退出非 0，stderr 列出文件。对基线（`HARNESS_BASE`）的检查不带任务号（基线上别的任务改这些路径是合法的）。

*locked_paths（A4）*
- frontmatter 的标量写法 `locked_paths: src/x/**` 等同 `[src/x/**]`（启动器、control-diff 都认）。
- `root == main` 且带 `--task`（在主仓库里直接跑任务）：locked_paths = 工作区卡 ∪ `git show HEAD:<卡>` 的并集（改工作区的卡解不了锁）。

**接口约定 v3（第 3 轮，tester；未写到的沿用 v1 / v2）**
- `stray-entries`：
  - 一律跳过路径中任一段是 `.venv`、`venv`、`node_modules`、`site-packages`、`.git` 的文件（不管是否被忽略）。
  - **glob 形式**的入口（含 `*`/`?`/`[`，如 `**/conftest.py`、`mytool/**`）只匹配**未被忽略**的未跟踪文件（`git ls-files --others --exclude-standard`）；被 .gitignore 忽略的不算（例如被忽略的 `build/conftest.py`）。
  - **字面路径**的入口（`GNUmakefile`、`pytest.ini`、`web/.npmrc` 等，含映射到子目录的）即使被忽略也算（`git ls-files --others` 含 ignored，或直接查这些路径是否存在且未跟踪）。
  - 输出排序、每行一个；不因大目录超时（只列这些候选，不遍历被跳过的目录）。
- npm / npx / pnpm / yarn / bun 的目录参数：`-C DIR`、`--dir DIR` / `--dir=DIR`（pnpm）、`--cwd DIR` / `--cwd=DIR`（yarn）、`--prefix DIR` / `--prefix=DIR`（npm/pnpm）都把该命令的 npm 组入口映射到 `DIR/`（`DIR/package.json`、`DIR/.npmrc` …），规则同 v2 的 `-C`。

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
- [x] 1. tester 写失败测试（假 security 命令、假 claude 记录 argv/env） — 结果：新增 pkg/tests/test_strict_hardening.sh 158 项（对 HEAD 111 项失败）、pkg/tests/fake/security；test-harness.sh「strict hardening (T-018)」15 项（11 项失败）；test_launch.sh A1 argv 断言按 §9 改（1 项失败）；其余套件全过，未提交；第 2 轮（接口约定 v2）：test_strict_hardening 增至 259 项（98 项失败），test-harness T-018 v2 6 项（5 项失败），未提交
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
- builder 第 2 轮（测试夹具，请 tester 处理）：① `A1 v2 security hangs` 两项：run() 的 PATH（$RB）里没有 `sleep`，假 security 的 `sleep 3` 直接失败、照常 exit 44，所以根本没有卡住；PATH 里有 sleep 时实现给出「无法检查钥匙串（gh:github.com：超时）」、退出 3（已手工验证）。② `A2 v2 python3 -m unittest -> unittest/**`：vhas 用 `grep -qx -- 'unittest/**'`（BRE），`/**` 匹配的是「零个或多个 /」，字面的 `unittest/**` 匹配不上；verify_entry_paths 的输出里确有 `unittest/**`（改 `grep -qxF` 即过）。
- tester 第 2 轮：已批准的 unlock 门卡能否解除任务 locked_paths（finding 7）不在本任务，转 T-021（与 F-9/F-12 一起处理：unlock 快照里的路径 ∩ locked_paths 才放行，且只在答案库批准后）。
- builder：（第 2 轮已转为本任务范围，见接口约定 v2）`pkg/.claude/hooks/gate_github.py` 的两处 `control_diff(main, "main", …)`（推送 / 开 PR 前）没带 `task=`，只查控制路径与入口文件、不查 locked_paths；该文件不在本任务 allowed_paths，未改

## 9. 范围变更 / 依赖变更
- tester（2026-11-14）：`--strict-mcp-config`（S-003#3）改变了 strict argv，`pkg/tests/test_launch.sh` 的「A1: claude args passed through after settings」由 `-p|hello` 改为 `-p|hello|--strict-mcp-config`（需求变化，断言仍是精确比较，未放宽）。为此把 `pkg/tests/test_launch.sh` 加进 allowed_paths（只改这一条断言）。
- tester：`pkg/scripts/test-harness.sh` 全局加 `HARNESS_SECURITY=<假 security，恒 exit 44>`，免得在真 Mac 上跑自测时读到真实钥匙串导致 macos 用例被拒（测试夹具，不改断言）。
- tester 第 2 轮（需求变化）：①钥匙串查询从 2 条增至每主机 3 条 + Claude Code 一条，test_strict_hardening 里「security 调用恰好 2 次」类断言改为对调用集合的精确比较；②失败即拒绝：「missing security binary → treated as absent」改为「→ 拒绝 3、提示无法检查」；test_launch.sh「A3: macos runs without bwrap/socat」的那次运行加 `HARNESS_SECURITY=<恒 44 的假命令>`（断言不变，只是夹具）；③去掉无效的 `mcp__claude_ai_*` 通配断言（plan 角色、--print-settings 两处一起），改断言 `disableClaudeAiConnectors`；④入口表扩充，npm/cargo/go 的「exactly」断言改为新的精确列表。allowed_paths 加 `pkg/scripts/new-task.sh`、`pkg/.claude/hooks/gate_github.py`（调用方带任务号）。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定一次实现：钥匙串检查放在 launch_argv（sandbox_problem 之后，write 之前），入口文件 / locked_paths 加进 strict_settings 的 deny 与 denyWrite，control_diff 从 base/branch 提交读 verify.sh 与任务卡 | harness_lib.py、doctor_cmd.py、harness-loop.sh | 首跑 153/158（doctor 段缺失），补 doctor 后全绿 |
| 2 | 接口约定 v2：钥匙串改为 keychain_scan（每主机 3 项 + Claude 项，只认 0/44，其他失败即拒绝）；入口推导改为按命令段解析（cd / -C / --prefix / -c、跟进一层脚本），入口可为 glob；strict 加 disableClaudeAiConnectors；stray-entries + finish() 拦未提交入口；gate_github / new-task 带任务号；标量 locked_paths、root==main 并 HEAD 卡 | harness_lib.py、doctor_cmd.py、harness-loop.sh、new-task.sh、gate_github.py | test_strict_hardening 256/259，test-harness 327/327，其余全过。剩 3 项是测试夹具问题（见 §8），实现侧已手工验证 |
| 3 | 接口约定 v3：stray-entries 分两路（字面入口用 --literal-pathspecs 只查这些路径、含被忽略的；glob 入口用 --exclude-standard 并排除 .venv/venv/node_modules/site-packages/.git），npm 组目录参数加 -C/--dir/--cwd | harness_lib.py | 第一次拼接误删了一段代码（NameError），从 HEAD 恢复后重做；test_strict_hardening 272/272，test-harness 327/327，其余全过 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
