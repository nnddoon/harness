---
name: human-gate
description: 生成一张人工确认卡（设计决策、UI/UX、音频视频等感官测试、合并/部署等不可逆操作、外部影响、需求歧义、解锁冻结路径），先做机器预检再请人判断；也用于处理用户对门卡的答复（形如「G-T013-2: B」）。
argument-hint: <kind> <一句话问题>   或   G-Txxx-n: <选项> <备注>
---

# /human-gate

输入：$ARGUMENTS

规范见 `.claude/rules/human-gates.md`。先判断输入是「开门」还是「答复」。

## A. 开门
1. **去重**：搜 `.harness/decisions.md` 和 open 门卡，已有答案就沿用并引用编号，不开新门。
2. **预检**（按 kind，全部做完再开门）：
   - `ui`：启动本地服务；Playwright（或项目已有工具）截 375/768/1440 宽度截图，保存到 `.harness/gates/G-Txxx-n/`；关键流程逐步截图；跑 a11y 扫描（如 axe）；有改动前版本时并排对比。
   - `sensory`：音频用 ffprobe/ffmpeg 测时长、采样率、`loudnorm`/`ebur128` 响度、峰值与削波、静音段；视频/推流测分辨率、帧率、码率、GOP、丢帧、端到端延迟、音画同步。把样本切成 10–30 秒片段，A/B 对照命名为 `A.wav`/`B.wav` 等。
   - `design` / `ambiguity`：2–3 个方案的取舍表 + 推荐。
   - `irreversible`：diff 摘要、测试结果、dry-run、回滚方式；合并类附 PR 链接。
   - `external`：草稿全文和影响对象。
   - `unlock`：必须改的理由、受影响的下游任务、替代方案。
2b. **看能不能不问你**：跑 `python3 .claude/hooks/harness_lib.py gate-policy <kind>`。
   - 输出 `auto`（你已对这一类放权）：照常写卡，但 `status: answered`、`answer: <推荐项>`、`decided_by: auto`，decisions.md 记「自动（信任阶梯）」，不发通知、不阻塞任务。晨报会列出这些供你抽查。
   - 输出 `ask`：照常开门。irreversible / external / unlock 永远是 `ask`。
3. **写卡**：按 `.harness/gates/_TEMPLATE.md` 写 `.harness/gates/G-Txxx-n.md`（编号 = `G-<任务号去掉横线>-<序号>`，例如 T-013 的第 2 张是 `G-T013-2`，保证多个 worktree 并行时不撞号；groom 用 `G-GROOM-<日期>`）。问题写成选择题；「怎么检查」必须可复制执行；标推荐和默认行为；`recommended:` 必填（信任阶梯靠它统计）；`review_minutes:` 写你估计的分钟数（调度器按它限流）；「机器已预检」里写上对抗审查的结果（如有）。
4. **关联**：任务卡 `gates:` 加上编号，验收 B 对应条目写上门卡号。仅当剩余工作全依赖答复时任务改为 `waiting_human`。
5. **发布到 GitHub**：写好卡（`status: open`）后，PostToolUse hook 会自动把它开成 GitHub Issue（选项变成勾选框，素材目录会提交并推送后附链接），并把 Issue 号写回 `issue:`——之后要编辑门卡先重读。
   - 选项写成 `- **A（推荐）**：…` 的格式，hook 才能转成勾选框；批准类（irreversible/unlock/external）把「批准」放在 A。
   - 合并类门卡在 frontmatter 填 `pr: <PR 号>`，不会另开 Issue：PR 合并即批准、关闭即拒绝。
   - 确认任务卡或 spec 的门卡写 `then: ready`（只确认一个任务时用 `task:`；确认多个时写 `then_tasks: [T-a, T-b]`）：用户选了批准，这些任务就自动变成 `ready`。
   - 用户在 GitHub 勾选或回复邮件后，由 `scripts/gate-sync.sh` 写回门卡、`decisions.md` 和任务状态。
6. **通知**：
   - 交互式会话：用 AskUserQuestion 直接问（用户当场答了就按 B 处理，并在对应 Issue 留言「已在会话中答复：X」后关闭它）（问题 = 门卡标题，选项 = A/B/C，推荐放第一），同时告诉用户门卡路径和检查命令。用户当场答复就直接进入 B。
   - 无人值守：只写卡，在最终输出首行写 `NEEDS_HUMAN: G-Txxx-n <一句话>`。

## B. 处理答复（输入形如 `G-Txxx-n: B，备注`）
1. 更新门卡：`status`（approved / rejected / answered）、`answer:`。
1b. 门卡带 `then_policy` / `then_rules` 时：你不能替用户生效（相关文件被冻结，命令被拦）。告诉用户：在 GitHub 上勾选即可自动生效，或自己在终端跑 `python3 .claude/hooks/harness_lib.py apply-gate G-xxx`。
2. `.harness/decisions.md` 追加：`- D-xxx | <日期> | G-Txxx-n | <决定> | <备注/理由>`。
3. 相关任务：勾选对应验收 B 项（附「G-Txxx-n 已批准」），`waiting_human` → `in_progress`，继续 `/task-run`。
4. 若是 `irreversible` 合并且已批准：提醒用户合并方式（推荐：用户在 GitHub 上点合并）；用户要求 Claude 执行时，hook 会弹出确认，用户确认后执行，合并后任务改为 `done`。
