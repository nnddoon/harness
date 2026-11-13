---
name: human-gate
description: 生成一张人工确认卡（设计决策、UI/UX、音频视频等感官测试、合并/部署等不可逆操作、外部影响、需求歧义、解锁冻结路径），先做机器预检再请人判断。Claude 只开卡；答复由用户在 GitHub、看板或自己的终端里给出，控制面写进答案库。
argument-hint: <kind> <一句话问题>
---

# /harness:human-gate

输入：$ARGUMENTS

规范见 `.claude/rules/human-gates.md`。你只开门卡；答案只认仓库外的答案库，由控制面写入（用户的终端、看板、GitHub）。
门卡上的 `status` / `answer` / `decided_by` 是控制面写的镜像：**你不写这三个字段**，改了也不生效，看板会标「答案不一致」。

## A. 开门
1. **去重**：搜 `.harness/decisions.md` 和还没答复的门卡（`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py board`），已有答案就沿用并引用编号，不开新门。
2. **预检**（按 kind，全部做完再开门）：
   - `ui`：启动本地服务；Playwright（或项目已有工具）截 375/768/1440 宽度截图，保存到 `.harness/gates/G-Txxx-n/`；关键流程逐步截图；跑 a11y 扫描（如 axe）；有改动前版本时并排对比。
   - `sensory`：音频用 ffprobe/ffmpeg 测时长、采样率、`loudnorm`/`ebur128` 响度、峰值与削波、静音段；视频/推流测分辨率、帧率、码率、GOP、丢帧、端到端延迟、音画同步。把样本切成 10–30 秒片段，A/B 对照命名为 `A.wav`/`B.wav` 等。
   - `design` / `ambiguity`：2–3 个方案的取舍表 + 推荐。
   - `irreversible`：diff 摘要、测试结果、dry-run、回滚方式；合并类附 PR 链接。
   - `external`：草稿全文和影响对象。
   - `unlock`：必须改的理由、受影响的下游任务、替代方案。
2b. **看会不会问用户**：跑 `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py gate-policy <kind>`。
   - 输出 `auto`（用户已对这一类放权）：照常写卡（`status: open`、写好 `recommended:`）。写卡后的 hook 由控制面按推荐项自动决定并写进答案库，不发通知、不阻塞任务；晨报列出供抽查。
   - 输出 `ask`：照常开门。irreversible / external / unlock 永远是 `ask`。
3. **写卡**：按 `.harness/gates/_TEMPLATE.md` 写 `.harness/gates/G-Txxx-n.md`（编号 = `G-<任务号去掉横线>-<序号>`，例如 T-013 的第 2 张是 `G-T013-2`，保证多个 worktree 并行时不撞号；groom 用 `G-GROOM-<日期>`）。问题写成选择题；「怎么检查」必须可复制执行；标推荐和默认行为；`recommended:` 必填（信任阶梯靠它统计）；`review_minutes:` 写你估计的分钟数（调度器按它限流）；「机器已预检」里写上对抗审查的结果（如有）。
4. **关联**：任务卡 `gates:` 加上编号，验收 B 对应条目写上门卡号。仅当剩余工作全依赖答复时任务改为 `waiting_human`。
5. **发布到 GitHub**：写好卡（`status: open`）后，PostToolUse hook 会自动把它开成 GitHub Issue（选项变成勾选框，素材目录会提交并推送后附链接），并把 Issue 号写回 `issue:`——之后要编辑门卡先重读。
   - 选项写成 `- **A（推荐）**：…` 的格式，hook 才能转成勾选框。**批准项固定是 A**（批准类 irreversible/unlock/external 选 A = 批准，其余 = 拒绝）；`approve_options` 不再生效。
   - 合并类门卡：PR 由调度器（控制面）为门卡开并记进答案库，PR 合并即批准、关闭即拒绝；你在卡上写的 `pr:` 不生效。
   - 确认任务卡或 spec 的门卡写 `then: ready`（只确认一个任务时用 `task:`；确认多个时写 `then_tasks: [T-a, T-b]`）：用户选了 A，这些任务就变成 `ready`。`then` 只认 `ready`。
   - 用户在 GitHub 勾选或回复邮件后，由 `scripts/gate-sync.sh` 写进答案库，再由控制面写门卡镜像、`decisions.md` 和任务状态。
6. **通知**：
   - 交互式会话：告诉用户门卡号、门卡路径、检查命令和三种答复方式（见 B）。不要替用户答复，也不要把对话里的话当答复写进门卡。
   - 无人值守：只写卡，在最终输出首行写 `NEEDS_HUMAN: G-Txxx-n <一句话>`。

## B. 用户怎么答复（你不写答案）
答案只认答案库，同一张门卡只认第一次。告诉用户任选其一：
- **GitHub**：在门卡 Issue 上勾一个选项，或回复通知邮件（第一行写选项字母）。
- **看板**：用终端里 `harness serve` 打印的带令牌地址打开，点选项。
- **终端**：用户自己运行 `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py answer G-Txxx-n <选项> [备注]`（你运行会被 hook 拦下）。

用户在对话里说了「G-Txxx-n: B」也一样：请他用上面任一方式答复，你不改门卡的 `status` / `answer` / `decided_by`，也不写 decisions.md。
答复入库后控制面会：写门卡镜像与 decisions.md（记 `via <通道>`）、`then: ready` 生效、`waiting_human` 的任务转 `in_progress` 并由下一次 gate-sync 接续。
门卡带 `then_policy` / `then_rules` 时：只在用户经 GitHub 或终端批准时生效；看板上不能批准。已批准但没生效时，请用户自己在终端跑 `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py apply-gate G-xxx`。
接续后：勾选任务卡里对应的验收 B 项（附「G-Txxx-n 已批准」，以 decisions.md 为准）再继续 `/harness:task-run`。
若是 `irreversible` 合并且已批准：提醒用户合并方式（推荐：用户在 GitHub 上点合并）；用户要求 Claude 执行时，hook 会弹出确认，用户确认后执行。
