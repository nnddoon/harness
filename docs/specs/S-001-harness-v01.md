# S-001 Harness v0.1 自用版

> 已确认：D-001（2026-11-12，全部确认）。文档版：https://claude.ai/artifact/4TyHqR24qLpojETt4Tokb7

## 1. 目标
v0.1 = 现有 harness + `harness init` + 本地看板，让人只做决定、不碰配置。用它开发它自己两周，证明：想法到合并更快、被打断更少、亲手改配置趋近于零。

## 2. 非目标
手机原生 App（手机继续用 GitHub Issue）、云端托管与账号、ACP 多 agent、容器隔离、在规格文档上评论生成任务。

## 3. 场景
1. 接入：`harness init` 识别技术栈、生成配置，确认后提交，全程不打开配置文件。
2. 早上：`harness serve` 先看晨报，再答完「今天要你决定的」，合计 10 分钟内。
3. 一句需求跑到合并：`/task-align` → 确认 → 夜间跑完 → 看板「需求」页看每项验收的状态和证据 → 合并。

## 4. 架构
`.harness/` 文件是唯一事实来源。三个入口：本地看板（新）、GitHub Issue、Claude Code 会话；两个脚本：`harness init`（新）、调度器。看板与 GitHub 收件箱走同一套写回逻辑。
自举：产品源码在 `pkg/`，任务只改 `pkg/`；仓库自己的 `.claude/`、`.harness/` 是上一个稳定版装出来的副本，确认发版后才升级。

## 5. 指标（第一周基线，第二周对比）
想法到合并的中位时长（git log + 任务卡）；每天被打断次数（当天开的门卡，不含信任阶梯代决定）；亲手改配置次数（非 harness 提交中改动 verify.sh / quick-check.sh / allow-commands.txt / settings.json）。

## 6. 任务图
| 任务 | 批 | 依赖 | 风险 |
|---|---|---|---|
| T-001 harness init | 1 | - | low |
| T-002 harness serve 只读三屏 | 1 | - | low |
| T-006 三个指标 | 1 | - | low |
| T-003 看板答复门卡 | 2 | T-002 | high |
| T-004 需求页：状态与证据 | 2 | T-002 | medium |
| T-005 Claude Code 插件 | 3 | T-001 | medium |

## 7. 风险
看板被 Claude 用来自批（令牌 + 放权只走 GitHub/终端）；Windows（只用标准库）；越做越重（只做三屏）；平台风险（护城河在流程层）；额度（审阅预算、挑错用便宜模型）。
