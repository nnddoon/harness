# 决策记录

> 每个人工门的答复、每个重要的自主决定都记一行。开新门之前先搜这里，已决定的不重复问。
> 格式：`- D-xxx | 日期 | 来源(G-xxx/T-xxx) | 决定 | 理由`

- D-001 | 2026-11-12 | S-001 | approved: A（全部确认 S-001 与 T-001…T-006） | 产品仓库先在本地建，打包后推 GitHub
- D-002 | 2026-11-12 | G-INT-1112-1 | approved: A（第 1 批合进 main） | 用户在对话中确认：按推荐
- D-003 | 2026-11-12 | G-INT-1112-2 | approved: A（第 2 批合进 main） | 用户在对话中确认
- D-004 | 2026-11-12 | T-007 | approved: 新任务「插件一行安装」并在全绿后合进 main | 用户在对话中要求：打包插件一行安装
- D-005 | 2026-11-13 | G-S002-1 | answered: A（全部确认，按 3 批开工 — 后果：T-008/T-009/T-010 进 ready） — 用户在对话中选择（AskUserQuestion） | via 对话
- D-006 | 2026-11-13 | G-S002-2 | answered: A（只在无人值守时强制（夜间、接续、groom、replan），交互会话默认 standard、可选 strict — 后果：白天 Claude 还能自己推分支开 PR） — 用户在对话中选择（AskUserQuestion） | via 对话
- D-007 | 2026-11-13 | G-S002-3 | answered: A（允许：控制面的整合验证在 srt 沙箱里、无凭证地跑 — 后果：夜间整合仍有完整验证） — 用户在对话中选择（AskUserQuestion） | via 对话
- D-008 | 2026-11-13 | G-T008-1 | approved: A（spec/S-002 与 T-008 合进 main） | 用户在对话中选择（AskUserQuestion） | via 对话
- D-009 | 2026-11-14 | G-INT-S002 | approved: A（integration/S-002 合进 main） | 用户在对话中选择（AskUserQuestion） | via 对话
- D-010 | 2026-11-14 | G-S002-verify | approved: A（.harness/verify.sh 改为 set -eo pipefail，随合并提交） | 用户在对话中选择（AskUserQuestion） | via 对话
