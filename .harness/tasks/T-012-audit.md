---
id: T-012
title: 审计日志与审计页
status: ready
priority: P2
risk: medium
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-012-audit
worktree: .claude/worktrees/T-012
session: auto
depends_on: [T-008, T-010]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/audit_log.py, pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/guard_bash.py, pkg/.claude/hooks/protect_paths.py, pkg/.claude/settings.json, pkg/cli/serve_cmd.py, pkg/cli/doctor_cmd.py, pkg/plugin/build.sh, pkg/tests/test_audit.sh, pkg/tests/run.sh, plugins/harness/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-012 审计日志与审计页

## 1. 背景与目标
每次工具调用、护栏判定、门卡答复都留在仓库外的审计日志里，敏感值打码；看板带令牌时可按任务查看。

## 2. 范围
**做：**
- PostToolUse（全部工具）与护栏判定写 `$XDG_STATE_HOME/harness/<仓库>/audit/<日期>.jsonl`
- 打码规则见 S-002#15，含控制面配置里的 token 原文
- 看板「审计」页：按任务、按天，只在带令牌时显示

**不做（明确排除）：**
- 不上传任何日志
- 不记录文件全文，只记路径和截断后的命令

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 日志放哪里 | 仓库外，不进 git | spec §4 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新增 hook；settings 与插件 hooks.json 加一项；看板新增一页 | pkg/.claude/settings.json；pkg/plugin/build.sh |
| 风险 | medium：日志可能含敏感内容 | - |

**接口约定 v2（第 2 轮，tester 已写失败测试：pkg/tests/test_audit.sh「接口约定 v2」段）**
1. 打码在规范化副本上判断：URL 解码（%XX）、去掉引号 `'` `"`、去掉反斜杠换行、解码字面 `\uXXXX`；副本命中任一秘密规则 → 原文里对应的整段 token 样连续串（或整个 input 字段）打码；原文其余部分不改（如 `a%20b` 原样保留）。新增规则：`(token|access_token)[=: ]\S+`、`x-access-token[:@]`（含它的 URL userinfo 整段打码）、`\b\w*(PASS|SECRET|TOKEN|KEY)\w*=\S+`。Bash 命令里的 heredoc 正文丢弃，只留第一行。不误伤 `token-bucket`、`KEYBOARD`、`--pretty=%H`、`/task-run`。护栏判定行同样适用。
2. 审计写入不阻塞、不跟随链接：日文件以 `O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW|O_NONBLOCK` 打开，非普通文件拒写；state_dir 之下各级（audit 目录、日文件）lstat，是符号链接就不写（悬空链接也不创建目标）。FIFO 在日文件位置时 audit_log.py、guard_bash.py、protect_paths.py 都在 2 秒内退出且判定不变；read_audit 遇 FIFO 立即返回 []。
3. 保留期：每次写入时删除 audit/ 下文件名日期早于「今天 − HARNESS_AUDIT_DAYS」（默认 30）的 `YYYY-MM-DD.jsonl`（只删目录项本身，不跟随链接，不碰其他文件名）；`harness down --prune-audit` 做同样清理；`harness doctor` 新增「## 审计日志」段，报总大小（带单位）；`read_audit` 只读文件最后 2000 行（AUDIT_READ_MAX）再按任务过滤。
   → 需要把 `pkg/cli/doctor_cmd.py` 加进 allowed_paths（范围变更由协调者记录）。

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：打码规则逐条夹具测试；未带令牌访问审计页 403 — 结果：
- [ ] 2. 实现 hook 与页面 — 结果：
- [ ] 3. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 每次工具调用一行 JSON，含时间、会话、任务、工具、截断输入、判定（S-002#15） — 证据：
- [ ] A2. 打码夹具全部通过，含控制面 token 原文（S-002#15） — 证据：
- [ ] A3. 无令牌访问审计页返回 403（S-002#15） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 日志写入失败不阻塞工具调用
- 单行不超过 4 KB

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 加 `pkg/.claude/hooks/guard_bash.py`、`pkg/.claude/hooks/protect_paths.py`：护栏判定要写审计行（接口约定「护栏经共享的 H.audit(...) 写入」），各自只在 out()/deny() 里加一次 `H.audit_hook` 调用（失败吞掉，不影响判定）。
- 加 `plugins/harness/**`：发布用的插件目录由 `bash pkg/plugin/build.sh plugins/harness` 重新生成（hooks.json 带上 audit_log.py；test_plugin_install 检查它是最新的）。
- 第 2 轮加 `pkg/cli/doctor_cmd.py`（协调者已批准）：接口约定 v2 #3 要求 doctor 报审计日志大小、`harness down --prune-audit` 清理过期日志。
- 无依赖变更（只用标准库）。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | harness_lib 加 audit/audit_hook/mask_secrets/read_audit；先打码（含 telegram.json token 与 SCRUB/KEEP 环境变量原文）再按字节截断，跨 1 KB 的 token 不会半截泄露；护栏在 out()/deny() 里写判定；record_answer 写 via；看板 /audit 只认令牌 | audit_log.py、harness_lib.py、guard_bash.py、protect_paths.py、settings.json、serve_cmd.py | test_audit 95/95 一次通过 |
| 2 | 接口约定 v2：秘密规则在规范化副本（去引号、去反斜杠换行、%XX、\uXXXX）上匹配，命中处映射回原文的 token 样连续串打码；heredoc 正文丢弃；写入经 O_NOFOLLOW 目录 fd + O_NOFOLLOW/O_NONBLOCK 打开、非普通文件拒写；每次写入按 HARNESS_AUDIT_DAYS 删过期日文件（unlink 目录项）；read_audit 只读最后 2000 行；doctor「审计日志」段与 down --prune-audit | harness_lib.py、doctor_cmd.py | test_audit 141/141 |
| 3 | doctor 多出一段让 test_doctor「五段按序」失败（108/109）；假设：没有审计日志时不报这一段即可同时满足两边 | doctor_cmd.py：只在已有日文件时追加「## 审计日志」（放在最后） | test_doctor 109/109、test_audit 141/141 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
