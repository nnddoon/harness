---
id: T-023
title: 0.2.2 热修：JS 测试运行器的配置文件算验证入口
status: claimed
priority: P0
risk: medium
size: S
source: human
spec: S-003
test_owner: tester
branch: task/T-023-js-runner-configs
worktree: .claude/worktrees/T-023
session: auto
depends_on: []
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s003-review-r1.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/cli/doctor_cmd.py, pkg/tests/test_js_runners.sh, pkg/tests/test_control_paths.sh, pkg/tests/test_strict_hardening.sh, pkg/plugin/VERSION, pkg/plugin/RELEASED.json, pkg/README.md, plugins/harness/**, docs/feedback/s003-review-r1.md]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-023 0.2.2 热修：JS 测试运行器的配置文件算验证入口

## 1. 背景与目标
独立审查 R-1（见 `docs/feedback/s003-review-r1.md`）：verify.sh 跑 `npm run test`、`package.json` 写 `"test": "jest"` 时，任务分支**只改 `jest.config.js`**（`testMatch: []` + `passWithNoTests: true`）就能让验证永远通过：control-diff 不命中，strict 的 denyWrite 也没有它。原因是 `VERIFY_ENTRY_RULES` 识别到 npm 后只锁 `NPM_ENTRY`，没有往下看 test 脚本调用的运行器和它读的配置文件。用户决定做 0.2.2 热修（2026-11-15）。

目标：verify 脚本经由 npm/npx/pnpm/yarn/bun 能到达的 JS 测试运行器，其配置文件和脚本里直接调用的仓库文件都算验证入口；control-diff 命中、strict denyWrite 覆盖、doctor 能显示。

## 2. 范围
**做：**
- npm 类命令所在目录：读 `package.json`（control-diff 时读**基准版本**，不信任务分支），解析被调用的 script（`npm test` / `npm run X` / `npm t` / `yarn X` / `pnpm X` / `bun run X`，含 `pre*`/`post*` 钩子，以及 script 里再调用的 `npm run Y`，限深度）。
- script 里出现的运行器 → 加它的配置文件 glob（同目录）：jest、vitest（含 vite.config.*、vitest.workspace.*）、mocha、playwright、karma、cypress、ava、nyc、c8；任一 JS 运行器出现时再加 babel（`babel.config.*`、`.babelrc*`）。
- script 里显式的 `--config <路径>` / `-c <路径>` / `--config=<路径>` → 锁该路径；`node <路径>`、`./<路径>`、`bash|sh <路径>`、以及看起来是仓库文件的参数（含 `/` 或以 `.js/.mjs/.cjs/.ts/.mts/.cts/.sh` 结尾，且不以 `-` 开头）→ 锁该路径。
- 读不到 `package.json`、script 不存在、或无法判定运行器时，**保守**：加全部 JS 运行器配置 glob。
- `npx <runner>` / `pnpm exec <runner>` / `yarn <runner>` 直接在 verify 脚本里调用运行器时，同样加该运行器的配置。
- doctor 的「验证入口」列表显示这些路径（沿用现有输出）。
- VERSION 升到 0.2.2，重建插件与 RELEASED.json，README 记一行 0.2.2 变化。

**不做（明确排除）：**
- 不做推送前密钥扫描（R-2 → S-004）。
- 不处理 ambiguity auto 门卡残留（→ S-004）。
- 不改 Python / make / cargo / go 规则。

## 接口约定（tester 写，builder 照此实现；测试在 `pkg/tests/test_js_runners.sh`）

**改动的函数**（全在 `pkg/.claude/hooks/harness_lib.py`；签名只加可选参数，旧调用不变）
- 新常量：`JS_RUNNER_ENTRY: dict[runner, list[glob]]`、`JS_BABEL`、`JS_ALL`（全部运行器 glob ∪ babel ∪ `bunfig.toml`）。
- `_scan_verify_text(text, cur, follow, depth=0, pkg_read=None)`：npm 规则命中的段，在算出的目录 `d` 上额外调用新函数 `_npm_entries(seg, d, pkg_read) -> set`（相对仓库根的路径 / glob）。
- `_verify_scan(read, pkg_read=None)`：`pkg_read` 缺省 = `read`；所有 `package.json` 都经 `pkg_read` 读。
- `control_diff`：base 和 branch 两次扫描都传 `pkg_read = base 版本读取`（`_git_show(root, base, rel)`）——**package.json 只读基准提交**，分支里的 package.json 只作为被改的文件命中（它本来就在 `NPM_ENTRY`）。分支 package.json 推出的路径不进结果。
- `verify_entry_paths` / `verify_unknown_runners` / `stray_entries` / `strict_settings`：签名不变，读工作区里检出的文件（strict 仍是 worktree ∪ 主仓库）。`verify_unknown_runners` 行为不变。
- `pkg/cli/doctor_cmd.py`：新增一段 `## 验证入口文件`，`verify_entry_paths(main)` 非空时才出现，每行一个路径/glob（排序原样）；放在「验证入口」那一槽之后。原 `## 验证入口`（表外运行器）不变——只有已知运行器时仍**不**出现。

**运行器 → glob**（相对 `d`；任何一个 JS 运行器出现时再加 `JS_BABEL`）
| 运行器（命令词） | glob |
|---|---|
| jest | `jest.config.*` |
| vitest | `vitest.config.*` `vitest.workspace.*` `vite.config.*` |
| mocha | `.mocharc*` |
| playwright | `playwright.config.*` `playwright-ct.config.*` |
| karma | `karma.conf.*` |
| cypress | `cypress.config.*` `cypress.json` |
| ava | `ava.config.*` |
| nyc | `.nycrc*` `nyc.config.*` |
| c8 | `.c8rc*` |
| babel（随任一运行器） | `babel.config.*` `.babelrc*` |
| `bun test`；或命令是 bun 时 | `bunfig.toml` |
命令词 = 跳过 `VAR=值`、`env`、`cross-env`、`dotenv … --`、以及包装器（`npx [-y/--yes/-p X/--package X/--]`、`npm exec`、`pnpm exec|dlx`、`yarn dlx|exec`、`bunx`）后的第一个词，取 basename（`node_modules/.bin/jest` = jest）。`nyc` / `c8` 既是运行器也是包装器：其后的命令继续识别。只认命令词，`echo jest` 不算。

**怎么解析 script**（`_npm_entries`）
- 定位段里第一个 `npm|npx|pnpm|yarn|bun|bunx` 词；目录 `d` 沿用现有 `cd` / `-C` / `--prefix` / `--dir` / `--cwd` 处理；package.json = `d/package.json`。
- 运行 script 的形式：`npm test|t|tst`、`npm start|stop|restart`、`npm run|run-script|rum X`、`yarn [run] X`、`pnpm [run] X`（含 `pnpm -r X` 之类前置选项）、`bun run X`。`yarn X` / `pnpm X`：X 是 script → 解析；否则 X 是已知运行器 → 该运行器；否则走下面的规则。
- 不跑 script 的子命令（install/i/ci/add/remove/audit/ls/outdated/update/prune/pack/publish/version/config/init/create/why/cache/help 等，`npm run` 不带名字）→ 不加运行器 glob、不保守。
- 直接调用运行器：`npx|npm exec|pnpm exec|pnpm dlx|yarn dlx|bunx <运行器>`（verify 脚本里或 script 里）→ 该运行器 glob + babel。
- 钩子：script X 前后的 `preX` / `postX` 存在就一并解析（npm/yarn/pnpm/bun 一律按会跑处理）。
- script 文本按 `_SEP` 拆段、`shlex.split`（失败退回 `str.split`）；段里的 `npm run Y` / `yarn Y` / `pnpm Y` 等递归解析（同一 package.json，除非段里有 `cd` / `--prefix` 改目录），**嵌套深度 ≤ 3**（顶层 script 为 0）。超深 → 保守。遇到已访问的 (目录, script) 跳过（不报错、不死循环）。
- `cd sub && jest`（script 里）→ glob 放在 `d/sub`；越出仓库 → 保守。
- **锁的文件参数**（字面、相对 `d`、在仓库内）：`--config X` / `--config=X` / `-c X` / `--config-file X` / `--nycrc-path X` 的值（任何扩展名；非字面 → 保守）；`node [选项] <路径>` 的脚本路径（跳过 `-e/--eval/-p/--print` 及其值；路径无扩展名时再加 `<路径>.*`）；`./x`、`bash|sh x`；其余不以 `-` 开头、以 `.js .mjs .cjs .jsx .ts .mts .cts .tsx .sh .json` 结尾的字面词。不锁目录（以 `/` 结尾或无扩展名的位置参数）、不锁含通配的词。verify.sh 里直接 `node <路径>` 同样锁该路径。
- **保守分支**（加 `JS_ALL` 到 `d`）：package.json 存在但不是合法 JSON / 不是对象 / `scripts` 不是对象；要跑的 script 不存在；深度超限；非字面 config 值；**或整次调用（含钩子与嵌套）既没识别出运行器也没锁到任何文件**（如 `"test": "echo ok"`、`npx tsc`）。
- package.json **不存在**（读取返回 None）→ 只有现有的 `NPM_ENTRY`，不加运行器 glob（与 T-018 现有断言「npm run test → exactly the npm set」一致；新增 package.json 本身会命中）。
- 不处理 workspaces（`-w` / `--filter` / `-r` 不展开子包）；不改 Python / make / cargo / go 规则。

**发版**：`pkg/plugin/VERSION` = `0.2.2`；`bash pkg/plugin/build.sh plugins/harness --write-released` 重建插件并写 `RELEASED.json`（version 0.2.2）；`pkg/README.md` 「11. 版本变化」加 `### 0.2.2` 一节（一行写 JS 运行器配置算验证入口）。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 热修还是放 S-004 | 0.2.2 热修 | 用户 2026-11-15「R-1 做 0.2.2 热修」 |
| 判定不了运行器时 | 保守锁全部 JS 配置 glob | 推断（strict 宁可多锁，误锁只会多开一张 unlock 门卡） |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | `_scan_verify_text` / `_verify_scan` 的 npm 分支；control-diff 与 strict denyWrite 共用 `verify_entry_paths` | `pkg/.claude/hooks/harness_lib.py` VERIFY_ENTRY_RULES、_scan_verify_text |
| 风险 | medium（控制面判定；误放行即 strict 失效） | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester — 结果：写了「接口约定」与 `pkg/tests/test_js_runners.sh`（103 项，当前 31 通过 / 72 失败，`bash -n` 通过）；已有套件全绿（test-harness 344/344，pkg/tests 各套件全部通过）。
- [x] 2. 实现 — 结果：`harness_lib.py` 新增 `JS_RUNNER_ENTRY`/`JS_BABEL`/`JS_ALL`、`_JsScan` 与 `_npm_entries`（script 解析、pre/post、嵌套 ≤3、环、cd/--prefix、文件参数、保守分支），`_scan_verify_text`/`_verify_scan` 加 `pkg_read`，verify 里 `node <脚本>` 锁路径，npm 规则正则加 `bunx`；`control_diff` 两次扫描都用基准提交的 package.json；doctor 新增「验证入口文件」段；VERSION 0.2.2、README、插件与 RELEASED.json 重建。test_js_runners 103/103，test-harness 344/344，pkg/tests 其余 19 个套件全部 N/N。
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. R-1 复现脚本：只改 `jest.config.js` 的分支被 control-diff 命中；vitest / mocha / playwright 同类场景同样命中 — 证据：
- [ ] A2. strict 的 denyWrite 覆盖这些配置文件；doctor 显示它们 — 证据：
- [ ] A3. 任务分支改 `package.json` 的 scripts 去调用新文件，control-diff 仍以基准版本判定（package.json 本身也命中） — 证据：
- [ ] A4. plugin.json version 为 0.2.2，版本守卫测试通过 — 证据：
- [ ] A5. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A6. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 宁可多锁，不可漏锁；解析失败一律走保守分支。
- 控制面读 package.json 一律读基准提交，不读任务分支版本。

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）

## 9. 范围变更 / 依赖变更

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | npm 规则命中段在目录 d 上解析 package.json scripts 推出运行器配置即可；control-diff 只换 package.json 的读取源 | `_JsScan`/`_npm_entries`，`pkg_read` 贯穿扫描，doctor 段 | test_js_runners 96/103（仅 A11 发版项未做），其余套件绿 |
| 2 | A11 只差发版 | VERSION 0.2.2、README `### 0.2.2`、`build.sh --write-released` | 103/103；全部套件 N/N |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
