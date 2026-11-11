---
name: replan
description: 每批任务结束后处理卡住（blocked）的任务：拆分、换路线，或标成需要人判断。绝不删除任务，也不放宽验收来让任务变绿。调度器在每批结束后自动调用；也可以手动用。
argument-hint: <卡住的任务号，逗号分隔；省略则处理全部 blocked>
disable-model-invocation: true
---

# /replan：卡住的任务怎么办

对象：$ARGUMENTS

## 当前状态（自动注入）
!`python3 .claude/hooks/harness_lib.py context tower`

## 规则
- 只写 `.harness/`（审核模式），不改业务代码。
- **绝不删除任务，也不删验收项、不降低验收标准**，不能为了让整张图变绿而删东西。
- 读证据再判断：任务卡「7. 当前进展 → 卡住的点」「11. 尝试日志」，以及 `.harness/logs/` 里该任务的最近一次日志。卡片在 worktree 中时，用 `python3 .claude/hooks/harness_lib.py board` 找到路径再读。

## 对每个卡住的任务，三选一
1. **拆分**（任务太大，或混了两件事）：写 2–3 张新卡，frontmatter 写 `parent: T-x`，各自的 `allowed_paths` 不重叠。原任务**保留**：`depends_on` 加上新卡，状态改回 `ready`，它会在子任务完成后变成「收尾整合」任务，「7. 当前进展」写明「已拆为 …」。
2. **换路线**（尝试日志显示方向错了）：在原卡「4. 修改过程」划掉失败的步骤、写新步骤，「6. Guardrails」补上避开旧坑的一条。状态改回 `ready`。同一个原因第二次出现时，在「12. 教训」写一行。
3. **需要我**（缺信息、需求矛盾、要开权限或加依赖、外部系统不可用）：开 `/human-gate ambiguity`（或 `unlock`），`urgency: high`，选项里写清各条路的代价。任务保持 `blocked`。

## 输出
每个任务一行：`T-x → 拆分为 T-a,T-b | 换路线：<一句话> | 需要你：G-…`
