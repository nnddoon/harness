---
id: G-T000-1
task: T-000
kind: ui                    # design | ui | sensory | irreversible | external | ambiguity | unlock
status: open                # 写卡时 open；approved | rejected | answered 由控制面按答案库写镜像（Claude 不改）
created:
urgency: normal             # low | normal | high（high：标题加 🔴、标签 urgency:high，可单独设通知）
recommended: A               # 推荐项（信任阶梯靠它和你的 answer 统计一致率）
decided_by: human            # 镜像：human | auto（放权类别由控制面按推荐自动决定；Claude 写 auto 无效）
review_minutes: 3            # 你大概要花几分钟（调度器按它限流：待审阅超过预算就不再开新任务）
default_if_no_answer: 继续按推荐方案开发，但不合并；任务保持 review
blocks: [T-000 步骤 5]       # 被阻塞的任务/步骤
answer:                      # 镜像：答案只认仓库外的答案库，由控制面写；Claude 不写
approve_options: [A]        # 已废弃、忽略：批准项固定是 A（irreversible/unlock/external 选 A=approved，其余=rejected）
then:                       # 可选：只认 ready——选了 A 时把任务（或 then_tasks）改成 ready；其他值忽略
then_policy:                # 可选：批准后放权某个门卡类别（例如 ui）；只在 GitHub 或终端由你批准时生效
then_rules: []              # 可选：批准后把这些原则写进 .claude/rules/lessons.md；同上
pr:                         # 忽略：PR 门卡只认控制面为它开的 PR（记在答案库）；合并=A，关闭=B
issue:                      # 由 hook 自动填写（GitHub Issue 号；门卡↔Issue 以答案库里的映射为准）
---

# G-T000-1 <一句话问题（尽量是选择题）>

**为什么需要你：** <一句话，机器为什么决定不了>

**预计耗时：** 3 分钟

## 怎么检查
```bash
<可直接复制的命令，例如：pnpm dev  →  打开 http://localhost:3000/player?demo=1>
```
1. <步骤 1>
2. <步骤 2>

素材：<截图/录屏/样本文件路径，例如 .harness/gates/G-T000-1/mobile-375.png>

## 机器已预检
| 项目 | 结果 | 通过 |
|---|---|---|
| 例：a11y 扫描 | 0 严重 / 2 轻微 | ✅ |
| 例：响度 | -16.2 LUFS（目标 -16±1） | ✅ |
| 对抗审查 | 3 个独立挑错，2 条成立已处理，1 条不成立 | ✅ |

## 选项
- **A（推荐）**：<方案> — 后果：<一句>
- **B**：<方案> — 后果：<一句>
- **C**：其他（请写备注）

**怎么答复：** 在 GitHub Issue 勾选 / 回复邮件，看板点选，或在你自己的终端运行 `harness_lib.py answer G-T000-1 A [备注]`。
