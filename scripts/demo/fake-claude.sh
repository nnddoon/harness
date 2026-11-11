#!/usr/bin/env bash
# Scripted stand-in for `claude -p`: writes what Claude would write at each step of the demo.
P="$2"; H=.claude/hooks
pub() { python3 -B $H/gate_github.py publish "$1" >/dev/null; }
if printf '%s' "$P" | grep -q '/task-align'; then
  cat > .harness/tasks/T-001-playback-rate.md <<'CARD'
---
id: T-001
title: 播放器倍速切换（0.5x–2x，记住上次选择）
status: proposed
priority: P1
risk: low
size: S
source: github#1
branch: task/T-001-playback-rate
worktree: .claude/worktrees/T-001
session: auto
depends_on: []
context_files: []
allowed_paths: [src/player/**, tests/player/**]
locked_paths: [src/player/events.ts]
unlock: []
gates: [G-T001-1]
auto_ok: no
---

# T-001 播放器倍速切换

## 1. 背景与目标
用户想用 1.5x/2x 快速听完长内容。做完后播放器可切换 0.5x–2x，刷新页面后保持上次选择。

## 2. 范围
**做：**
- 播放器控制栏加倍速选择器，档位 0.5 / 0.75 / 1 / 1.25 / 1.5 / 2
- 选择写入 localStorage，下次打开恢复

**不做（明确排除）：**
- 不做逐字稿同步、不改音频解码

## 3. 需求对齐记录
| 问题 | 结论 | 来源 |
|---|---|---|
| 档位还是滑杆 | 固定档位 | 推断（移动端好点按），待 G-T001-1 确认 |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. `usePlaybackRate` hook：读写 localStorage — 结果：
- [ ] 2. 控制栏加 `RateSelector` 组件 — 结果：
- [ ] 3. 补单元测试 + Playwright 截图 — 结果：
- [ ] 4. 完整验证 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 切到 1.5x 后刷新仍是 1.5x — 验证：`pnpm test player/rate` — 证据：
- [ ] A2. 已有测试全部通过，未删除/跳过 — 验证：`pnpm test` — 证据：
- [ ] A3. Lint/类型检查通过 — 验证：`pnpm lint && pnpm typecheck` — 证据：
- [ ] A4. 只改了 allowed_paths — 验证：`git diff --name-only origin/main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无：沿用现有控制栏样式）

## 6. Guardrails（本任务特有）
- 不改：`src/player/events.ts` 的 `onRateChange` 签名（统计模块订阅）
- 不引入新的 UI 库
CARD
  sed -e 's/T-001/T-002/g' -e 's/播放器倍速切换（0.5x–2x，记住上次选择）/文章语音朗读按钮（TTS）/' -e 's/^size: S/size: M/' \
      -e 's#^allowed_paths: .*#allowed_paths: [src/tts/**, src/article/ReadAloudButton.tsx, tests/tts/**]#' \
      -e 's#^locked_paths: .*#locked_paths: []#' -e 's/playback-rate/read-aloud/g' \
      .harness/tasks/T-001-playback-rate.md > .harness/tasks/T-002-read-aloud.md
  python3 - <<'PY'
p=".harness/backlog.md"; s=open(p,encoding="utf-8").read()
s=s.replace("- T-001 | proposed | P1 | 示例：播放器倍速切换 | deps: - | auto_ok: no | owner: -",
 "- T-001 | proposed | P1 | 播放器倍速切换 | deps: - | auto_ok: no | owner: -\n- T-002 | proposed | P1 | 文章语音朗读按钮（TTS） | deps: - | auto_ok: no | owner: -")
open(p,"w",encoding="utf-8").write(s)
PY
  for t in 1 2; do
    title=$([ $t = 1 ] && echo "确认 T-001 任务卡：播放器倍速切换（S，约 1 小时）" || echo "确认 T-002 任务卡：文章语音朗读按钮（M，约半天，含一次试听）")
    cat > .harness/gates/G-T00$t-1.md <<CARD
---
id: G-T00$t-1
task: T-00$t
kind: design
status: open
created: 2026-11-10
urgency: normal
recommended: A
default_if_no_answer: 保持 proposed，不开工
blocks: [T-00$t 全部]
answer:
approve_options: [A]
then: ready
pr:
issue:
---

# G-T00$t-1 $title

**为什么需要你：** 任务卡写好了，开工前请确认范围和验收。

**预计耗时：** 2 分钟

## 怎么检查
打开任务卡：\`.harness/tasks/T-00$t-*.md\`，看第 2 节「范围」和第 5 节「验收」。

## 选项
- **A（推荐）**：确认，按此执行
- **B**：要改（请留言写改哪里）
CARD
    pub .harness/gates/G-T00$t-1.md
  done
  exit 0
fi
if printf '%s' "$P" | grep -q '/backlog-groom'; then
  python3 - <<'PY'
p=".harness/backlog.md"; s=open(p,encoding="utf-8").read()
s=s.replace("## AI 提议区（/backlog-groom 写入，需批准；auto_ok: yes 的可自动转 ready）\n",
 "## AI 提议区（/backlog-groom 写入，需批准；auto_ok: yes 的可自动转 ready）\n"
 "- T-003 | ready | P2 | 补 RateSelector 键盘操作测试 | deps: - | auto_ok: yes | owner: -\n"
 "- T-004 | proposed | P1 | TTS 接口加限流与鉴权 | deps: - | auto_ok: no | owner: -\n")
open(p,"w",encoding="utf-8").write(s)
PY
  sed -e 's/T-000/T-003/g' -e 's/^status: proposed /status: ready    /' -e 's/^source: human /source: groom /' -e 's/^auto_ok: no /auto_ok: yes/' \
      -e 's#^allowed_paths: \[\]#allowed_paths: [tests/player/**]#' -e 's#^branch: .*#branch: task/T-003-rate-keyboard-tests#' \
      -e 's/^title: .*/title: 补 RateSelector 键盘操作测试/' .harness/tasks/_TEMPLATE.md > .harness/tasks/T-003-rate-keyboard-tests.md
  exit 0
fi
TID=$(printf '%s' "$P" | grep -o 'T-[0-9]\{3\}' | head -1)
CARD=$(ls .harness/tasks/$TID*.md)
setst() { sed -i.bak "s/^status: [a-z_]*/status: $1/" "$CARD"; rm -f "$CARD.bak"; }
close_task() {  # review + handoff + PR gate
  sed -i.bak 's/^- \[ \]/- [x]/' "$CARD"; rm -f "$CARD.bak"; setst review
  printf '# 交接包 %s\n\n- 变更摘要：完成，验收 A 全过，verifier PASS\n' "$TID" > .harness/handoffs/$TID.md
  n=$((10#${TID#T-})); k=$(ls .harness/gates/G-${TID//-/}-*.md 2>/dev/null | wc -l | tr -d ' '); g="G-${TID//-/}-$((k+1))"
  sed -e "s/G-T000-1/$g/g" -e "s/^task: T-000/task: $TID/" -e 's/^kind: ui /kind: irreversible /' -e "s/^pr: .*/pr: $n/" \
      .harness/gates/_TEMPLATE.md > .harness/gates/$g.md
  sed -i.bak "s/^# $g .*/# $g 合并 $TID 到 main？/" .harness/gates/$g.md; rm -f .harness/gates/$g.md.bak
  pub .harness/gates/$g.md
  git add -A >/dev/null; git commit -qm "$TID: done" >/dev/null
}
if [ "$TID" = T-002 ] && ! printf '%s' "$P" | grep -q '已答复'; then
  sed -i.bak '0,/^- \[ \] 1\./s//- [x] 1./; 0,/^- \[ \] 2\./s//- [x] 2./' "$CARD"; rm -f "$CARD.bak"
  mkdir -p .harness/gates/G-T002-2
  printf 'RIFF....WAVEfmt ' > .harness/gates/G-T002-2/A-voice-xiaoyu.wav; cp .harness/gates/G-T002-2/A-voice-xiaoyu.wav .harness/gates/G-T002-2/B-voice-yunxi.wav
  cat > .harness/gates/G-T002-2.md <<'CARD2'
---
id: G-T002-2
task: T-002
kind: sensory
status: open
created: 2026-11-10
urgency: normal
recommended: A
default_if_no_answer: 用 A，但不合并；任务保持 waiting_human
blocks: [T-002 步骤 3–4]
answer:
approve_options: [A]
then:
pr:
issue:
---

# G-T002-2 朗读用哪个声音？（各 20 秒，同一段文章）

**为什么需要你：** 两个声音的指标都达标，自然度只能靠耳朵判断。

**预计耗时：** 2 分钟

## 怎么检查
1. 依次播放 `A-voice-xiaoyu.wav`、`B-voice-yunxi.wav`（见下方素材）
2. 留意：断句是否自然、数字和英文读法

## 机器已预检
| 项目 | A | B | 目标 |
|---|---|---|---|
| 响度 | -16.1 LUFS | -15.8 LUFS | -16 ± 1 |
| 峰值 | -1.6 dBTP | -1.2 dBTP | ≤ -1 dBTP |
| 首字延迟 | 420 ms | 610 ms | ≤ 800 ms |

## 选项
- **A（推荐）**：晓语 — 首字更快，断句略机械
- **B**：云希 — 更自然，首字慢约 0.2 秒
- **C**：都不行（请留言）
CARD2
  pub .harness/gates/G-T002-2.md
  setst waiting_human
  git add -A >/dev/null; git commit -qm "$TID: wip, waiting for G-T002-2" >/dev/null
  echo '{"result":"NEEDS_HUMAN: G-T002-2 朗读用哪个声音？"}'
  exit 0
fi
close_task
