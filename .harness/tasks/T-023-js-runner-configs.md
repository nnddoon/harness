---
id: T-023
title: 0.2.2 热修：JS 测试运行器的配置文件算验证入口
status: ready
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
- [ ] 1. tester — 结果：
- [ ] 2. 实现 — 结果：
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

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
